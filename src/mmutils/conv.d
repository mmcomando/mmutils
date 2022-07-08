/// Module to replace std.conv 'to' function with similar but @nogc
/// Function in this module use TLS buffer to store string result, so returned strings are valid only to next usage of X->string conversion functions
module mmutils.conv;

import std.meta : NoDuplicates;
import std.traits;

private extern (C) int sscanf(scope const char* s, scope const char* format, ...) nothrow @nogc;
private extern (C) int snprintf(scope char* s, size_t n, scope const char* format, ...) nothrow @nogc;

private auto min(A, B)(A a, B b) {
	return (a < b) ? a : b;
}

private static char[1024] gTmpStrBuff;

/// Converts variable from to Type TO
/// strings are stored in default global buffer
TO to(TO, FROM)(auto ref const FROM from) {
	return to!(TO, FROM)(from, gTmpStrBuff);
}

private bool isString(T)(){
    return is(T == string) || is(T == const(char)[]) || is(T == char[]);
}

/// Converts variable from to Type TO
/// strings are stored in buff buffer
TO to(TO, FROM)(auto ref const FROM from, char[] buff) {
	static if (is(TO == FROM)) {
		return from;
	} else static if (isString!TO) {
		static if (is(FROM == bool)) {
			return bool2str(from, buff);
		} else static if (is(FROM == enum)) {
			return enum2str(from, buff);
		} else static if (isSIMDVector!FROM) {
			return slice2str(from.array, buff);
		} else static if (worksWithStr2Num!FROM) {
			return num2str(from, buff);
		} else static if (is(FROM == struct)) {
			return struct2str(from, buff);
		} else static if (isDynamicArray!(FROM)) {
			return slice2str(from, buff);
		} else static if (isStaticArray!(FROM)) {
			return slice2str(from[], buff);
		} else static if (isDelegate!(FROM) || isFunctionPointer!FROM) {
			return del2str(from, buff);
		} else static if (is(FROM == class)) {
			return num2str(cast(void*) from, buff);
		} else {
			static assert(0, "Type conversion not supported");
		}
	} else static if (isString!FROM) {
		FROM frm = from;
		static if (is(TO == enum)) {
			return str2enum!(TO)(frm);
		} else static if (worksWithStr2Num!TO) {
			return str2num!(TO)(frm);
		} else static if (is(TO == struct)) {
			return str2struct!(TO)(frm);
		} else {
			static assert(0, "Type conversion not supported");
		}
	} else {
			static assert(0, "Type conversion not supported");
    }

}

/// Converts part of from string to TO variable
TO parse(TO)(auto ref const(char)[] from) {
	static if (is(TO == enum)) {
		return str2enum!(TO)(from);
	} else static if (worksWithStr2Num!TO) {
		return str2num!(TO)(from);
	} else static if (is(TO == struct)) {
		return str2struct!(TO)(from);
	} else {
		static assert(0, "Type conversion not supported");
	}

}

nothrow @nogc unittest {
	// Convert to same value
	assert(10.to!int == 10);
	// Convert numbers
	assert("10".to!ubyte == 10);
	assert(10.to!string == "10");

	// Convert enums
	assert((TestEnum.a).to!string == "a");
	assert("a".to!TestEnum == TestEnum.a);

	// Convert structs
	TestStructA testStruct = "TestStructA(10, 10)".str2struct!TestStructA;
	assert(testStruct.a == 10);
	assert(testStruct.b == 10);
	assert(testStruct.to!string == "TestStructA(10, 10)");
}

///////////////////////  Convert numbers

/// Converts number of type NUM to string and stores it in buff
/// Internally uses snprintf, string might be cut down to fit in buffer
/// To check for buffer overflow you might compare length of buff and returned string, if they are equal there might be not enough space in buffer
/// NULL char is always added at the end of the string
const(char)[] num2str(FROM)(FROM from, char[] buff) {
	static assert(worksWithStr2Num!FROM, "num2str converts only numeric or pointer type to string");
	string sp = getSpecifier!(FROM);
	char[5] format;
	format[0] = '%';
	foreach (i, c; sp)
		format.ptr[1 + i] = c;
	format.ptr[1 + sp.length] = '\0';
	int takesCharsNum = snprintf(buff.ptr, buff.length, format.ptr, from);
	if (takesCharsNum < buff.length) {
		return cast(string) buff[0 .. takesCharsNum];
	} else {
		return cast(string) buff;
	}
}

