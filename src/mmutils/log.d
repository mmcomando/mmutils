/++
 + Log implementation
 + Compile and Run: dmd -unittest -main log.d && ./log
 + Ex. usage:
 + log(LL(), "Info Msg");
 + log(LL(LogType.Fatal), "Fatal Msg %d", 2);
 + log(LL(LogType.Info, LogPriority.VeryImportnat), "Very Importnat Info");
 +
 + Add custom log handler:
 +mmutils_add_log_handler(&my_custom_log_handler_func);
 +/
module mmutils.log;

import core.stdc.stdarg : va_end, va_list, va_start;
import core.stdc.stdio : fclose, FILE, fopen, fprintf, printf, snprintf, vsnprintf;
import core.sys.linux.time : clock_gettime, CLOCK_MONOTONIC, CLOCK_MONOTONIC_COARSE, timespec;



extern (C):

/// Basic usage
unittest
{
	mmutils_clear_log_handlers();
	mmutils_log_to_file("logs.txt", true);
	mmutils_add_log_handler(&mmutils_printf_log_handler);
	mmutils_set_global_log_priority(LogPriority.Importnat);
	log(LL(LogType.Fatal), "Fatal");
	log(LL(LogType.Error), "Error");
	log(LL(LogType.Warning), "Warning");
	log(LL(LogType.Debug), "Debug");
	log(LL(LogType.Info), "Info");
	log(LL(LogType.Info, LogPriority.VeryImportnat), "Very Importnat Info");
}

/// Performance log
unittest
{
	mmutils_clear_log_handlers();
	mmutils_add_log_handler(&mmutils_printf_log_handler);
	auto perfCheck = log_perf(LL(LogType.Error), "End", "Start");
}

/// Performance test
/// In my run printing 1_000_000 logs to file takes 0.8s
unittest
{
	mmutils_clear_log_handlers();
	mmutils_log_to_file("logs_perf_test.txt", true);
	auto perfCheck = log_perf(LL(LogType.Error), "End", "Start");

	int logNum = 1000000;
	foreach (i; 0 .. logNum)
	{
		log(LL(), "Log i(%d)", i);
	}
	mmutils_add_log_handler(&mmutils_printf_log_handler);
	log(LL(), "Printed logNum(%d)", logNum);
}


/// Log Type
/// Used to distinguish log purpose
enum LogType
{
	Info = 0, /// Informative log, LogPriority.Useful
	Debug, /// Log which might be useful for finding errors, LogPriority.Useful
	Warning, /// Log about possibliy bad event, LogPriority.VeryUseful
	Error, /// Log about error, LogPriority.Importnat
	Fatal, /// Log about fatal error, LogPriority.VeryImportnat
}

/// Log Priority
/// Controls logs filtering based on its priority
enum LogPriority
{
	Auto, /// Log priority is based on LogType
	Never, /// Log should never be printed, used to disable logging, shouldn't be used by user
	VeryRarelyUseful, /// ditto
	RarelyUseful, /// ditto
	Useful, /// ditto
	VeryUseful, /// ditto
	Importnat, /// ditto
	VeryImportnat, /// dittoa
	Always, /// Log should be printed always
}

/// Basic information mostly set by compiler in caller side
struct LogEntry
{
	const(char)* codeFile; /// ditto
	const(char)* prettyFuncName; /// ditto
	const(char)* moduleName; /// ditto
	int codeLine; /// ditto
	LogType logType; /// ditto
	LogPriority logPriority; /// ditto
}

/// Data about log
struct LogData
{
	KeyValue[] data; /// ditto
	const(char)* message; /// Human readable log message 
	ulong tv_sec; /// Log time in seconds
	int tv_nsec; /// Log time in nano seconds
	LogEntry logEntry; /// ditto 
}

/// Other data, might be non human readable
struct KeyValue
{
	const(char)[] key; /// String key at which data is stored 
	const(ubyte)[] value; /// Binary data
}

/// Function type for User log callbacks
alias LogHandlerFunc = void function(const ref LogData logData);

