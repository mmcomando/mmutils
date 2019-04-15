module mmutils.hash_set_simd;

version (X86_64)  : import core.bitop;
import core.simd : ushort8;
import std.meta;
import std.traits;
import core.stdc.stdio;

/+
//There is some bug, maybe with not tracking deleting entries (ending is never true)

enum doNotInline = "version(DigitalMars)pragma(inline,false);version(LDC)pragma(LDC_never_inline);";
void doNotOptimize(Args...)(ref Args args)
{
	asm
	{
		naked;
		ret;
	}
} // function call overhead

version (DigitalMars)
{
	import core.bitop;

	alias firstSetBit = bsr; // DMD treats it as intrinsics
}
else version (LDC)
{
	import ldc.intrinsics;

	int firstSetBit(int i)
	{
		return llvm_cttz(i, true) + 1;
	}
}
else
{
	static assert("Compiler not supported.");
}

enum ushort emptyMask = 1;
enum ushort neverUsedMask = 2;
enum ushort hashMask = ushort.max - 1;
// lower 15 bits - part of hash, last bit - isEmpty
struct Control
{

	ushort b = neverUsedMask;

	bool isEmpty()
	{
		return (b & emptyMask) == 0;
	}

	bool isNeverUsed()
	{
		return (b & neverUsedMask) > 0;
	}

	/*void setEmpty(){
	 b=emptyMask;
	 }*/

	/*bool cmpHash(size_t hash){
	 union Tmp{
	 size_t h;
	 ushort[size_t.sizeof/2] d;
	 }
	 Tmp t=Tmp(hash);
	 return (t.d[0] & hashMask)==(b & hashMask);
	 }*/

	void set(size_t hash)
	{
		union Tmp
		{
			size_t h;
			ushort[size_t.sizeof / 2] d;
		}

		Tmp t = Tmp(hash);
		b = (t.d[3] & hashMask) | emptyMask;
		//writeln(b);
	}
}

// Hash helper struct
// hash is made out of two parts[     H1 48 bits      ][ H2 16 bits]
// whole hash is used to find group
// H2 is used to quickly(SIMD) find element in group
struct Hash
{
nothrow @nogc @safe:
	union
	{
		size_t h = void;
		ushort[size_t.sizeof / 2] d = void;
	}

	this(size_t hash)
	{
		h = hash;
	}

	size_t getH1()
	{
		Hash tmp = h;
		tmp.d[3] = d[3] & emptyMask; //clear H2 hash
		return tmp.h;
	}

	ushort getH2()
	{
		return d[3] & hashMask;
	}

	ushort getH2WithLastSet()
	{
		return d[3] | emptyMask;
	}

}

size_t defaultHashFunc(T)(auto ref T t)
{
	static if (isIntegral!(T))
	{
		return hashInt(t);
	}
	else
	{
		return hashInt(t.hashOf); // hashOf is not giving proper distribution between H1 and H2 hash parts
	}
}

// Can turn bad hash function to good one
ulong hashInt(ulong x) nothrow @nogc @safe
{
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9;
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb;
	x = x ^ (x >> 31);
	return x;
}

// Sets bits in ushort where value in control matches check value
// Ex. control=[0,1,2,3,4,5,6,7], check=2, return=0b0000_0000_0011_0000
private auto matchSIMD(ushort8 control, ushort check) @nogc
{
	// DMD has bug in release mode
	// https://issues.dlang.org/show_bug.cgi?id=18034
	version (DigitalMars)
	{
		import core.simd : __simd, ubyte16, XMM;

		ushort8 v = ushort8(check);
		ubyte16 ok = __simd(XMM.PCMPEQW, control, v);
		ubyte16 bitsMask = [1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128];
		ubyte16 bits = bitsMask & ok;
		ubyte16 zeros = 0;
		ushort8 vv = __simd(XMM.PSADBW, bits, zeros);
		ushort num = cast(ushort)(vv[0] + vv[4] * 256);
	}
	else version (LDC)
	{
		import ldc.simd: equalMask;

		ushort8 v = ushort8(check);
		ushort8 ok = equalMask!ushort8(control, v);
		version (X86)
		{
			import ldc.gccbuiltins_x86: __builtin_ia32_pmovmskb128;

			ushort num = cast(ushort) __builtin_ia32_pmovmskb128(ok);
		}
		else version (X86_64)
		{
			import ldc.gccbuiltins_x86: __builtin_ia32_pmovmskb128;

			ushort num = cast(ushort) __builtin_ia32_pmovmskb128(ok);
		}
		else
		{
			ushort num = 0;
			foreach (i; 0 .. 8)
			{
				if (control.ptr[i] == check)
				{
					num |= (0b11 << i * 2);
				}
			}
		}
	}
	else
	{
		ushort num = 0;
		foreach (i; 0 .. 8)
		{
			if (control.ptr[i] == check)
			{
				num |= (0b11 << i * 2);
			}
		}
	}
	return num;
}