nothrow @nogc unittest {
	char[4] buff;
	assert(num2str(10, gTmpStrBuff[]) == "10");
	assert(num2str(-10, gTmpStrBuff[]) == "-10");
	assert(num2str(123456789, buff[]) == "123\0");
}

/// Converts string to numeric type NUM
/// If string is malformed NUM.init is returned
NUM str2num(NUM)(auto ref string from) {
	static assert(worksWithStr2Num!NUM, "str2num converts string to numeric or pointer type");
	if (from.length == 0) {
		return NUM.init;
	}
	NUM ret = NUM.init;
	string sp = getSpecifier!(NUM);
	char[32] format;
	format[0] = '%';
	int takesCharsNum = snprintf(format.ptr + 1, format.length, "%d", cast(int) from.length);
	foreach (i, c; sp)
		format.ptr[1 + takesCharsNum + i] = c;
	format.ptr[1 + takesCharsNum + sp.length] = '%';
	format.ptr[2 + takesCharsNum + sp.length] = 'n';
	format.ptr[3 + takesCharsNum + sp.length] = '\0';
	int charsScanned = 0;
	sscanf(from.ptr, format.ptr, &ret, &charsScanned);
	from = from[charsScanned .. $];
	return ret;
}

nothrow @nogc unittest {
	char[18] noEnd = "123456789123456789"; // Test without c string ending (\0)
	string empty;
	assert(empty.str2num!ubyte == 0);
	assert("".str2num!ubyte == 0);
	assert("asdaf".str2num!ubyte == 0);
	assert(str2num!int(cast(string) noEnd[0 .. 2]) == 12);

	assert("10".str2num!ubyte == 10);
	assert("10".str2num!ushort == 10);
	assert("+10".str2num!uint == 10);
	assert("+10".str2num!ulong == 10);

	assert("-10".str2num!byte == -10);
	assert("-10".str2num!short == -10);
	assert("-10".str2num!int == -10);
	assert("-10".str2num!long == -10);
}

///////////////////////  Convert bools

/// Converts bool to string
string bool2str(T)(auto ref const T bbb, char[] buff) {
	static assert(is(T == bool), "T must be a boolean");
	enum string[2] strs = ["false", "true"];
	string name = strs[bbb];
	size_t toCopy = min(name.length, buff.length);

	foreach (i, char c; name[0 .. toCopy]) {
		buff[i] = c;
	}
	return cast(string) buff[0 .. toCopy];
}
///////////////////////  Convert enums

/// Converts enum to string
/// If wrong enum value is specified "WrongEnum" string is returned
string enum2str(T)(auto ref const T en, char[] buff) {
	static assert(is(T == enum), "T must be an enum");
	switch (en) {
		foreach (i, e; NoDuplicates!(EnumMembers!T)) {
	case e:
			enum name = __traits(allMembers, T)[i];
			foreach (k, char c; name) {
				buff[k] = c;
			}
			return cast(string) buff[0 .. name.length];
		}
	default:
		return "WrongEnum";

	}
}

nothrow @nogc unittest {
	assert(enum2str(TestEnum.a, gTmpStrBuff) == "a");
	assert(enum2str(TestEnum.b, gTmpStrBuff) == "b");
	assert(enum2str(cast(TestEnum) 123, gTmpStrBuff) == "WrongEnum");
}

/// Converts string to enum
/// If wrong string is specified max enum base type is returned ex. for: enum:ubyte E{} will return 255
T str2enum(T)(auto ref const(char)[] str) {
	static assert(is(T == enum), "T must be an enum");

	foreach (i, e; NoDuplicates!(EnumMembers!T)) {
		enum name = __traits(allMembers, T)[i];
		if (str.length == name.length && str[0 .. name.length] == name) {
			str = str[name.length .. $];
			return e;
		}
	}
	return cast(T)(OriginalType!T).max; // Probably invalid enum

}

