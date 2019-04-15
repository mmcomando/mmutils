module mmutils.thread_pool;

import core.atomic;
import core.stdc.stdio;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy;

import std.algorithm : map;

// version = MM_NO_LOGS; // Disable log creation
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

T* makeVar(T)(T init = T.init)
{
	T* el = cast(T*) malloc(T.sizeof);
	memcpy(el, &init, T.sizeof);
	return el;
}

T[] makeVarArray(T)(size_t num, T init = T.init)
{
	T* ptr = cast(T*) malloc(num * T.sizeof);
	T[] arr = ptr[0 .. num];
	foreach (ref el; arr)
	{
		memcpy(&el, &init, T.sizeof);
	}
	return arr;
}

void disposeVar(T)(T* var)
{
	free(var);
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

struct LowLockQueue(T, LockType = ulong)
{
private:
	static struct Node
	{
		this(T val)
		{
			value = val;
		}

		T value;
		align(64) Node* next;
	}

	align(64) Node* first;
	align(64) shared LockType consumerLock;
	align(64) Node* last;
	align(64) shared LockType producerLock;

public:

	void initialize()
	{
		first = last = makeVar!Node(Node.init);
		producerLock = consumerLock = false;

	}

	bool empty()
	{
		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		bool isEmpty = first.next == null;
		atomicStore(producerLock, false);
		return isEmpty;
	}

	void add(T t)
	{
		Node* tmp = makeVar!Node(Node(t));

		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		last.next = tmp;
		last = tmp;
		atomicStore(producerLock, false);

	}

	// Add every, nth element to better preserve execution order of input range
	void addRange(Range)(Range t, int start, int stride)
	{
		int len = cast(int) t.length;
		Node* firstInChain;
		Node* lastInChain;
		Node* tmp = makeVar!Node(Node(t[start]));
		firstInChain = tmp;
		lastInChain = tmp;
		for (int i = start + stride; i < len; i += stride) // foreach (i; 1 .. t.length)
		{
			tmp = makeVar!Node(Node(t[i]));
			lastInChain.next = tmp;
			lastInChain = tmp;
		}

		while (!cas(&producerLock, cast(LockType) false, cast(LockType) true))
			instructionPause();

		last.next = firstInChain;
		last = lastInChain;
		atomicStore(producerLock, cast(LockType) false);

	}

	T pop()
	{
		while (!cas(&consumerLock, cast(LockType) false, cast(LockType) true))
		{
		}

		Node* theFirst = first;
		Node* theNext = first.next;

		if (theNext != null)
		{
			T result = theNext.value;
			theNext.value = T.init;
			first = theNext;
			atomicStore(consumerLock, cast(LockType) false);

			disposeVar(theFirst);
			return result;
		}

		atomicStore(consumerLock, cast(LockType) false);
		return T.init;
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

version (MM_NO_LOGS)
	private enum gLogsCacheNum = 0;
else
	private enum gLogsCacheNum = 1024;

alias JobDelegate = void delegate(JobData*);

struct JobLog
{
	string name;
	ulong time;
	ulong duration;
	bool complete;
}

struct JobData
{
	JobDelegate del;
	string name;
	private JobsGroup* group;
}

alias MTQueue = LowLockQueue!(JobData*, bool);

struct ThreadData
{
	align(64) MTQueue jobsToDo;
	align(64) Semaphore semaphore;
	align(64) Thread thread;
	JobLog[] logs;
	int lastLogIndex = -1;
	ThreadPool* threadPool;

	int threadId;
	bool end;
	bool acceptJobs;
	bool externalThread;

	void threadStartFunc()
	{
		end = false;
		threadFunc(&this);
	}
}

struct ThreadPool
{
private:
	ThreadData*[gMaxThreadsNum] threadsData; // array
	align(64) shared int threadsNum;
	align(64) shared bool threadsDataLock; // Any modification of threadsData array (change in size or pointer modification) had to be locked
	align(64) int threadSelector;
	align(64) FILE* logFile;

public:

	void initialize()
	{
		logFile = fopen("trace.json", "w");
		fprintf(logFile, "[");
		fclose(logFile);
		logFile = fopen("trace.json", "a");
		assert(logFile !is null);
	}

	// Adds external thread to thread pool array
	ThreadData* addThisThreadToThreadPool()
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

	// Allows external threads to return from threadFunc
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

			th.end = true;
		}
	}

	void waitThreads()
	{
		lockThreadsData();
		scope (exit)
			unlockThreadsData();

		foreach (i, ref ThreadData* th; threadsData)
		{
			if (th is null)
				continue;

			th.acceptJobs = false;
			th.end = true;

			if (th.externalThread)
				continue;

			th.thread.join();
			disposeThreadData(th);
		}
	}

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
				th.acceptJobs = i < num;
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

	void addJobAsynchronous(JobData* data)
	{
		ThreadData* threadData = getThreadDataToAddJobTo();
		threadData.jobsToDo.add(data);
		threadData.semaphore.post();
	}

	void addJob(JobData* data)
	{
		assert(data.group);
		atomicOp!"+="(data.group.jobsToBeDoneCount, 1);
		addJobAsynchronous(data);
	}

	void addJobsRange(Range)(Range arr)
	{
		if (arr.length == 0)
		{
			return;
		}
		atomicOp!"+="(arr[0].group.jobsToBeDoneCount, cast(int) arr.length);
		int threadsNumLocal = threadsNum;
		int part = cast(int) arr.length / threadsNumLocal;
		if (part > 0)
		{
			auto slice = arr[0 .. threadsNumLocal * part];
			foreach (i, ThreadData* threadData; threadsData[0 .. threadsNumLocal])
			{
				threadData.jobsToDo.addRange(slice, cast(int) i, threadsNumLocal);

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

private:
	void lockThreadsData()
	{
		// Only one thread at a time can change threads number in a threadpool
		while (!cas(&threadsDataLock, false, true))
		{
		}
	}

	void unlockThreadsData()
	{
		atomicStore(threadsDataLock, false);
	}

	ThreadData* makeThreadData()
	{
		ThreadData* threadData = makeVar!ThreadData();
		threadData.jobsToDo.initialize();
		threadData.logs = makeVarArray!(JobLog)(gLogsCacheNum);
		return threadData;
	}

	void disposeThreadData(ThreadData* data)
	{
		return disposeVar(data);
	}

	ThreadData* getThreadDataToAddJobTo()
	{
		threadSelector++;
		int threadNum = threadSelector;

		foreach (i; 0 .. 1_000)
		{
			if (threadNum >= threadsNum)
			{
				threadNum = 0;
				threadSelector = 0;
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

	void onStartJob(JobData* data, ThreadData* threadData)
	{
		version (MM_NO_LOGS)
		{
		}
		else
		{
			if (threadData.lastLogIndex >= threadData.logs.length - 1)
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

	void onEndJob(JobData* data, ThreadData* threadData)
	{
		version (MM_NO_LOGS)
		{
		}
		else
		{
			assert(threadData.lastLogIndex < threadData.logs.length);
			JobLog* log = &threadData.logs[threadData.lastLogIndex];
			log.duration = useconds() - log.time + 3;
			log.complete = true;
		}
	}

	void onThreadFlushLogs(ThreadData* threadData)
	{
		version (MM_NO_LOGS)
		{
		}
		else
		{
			assert(threadData);

			long start = useconds();
			if (threadData.lastLogIndex < 0)
			{
				return;
			}
			size_t size = 0;
			size_t used = 0;

			// (log rows num) * (static json length * time length * duration length)
			size += (threadData.lastLogIndex + 1 + 1) * (128 + 20 + 20);

			foreach (ref log; threadData.logs[0 .. threadData.lastLogIndex + 1])
			{
				size += log.name.length; // size of name
			}

			char* buffer = cast(char*) malloc(size);

			foreach (ref log; threadData.logs[0 .. threadData.lastLogIndex + 1])
			{
				size_t charWritten;
				if (log.complete)
				{
					charWritten = snprintf(buffer + used, size - used,
							`{"name":"%s", "pid":1, "tid":%lld, "ph":"X", "ts":%lld,  "dur":%lld },`,
							log.name.ptr, threadData.threadId + 1, log.time, log.duration);

				}
				else
				{
					charWritten = snprintf(buffer + used, size - used,
							`{"name":"%s", "pid":1, "tid":%lld, "ph":"B", "ts":%lld },`,
							log.name.ptr, threadData.threadId + 1, log.time);
				}
				used += charWritten;
			}

			long end = useconds();
			size_t charWritten = snprintf(buffer + used, size - used,
					`{"name":"logFlush", "pid":1, "tid":%lld, "ph":"X", "ts":%lld,  "dur":%lld },`,
					threadData.threadId + 1, start, end - start);
			used += charWritten;
			fwrite(buffer, 1, used, logFile);
		}

		threadData.lastLogIndex = -1;
	}

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
	string name;
	JobData[] jobs;
	ThreadPool* thPool;

	this(ThreadPool* thPool, string name, JobData[] jobs = [])
	{
		this.name = name;
		this.jobs = jobs;
		this.thPool = thPool;
	}

	void start()
	{
		if (jobs.length == 0)
		{
			// Immediately call group end
			onGroupFinish();
			return;
		}

		setUpJobs();
		auto rng = jobs[].map!((ref a) => &a);
		thPool.addJobsRange(rng);
	}

private:
	JobsGroup*[] children;
	align(64) shared int dependicesWaitCount;
	align(64) shared int jobsToBeDoneCount;

	void dependantOn(JobsGroup* parent)
	{
		size_t newLen = parent.children.length + 1;
		size_t elSize = (JobsGroup*).sizeof;
		JobsGroup** ptr = cast(JobsGroup**) malloc(newLen * elSize);
		JobsGroup*[] arr = ptr[0 .. newLen];
		memcpy(arr.ptr, parent.children.ptr, elSize * parent.children.length);
		arr[$ - 1] = &this;
		parent.children = arr;

		atomicOp!"+="(dependicesWaitCount, 1);
	}

	void onGroupFinish()
	{
		decrementChildrenDependices();
	}

	void decrementChildrenDependices()
	{
		foreach (JobsGroup* group; children)
		{
			auto num = atomicOp!"-="(group.dependicesWaitCount, 1);
			assert(num >= 0);
			if (num == 0)
			{
				group.start();
			}
		}
	}

	void setUpJobs()
	{
		atomicStore(jobsToBeDoneCount, 0);

		foreach (i; 0 .. jobs.length)
		{
			jobs[i].group = &this;
		}
	}

}

private void threadFunc(ThreadData* threadData)
{
	ThreadPool* threadPool = threadData.threadPool;
	int threadNum = threadData.threadId;
	while (!threadData.end || !threadData.jobsToDo.empty())
	{
		JobData* data;
		if (threadData.semaphore.tryWait())
		{
			data = threadData.jobsToDo.pop();
			assert(data !is null);
		}
		else if (threadData.acceptJobs)
		{
			data = threadPool.stealJob(threadNum);

			if (data is null)
			{
				// Thread does not have own job and can not steal it, so wait for a job 
				bool ok = threadData.semaphore.timedWait(1_000);
				if (ok)
				{
					data = threadData.jobsToDo.pop();
					assert(data !is null);
				}
			}
		}
		else
		{
			bool ok = threadData.semaphore.timedWait(100_000);
			if (ok)
			{
				data = threadData.jobsToDo.pop();
				assert(data !is null);
			}
		}

		// Nothing to do
		if (data is null)
		{
			continue;
		}

		// Do the job
		threadPool.onStartJob(data, threadData);
		data.del(data);

		auto num = atomicOp!"-="(data.group.jobsToBeDoneCount, 1);
		if (num == 0)
		{
			data.group.onGroupFinish();
		}
		threadPool.onEndJob(data, threadData);

	}
	assert(threadData.jobsToDo.empty());
}

//////////////////////////////////////////////
//////////////////// Test ////////////////////
//////////////////////////////////////////////

void testThreadPool()
{
	enum jobsNum = 16 * 1024 * 4;

	ThreadPool thPool;
	thPool.initialize();
	ThreadData* threadData = thPool.addThisThreadToThreadPool();

	struct TestApp
	{
		void run(JobData* data)
		{
			changeThreadsNum();
			data.del = &run2;
			data.name = "run2";
			thPool.addJob(data);
		}

		void run2(JobData* data)
		{
			changeThreadsNum();
		}

		void stop(JobData* data)
		{
			thPool.releaseExternalThreads();
			// D_Thread.sleep(dur!"msecs"(1));
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
		thPool.setThreadsNum(threadsNum);
		TestApp testApp = TestApp();

		JobData[jobsNum] jobs;
		foreach (i; 0 .. jobsNum)
			jobs[i] = JobData(&testApp.run, "Run");

		JobsGroup mainGroup = JobsGroup(&thPool, "Main Group", jobs[]);

		JobData[1] groupEndJobs;
		groupEndJobs[0] = JobData(&testApp.stop, "Stop Threads");
		JobsGroup groupEnd = JobsGroup(&thPool, "End Group", groupEndJobs[]);
		groupEnd.dependantOn(&mainGroup);

		ulong start = useconds();
		mainGroup.start();
		threadData.threadStartFunc();
		ulong end = useconds();
		printf("Threads Num: %2d jobs/ms: %3.2f\n", threadsNum, jobsNum / ((end - start) / 1000.0f));
		// D_Thread.sleep(dur!"msecs"(10));
	}

	testThreadsNum(1);
	testThreadsNum(4);
	testThreadsNum(8);
	testThreadsNum(16);
	thPool.flushAllLogs();
	thPool.waitThreads();

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