/// Enables default logging to file
void mmutils_log_to_file(const char* file, bool clearFile = false)
{
	if (gLogFile)
	{
		fclose(gLogFile);
	}
	gLogFile = fopen(file, clearFile ? "w" : "a");
	mmutils_add_log_handler(&mmutils_file_log_handler);
}

/// Default log handler function which saves logs to file
void mmutils_file_log_handler(const ref LogData ld)
{
	if (gLogFile == null)
	{
		gLogFile = fopen("log_default.txt", "w");
	}
	fprintf(gLogFile, "%d.%06d, %d|%d %s:%d %s: %s\n", cast(int) ld.tv_sec,
			ld.tv_nsec / 1000, ld.logEntry.logType, ld.logEntry.logPriority,
			ld.logEntry.codeFile, ld.logEntry.codeLine, ld.logEntry.prettyFuncName, ld.message);
}

/// Default log handler function which prints logs to stdout
void mmutils_printf_log_handler(const ref LogData ld)
{
	printf("%d.%06d, %d|%d %s:%d %s: %s\n", cast(int) ld.tv_sec, ld.tv_nsec / 1000,
			ld.logEntry.logType, ld.logEntry.logPriority, ld.logEntry.codeFile,
			ld.logEntry.codeLine, ld.logEntry.prettyFuncName, ld.message);
}

/// Helper function whcich allows compiler to get information about file and line on calling side
LogEntry LL(LogType logType = LogType.Info, LogPriority logPriority = LogPriority.Auto, string codeFile = __FILE__,
		string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__, int codeLine = __LINE__,)
{
	if (logPriority == LogPriority.Auto)
	{
		final switch (logType)
		{
		case LogType.Info:
			logPriority = LogPriority.Useful;
			break;
		case LogType.Debug:
			logPriority = LogPriority.Useful;
			break;
		case LogType.Warning:
			logPriority = LogPriority.VeryUseful;
			break;
		case LogType.Error:
			logPriority = LogPriority.Importnat;
			break;
		case LogType.Fatal:
			logPriority = LogPriority.VeryImportnat;
			break;
		}
	}
	return LogEntry(codeFile.ptr, prettyFuncName.ptr, moduleName.ptr, codeLine,
			logType, logPriority);
}

version (DMD)
{
	/// Function to log messages with printf like arguments
	/// Ex:
	/// log(LL(LogType.Fatal), "This is number %d", 1);
	/// log(LL(), "This is number %d", 1); // Default LogType.Info
	pragma(printf) void log(LogEntry logEntry, const char* format, ...)
	{
		char[gBufferLength] buffer = void;
		va_list args;
		va_start(args, format);
		vsnprintf(buffer.ptr, buffer.length, format, args);
		va_end(args);
		mmutils_log(logEntry, buffer.ptr);
	}
}
else
{
	// Only DMD supports pragma(printf) 
	/// Function to log messages with printf like arguments
	/// Ex:
	/// log(LL(LogType.Fatal), "This is number %d", 1);
	/// log(LL(), "This is number %d", 1); // Default LogType.Info
	void log(LogEntry logEntry, const char* format, ...)
	{
		char[gBufferLength] buffer = void;
		va_list args;
		va_start(args, format);
		vsnprintf(buffer.ptr, buffer.length, format, args);
		va_end(args);
		mmutils_log(logEntry, buffer.ptr);
	}
}

/// Helper for logging performance informations
/// return value has to be assigned to variable for proper destruction at the end of sscope
/// Ex. auto perfCheck = log_perf(LL(LogType.Error), "My function has ended", "Start function it might take %d years", 5)
LogPerf log_perf(LogEntry logEntry, const char* msgEnd, const char* msgStart, ...)
{
	LogPerf logPerf = void;
	if (logEntry.logPriority < mmutils_get_log_priority())
	{
		logPerf.logEntry.logPriority = LogPriority.Never;
		return logPerf;
	}

	logEntry.logPriority = LogPriority.Always; // Check was already made

	timespec tim = void;
	clock_gettime(CLOCK_MONOTONIC, &tim);

	logPerf.tv_sec = tim.tv_sec;
	logPerf.tv_nsec = cast(int) tim.tv_nsec;
	logPerf.logEntry = logEntry;
	logPerf.msgEnd = msgEnd;

	char[gBufferLength] buffer = void;

	va_list args;
	va_start(args, msgStart);
	immutable written = snprintf(buffer.ptr, buffer.length,
			"[P START, %5lld.%0.9lld] ", tim.tv_sec, tim.tv_nsec);
	vsnprintf(buffer.ptr + written, buffer.length - written, msgStart, args);
	va_end(args);

	mmutils_log(logEntry, buffer.ptr);
	return logPerf;
}

