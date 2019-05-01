module mmutils.thread_pool;

import core.atomic;
import core.stdc.stdio;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy;

import std.stdio;
import std.algorithm : map;

version = MM_NO_LOGS; // Disable log creation
version = MM_USE_POSIX_THREADS; // Use posix threads insted of standard library, required for betterC

//////////////////////////////////////////////
/////////////// BetterC Support //////////////
//////////////////////////////////////////////

version (D_BetterC)
{
	extern (C) __gshared int _d_eh_personality(int, int, size_t, void*, void*)
	{
		return 0;
	}

	extern (C) __gshared void _d_eh_resume_unwind(void*)
	{
		return;
	}

	extern (C) void* _d_allocmemory(size_t sz)
	{
		return malloc(sz);
	}
}

//////////////////////////////////////////////
//////////////////// Alloc ///////////////////
//////////////////////////////////////////////
T* makeVar(T)(T init)
{
	T* el = cast(T*) malloc(T.sizeof);
	memcpy(el, &init, T.sizeof);
	return el;
	// return Mallocator.instance.make!T(init);
}

// import std.experimental.allocator;
// import std.experimental.allocator.mallocator;

T* makeVar(T)()
{
	T init;
	T* el = cast(T*) malloc(T.sizeof);
	memcpy(el, &init, T.sizeof);
	// return Mallocator.instance.make!T(init);
	return el;
}

T[] makeVarArray(T)(int num, T init = T.init)
{
	T* ptr = cast(T*) malloc(num * (T.sizeof + T.sizeof % T.alignof));
	T[] arr = ptr[0 .. num];
	foreach (ref el; arr)
	{
		memcpy(&el, &init, T.sizeof);
	}
	// return Mallocator.instance.makeArray!T(num);
	return arr;
}

void disposeVar(T)(T* var)
{
	free(var);
}

void disposeArray(T)(T[] var)
{
	free(var.ptr);
}
//////////////////////////////////////////////
//////////////////// Timer ///////////////////
//////////////////////////////////////////////

/// High precison timer
long useconds()
{
	version (Posix)
	{
		import core.sys.posix.sys.time : gettimeofday, timeval;

		timeval t;
		gettimeofday(&t, null);
		return t.tv_sec * 1_000_000 + t.tv_usec;
	}
	else version (Windows)
	{
		import core.sys.windows.windows : QueryPerformanceFrequency;

		__gshared double mul = -1;
		if (mul < 0)
		{
			long frequency;
			int ok = QueryPerformanceFrequency(&frequency);
			assert(ok);
			mul = 1_000_000.0 / frequency;
		}
		long ticks;
		int ok = QueryPerformanceCounter(&ticks);
		assert(ok);
		return cast(long)(ticks * mul);
	}
	else
	{
		static assert("OS not supported.");
	}
}

//////////////////////////////////////////////
//////////////////// Queue ///////////////////
//////////////////////////////////////////////

void instructionPause()
{
	version (X86_64)
	{
		version (LDC)
		{
			import ldc.gccbuiltins_x86 : __builtin_ia32_pause;

			__builtin_ia32_pause();
		}
		else version (DigitalMars)
		{
			asm
			{
				rep;
				nop;
			}

		}
		else
		{
			static assert(0);
		}
	}
}

struct LowLockQueue(LockType = ulong)
{
private:

	align(64) shared LockType producerLock;
	align(64) JobData* first;

	bool empty()
	{
		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		bool isEmpty = first == null;
		atomicStore!(MemoryOrder.rel)(producerLock, false);
		return isEmpty;
	}

	void add(JobData* t)
	{
		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		t.next = first;
		first = t;

		atomicStore!(MemoryOrder.rel)(producerLock, false);
	}

	// Add every, nth element to better preserve execution order of input range
	void addRange(Range)(Range arr)
	{
		if (arr.length == 0)
			return;

		JobData* start = arr[0];
		JobData* last = start;

		foreach (t; arr[1 .. $])
		{
			last.next = t;
			last = t;
		}

		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();
		last.next = first;
		first = start;
		atomicStore!(MemoryOrder.rel)(producerLock, cast(LockType) false);

	}