// ADV additional value - used to implement HashMap without unnecessary copies
struct HashMap(T, Value, bool useFibP = false, alias hashFunc = defaultHashFunc)
{
	static assert(size_t.sizeof == 8); // Only 64 bit
	enum rehashFactor = 0.9;
	enum size_t getIndexEmptyValue = size_t.max;
	enum useFib = useFibP;

	static struct Group
	{
		union
		{
			Control[8] control;
			ushort8 controlVec;
		}

		T[8] elements;
		//Value[8] values;

		// Prevent error in Vector!Group
		bool opEquals()(auto ref const Group r) const
		{
			assert(0);
		}
	}

	void clear()
	{
		ggg = []; // TODO free
		vvv = []; // TODO free
		//eee = [];// TODO free
		addedElements = 0;
		markedDeleted = 0;
		rehashesNum = 0;
	}

	void reset()
	{
		ggg = []; // TODO free
		vvv = []; // TODO free
		//eee = [];// TODO free
		addedElements = 0;
		markedDeleted = 0;
		rehashesNum = 0;
	}

	Group[] ggg; // Length should be always power of 2
	Value[8][] vvv; // Length should be always power of 2
	//T[8][] eee; // Length should be always power of 2
	//Group[] groups; // Length should be always power of 2
	size_t addedElements; // Used to compute loadFactor
	size_t markedDeleted;
	int rehashesNum;

	float getLoadFactor(size_t forElementsNum)
	{
		if (ggg.length == 0)
		{
			return 1;
		}
		return cast(float) forElementsNum / (ggg.length * 8);
	}

	void rehash()
	{
		mixin(doNotInline);
		rehashesNum++;
		// Get all elements
		T[] allElements;
		allElements.reserve(ggg.length);
		Value[] allValues;
		allValues.reserve(ggg.length);
		foreach (ref Control c, ref T el, ref Value val; this)
		{
			allElements ~= el;
			allValues ~= val;
			c.b = neverUsedMask;
		}

		if (getLoadFactor(addedElements + 1) > rehashFactor)
		{ // Reallocate
			ggg.length = (ggg.length ? ggg.length : 1) << 1; // Power of two
			vvv.length = ggg.length;
			//eee.length =ggg.length;
		}
		markedDeleted = 0;
		// Insert elements
		foreach (i, ref el; allElements)
		{
			add(el, allValues[i]);
		}
		addedElements = allElements.length;
		assert(markedDeleted == 0);
		//allElements.clear();
	}

	size_t length()
	{
		return addedElements;
	}

	bool tryRemove(T el)
	{
		size_t index = getIndex(el);
		if (index == getIndexEmptyValue)
		{
			return false;
		}
		addedElements--;
		size_t group = index / 8;
		size_t elIndex = index % 8;
		ggg[group].control[elIndex].b = neverUsedMask;
		markedDeleted++;
		//TODO value destructor
		return true;
	}

	void remove(T el)
	{
		bool ok = tryRemove(el);
		assert(ok);
	}

	void add(T el, Value value)
	{
		//mixin(doNotInline);
		add(el, value);
	}

	void add(ref T el, Value value)
	{
		//mixin(doNotInline);
		if (isIn(el))
		{
			return;
		}

		if (getLoadFactor(addedElements + 1) > rehashFactor)
		{
			rehash();
		}
		if (getLoadFactor(length + markedDeleted) > rehashFactor)
		{
			rehash();
		}
		addedElements++;
		Hash hash = Hash(hashFunc(el));
		int group = hashMod(hash.h); // Starting point
		
		while (true)
		{
			Group* gr = &ggg[group];
			foreach (i, ref Control c; gr.control)
			{
				if (c.isEmpty)
				{
					if (!c.isNeverUsed)
					{
						writeln("a ", c.b);
						markedDeleted--;
					}
					c.set(hash.h);
					gr.elements[i] = el;
					//eee[group][i] = el;
					vvv[group][i] = value;
					return;
				}
			}
			group++;
			if (group >= ggg.length)
			{
				group = 0;
			}
		}
	}