/// Register function to handle log messages
bool mmutils_add_log_handler(LogHandlerFunc handler)
{
	if (gLogHandlersNum >= gMaxLogHandlers || handler == null)
	{
		return false;
	}
	gLogHandlers[gLogHandlersNum] = handler;
	gLogHandlersNum++; //TODO lock
	return true;
}

/// Removes all log handlers
bool mmutils_clear_log_handlers()
{
	gLogHandlersNum = 0;
	mmutils_set_global_log_priority(LogPriority.Auto);
	return true;
}
// TODO implement mmutils_remove_log_handler

/// Sets current logging priority
/// Current logging priority below which messages are ignored in all handlers
void mmutils_set_global_log_priority(LogPriority logPriority)
{
	gLogPriority = logPriority;
}

/// Gets current logging priority
LogPriority mmutils_get_log_priority()
{
	return gLogPriority;
}

/// Log message with logEntry data
/// This functions calls all registred log handler functons
int mmutils_log(LogEntry logEntry, const char* message)
{
	// printf(" %d %d\n", logEntry.logPriority, mmutils_get_log_priority());
	if (logEntry.logPriority < mmutils_get_log_priority())
	{
		return 0;
	}

	timespec tim = void;
	clock_gettime(USED_CLOCK, &tim);

	LogData ld = void;
	ld.data = null;
	ld.logEntry = logEntry;
	ld.message = message;
	ld.tv_sec = tim.tv_sec;
	ld.tv_nsec = cast(int) tim.tv_nsec;

	mmutils_log_impl(ld);
	return 0;
}

private:

struct LogPerf
{
	LogEntry logEntry;
	const(char)* msgEnd;
	ulong tv_sec;
	int tv_nsec;
	@disable this(this);
	~this()
	{
		if (logEntry.logPriority == LogPriority.Never)
		{
			return;
		}
		timespec tim = void;
		clock_gettime(CLOCK_MONOTONIC, &tim);

		ulong dtSec = tim.tv_sec - tv_sec;
		long dtNSec = tim.tv_nsec - tv_nsec;
		if (dtNSec < 0)
		{
			dtSec--;
			dtNSec += 1000_000_000;
		}

		char[gBufferLength] buffer = void;
		snprintf(buffer.ptr, buffer.length, "[P END  , %5lld.%0.9lld, DT %lld.%0.9lld] %s",
				tim.tv_sec, tim.tv_nsec, dtSec, dtNSec, msgEnd);
		mmutils_log(logEntry, buffer.ptr);
	}
}

pragma(inline, false) void mmutils_log_impl(const ref LogData logData)
{
	// writeln(logData.codeFile[0..17]);
	foreach (handler; gLogHandlers[0 .. gLogHandlersNum])
	{
		if (handler == null)
		{
			continue;
		}
		handler(logData);
	}
}

alias USED_CLOCK = CLOCK_MONOTONIC_COARSE; // No syscall, precision ~10ms, makes logging to file ~3 times faster
// alias USED_CLOCK = CLOCK_MONOTONIC;

immutable gMaxLogHandlers = 32;
__gshared int gLogHandlersNum = 0;
__gshared LogPriority gLogPriority = LogPriority.Auto;
__gshared LogHandlerFunc[gMaxLogHandlers] gLogHandlers;
immutable gBufferLength = 1024;

__gshared FILE* gLogFile = null; // For default log file handler