	JobData* pop()
	{
		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		assert(first != null);
		JobData* result = first;
		first = first.next;

		atomicStore!(MemoryOrder.rel)(producerLock, cast(LockType) false);
		return result;
	}
}

//////////////////////////////////////////////
///////////// Semaphore + Thread /////////////
//////////////////////////////////////////////

version (MM_USE_POSIX_THREADS)
{
	version (Posix)
	{
		import core.sys.posix.pthread;
		import core.sys.posix.semaphore;
	}
	else version (Windows)
	{
	extern (C):
		struct pthread_t
		{
			void* p;
			uint x;
		}

		struct timespec
		{
			time_t a;
			int b;
		}

		// pthread
		int pthread_create(pthread_t*, in pthread_attr_t*, void* function(void*), void*);
		int pthread_join(pthread_t, void**);

		// semaphore.h
		alias sem_t = void*;
		int sem_init(sem_t*, int, uint);
		int sem_wait(sem_t*);
		int sem_trywait(sem_t*);
		int sem_post(sem_t*);
		int sem_destroy(sem_t*);
		int sem_timedwait(sem_t* sem, const timespec* abstime);
	}
	else
	{
		static assert(false);
	}

	struct Semaphore
	{
		sem_t mutex;

		void initialize()
		{
			sem_init(&mutex, 0, 0);
		}

		void wait()
		{
			int ret = sem_wait(&mutex);
			assert(ret == 0);
		}

		bool tryWait()
		{
			//return true;
			int ret = sem_trywait(&mutex);
			return (ret == 0);
		}

		bool timedWait(int usecs)
		{
			timespec tv;
			// if there is no such a function look at it: https://stackoverflow.com/questions/5404277/porting-clock-gettime-to-windows
			clock_gettime(CLOCK_REALTIME, &tv);
			tv.tv_sec += usecs / 1_000_000;
			tv.tv_nsec += (usecs % 1_000_000) * 1_000;

			int ret = sem_timedwait(&mutex, &tv);
			return (ret == 0);
		}

		void post()
		{
			int ret = sem_post(&mutex);
			assert(ret == 0);
		}

		void destroy()
		{
			sem_destroy(&mutex);
		}
	}

	private extern (C) void* threadRunFunction(void* threadVoid)
	{
		Thread* th = cast(Thread*) threadVoid;

		th.threadStart();

		pthread_exit(null);
		return null;
	}

	struct Thread
	{
		alias DG = void delegate();

		DG threadStart;
		pthread_t handle;

		void start(DG dg)
		{
			threadStart = dg;
			int ok = pthread_create(&handle, null, &threadRunFunction, cast(void*)&this);
			assert(ok == 0);
		}

		void join()
		{
			pthread_join(handle, null);
			handle = handle.init;
			threadStart = null;
		}
	}
}
else
{
	import core.thread : D_Thread = Thread;
	import core.sync.semaphore : D_Semaphore = Semaphore;
	import core.time : dur;
	import std.experimental.allocator;
	import std.experimental.allocator.mallocator;

	struct Semaphore
	{
		D_Semaphore sem;

		void initialize()
		{
			sem = Mallocator.instance.make!D_Semaphore();
		}

		void wait()
		{
			sem.wait();
		}

		bool tryWait()
		{
			return sem.tryWait();
		}

		bool timedWait(int usecs)
		{
			return sem.wait(dur!"usecs"(usecs));
		}

		void post()
		{
			sem.notify();
		}

		void destroy()
		{
			Mallocator.instance.dispose(sem);
		}
	}

	struct Thread
	{
		alias DG = void delegate();

		DG threadStart;
		D_Thread thread;

		void start(DG dg)
		{
			thread = Mallocator.instance.make!D_Thread(dg);
			thread.start();
		}

		void join()
		{
			thread.join();
		}
	}
}

//////////////////////////////////////////////
///////////////// ThreadPool /////////////////
//////////////////////////////////////////////

