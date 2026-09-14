module bct.threadpool;

import fp.dynarray;
import fp.pointer;
import core.atomic : atomicOp, atomicLoad, atomicStore, cas;

@nogc nothrow:

version (linux) {
	import core.sys.posix.pthread : pthread_t, pthread_create, pthread_join;
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
	import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
	enum bool threadingSupported = true;
	version = PthreadBackend;
} else version (OSX) {
	import core.sys.posix.pthread : pthread_t, pthread_create, pthread_join;
	import core.stdc.errno : errno, EINTR;
	import core.sys.darwin.mach.kern_return : KERN_ABORTED;
	import core.sys.darwin.mach.semaphore :
		mach_task_self, semaphore_create, semaphore_destroy, semaphore_signal,
		semaphore_t, semaphore_wait, SYNC_POLICY_FIFO;
	import core.sys.darwin.sys.sysctl : sysctlbyname;
	enum bool threadingSupported = true;
	version = PthreadBackend;
} else version (Windows) {
	import core.sys.windows.windows :
		HANDLE, DWORD, CreateThread, WaitForSingleObject, CloseHandle,
		INFINITE, GetSystemInfo, SYSTEM_INFO, CreateSemaphoreA, ReleaseSemaphore;
	enum bool threadingSupported = true;
} else {
	enum bool threadingSupported = false;
}


size_t hardwareConcurrency() @trusted @nogc nothrow {
	version (linux) {
		immutable n = sysconf(_SC_NPROCESSORS_ONLN);
		return n > 0 ? cast(size_t) n : 1;
	} else version (OSX) {
		uint n;
		size_t len = n.sizeof;
		sysctlbyname("hw.physicalcpu", &n, &len, null, 0);
		return n > 0 ? cast(size_t) n : 1;
	} else version (Windows) {
		SYSTEM_INFO info;
		GetSystemInfo(&info);
		return info.dwNumberOfProcessors > 0 ? cast(size_t) info.dwNumberOfProcessors : 1;
	} else
		return 1;
}


alias JobFn = void function(void*) @nogc nothrow;

struct Job {
	JobFn fn;
	void* arg;
}


