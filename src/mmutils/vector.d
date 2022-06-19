module mmutils.vector;

import core.bitop;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, memset;
import std.algorithm : swap;
import std.conv : emplace;
import std.traits : hasMember, isCopyable, TemplateOf, Unqual;


@nogc @safe nothrow pure size_t nextPow2(size_t num) {
	return 1 << bsr(num) + 1;
}

__gshared size_t gVectorsCreated = 0;
__gshared size_t gVectorsDestroyed = 0;

struct Vector(T) {
	T[] array;
	size_t used;
public:

	this()(T t) {
		add(t);
	}

	this(X)(X[] t) if (is(Unqual!X == Unqual!T)) {
		add(t);

	}

	static if (isCopyable!T) {
		this(this) {
			T[] tmp = array[0 .. used];
			array = null;
			used = 0;
			add(tmp);
		}
	} else {
		@disable this(this);
	}

	~this() {
		clear();
	}

	void clear() {
		removeAll();
	}

	void removeAll() {
		if (array !is null) {
			foreach (ref el; array[0 .. used]) {
				destroy(el);
			}
			freeData(cast(void[]) array);
			gVectorsDestroyed++;
		}
		array = null;
		used = 0;
	}

	bool empty() {
		return (used == 0);
	}

	size_t length() {
		return used;
	}

	void length(size_t newLength) {
		if (newLength > used) {
			reserve(newLength);
			foreach (ref el; array[used .. newLength]) {
				emplace(&el);
			}
		} else {
			foreach (ref el; array[newLength .. used]) {
				destroy(el);
			}
		}
		used = newLength;
	}

	void reset() {
		used = 0;
	}

	void reserve(size_t numElements) {
		if (numElements > array.length) {
			extend(numElements);
		}
	}

	size_t capacity() {
		return array.length - used;
	}

	void extend(size_t newNumOfElements) {
		auto oldArray = manualExtend(array, newNumOfElements);
		if (oldArray !is null) {
			freeData(oldArray);
		}
	}

	@nogc void freeData(void[] data) {
		// 0x0F probably invalid value for pointers and other types
		memset(data.ptr, 0x0F, data.length); // Makes bugs show up xD 
		free(data.ptr);
	}

	static void[] manualExtend(ref T[] array, size_t newNumOfElements = 0) {
		if (newNumOfElements == 0)
			newNumOfElements = 2;
		if (array.length == 0)
			gVectorsCreated++;
		T[] oldArray = array;
		size_t oldSize = oldArray.length * T.sizeof;
		size_t newSize = newNumOfElements * T.sizeof;
		T* memory = cast(T*) malloc(newSize);
		memcpy(cast(void*) memory, cast(void*) oldArray.ptr, oldSize);
		array = memory[0 .. newNumOfElements];
		return cast(void[]) oldArray;
	}

	Vector!T copy()() {
		Vector!T duplicate;
		duplicate.reserve(used);
		duplicate ~= array[0 .. used];
		return duplicate;
	}

	bool canAddWithoutRealloc(uint elemNum = 1) {
		return used + elemNum <= array.length;
	}

	void add()(T t) {
		if (used >= array.length) {
			extend(nextPow2(used + 1));
		}
		emplace(&array[used], t);
		used++;
	}

	/// Add element at given position moving others
	void add()(T t, size_t pos) {
		assert(pos <= used);
		if (used >= array.length) {
			extend(array.length * 2);
		}
		foreach_reverse (size_t i; pos .. used) {
			swap(array[i + 1], array[i]);
		}
		emplace(&array[pos], t);
		used++;
	}

	void add(X)(X[] t) if (is(Unqual!X == Unqual!T)) {
		if (used + t.length > array.length) {
			extend(nextPow2(used + t.length));
		}
		foreach (i; 0 .. t.length) {
			emplace(&array[used + i], t[i]);
		}
		used += t.length;
	}

	void remove(size_t elemNum) {
		destroy(array[elemNum]);
		swap(array[elemNum], array[used - 1]);
		used--;
	}

	void removeStable()(size_t elemNum) {
		used--;
		foreach (i; 0 .. used) {
			array[i] = array[i + 1];
		}
	}

	bool tryRemoveElement()(T elem) {
		foreach (i, ref el; array[0 .. used]) {
			if (el == elem) {
				remove(i);
				return true;
			}
		}
		return false;
	}

	void removeElement()(T elem) {
		bool ok = tryRemoveElement(elem);
		assert(ok, "There is no such an element in vector");
	}

	ref T opIndex(size_t elemNum) {
		assert(elemNum < used, "Range violation [index]");
		return array.ptr[elemNum];
	}

	auto opSlice() {
		return array.ptr[0 .. used];
	}

	T[] opSlice(size_t x, size_t y) {
		assert(y <= used);
		return array.ptr[x .. y];
	}

	size_t opDollar() {
		return used;
	}

	void opAssign(X)(X[] slice) {
		reset();
		this ~= slice;
	}

	void opOpAssign(string op)(T obj) {
		static assert(op == "~");
		add(obj);
	}

	void opOpAssign(string op, X)(X[] obj) {
		static assert(op == "~");
		add(obj);
	}

	void opIndexAssign()(T obj, size_t elemNum) {
		assert(elemNum < used, "Range viloation");
		array[elemNum] = obj;
	}