nothrow @nogc unittest {
	assert(str2enum!(TestEnum)("a") == TestEnum.a);
	assert(str2enum!(TestEnum)("b") == TestEnum.b);
	assert(str2enum!(TestEnum)("ttt") == byte.max);
}

///////////////////////  Convert slices

/// Converts slice to string
/// Uses to!(string)(el, buff) to convert inner elements
/// If buff.length<=5 null is returned
/// If there is not enough space in the buffer, function converts as much as it could with string "...]" at the end
string slice2str(T)(auto ref const T slice, char[] buff) {
	alias EL = Unqual!(ForeachType!T);

	if (buff.length <= 5) {
		return null;
	}

	static if (is(EL == char)) {
		buff[$ - 4 .. $] = "...]";
		size_t lengthToCopy = min(slice.length, buff.length - 2);
		buff[0] = '"';
		buff[1 + lengthToCopy] = '"';
		buff[1 .. 1 + lengthToCopy] = slice[0 .. lengthToCopy];
		return cast(string) buff[0 .. lengthToCopy + 2];
	} else {
		buff[0] = '[';

		char[] buffSlice = buff[1 .. $];
		foreach (ref el; slice) {
			string elStr = to!(string)(el, buffSlice);
			if (elStr.length + 2 >= buffSlice.length) {
				buff[$ - 4 .. $] = "...]";
				buffSlice = null;
				break;
			}
			buffSlice[elStr.length] = ',';
			buffSlice[elStr.length + 1] = ' ';
			buffSlice = buffSlice[elStr.length + 2 .. $];
		}
		if (buffSlice.length == 0) {
			return cast(string) buff;
		}

		size_t size = buff.length - buffSlice.length;
		buff[size - 2] = ']';
		return cast(string) buff[0 .. size - 1];
	}
}

nothrow @nogc unittest {
	char[10] bb;
	TestStructA[9] sl;
	int[9] ints = [1, 2, 3, 4, 5, 6, 7, 8, 9];
	assert(slice2str(ints[], gTmpStrBuff) == "[1, 2, 3, 4, 5, 6, 7, 8, 9]");
	assert(slice2str(sl[], bb[]) == "[TestS...]");
}

///////////////////////  Convert delegates and functions

/// Converts delegate or function to string
string del2str(FROM)(FROM from, char[] buff) {
	static assert(isDelegate!FROM || isFunctionPointer!FROM,
			"del2str converts only delegates and functions to string");
	static if (isDelegate!FROM) {
		int takesCharsNum = snprintf(buff.ptr, buff.length,
				"delegate(obj: %p, func: %p)", from.ptr, from.funcptr);
	} else {
		int takesCharsNum = snprintf(buff.ptr, buff.length,
				"function(func: %p)", cast(void*) from);
	}
	if (takesCharsNum < buff.length) {
		return cast(string) buff[0 .. takesCharsNum];
	} else {
		return cast(string) buff;
	}
}

nothrow @nogc unittest {
	static void func() {
	}

	static void del() {
	}

	assert(del2str(&func, gTmpStrBuff));
	assert(del2str(&del, gTmpStrBuff));
}

///////////////////////  Convert struct

/// Converts struct to strings
/// Function is not using to!string so inner elements might be displayed differently ex. enums (they are displayed as numbers)
/// Elements which cannot be converted are skipped
string struct2str(T)(auto ref const T s, char[] buff) {
	static assert(is(T == struct), "T must be a struct");
	if (buff.length < 3) {
		return null;
	}
	char[] sl = buff;
	enum name = T.stringof;
	size_t namePart = min(name.length, buff.length);
	sl[0 .. namePart] = name[0 .. namePart];
	sl = sl[namePart .. $];
	if (sl.length > 1) {
		sl[0] = '(';
		sl = sl[1 .. $];
	}

	foreach (i, ref var; s.tupleof) {
		alias Type = typeof(var);
		static if (is(Type == struct) || worksWithStr2Num!Type) {
			if (sl.length <= 3) {
				break;
			}
			string str = to!string(var, sl);
			sl = sl[str.length .. $];
			if (sl.length < 2) {
				break;
			}
			if (i != s.tupleof.length - 1) {
				sl[0] = ',';
				sl[1] = ' ';
				sl = sl[2 .. $];
			}
		}
	}
	if (sl.length > 1) {
		sl[0] = ')';
		sl = sl[1 .. $];
	}
	return cast(string) buff[0 .. buff.length - sl.length];
}