private enum gMaxThreadsNum = 128;

alias JobDelegate = void delegate(ThreadData*, JobData*);

// Structure to store job start and end time
struct JobLog
{
	string name; /// Name of job
	ulong time; /// Time started (us)
	ulong duration; /// Took time (us)
	bool complete; /// If job is currently executing 
}

/// Structure containing job data
/// JobData memory is allocated by user
/// JobData lifetime is managed by user
/// JobData has to live as long as it's group or end of job execution
/// JobData fields can be changed in del delegate and job can be added to thread pool again, to continue execution (call same function again or another if del was changed)
struct JobData
{
	JobDelegate del; /// Delegate to execute
	string name; /// Name of job
	private JobsGroup* group; /// Group to which this job belongs
	private align(64) JobData* next; /// JobData makes a list of jobs to be done by thread
}

/// Structure responsible for thread in thread pool
/// Stores jobs to be executed by this thread (jobs can be stolen by another thread)
/// Stores cache for logs
struct ThreadData
{
public:
	ThreadPool* threadPool; /// Pool this thread belongs to
	int threadId; /// Thread id. Valid only for this thread pool
private:
	align(64) LowLockQueue!(bool) jobsToDo; /// Queue of jobs
	align(64) Semaphore semaphore; /// Semaphore to wake/sleep this thread
	align(64) Thread thread; /// Systemn thread handle
	JobLog[] logs; /// Logs cache
	int lastLogIndex = -1; /// Last created log index
	int jobsDoneCount;

	shared bool end; /// Check if thread has to exit. Thread will exit only if end is true and jobsToDo is empty
	shared bool acceptJobs; /// Check if thread should accept new jobs, If false thread won't steal jobs from other threads and will sleep longer if queue js empty
	bool externalThread; /// Thread not allocated by thread pool

	/// Thread entry point
	void threadStartFunc()
	{
		end = false;
		threadFunc(&this);
	}
}