	// Division is expensive but groups.length is power of two so use trick
	int hashMod(size_t hash) nothrow @nogc @system
	{
		static if (useFib)
		{
			Hash hhh = Hash(hash);
			//assert(hhh.getH1()<=562949953421312);
			//printf("Aval = %#lx\n", hhh.h);
			//printf("Bval = %#lx\n", hhh.getH1());
			//hhh.d[3]=0;
			//emptyMask
			ulong num = 11400714819323198485UL;
			//ulong num = 347922205179541;

			ulong mask = ggg.length - 1;
			return cast(int)((hhh.h * num) & mask);
			//return (hash * (ulong)11400714819323198485) >> 61;
		}
		else
		{
			Hash hhh = Hash(hash);
			//hhh.d[3]=0;
			return cast(int)(hhh.h & (ggg.length - 1));
		}

	}

	ref Value get(ref T el)
	{

		auto index = getIndexEmptyValue;
		assert(index != getIndexEmptyValue);
		return vvv[index / 8][index % 8];

	}

	bool isIn(ref T el)
	{
		//mixin(doNotInline);
		return getIndex(el) != getIndexEmptyValue;
	}

	bool isIn(T el)
	{
		//mixin(doNotInline);
		return getIndex(el) != getIndexEmptyValue;
	}

	// For debug
	int numA;
	int numB;
	int numC;

	size_t getIndex(T el) @system
	{
		size_t groupsLength = ggg.length;
		if (groupsLength == 0)
		{
			return getIndexEmptyValue;
		}
		auto gggg = ggg;
		//auto eeee=eee;

		Hash hash = Hash(hashFunc(el));
		size_t mask = groupsLength - 1;
		size_t group = hashMod(hash.h); //cast(int)(hash.h & mask); // Starting point	
		numA++;
		while (true)
		{
			numB++;
			Group* gr = &gggg[group];
			int cntrlV = matchSIMD(gr.controlVec, hash.getH2WithLastSet); // Compare 8 controls at once to h2
			while (cntrlV != 0)
			{
				numC++;
				int ffInd = firstSetBit(cntrlV);
				int i = ffInd / 2; // Find first set bit and divide by 2 to get element index
				//numA += gr.elements.ptr[i];
				if (gr.elements.ptr[i] == el) //	return 0;
				{

					return group * 8 + i;
				}
				cntrlV &= 0xFFFF_FFFF << (ffInd + 1);
			}
			/*foreach(i, e; gr.elements){
					if (!gr.control[i].isEmpty() &&  e == el)
				{

					return group * 8 + i;
				}
			}*/
			cntrlV = matchSIMD(gr.controlVec, neverUsedMask); // If there is neverUsed element, we will never find our element
			if (cntrlV != 0)
			{
				//numA++;
				return getIndexEmptyValue;
			}
			group++;
			group = group & mask;
		}

	}

	Value* opBinaryRight(string op)(T key)
	{
		static assert(op == "in");
		auto index = getIndex(key);
		if (index == getIndexEmptyValue)
		{
			return null;
		}
		return &vvv[index / 8][index % 8];
	}

	ref Value opIndex(T key)
	{
		return get(key);
	}

	void opIndexAssign(Value value, T key)
	{
		add(key, value);
	}

	// foreach support
	int opApply(DG)(scope DG dg)
	{
		int result;
		foreach (g, ref Group gr; ggg)
		{
			foreach (i, ref Control c; gr.control)
			{
				if (c.isEmpty)
				{
					continue;
				}

				result = dg(gr.control[i], gr.elements[i], vvv[g][i]);

				if (result)
					break;
			}
		}

		return result;
	}

	void saveGroupDistributionPlot(string path)
	{
		int[] data;
		data.length = ggg.length;

		foreach (ref Control c, ref T el, ref Value val; this)
		{
			int group = hashMod(hashFunc(el));
			data[group]++;
		}

		FILE* file = fopen(path.ptr, "w");
		scope (exit)
			fclose(file);

		foreach (i, int d; data)
		{
			fprintf(file, "%lu %d\n", i, d);
		}

	}

}

