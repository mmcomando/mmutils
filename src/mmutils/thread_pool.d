module mmutils.thread_pool;

import core.atomic;
import core.stdc.stdio;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy;

import std.stdio;
import std.algorithm : map;

version = MM_NO_LOGS; // Disable log creation
// version = MM_USE_POSIX_THREADS; // Use posix threads insted of standard library, required for betterC

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
}

T* makeVar(T)()
{
	T init;
	T* el = cast(T*) malloc(T.sizeof);
	memcpy(el, &init, T.sizeof);
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
	return arr;
}

void disposeVar(T)(T* var)
{
	destroy(*var);
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
//////////////////// Pause ///////////////////
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

	private extern (C) void* threadRunFunc(void* threadVoid)
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
			int ok = pthread_create(&handle, null, &threadRunFunc, cast(void*)&this);
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
}

/// First in first out queue with atomic lock
struct JobQueue
{
	alias LockType = long;
	align(64) shared LockType lock; /// Lock for accesing list of Jobs
	align(64) JobData* first; /// Fist element in list of Jobs

	/// Check if empty without locking, doesn't give guarantee that list is truly empty
	bool emptyRaw()
	{
		bool isEmpty = first == null;
		return isEmpty;
	}

	/// Check if empty
	bool empty()
	{
		while (!cas(&lock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		bool isEmpty = first == null;
		atomicStore!(MemoryOrder.rel)(lock, cast(LockType) false);
		return isEmpty;
	}

	/// Add job to queue
	void add(JobData* t)
	{
		while (!cas(&lock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		t.next = first;
		first = t;

		atomicStore!(MemoryOrder.rel)(lock, cast(LockType) false);
	}

	/// Add range of jobs to queue
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

		while (!cas(&lock, cast(LockType) false, cast(LockType) true))
			instructionPause();
		last.next = first;
		first = start;
		atomicStore!(MemoryOrder.rel)(lock, cast(LockType) false);
	}

	/// Pop job from queue
	JobData* pop()
	{
		while (!cas(&lock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		if (first == null)
		{
			atomicStore!(MemoryOrder.rel)(lock, cast(LockType) false);
			return null;
		}

		JobData* result = first;
		first = first.next;

		atomicStore!(MemoryOrder.rel)(lock, cast(LockType) false);
		return result;
	}

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

	/// Function starting execution of thread main loop
	/// External threads can call this function to start executing jobs
	void threadStartFunc()
	{
		end = false;
		threadFunc(&this);
	}

private:
	JobQueue jobsQueue; /// Queue of jobs to be done, jobs can be stolen from another thread
	JobQueue jobsExclusiveQueue; /// Queue of jobs to be done, jobs can't be stolen
	align(64) Semaphore semaphore; /// Semaphore to wake/sleep this thread
	align(64) Thread thread; /// Systemn thread handle
	JobLog[] logs; /// Logs cache
	int lastLogIndex = -1; /// Last created log index
	int jobsDoneCount;

	shared bool end; /// Check if thread has to exit. Thread will exit only if end is true and jobsToDo is empty
	shared bool acceptJobs; /// Check if thread should accept new jobs, If false thread won't steal jobs from other threads and will sleep longer if queue js empty
	bool externalThread; /// Thread not allocated by thread pool

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
	align(64) shared int threadsNum; /// Number of threads currentlu accepting jobs
	align(64) shared bool threadsDataLock; /// Any modification of threadsData array (change in size or pointer modification) had to be locked
	align(64) shared int threadSelector; /// Index of thread to which add next job
	FILE* logFile; /// File handle for defaultFlushLogs log file
	JobData[4] resumeJobs; /// Dummu jobs to resume some thread

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

		foreach (ref JobData j; resumeJobs)
			j = JobData(&dummyJob, "Dummy-Resume");

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

	/// Clean ups ThreadPool
	~this()
	{
		if (logFile)
		{
			fclose(logFile);
			logFile = null;
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

			auto rng = resumeJobs[].map!((ref a) => &a);
			addJobsRange(rng, cast(int) i);
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
	/// If threadNum is different than -1 only thread with threadNum will be able to execute given job
	/// It is advised to use synchronized group of jobs
	void addJobAsynchronous(JobData* data, int threadNum = -1)
	{
		if (threadNum == -1)
		{
			ThreadData* threadData = getThreadDataToAddJobTo();
			threadData.jobsQueue.add(data);
			threadData.semaphore.post();
			return;
		}
		ThreadData* threadData = threadsData[threadNum];
		assert(threadData !is null);
		threadData.jobsExclusiveQueue.add(data);
		threadData.semaphore.post();
	}

	/// Adds job to be executed by thread pool, group specified in group data won't be finished until this job ends
	/// If threadNum is different than -1 only thread with threadNum will be able to execute given job
	void addJob(JobData* data, int threadNum = -1)
	{
		assert(data.group);
		atomicOp!"+="(data.group.jobsToBeDoneCount, 1);
		addJobAsynchronous(data, threadNum);
	}

	/// Adds multiple jobs at once
	/// Range has to return JobData*
	/// Range has to have length property
	/// Range is used so there is no need to allocate JobData*[]
	/// All jobs has to belong to one group
	/// If threadNum is different than -1 only thread with threadNum will be able to execute given jobs
	void addJobsRange(Range)(Range rng, int threadNum = -1)
	{
		if (threadNum != -1)
		{
			ThreadData* threadData = threadsData[threadNum];
			assert(threadData !is null);
			threadData.jobsExclusiveQueue.addRange(rng);
			foreach (sInc; 0 .. rng.length)
				threadData.semaphore.post();

			return;
		}

		if (rng.length == 0)
		{
			return;
		}

		foreach (JobData* threadData; rng)
		{
			assert(rng[0].group == threadData.group);
		}
		atomicOp!"+="(rng[0].group.jobsToBeDoneCount, cast(int) rng.length);
		int threadsNumLocal = threadsNum;
		int part = cast(int) rng.length / threadsNumLocal;
		if (part > 0)
		{
			foreach (i, ThreadData* threadData; threadsData[0 .. threadsNumLocal])
			{
				auto slice = rng[i * part .. (i + 1) * part];
				threadData.jobsQueue.addRange(slice);

				foreach (sInc; 0 .. part)
					threadData.semaphore.post();

			}
			rng = rng[part * threadsNumLocal .. $];
		}
		foreach (i, ThreadData* threadData; threadsData[0 .. rng.length])
		{
			threadData.jobsQueue.add(rng[i]);
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
		addJobsRange(rng, group.executeOnThreadNum);
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

			size_t charWritten = snprintf(buffer + used, size - used,
					`{"name":"%s", "pid":1, "tid":%lld, "ph":"X", "ts":%lld,  "dur":%lld }, %s`,
					log.name.ptr, threadData.threadId + 1, log.time, log.duration, "\n".ptr);
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

	/// Does nothing
	void dummyJob(ThreadData* threadData, JobData* data)
	{

	}

	/// Steal job from another thread
	JobData* stealJob(int threadNum)
	{
		foreach (thSteal; 0 .. atomicLoad(threadsNum))
		{
			if (thSteal == threadNum)
				continue; // Do not steal from requesting thread

			ThreadData* threadData = threadsData[thSteal];

			if (threadData is null || !threadData.semaphore.tryWait())
				continue;

			JobData* data = threadData.jobsQueue.pop();

			if (data is null)
				threadData.semaphore.post();

			return data;
		}
		return null;
	}
}

/// Adding groups of jobs is faster and groups can have dependencies between each other
struct JobsGroup
{
public:
	string name; /// Name of group
	JobData[] jobs; /// Jobs to be executed by this group, jobs have to live as long as group lives
	void delegate(JobsGroup* group) onFinish; // Delegate called when group will finish, can be used to free memory
	ThreadPool* thPool; /// Thread pool of this group
	int executeOnThreadNum = -1; /// Thread num to execute jobs on

	this(string name, JobData[] jobs = [], int executeOnThreadNum = -1)
	{
		this.name = name;
		this.jobs = jobs;
		this.executeOnThreadNum = executeOnThreadNum;
		jobsToBeDoneCount = 0;
	}

	~this()
	{
		free(children.ptr);
		children = null;
	}

	/// Make this group dependant from another group
	/// Dependant group won't start untill its dependencies will be fulfilled
	void dependantOn(JobsGroup* parent)
	{
		size_t newLen = parent.children.length + 1;
		JobsGroup** ptr = cast(JobsGroup**) realloc(parent.children.ptr,
				newLen * (JobsGroup*).sizeof);
		parent.children = ptr[0 .. newLen];
		parent.children[$ - 1] = &this;
		// parent.children ~= &this;
		atomicOp!"+="(dependenciesWaitCount, 1);
	}

	/// Returns number of dependencies this group is waiting for
	int getDependenciesWaitCount()
	{
		return atomicLoad(dependenciesWaitCount);
	}

private:
	JobsGroup* spawnedByGroup; /// Group which spawned this group, if present spwaning group is waiting for this group to finish
	JobsGroup*[] children; /// Groups depending on this group
	align(64) shared int dependenciesWaitCount; /// Count of dependencies this group waits for
	align(64) shared int jobsToBeDoneCount; /// Number of this group jobs still executing

	/// Checks if depending groups or spawning group have to be started
	/// Executes user onFinish function
	void onGroupFinish()
	{

		decrementChildrendependencies();
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

	/// Check if decrement dependencies counter and start them if theirs dependencies are fulfilled
	void decrementChildrendependencies()
	{
		foreach (JobsGroup* group; children)
		{
			auto num = atomicOp!"-="(group.dependenciesWaitCount, 1);
			assert(num >= 0);
			if (num == 0)
			{
				thPool.addGroupAsynchronous(group); // All dependencies of this group are fulfilled, so is already synchronized
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

	while (!atomicLoad!(MemoryOrder.raw)(threadData.end)
			|| !threadData.jobsQueue.empty() || !threadData.jobsExclusiveQueue.empty())
	{
		JobData* data;
		if (threadData.semaphore.tryWait())
		{
			if (!threadData.jobsExclusiveQueue.emptyRaw())
				data = threadData.jobsExclusiveQueue.pop();

			if (data is null)
				data = threadData.jobsQueue.pop();

			if (data is null)
				threadData.semaphore.post();

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

					if (!threadData.jobsExclusiveQueue.emptyRaw())
						data = threadData.jobsExclusiveQueue.pop();

					if (data is null)
						data = threadData.jobsQueue.pop();

					if (data is null)
						threadData.semaphore.post();
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
		if (data.group)
		{
			auto num = atomicOp!"-="(data.group.jobsToBeDoneCount, 1);
			if (num == 0)
			{
				data.group.onGroupFinish();
			}
		}

	}
	assert(threadData.jobsQueue.empty());
}

//////////////////////////////////////////////
//////////////////// Test ////////////////////
//////////////////////////////////////////////

void testThreadPool()
{
	enum jobsNum = 1024 * 4;

	ThreadPool thPool;
	thPool.initialize();

	ThreadData* mainThread = thPool.registerExternalThread(); // Register main thread as thread 0
	JobData startFrameJobData; // Variable to store job starting the TestApp

	JobData[jobsNum] frameJobs; // Array to store jobs created in TestApp.continueFrameInOtherJob
	shared int frameNum; // Simulate game loop, run jobs for few frames and exit

	// App starts as one job &startFrame
	// Then using own JobData memory spawns 'continueFrameInOtherJob' job
	// 'continueFrameInOtherJob' job fills frameJobs array with &importantTask jobs. Group created to run this jobs is freed using JobsGroup.onFinish delegate
	// 'importantTask' allocate new jobs (&importantTaskSubTask) and group, they all deallocated using JobsGroup.onFinish delegate
	// 'continueFrameInOtherJob' waits for all 'importantTask'.  All 'importantTask' wait for all 'importantTaskSubTask'. 
	// So after all 'importantTaskSubTask' and 'importantTask' are done 'continueFrameInOtherJob' ends and spawns &finishFrame
	// 'finishFrame' spawn new frame or exits application
	struct TestApp
	{
		// First job in frame
		// Do some stuff and spawn some other job
		// 1 - Number of jobs of this kind in frame
		void startFrame(ThreadData* threadData, JobData* startFrameJobData)
		{
			startFrameJobData.del = &continueFrameInOtherJobAAA;
			startFrameJobData.name = "cont frmAAA";
			thPool.addJobAsynchronous(startFrameJobData, thPool.threadsNum - 1); /// startFrame is the only job in thread pool no synchronization is required
		}

		void continueFrameInOtherJobAAA(ThreadData* threadData, JobData* startFrameJobData)
		{

			static struct JobGroupMemory
			{
				JobsGroup[6] groups;
				JobData[1][6] groupsJobs;
				TestApp* app;
				JobData* startFrameJobData;

				void spawnCont(JobsGroup* group)
				{
					// startFrameJobData.del = &continueFrameInOtherJob;
					startFrameJobData.del = &app.finishFrame;
					startFrameJobData.name = "cont frm";
					group.thPool.addJobAsynchronous(startFrameJobData); /// startFrame is the only job in thread pool no synchronization is required
					disposeVar!(JobGroupMemory)(&this);
				}
			}

			JobGroupMemory* memory = makeVar!JobGroupMemory();
			memory.app = &this;
			memory.startFrameJobData = startFrameJobData;

			with (memory)
			{
				groups[0] = JobsGroup("dependant 0", groupsJobs[0]);
				groups[1] = JobsGroup("dependant 1", groupsJobs[1]);
				groups[2] = JobsGroup("dependant 2", groupsJobs[2]);
				groups[3] = JobsGroup("dependant 3", groupsJobs[3]);
				groups[4] = JobsGroup("dependant 4", groupsJobs[4]);
				groups[5] = JobsGroup("dependant 5", groupsJobs[5]);
				groups[5].onFinish = &spawnCont;

				groups[2].dependantOn(&groups[0]);
				groups[2].dependantOn(&groups[1]);

				groups[3].dependantOn(&groups[0]);
				groups[3].dependantOn(&groups[1]);
				groups[3].dependantOn(&groups[2]);

				groups[4].dependantOn(&groups[1]);
				groups[4].dependantOn(&groups[3]);

				groups[5].dependantOn(&groups[0]);
				groups[5].dependantOn(&groups[1]);
				groups[5].dependantOn(&groups[2]);
				groups[5].dependantOn(&groups[3]);
				groups[5].dependantOn(&groups[4]);

				foreach (ref jobs; groupsJobs)
					foreach (ref j; jobs)
						j = JobData(&this.importantTaskSubTask, "n");

				thPool.addGroupAsynchronous(&groups[0]);
				thPool.addGroupAsynchronous(&groups[1]);
			}
		}

		// Job for some big system
		// Spawns some jobs and when they are done spawns finishFrame job
		// 1 - Number of jobs of this kind in frame
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
					group.thPool.addJobAsynchronous(startFrameJobData, group.thPool.threadsNum - 1); /// startFrameJobData is continuation of 'startFrame data', all important jobs finished so it is the only job, no synchronization required. Always spawn on last thread
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

		// Some task which by itself does a lot of computation so it spawns few more jobs
		// jobsNum - Number of jobs of this kind in frame
		void importantTask(ThreadData* threadData, JobData* data)
		{
			// All tasks created here will, make 'importantTask' wait with finish untill this jobs will finish

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

			subGroup.group = JobsGroup("128 jobs", subGroup.jobs[]);
			subGroup.group.onFinish = &subGroup.freeMee;
			thPool.addGroup(&subGroup.group, data.group);

			/// Add single tasks
			data.del = &importantTaskSubTask;
			data.name = "sub";
			thPool.addJob(data);
		}

		// Job which simply does some work
		// jobsNum * 128 - Number of jobs of this kind in frame
		void importantTaskSubTask(ThreadData* threadData, JobData* data)
		{
		}

		// Finish frame
		// 1 - Number of jobs of this kind in frame
		void finishFrame(ThreadData* threadData, JobData* startFrameJobData)
		{
			auto num = atomicOp!"+="(frameNum, 1);
			if (num == 10)
			{
				thPool.releaseExternalThreads(); // After 10 frames exit application
				return;
			}
			*startFrameJobData = JobData(&startFrame, "StartFrame"); //
			thPool.addJobAsynchronous(startFrameJobData); // Start next frame, there should't be any other tasks execept of this one, so no synchronization is required

		}

		// Func to test if dynamic changing of threads number works
		// void changeThreadsNum()
		// {
		// 	import std.random : uniform;

		// 	bool change = uniform(0, 100) == 3;
		// 	if (!change)
		// 		return;

		// 	int threadsNum = uniform(3, 5);
		// 	thPool.setThreadsNum(threadsNum);

		// }
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

	while (1)
	{
		// foreach (i; 1 .. 32)
		// 	testThreadsNum(i);

		testThreadsNum(1);
		testThreadsNum(4);
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
	int main()
	{
		testThreadPool();
		return 0;
	}
}
// Compile
// -fsanitize=address
// rdmd -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
// ldmd2 -release -inline -checkaction=C -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
// ldmd2 -checkaction=C -g -of=thread_pool src/mmutils/thread_pool.d && ./thread_pool