/// Thread Pool
/// Manages bounch of threads to execute given jobs as quickly as possible
/// There are no priorities beetween jobs. Jobs added to queues in same order as they are in slices, but due to job stealing and uneven speed of execution beetween threads jobs execution order is unspecified.
/// Number of threads executing jobs can be dynamically changed in any time. Threads removed from execution will work until the end of the program but shouldn't accept new jobs.
struct ThreadPool
{
	alias FlushLogsDelegaste = void delegate(ThreadData* threadData, JobLog[] logs); /// Type of delegate to flush logs
	FlushLogsDelegaste onFlushLogs; /// User custom delegate to flush logs, if overriden defaultFlushLogs will be used. Can be sset after initialize() call
	int logsCacheNum; /// Number of log cache entries. Should be set before setThreadsNum is called
private:
	ThreadData*[gMaxThreadsNum] threadsData; /// Data for threads
	align(64) shared int threadsNum; /// number of threads currentlu accepting jobs
	align(64) shared bool threadsDataLock; /// Any modification of threadsData array (change in size or pointer modification) had to be locked
	align(64) shared int threadSelector; /// Index of thread to which add next job
	FILE* logFile; /// File handle for defaultFlushLogs log file

public:
	int jobsDoneCount()
	{
		int sum;
		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;

			sum += th.jobsDoneCount;
		}
		return sum;
	}

	void jobsDoneCountReset()
	{
		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;
			th.jobsDoneCount = 0;
		}
	}
	/// Initialize thread pool
	void initialize()
	{

		version (MM_NO_LOGS)
		{
			logsCacheNum = 0;
		}
		else
		{
			onFlushLogs = &defaultFlushLogs;
			logsCacheNum = 1024;

			logFile = fopen("trace.json", "w");
			fprintf(logFile, "[");
			fclose(logFile);
			logFile = fopen("trace.json", "a");
			assert(logFile !is null);
		}
	}

	/// Registers external thread to thread pool array. There will be allocated data for this thread and it will have specified id
	/// External threads are not joined at the end of thread pool execution
	/// Returns ThreadData corresponding to external thread. To acually start executing, external thread had to call threadStartFunc() from returned variable
	ThreadData* registerExternalThread()
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();

		ThreadData* threadData = makeThreadData();
		threadData.threadPool = &this;
		threadData.semaphore.initialize();
		threadData.externalThread = true;
		threadData.acceptJobs = true;

		int threadNum = atomicOp!"+="(threadsNum, 1) - 1;

		threadData.threadId = threadNum;

		threadsData[threadNum] = threadData;

		return threadData;
	}

	/// Unregisters external thread. Can be called only when external thread have left the thread pool
	void unregistExternalThread(ThreadData* threadData)
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();

		disposeThreadData(threadData);
	}

	/// Allows external threads to return from threadStartFunc
	void releaseExternalThreads()
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();

		// Release external threads (including main thread)
		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;
			if (!th.externalThread)
				continue;

			atomicStore(th.end, true);
		}
	}

	/// Waits for all threads to finish and joins them (excluding external threads)
	void waitThreads()
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();
		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;

			atomicStore(th.acceptJobs, false);
			atomicStore(th.end, true);
		}
		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null || th.externalThread)
				continue;

			th.thread.join();
			disposeThreadData(th);
		}
	}

	/// Sets number of threads to accept new jobs
	/// If there were never so much threads created, they will be created
	/// If number of threads set is smaller than there was threads before, they are not joined but they stop getting new jobs, they stop stealing jobs and they sleep longer
	/// Locking operation
	void setThreadsNum(int num)
	{
		assert(num <= gMaxThreadsNum);
		assert(num > 0);

		lockThreadsData();
		scope (exit)
			unlockThreadsData();

		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th)
			{
				// Exists but has to be disabled
				atomicStore(th.acceptJobs, i < num);
				continue;
			}
			else if (i >= num)
			{
				// Doesn't exist and is not required
				continue;
			}
			// Doesn't exist and is required
			th = makeThreadData();
			th.threadPool = &this;
			th.threadId = cast(int) i;
			th.acceptJobs = true;
			th.semaphore.initialize();

			th.thread.start(&th.threadStartFunc);
		}

		atomicStore(threadsNum, num);

	}

	/// Adds job to be executed by thread pool, such a job won't be synchronized with any group or job
	/// It is advised to use synchronized group of jobs
	void addJobAsynchronous(JobData* data)
	{
		ThreadData* threadData = getThreadDataToAddJobTo();
		threadData.jobsToDo.add(data);
		threadData.semaphore.post();
	}

	/// Adds job to be executed by thread pool, group specified in group data won't be finished until this job ends
	void addJob(JobData* data)
	{
		assert(data.group);
		atomicOp!"+="(data.group.jobsToBeDoneCount, 1);
		addJobAsynchronous(data);
	}

	/// Adds multiple jobs at once
	/// Range has to return JobData*
	/// Range has to have length property
	/// Range is used so there is no need to allocate JobData*[]
	/// All jobs has to belong to one group
	void addJobsRange(Range)(Range arr)
	{
		if (arr.length == 0)
		{
			return;
		}

		foreach (JobData* threadData; arr)
		{
			assert(arr[0].group == threadData.group);
		}
		atomicOp!"+="(arr[0].group.jobsToBeDoneCount, cast(int) arr.length);
		int threadsNumLocal = threadsNum;
		int part = cast(int) arr.length / threadsNumLocal;
		if (part > 0)
		{
			foreach (i, ThreadData* threadData; threadsData[0 .. threadsNumLocal])
			{
				auto slice = arr[i * part .. (i + 1) * part];
				threadData.jobsToDo.addRange(slice);

				foreach (kkk; 0 .. part)
				{
					threadData.semaphore.post();
				}

			}
			arr = arr[part * threadsNumLocal .. $];
		}
		foreach (i, ThreadData* threadData; threadsData[0 .. arr.length])
		{
			threadData.jobsToDo.add(arr[i]);
			threadData.semaphore.post();
		}

	}

	/// Adds group of jobs to threadPool, group won't be synchronized
	void addGroupAsynchronous(JobsGroup* group)
	{
		group.thPool = &this;
		if (group.jobs.length == 0)
		{
			// Immediately call group end
			group.onGroupFinish();
			return;
		}

		group.setUpJobs();
		auto rng = group.jobs[].map!((ref a) => &a);
		addJobsRange(rng);
	}

	/// Adds group of jobs to threadPool
	/// Spwaning group will finish after this group have finished
	void addGroup(JobsGroup* group, JobsGroup* spawnedByGroup)
	{
		assert(spawnedByGroup);
		group.spawnedByGroup = spawnedByGroup;
		atomicOp!"+="(spawnedByGroup.jobsToBeDoneCount, 1); // Increase by one, so 'spawning group' will wait for 'newly added group' to finish
		addGroupAsynchronous(group); // Synchronized by jobsToBeDoneCount atomic variable
	}

	/// Explicitly calls onFlushLogs on all threads
	void flushAllLogs()
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();
		foreach (thNum; 0 .. atomicLoad(threadsNum))
		{
			ThreadData* th = threadsData[thNum];
			onThreadFlushLogs(th);
		}

		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;

			onThreadFlushLogs(th);
		}
	}

	/// Default implementation of flushing logs
	/// Saves logs to trace.json file in format acceptable by Google Chrome tracking tool chrome://tracing/ 
	/// Logs can be watched even if apllication crashed, but might require removing last log entry from trace.json
	void defaultFlushLogs(ThreadData* threadData, JobLog[] logs)
	{
		// (log rows num) * (static json length * time length * duration length)
		long start = useconds();
		size_t size = (logs.length + 1) * (128 + 20 + 20);
		size_t used = 0;

		foreach (ref log; logs)
		{
			size += log.name.length; // size of name
		}

		char* buffer = cast(char*) malloc(size);

		foreach (ref log; logs)
		{
			size_t charWritten;
			if (log.complete)
			{
				charWritten = snprintf(buffer + used, size - used,
						`{"name":"%s", "pid":1, "tid":%lld, "ph":"X", "ts":%lld,  "dur":%lld }, %s`,
						log.name.ptr, threadData.threadId + 1, log.time, log.duration, "\n".ptr);

			}
			else
			{
				charWritten = snprintf(buffer + used, size - used,
						`{"name":"%s", "pid":1, "tid":%lld, "ph":"B", "ts":%lld }, %s`,
						log.name.ptr, threadData.threadId + 1, log.time, "\n".ptr);
			}
			used += charWritten;
		}

		long end = useconds();
		size_t charWritten = snprintf(buffer + used, size - used,
				`{"name":"logFlush", "pid":1, "tid":%lld, "ph":"X", "ts":%lld,  "dur":%lld }, %s`,
				threadData.threadId + 1, start, end - start, "\n".ptr);
		used += charWritten;
		fwrite(buffer, 1, used, logFile);
	}