@nogc nothrow pure unittest
{
	ushort8 control = 15;
	control.array[0] = 10;
	control.array[7] = 10;
	ushort check = 15;
	ushort ret = matchSIMD(control, check);
	assert(ret == 0b0011_1111_1111_1100);
}

unittest
{
	HashMap!(int, bool) set;

	assert(set.isIn(123) == false);
	set.add(123, true);
	set.add(123, true);
	assert(set.markedDeleted == 0);
	assert(set.isIn(123) == true);
	assert(set.isIn(122) == false);
	assert(set.addedElements == 1);
	set.remove(123);
	assert(set.markedDeleted == 1);
	assert(set.isIn(123) == false);
	assert(set.addedElements == 0);
	assert(set.tryRemove(500) == false);
	set.add(123, true);
	assert(set.tryRemove(123) == true);
	assert(set.rehashesNum == 1);
	set.clear();
	foreach (k; 0 .. 100)
	{
		foreach (i; 0 .. 100)
			set.add(i, true);
		foreach (i; 0 .. 100)
			assert(set.isIn(i));
		foreach (i; 100 .. 500)
			assert(!set.isIn(i));
		assert(set.ggg.length == 16);
		assert(set.rehashesNum == 4);
	}

	foreach (i; 0 .. 1_000_000) //while(true)
	{
		import std.random: uniform;

		set.add(uniform(-10_000, 10_000), true);
		set.tryRemove(uniform(-10_000, 10_000));
	}

	//foreach (int el; set) {
	//	assert(set.isIn(el));
	//}
}

import std.stdio;

/// Test case when there is no ending mark
unittest
{
	ulong hashFunc(int el)
	{
		return el;
	}

	HashMap!(int, bool, false, hashFunc) map;
	foreach (i; 0 .. 8)
		map.add(i * 2, true);
	foreach (i; 0 .. 8)
		map.remove(i * 2);

	assert(map.length == 0);

	foreach (i; 0 .. 8)
		map.add(i * 2 + 1, true);
	foreach (i; 0 .. 8)
		map.remove(i * 2 + 1);

	assert(map.length == 0);

	bool isNeverUsedElement = false;
	foreach (gr; map.ggg)
	{
		isNeverUsedElement = isNeverUsedElement || matchSIMD(gr.controlVec, neverUsedMask) > 0;
	}
	assert(isNeverUsedElement);

	assert(map.ggg.length == 2);
	assert(!map.isIn(100));
}

uint[] getRandomNumbers(size_t length, uint min, uint max)
{
	import std.random: Random, uniform;

	auto rnd = Random(0);
	uint[] numbers;
	numbers.length = length;
	foreach (ref n; numbers)
		n = uniform(min, max, rnd);

	FILE* file = fopen("test_numbers.bin", "wb"); // w for write, b for binary
	fwrite(numbers.ptr, numbers.length * 4, 1, file); // write 10 bytes from our buffer
	fclose(file);

	return numbers;
}

void benchmarkHashSetInt()
{
	HashMap!(int, bool) set;
	int[int] mapStandard;
	uint elementsNumToAdd = cast(uint)(64536 * 0.8);
	// Add elements
	foreach (int i; 0 .. elementsNumToAdd)
	{
		set.add(i, true);
		mapStandard[i] = true;
	}
	// Check if isIn is working
	foreach (int i; 0 .. elementsNumToAdd)
	{
		assert(set.isIn(i));
		assert((i in mapStandard) !is null);
	}
	// Check if isIn is returning false properly
	foreach (int i; elementsNumToAdd .. elementsNumToAdd + 10_000)
	{
		assert(!set.isIn(i));
		assert((i in mapStandard) is null);
	}
	//set.numA=set.numB=set.numC=0;
	enum itNum = 100;
	//BenchmarkData!(2, itNum) bench;
	doNotOptimize(set); // Make some confusion for compiler
	doNotOptimize(mapStandard);
	ushort myResults;
	myResults = 0;
	//benchmark standard library implementation
	foreach (b; 0 .. itNum)
	{
		//bench.start!(1)(b);
		foreach (i; 0 .. 1000_000)
		{
			auto ret = myResults in mapStandard;
			myResults += 1 + cast(bool) ret; //cast(typeof(myResults))(cast(bool)ret);
			doNotOptimize(ret);
		}
		//bench.end!(1)(b);
	}

	auto stResult = myResults;
	//benchmark this implementation
	myResults = 0;
	foreach (b; 0 .. itNum)
	{
		//bench.start!(0)(b);
		foreach (i; 0 .. 1000_000)
		{
			auto ret = set.isIn(myResults);
			myResults += 1 + ret; //cast(typeof(myResults))(ret);
			doNotOptimize(ret);
		}
		//bench.end!(0)(b);
	}
	assert(myResults == stResult); // Same behavior as standard map
	//writeln(set.getLoadFactor(set.addedElements));
	//writeln(set.numA);
	//writeln(set.numB);
	//writeln(set.numC);

	doNotOptimize(myResults);
	//bench.plotUsingGnuplot("test.png", ["my", "standard"]);
	set.saveGroupDistributionPlot("distribution_this.png");
}

