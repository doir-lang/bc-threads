module bc.threadpool;

import fp.dynarray;
import fp.pointer;
import bc.thread;
import bc.mutex;
import bc.semaphore;
import core.atomic : atomicOp, atomicLoad, atomicStore;

@nogc nothrow:

public import bc.platform : threadingSupported;
import bc.thread : hardwareConcurrency;
import bc.platform : PthreadBackendMixin;

// version identifiers are module-local, so bc.platform's `PthreadBackend`
// tag doesn't reach here - mixin the shared declaration for the
// extern(C)/extern(Windows) worker entry point below, which must match
// bc.thread.ThreadFunction exactly.
mixin(PthreadBackendMixin);
version (Windows) import core.sys.windows.windows : DWORD;


alias JobFunction = void function(void*) @nogc nothrow;

struct Job {
	JobFunction fn;
	void* arg;
}


static if (threadingSupported) {

	struct ThreadPool {
		Semaphore wake;
		Semaphore done;

		Job* queue = null;
		Mutex queueLock;

		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;

		private bc.thread.Thread* handles = null;
		private size_t count = 0;
	}

	private Job claimJob(ThreadPool* pool) @trusted @nogc nothrow {
		bc.mutex.writeLock(pool.queueLock);
		Job job = *fp.dynarray.back(pool.queue);
		fp.dynarray.popBack(pool.queue);
		bc.mutex.writeUnlock(pool.queueLock);
		return job;
	}

	private void workerLoop(ThreadPool* pool) @trusted @nogc nothrow {
		while (true) {
			bc.semaphore.wait(pool.wake);
			if (atomicLoad(pool.stopping)) return;
			Job job = claimJob(pool);
			job.fn(job.arg);
			atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
			bc.semaphore.post(pool.done);
		}
	}

	version (PthreadBackend) {
		extern (C) private void* workerMain(void* arg) @nogc nothrow {
			workerLoop(cast(ThreadPool*) arg);
			return null;
		}
	} else version (Windows) {
		extern (Windows) private DWORD workerMain(void* arg) @nogc nothrow {
			workerLoop(cast(ThreadPool*) arg);
			return 0;
		}
	}

	ThreadPool* create(size_t workerCount = 0) @trusted @nogc nothrow {
		auto pool = fp.pointer.malloc!ThreadPool(1);
		*pool = ThreadPool.init;
		pool.count = workerCount > 0 ? workerCount : hardwareConcurrency();
		fp.dynarray.growToSize(pool.handles, pool.count);

		pool.wake = bc.semaphore.create(0);
		pool.done = bc.semaphore.create(0);
		pool.queueLock = bc.mutex.create();

		foreach (i; 0 .. pool.count)
			pool.handles[i] = bc.thread.create(&workerMain, pool);
		return pool;
	}

	size_t workerCount(const ThreadPool* pool) @nogc nothrow { return pool.count; }

	size_t pendingJobs(const ThreadPool* pool) @trusted @nogc nothrow {
		return cast(size_t) atomicLoad(pool.outstanding);
	}

	void submit(ThreadPool* pool, scope Job[] jobs) @trusted @nogc nothrow {
		if (jobs.length == 0) return;

		bc.mutex.writeLock(pool.queueLock);
		foreach (ref job; jobs) fp.dynarray.pushBack(pool.queue, job);
		bc.mutex.writeUnlock(pool.queueLock);

		atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		foreach (_; 0 .. jobs.length) bc.semaphore.post(pool.wake);
	}

	void wait(ThreadPool* pool) @trusted @nogc nothrow {
		while (atomicLoad(pool.outstanding) > 0) bc.semaphore.wait(pool.done);
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
		foreach (i; 0 .. pool.count) bc.semaphore.post(pool.wake);
		foreach (i; 0 .. pool.count) bc.thread.join(pool.handles[i]);
		bc.semaphore.free(pool.wake);
		bc.semaphore.free(pool.done);
		bc.mutex.free(pool.queueLock);
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