private:
	/// Atomic lock
	void lockThreadsData()
	{
		// Only one thread at a time can change threads number in a threadpool
		while (!cas(&threadsDataLock, false, true))
		{
		}
	}

	/// Atomic unlock
	void unlockThreadsData()
	{
		atomicStore(threadsDataLock, false);
	}

	/// Allocate ThreadData
	ThreadData* makeThreadData()
	{
		ThreadData* threadData = makeVar!ThreadData();
		threadData.logs = makeVarArray!(JobLog)(logsCacheNum);
		return threadData;
	}

	/// Dispose ThreadData
	void disposeThreadData(ThreadData* threadData)
	{
		disposeArray(threadData.logs);
		return disposeVar(threadData);
	}

	/// Get thread most suiting to add job to
	ThreadData* getThreadDataToAddJobTo()
	{
		int threadNum = atomicOp!"+="(threadSelector, 1);

		foreach (i; 0 .. 1_000)
		{
			if (threadNum >= threadsNum)
			{
				threadNum = 0;
				atomicStore(threadSelector, 0);
			}
			ThreadData* threadData = threadsData[threadNum];
			if (threadData != null)
			{
				return threadData;
			}
			threadNum++;
		}
		assert(0);
	}

	/// Create log on start of job
	void onStartJob(JobData* data, ThreadData* threadData)
	{

		threadData.jobsDoneCount++;
		version (MM_NO_LOGS)
		{
		}
		else
		{
			if (cast(int) threadData.logs.length <= 0)
			{
				return;
			}
			if (threadData.lastLogIndex >= cast(int) threadData.logs.length - 1)
			{
				onThreadFlushLogs(threadData);
			}

			threadData.lastLogIndex++;

			JobLog log;
			log.name = data.name;
			log.time = useconds();
			log.complete = false;
			threadData.logs[threadData.lastLogIndex] = log;

		}
	}

	/// Set log finish time on end of job
	void onEndJob(JobData* data, ThreadData* threadData)
	{
		version (MM_NO_LOGS)
		{
		}
		else
		{
			if (cast(int) threadData.logs.length <= 0)
			{
				return;
			}
			assert(threadData.lastLogIndex < threadData.logs.length);
			JobLog* log = &threadData.logs[threadData.lastLogIndex];
			log.duration = useconds() - log.time;
			log.complete = true;
		}
	}

	/// Flush logs
	void onThreadFlushLogs(ThreadData* threadData)
	{
		scope (exit)
		{
			threadData.lastLogIndex = -1;
		}

		assert(threadData);

		if (threadData.lastLogIndex < 0 || onFlushLogs is null)
		{
			return;
		}

		onFlushLogs(threadData, threadData.logs[0 .. threadData.lastLogIndex + 1]);
	}

	// Steal job from another thread
	JobData* stealJob(int threadNum)
	{
		foreach (thSteal; 0 .. atomicLoad(threadsNum))
		{
			if (thSteal == threadNum)
				continue; // Do not steal from requesting thread

			ThreadData* threadData = threadsData[thSteal];

			if (threadData is null || !threadData.semaphore.tryWait())
				continue;

			JobData* data = threadData.jobsToDo.pop();

			assert(data !is null);
			return data;
		}
		return null;
	}
}