import core.sys.posix.time;

void benchmarkHashSetPerformancePerElement()
{
	struct BD
	{
		size_t elementsNum;
		float time;
	}

	ushort trueResults;
	doNotOptimize(trueResults);

	enum itNum = 1_00;
	enum startingNum = 0;
	//enum numToAdd = 16 * 8;
	enum numToAdd = 8;
	enum someNum = 9_213_146;
	enum numbersNum = startingNum + itNum * numToAdd;

	HashMap!(uint, bool, false) map;
	HashMap!(uint, bool, true) mapFib;
	bool[int] mapStandard;

	uint[] numbers = getRandomNumbers(numbersNum, uint.min, uint.max);

	timespec start;
	timespec end;

	void testMap(bool myMap, T)(ref T map, string outputDataFile, string distributionFile)
	{
		size_t lastAdded = startingNum;
		BD[] data;
		data.length = itNum;
		foreach (b; 0 .. itNum)
		{
			foreach (i; 0 .. startingNum)
			{
				uint n = numbers[i] * someNum;
				map[n] = true;
			}
			foreach (i; lastAdded .. lastAdded + numToAdd)
			{
				uint n = numbers[i] * someNum;
				map[n] = true;
			}
			lastAdded += numToAdd;

			static if (myMap)
			{
				map.numA = 0;
				map.numB = 0;
				map.numC = 0;
				map.saveGroupDistributionPlot(distributionFile);
			}

			clock_gettime(CLOCK_MONOTONIC, &start);
			/*foreach (i; 0 .. elementsToTest)
			{
				auto ret = i in map;
				trueResults += ret != null; //cast(typeof(trueResults))(cast(bool)ret);
				doNotOptimize(ret);
			}*/
        for (int kkk = 0; kkk < 1000; kkk++)
			foreach (i; 0 .. lastAdded)
			{
				uint n = numbers[i];
				n *= someNum;
				auto ret = n in map;
				//assert(ret != null);
				trueResults += ret != null; //cast(typeof(trueResults))(cast(bool)ret);
				doNotOptimize(ret);
			}

			clock_gettime(CLOCK_MONOTONIC, &end);
			data[b].elementsNum = lastAdded;
			data[b].time = ((end.tv_nsec - start.tv_nsec) + (
					end.tv_sec - start.tv_sec) * 1_000_000_000) / 1_000_000_000.0f;
		}

		FILE* file = fopen(outputDataFile.ptr, "w");
		foreach (i, d; data)
			fprintf(file, "%lu %f\n", d.elementsNum, d.time);
		fclose(file);

		static if (myMap)
		{
			writeln(map.numA);
			writeln(map.numB);
			writeln(map.numC);
			writeln("---------------");
		}

	}

	doNotOptimize(trueResults);

	testMap!(true)(map, "time_this.data", "distribution_this.data");
	testMap!(true)(mapFib, "time_this_fib.data", "distribution_this_fib.data");
	testMap!(false)(mapStandard, "time_d_std.data", "");

}

// void main()
// {
// 	benchmarkHashSetPerformancePerElement();
// }
///home/pc/dlang/ldc2-1.13.0/bin/ldc2 -O2 -g  hash_map_simd.d ; ./hash_map_simd ; gnuplot compare.gnuplot ; gnuplot distribution.script
//convert compare.png distribution.png  -append result.png


+/