nothrow @nogc unittest {
	TestStructB test = TestStructB(2);
	assert(struct2str(test,
			gTmpStrBuff) == "TestStructB(TestStructA(1, 255), 2, 9223372036854775807, a)");
}

/// Converts string to struct
/// string format is very strict, returns 0 initialized variable if string is bad
/// Works like struct2str but opposite
T str2struct(T)(auto ref string str) {
	static assert(is(T == struct), "T must be a struct");

	union ZeroInit { // Init for @disable this() struct
		mixin("align(T.alignof) ubyte[T.sizeof] zeros;"); // Workaround for IDE parser error
		T s = void;
	}

	ZeroInit var;
	if (str[$ - 1] != ')') {
		return var.s;
	}

	string sl = str;
	enum name = T.stringof;
	assert(sl[0 .. name.length] == name);
	sl = sl[name.length .. $];
	assert(sl[0] == '(');
	sl = sl[1 .. $];

	foreach (i, ref v; var.s.tupleof) {
		alias Type = typeof(v);
		static if (is(Type == struct) || worksWithStr2Num!Type) {
			v = parse!Type(sl);
			if (i != var.s.tupleof.length - 1) {
				sl = sl[2 .. $];
			}
		}
	}
	assert(sl[0] == ')');
	sl = sl[1 .. $];
	str = sl;
	return var.s;
}

nothrow @nogc unittest {
	string loadFrom = "TestStructB(TestStructA(1, 255), 2, 9223372036854775807, b)";
	TestStructB test = str2struct!(TestStructB)(loadFrom);
	assert(test.a == 2);
	assert(test.b == 9223372036854775807);
	assert(test.en == TestEnum.b);
	assert(test.c.a == 1);
	assert(test.c.b == 255);
}

private bool worksWithStr2Num(T)() {
	return !isSIMDVector!(T) && (isNumeric!T || isPointer!T || is(Unqual!T == char));
}

unittest {
	version (x86_64) {
		import core.simd : ushort8;

		static assert(worksWithStr2Num!(int));
		static assert(worksWithStr2Num!(void*));
		static assert(worksWithStr2Num!(double));
		static assert(!worksWithStr2Num!(ushort8));
	}
}

string getSpecifier(TTT)() {
	static if (is(TTT == enum)) {
		alias T = OriginalType!TTT;
	} else {
		alias T = Unqual!TTT;
	}
	static if (is(T == float))
		return "g";
	else static if (is(T == double))
		return "lg";
	else static if (is(T == real))
		return "Lg";
	else static if (is(T == char))
		return "c";
	else static if (is(T == byte))
		return "hhd";
	else static if (is(T == ubyte))
		return "hhu";
	else static if (is(T == short))
		return "hd";
	else static if (is(T == ushort))
		return "hu";
	else static if (is(T == int))
		return "d";
	else static if (is(T == uint))
		return "u";
	else static if (is(T == long))
		return "lld";
	else static if (is(T == ulong))
		return "llu";
	else static if (isPointer!T)
		return "p";
	else
		static assert(0, "Type conversion not supported");
}

// Used for tests

private enum TestEnum : byte {
	a = 50,
	b = 100,
}

private struct TestStructA {
	int a = 1;
	ubyte b = ubyte.max;
}

private struct TestStructB {
nothrow @nogc pure:
	@disable this();

	this(int a) {
		this.a = a;
	}

	TestStructA c;
	int a = 3;
	long b = long.max;
	TestEnum en;
}