/// Adding groups of jobs is faster and groups can have dependices between each other
struct JobsGroup
{
public:
	string name; /// Name of group
	JobData[] jobs; /// Jobs to be executed by this group, jobs have to live as long as group lives
	ThreadPool* thPool; /// Thread pool of this group
	void delegate(JobsGroup* group) onFinish; // Delegate called when group will finish, can be used to free memory

	this(string name, JobData[] jobs = [])
	{
		this.name = name;
		this.jobs = jobs;
		jobsToBeDoneCount = 0;
	}

	/// Make this group dependant from another group
	/// Dependant group won';'t start untill its dependices will be fulfilled
	void dependantOn(JobsGroup* parent)
	{
		size_t newLen = parent.children.length + 1;
		size_t elSize = (JobsGroup*).sizeof;
		JobsGroup** ptr = cast(JobsGroup**) malloc(newLen * elSize);
		JobsGroup*[] arr = ptr[0 .. newLen];
		memcpy(arr.ptr, parent.children.ptr, elSize * parent.children.length);
		arr[$ - 1] = &this;
		free(parent.children.ptr);
		parent.children = arr;
		// parent.children ~= &this;
		atomicOp!"+="(dependicesWaitCount, 1);
	}

private:
	JobsGroup* spawnedByGroup; /// Group which spawned this group, if present spwaning group is waiting for this group to finish
	JobsGroup*[] children; /// Groups depending on this group
	align(64) shared int dependicesWaitCount; /// Count of dependices this group waits for
	align(64) shared int jobsToBeDoneCount; /// Number of this group jobs still executing

	/// Checks if depending groups or spawning group have to be started
	/// Executes user onFinish function
	void onGroupFinish()
	{

		decrementChildrenDependices();
		if (spawnedByGroup)
		{
			auto num = atomicOp!"-="(spawnedByGroup.jobsToBeDoneCount, 1);
			if (num == 0)
			{
				spawnedByGroup.onGroupFinish();
			}
		}
		if (onFinish)
			onFinish(&this);
	}