static if (threadingSupported) {

	version (linux) {
		private void semInit(ref sem_t s) @trusted @nogc nothrow { sem_init(&s, 0, 0); }
		private void semWait(ref sem_t s) @trusted @nogc nothrow { sem_wait(&s); }
		private void semPost(ref sem_t s) @trusted @nogc nothrow { sem_post(&s); }
		private void semDestroy(ref sem_t s) @trusted @nogc nothrow { sem_destroy(&s); }
	} else version (OSX) {
		private void semInit(ref semaphore_t s) @trusted @nogc nothrow {
			semaphore_create(mach_task_self(), &s, SYNC_POLICY_FIFO, 0);
		}
		private void semWait(ref semaphore_t s) @trusted @nogc nothrow {
			while(true) {
				immutable rc = semaphore_wait(s);
				if(!rc) return;
				if(rc == KERN_ABORTED && errno == EINTR) continue;
				return;
			}
		}
		private void semPost(ref semaphore_t s) @trusted @nogc nothrow { semaphore_signal(s); }
		private void semDestroy(ref semaphore_t s) @trusted @nogc nothrow { semaphore_destroy(mach_task_self(), s); }
	} else version (Windows) {
		private void semInit(ref HANDLE h) @trusted @nogc nothrow { h = CreateSemaphoreA(null, 0, int.max, null); }
		private void semWait(ref HANDLE h) @trusted @nogc nothrow { WaitForSingleObject(h, INFINITE); }
		private void semPost(ref HANDLE h) @trusted @nogc nothrow { ReleaseSemaphore(h, 1, null); }
		private void semDestroy(ref HANDLE h) @trusted @nogc nothrow { CloseHandle(h); }
	}

	struct ThreadPool {
		version (linux) sem_t wake;
		else version (OSX) semaphore_t wake;
		else version (Windows) HANDLE wake;

		version (linux) sem_t done;
		else version (OSX) semaphore_t done;
		else version (Windows) HANDLE done;

		Job* queue = null;
		shared uint queueLock = 0;

		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;

		version (PthreadBackend) private pthread_t* handles = null;
		else version (Windows) private HANDLE* handles = null;
		private size_t count = 0;
	}

	private Job claimJob(ThreadPool* pool) @trusted @nogc nothrow {
		while (!cas(&pool.queueLock, cast(uint) 0, cast(uint) 1)) {}
		Job job = *fp.dynarray.back(pool.queue);
		fp.dynarray.popBack(pool.queue);
		atomicStore(pool.queueLock, cast(uint) 0);
		return job;
	}

	version (PthreadBackend) {
		extern (C) private void* workerMain(void* arg) @nogc nothrow {
			auto pool = cast(ThreadPool*) arg;
			while (true) {
				semWait(pool.wake);
				if (atomicLoad(pool.stopping)) return null;
				Job job = claimJob(pool);
				job.fn(job.arg);
				atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
				semPost(pool.done);
			}
		}
	} else version (Windows) {
		extern (Windows) private DWORD workerMain(void* arg) @nogc nothrow {
			auto pool = cast(ThreadPool*) arg;
			while (true) {
				semWait(pool.wake);
				if (atomicLoad(pool.stopping)) return 0;
				Job job = claimJob(pool);
				job.fn(job.arg);
				atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
				semPost(pool.done);
			}
		}
	}

	ThreadPool* create(size_t workerCount = 0) @trusted @nogc nothrow {
		auto pool = fp.pointer.malloc!ThreadPool(1);
		*pool = ThreadPool.init;
		pool.count = workerCount > 0 ? workerCount : hardwareConcurrency();
		fp.dynarray.growToSize(pool.handles, pool.count);

		semInit(pool.wake);
		semInit(pool.done);

		foreach (i; 0 .. pool.count)
			version (PthreadBackend) pthread_create(&pool.handles[i], null, &workerMain, pool);
			else version (Windows) pool.handles[i] = CreateThread(null, 0, &workerMain, pool, 0, null);
		return pool;
	}

	size_t workerCount(const ThreadPool* pool) @nogc nothrow { return pool.count; }

	size_t pendingJobs(const ThreadPool* pool) @trusted @nogc nothrow {
		return cast(size_t) atomicLoad(pool.outstanding);
	}

	void submit(ThreadPool* pool, scope Job[] jobs) @trusted @nogc nothrow {
		if (jobs.length == 0) return;

		while (!cas(&pool.queueLock, cast(uint) 0, cast(uint) 1)) {}
		foreach (ref job; jobs) fp.dynarray.pushBack(pool.queue, job);
		atomicStore(pool.queueLock, cast(uint) 0);

		atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		foreach (_; 0 .. jobs.length) semPost(pool.wake);
	}

	void wait(ThreadPool* pool) @trusted @nogc nothrow {
		while (atomicLoad(pool.outstanding) > 0) semWait(pool.done);
	}

	void waitJobCount(ThreadPool* pool, size_t count) @trusted @nogc nothrow {
		while (atomicLoad(pool.outstanding) > cast(ptrdiff_t) count) {}
	}

	void run(ThreadPool* pool, scope Job[] jobs) @trusted @nogc nothrow {
		immutable pending = pendingJobs(pool);
		submit(pool, jobs);
		waitJobCount(pool, pending);
	}

	void free(ThreadPool* pool) @trusted @nogc nothrow {
		if (pool is null || pool.handles is null) return;
		atomicStore(pool.stopping, true);
		foreach (i; 0 .. pool.count) semPost(pool.wake);
		foreach (i; 0 .. pool.count) {
			version (PthreadBackend) pthread_join(pool.handles[i], null);
			else version (Windows) { WaitForSingleObject(pool.handles[i], INFINITE); CloseHandle(pool.handles[i]); }
		}
		semDestroy(pool.wake);
		semDestroy(pool.done);
		fp.dynarray.free(pool.queue);
		fp.dynarray.free(pool.handles);
		fp.pointer.free(pool);
	}

} else {

	struct ThreadPool {}

	ThreadPool* create(size_t workerCount = 0) @trusted @nogc nothrow {
		return fp.pointer.malloc!ThreadPool(1);
	}

	size_t workerCount(const ThreadPool* pool) @nogc nothrow { return 1; }

	size_t pendingJobs(const ThreadPool* pool) @nogc nothrow { return 0; }

	void submit(ThreadPool* pool, scope Job[] jobs) @nogc nothrow {
		foreach (ref job; jobs) job.fn(job.arg);
	}

	void wait(ThreadPool* pool) @nogc nothrow {}

	void waitJobCount(ThreadPool* pool, size_t count) @nogc nothrow {}

	void run(ThreadPool* pool, scope Job[] jobs) @nogc nothrow {
		submit(pool, jobs);
	}

	void free(ThreadPool* pool) @trusted @nogc nothrow {
		fp.pointer.free(pool);
	}
}