	void opSliceAssign()(T[] obj, size_t a, size_t b) {
		assert(b <= used && a <= b, "Range viloation");
		array.ptr[a .. b] = obj;
	}

	bool opEquals()(auto ref const Vector!(T) r) const {
		return used == r.used && array.ptr[0 .. used] == r.array.ptr[0 .. r.used];
	}

	size_t toHash() const nothrow @trusted {
		return hashOf(cast(Unqual!(T)[]) array.ptr[0 .. used]);
	}

	import std.format : FormatSpec, formatValue;

	/**
	 * Preety print
	 */
	void toString(scope void delegate(const(char)[]) sink, FormatSpec!char fmt) {
		static if (__traits(compiles, formatValue(sink, array[0 .. used], fmt))) {
			formatValue(sink, array[0 .. used], fmt);
		}
	}

}

// Helper to avoid GC
private T[n] s(T, size_t n)(auto ref T[n] array) pure nothrow @nogc @safe {
	return array;
}

@nogc nothrow unittest {
	Vector!int vec;
	assert(vec.empty);
	vec.add(0);
	vec.add(1);
	vec.add(2);
	vec.add(3);
	vec.add(4);
	vec.add(5);
	assert(vec.length == 6);
	assert(vec[3] == 3);
	assert(vec[5] == 5);
	assert(vec[] == [0, 1, 2, 3, 4, 5].s);
	assert(!vec.empty);
	vec.remove(3);
	assert(vec.length == 5);
	assert(vec[] == [0, 1, 2, 5, 4].s); //unstable remove
}

@nogc nothrow unittest {
	Vector!int vec;
	assert(vec.empty);
	vec ~= [0, 1, 2, 3, 4, 5].s;
	assert(vec[] == [0, 1, 2, 3, 4, 5].s);
	assert(vec.length == 6);
	vec ~= 6;
	assert(vec[] == [0, 1, 2, 3, 4, 5, 6].s);

}

@nogc nothrow unittest {
	Vector!int vec;
	vec ~= [0, 1, 2, 3, 4, 5].s;
	vec[3] = 33;
	assert(vec[3] == 33);
}

@nogc nothrow unittest {
	Vector!char vec;
	vec ~= "abcd";
	assert(vec[] == cast(char[]) "abcd");
}

@nogc nothrow unittest {
	Vector!int vec;
	vec ~= [0, 1, 2, 3, 4, 5].s;
	vec.length = 2;
	assert(vec[] == [0, 1].s);
}
///////////////////////////////////////////

enum string checkVectorAllocations = `
//assert(gVectorsCreated==gVectorsDestroyed);
gVectorsCreated=gVectorsDestroyed=0;
scope(exit){if(gVectorsCreated!=gVectorsDestroyed){	
	import std.stdio : writefln;
	writefln("created==destroyed  %s==%s", gVectorsCreated, gVectorsDestroyed);
	assert(gVectorsCreated==gVectorsDestroyed, "Vector memory leak");
}}
`;

unittest {
	mixin(checkVectorAllocations);
	Vector!int vecA = Vector!int([0, 1, 2, 3, 4, 5].s);
	assert(vecA[] == [0, 1, 2, 3, 4, 5].s);
	Vector!int vecB;
	vecB = vecA;
	assert(vecB[] == [0, 1, 2, 3, 4, 5].s);
	assert(vecB.array.ptr != vecA.array.ptr);
	assert(vecB.used == vecA.used);
	Vector!int vecC = vecA;
	assert(vecC[] == [0, 1, 2, 3, 4, 5].s);
	assert(vecC.array.ptr != vecA.array.ptr);
	assert(vecC.used == vecA.used);
	Vector!int vecD = vecA.init;
}

unittest {
	static int numInit = 0;
	static int numDestroy = 0;
	scope (exit) {
		assert(numInit == numDestroy);
	}
	static struct CheckDestructor {
		int num = 1;

		this(this) {
			numInit++;
		}

		this(int n) {
			num = n;
			numInit++;

		}

		~this() {
			numDestroy++;
		}
	}

	CheckDestructor[2] arr = [CheckDestructor(1), CheckDestructor(1)];
	Vector!CheckDestructor vec;
	vec ~= CheckDestructor(1);
	vec ~= arr;
	vec.remove(1);
}

unittest {
	assert(gVectorsCreated == gVectorsDestroyed);
	gVectorsCreated = 0;
	gVectorsDestroyed = 0;
	scope (exit) {
		assert(gVectorsCreated == gVectorsDestroyed);
	}
	string strA = "aaa bbb";
	string strB = "ccc";
	Vector!(Vector!char) vecA = Vector!(Vector!char)(Vector!char(cast(char[]) strA));
	assert(vecA[0] == Vector!char(cast(char[]) strA));
	Vector!(Vector!char) vecB;
	vecB = vecA;
	assert(vecB[0] == Vector!char(cast(char[]) strA));
	assert(vecA.array.ptr != vecB.array.ptr);
	assert(vecB.used == vecA.used);
	assert(vecB[0].array.ptr != vecA[0].array.ptr);
	assert(vecB[0].used == vecA[0].used);
}

unittest {
	static struct Test {
		int num;
		@disable this(this);
	}

	Vector!Test test;
}