	/// Check if decrement dependices counter and start them if theirs dependices are fulfilled
	void decrementChildrenDependices()
	{
		foreach (JobsGroup* group; children)
		{
			auto num = atomicOp!"-="(group.dependicesWaitCount, 1);
			assert(num >= 0);
			if (num == 0)
			{
				thPool.addGroupAsynchronous(group); // All dependices of this group are fulfilled, so is already synchronized
			}
		}
	}
	/// Prepare jobs data for adding to thread pool
	void setUpJobs()
	{
		foreach (i; 0 .. jobs.length)
		{
			jobs[i].group = &this;
		}
	}

}

/// Main function executed by thread present in thread pool
/// Executes functions from its own queue
/// If there are no jobs in its queue, steals from another thread
/// If there is nothing to steal, sleeps on its semaphore for a while (stage when cpu is not used)
/// Sleep time is longer for jobs not accepting jobs, they don't exit because it is hard to guarantee that nobody is adding to them some job (thread might exit but job will be added anyway and application will malfunctio
/// Thread end only when it's queue is empty. Jobs shouldn't be added to queue after ThreadPool.waitThreads() call
private void threadFunc(ThreadData* threadData)
{
	ThreadPool* threadPool = threadData.threadPool;
	int threadNum = threadData.threadId;

	void someHelper()
	{

	}

	while (!atomicLoad!(MemoryOrder.raw)(threadData.end) || !threadData.jobsToDo.empty())
	{
		JobData* data;
		if (threadData.semaphore.tryWait())
		{
			data = threadData.jobsToDo.pop();
			assert(data !is null);
		}
		else
		{
			bool acceptJobs = atomicLoad!(MemoryOrder.raw)(threadData.acceptJobs);
			if (acceptJobs)
			{
				data = threadPool.stealJob(threadNum);
			}

			if (data is null)
			{
				// Thread does not have own job and can not steal it, so wait for a job 
				bool ok = threadData.semaphore.timedWait(1_000 + !acceptJobs * 10_000);
				if (ok)
				{
					data = threadData.jobsToDo.pop();
					assert(data !is null);
				}
			}
		}

		// Nothing to do
		if (data is null)
		{
			continue;
		}

		// Do the job
		threadPool.onStartJob(data, threadData);
		data.del(threadData, data);
		threadPool.onEndJob(data, threadData);
		if (data.group) ///////////////////////////////////////////////
		{
			auto num = atomicOp!"-="(data.group.jobsToBeDoneCount, 1);
			if (num == 0)
			{
				data.group.onGroupFinish();
			}
		}

	}
	assert(threadData.jobsToDo.empty());
}

//////////////////////////////////////////////
//////////////////// Test ////////////////////
//////////////////////////////////////////////