unittest {
	static struct Counter { int value; }

	static void increment(void* arg) @nogc nothrow {
		auto c = cast(Counter*) arg;
		c.value++;
	}

	auto pool = create(4);
	scope(exit) free(pool);
	assert(workerCount(pool) >= 1);

	immutable n = workerCount(pool);
	Counter* counters = fp.dynarray.create!Counter(n);
	scope(exit) fp.dynarray.free(counters);
	foreach (ref c; fp.dynarray.slice(counters)) c.value = 0;

	Job* jobs = fp.dynarray.create!Job(n);
	scope(exit) fp.dynarray.free(jobs);
	foreach (i, ref job; fp.dynarray.slice(jobs)) job = Job(&increment, &counters[i]);

	run(pool, fp.dynarray.slice(jobs));
	foreach (ref c; fp.dynarray.slice(counters)) assert(c.value == 1);

	// Reusing the same pool for a second, smaller batch works too.
	run(pool, jobs[0 .. 1]);
	assert(counters[0].value == 2);
}


unittest {
	// `run` queues jobs rather than requiring one per worker: with more
	// jobs than workers, idle workers keep pulling from the queue until
	// it's drained instead of every job needing its own worker slot.
	static struct Counter { int value; }

	static void increment(void* arg) @nogc nothrow {
		auto c = cast(Counter*) arg;
		c.value++;
	}

	auto pool = create(4);
	scope(exit) free(pool);

	enum n = 97; // deliberately not a multiple of the worker count
	Counter[n] counters;
	foreach (ref c; counters) c.value = 0;

	Job[n] jobs;
	foreach (i; 0 .. n) jobs[i] = Job(&increment, &counters[i]);

	run(pool, jobs[]);
	foreach (ref c; counters) assert(c.value == 1);

	// Draining a second, differently-sized batch through the same queue
	// works too.
	run(pool, jobs[0 .. 10]);
	foreach (i; 0 .. 10) assert(counters[i].value == 2);
	foreach (i; 10 .. n) assert(counters[i].value == 1);
}


unittest {
	static struct Node {
		int depth;
		ThreadPool* pool;
		shared int* totalRuns;
		Node[] childSlots;
		Job[] childJobSlots;
	}

	enum maxDepth = 2;
	enum childCount = 3;

	static void runNode(void* arg) @nogc nothrow {
		auto node = cast(Node*) arg;
		atomicOp!"+="(*node.totalRuns, 1);
		if (node.depth >= maxDepth) return;

		foreach (i, ref slot; node.childSlots) {
			slot = Node(node.depth + 1, node.pool, node.totalRuns, null, null);
			node.childJobSlots[i] = Job(&runNode, &slot);
		}
		submit(node.pool, node.childJobSlots);
	}

	auto pool = create(4);
	scope(exit) free(pool);

	shared int totalRuns = 0;
	enum rootCount = 2;
	enum totalChildren = rootCount * childCount;

	Node[totalChildren] childNodes;
	Job[totalChildren] childJobs;
	Node[rootCount] roots;
	Job[rootCount] rootJobs;
	foreach (i; 0 .. rootCount) {
		roots[i] = Node(0, pool, &totalRuns,
			childNodes[i * childCount .. (i + 1) * childCount],
			childJobs[i * childCount .. (i + 1) * childCount]);
		rootJobs[i] = Job(&runNode, &roots[i]);
	}

	run(pool, rootJobs[]);

	assert(totalRuns == rootCount + totalChildren);
}


unittest {
	static struct Counter { int value; }

	static void increment(void* arg) @nogc nothrow {
		auto c = cast(Counter*) arg;
		c.value++;
	}

	auto pool = create(4);
	scope(exit) free(pool);

	enum n = 16;
	Counter[n] counters;
	foreach (ref c; counters) c.value = 0;
	Job[n] jobs;
	foreach (i; 0 .. n) jobs[i] = Job(&increment, &counters[i]);

	submit(pool, jobs[]);
	wait(pool);
	foreach (ref c; counters) assert(c.value == 1);

	submit(pool, jobs[0 .. 8]);
	submit(pool, jobs[8 .. n]);
	wait(pool);
	foreach (ref c; counters) assert(c.value == 2);
}