void testThreadPool()
{
	enum jobsNum = 1024 * 32;

	ThreadPool thPool;
	thPool.initialize();
	ThreadData* mainThread = thPool.registerExternalThread();
	JobData startFrameJobData;

	JobData[jobsNum] frameJobs;
	shared int frameNum;

	struct TestApp
	{
		void startFrame(ThreadData* threadData, JobData* startFrameJobData)
		{
			changeThreadsNum();
			startFrameJobData.del = &continueFrameInOtherJob;
			startFrameJobData.name = "cont frm";
			thPool.addJobAsynchronous(startFrameJobData); /// startFrame is the only job in thread pool no synchronization is required
		}

		void continueFrameInOtherJob(ThreadData* threadData, JobData* startFrameJobData)
		{
			static struct JobGroupMemory
			{
				JobsGroup group;
				TestApp* app;
				JobData* startFrameJobData;

				void freeAndContinue(JobsGroup* group)
				{
					startFrameJobData.del = &app.finishFrame;
					startFrameJobData.name = "finishFrame";
					group.thPool.addJobAsynchronous(startFrameJobData); /// startFrameJobData is continuation of 'startFrame data', all important jobs finished so it is the only job, no synchronization required
					disposeVar!(JobGroupMemory)(&this);
				}
			}

			JobGroupMemory* important = makeVar!JobGroupMemory();
			important.app = &this;
			important.startFrameJobData = startFrameJobData;

			foreach (ref j; frameJobs)
				j = JobData(&this.importantTask, "vip");

			important.group = JobsGroup("a lot of jobs", frameJobs[]);
			important.group.onFinish = &important.freeAndContinue;

			thPool.addGroupAsynchronous(&important.group); // No Synchronization required continueFrameInOtherJob is the only job
		}

		void importantTask(ThreadData* threadData, JobData* data)
		{
			// All tasks created here will, make 'important' wait with finish untill this jobs will finish

			/// Add 10 tasks in group
			static struct JobGroupMemory
			{
				JobsGroup group;
				JobData[128] jobs;

				void freeMee(JobsGroup* group)
				{
					disposeVar!(JobGroupMemory)(&this);
				}
			}

			JobGroupMemory* subGroup = makeVar!JobGroupMemory();

			foreach (ref j; subGroup.jobs)
				j = JobData(&this.importantTaskSubTask, "vip sub");

			subGroup.group = JobsGroup("10 jobs", subGroup.jobs[]);
			subGroup.group.onFinish = &subGroup.freeMee;
			thPool.addGroup(&subGroup.group, data.group);

			/// Add single tasks
			data.del = &importantTaskSubTask;
			data.name = "sub";
			thPool.addJob(data);
		}

		void importantTaskSubTask(ThreadData* threadData, JobData* data)
		{

		}

		void finishFrame(ThreadData* threadData, JobData* startFrameJobData)
		{
			auto num = atomicOp!"+="(frameNum, 1);
			// writeln(num);
			if (num == 10)
			{
				thPool.releaseExternalThreads(); // After 10 frames exit application
				return;
			}
			*startFrameJobData = JobData(&startFrame, "StartFrame"); //
			thPool.addJobAsynchronous(startFrameJobData); // Start next frame, there should't be any other tasks execept of this one, so no synchronization is required

		}

		void changeThreadsNum()
		{
			// import std.random : uniform;

			// bool change = uniform(0, 100) == 3;
			// if (!change)
			// 	return;

			// int threadsNum = uniform(3, 5);
			// thPool.setThreadsNum(threadsNum);

		}
	}

	void testThreadsNum(int threadsNum)
	{
		frameNum = 0;
		thPool.jobsDoneCountReset();
		thPool.setThreadsNum(threadsNum);

		TestApp testApp = TestApp();
		startFrameJobData = JobData(&testApp.startFrame, "StartFrame"); // Start first frame, will live as long as main thread won't exit from threadStartFunc()

		ulong start = useconds();
		thPool.addJobAsynchronous(&startFrameJobData); // Synchronization is made by groupEnd (last job in pool) which calls thPool.releaseExternalThreads();
		mainThread.threadStartFunc();
		ulong end = useconds();
		printf("Threads Num: %2d. Jobs: %d. Time: %5.2f ms. jobs/ms: %5.2f\n", threadsNum, thPool.jobsDoneCount,
				(end - start) / 1000.0f, thPool.jobsDoneCount / ((end - start) / 1000.0f));
	}

	//while (1)
	{
		// foreach (i; 1 .. 32)
		// 	testThreadsNum(i);

		// testThreadsNum(1);
		// testThreadsNum(4);
		testThreadsNum(16);
	}
	thPool.flushAllLogs();
	thPool.waitThreads();
	thPool.unregistExternalThread(mainThread);

}

version (D_BetterC)
{

	extern (C) int main(int argc, char*[] argv) // for betterC
	{
		testThreadPool();
		return 0;
	}
}
else
{
	int main() // extern (C) int main(int argc, char*[] argv) // for betterC
	{
		testThreadPool();
		return 0;
	}
}
// Compile
// rdmd -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
// ldmd2 -release -inline -checkaction=C -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
// ldmd2 -checkaction=C -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
