/// A fork-join thread pool: worker threads pulling `Job`s from one shared queue. Without threads, a pool runs each job inline on the calling thread, so callers need not branch on the platform.
module bc.threadpool;

static import bc.mutex;
static import bc.platform;
static import bc.semaphore;
static import bc.thread;
static import fp.dynarray;
static import fp.pointer;
public import bc.platform : threadingSupported;
import core.atomic : atomicOp, atomicLoad, atomicStore;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);
version (Windows) import core.sys.windows.windows : DWORD;


/// The function a `Job` runs, called with the job's `arg` on a worker thread.
alias JobFunction = void function(void*) @nogc nothrow;

/// One unit of work: a worker calls `fn(arg)`.
struct Job {
	JobFunction fn;
	void* arg;
}


static if (threadingSupported) {

	/// A pool of worker threads sharing one job queue, used through the pointer `create` returns. Its fields belong to the implementation.
	struct ThreadPool {
		bc.semaphore.Semaphore wake;
		bc.semaphore.Semaphore done;

		Job* queue = null;
		bc.mutex.Mutex* queueLock;

		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;

		private bc.thread.Thread* handles = null;
		private size_t count = 0;
	}


	/// How many worker threads `pool` has; always 1 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = create(3);
	/// assert(workerCount(pool) == 3);
	/// free(pool);
	/// ---
	size_t workerCount(const ThreadPool* pool) { return pool.count; }

	/// How many jobs submitted to `pool`, queued or running, have not finished; always 0 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = create(2);
	/// assert(pendingJobs(pool) == 0);
	/// free(pool);
	/// ---
	size_t pendingJobs(const ThreadPool* pool) @trusted {
		return cast(size_t) atomicLoad(pool.outstanding);
	}


	private Job claimJob(ThreadPool* pool) @trusted {
		bc.mutex.writeLock(pool.queueLock);
		Job job = *fp.dynarray.back(pool.queue);
		cast(void) fp.dynarray.popBack(pool.queue);
		bc.mutex.writeUnlock(pool.queueLock);
		return job;
	}

	private void workerLoop(ThreadPool* pool) @trusted {
		while (true) {
			// Every post to `wake` either stops the pool or follows one queued job, so the queue is not empty here.
			bc.semaphore.wait(pool.wake);
			if (atomicLoad(pool.stopping)) return;
			Job job = claimJob(pool);
			job.fn(job.arg);
			atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
			bc.semaphore.post(pool.done);
		}
	}

	version (PthreadBackend) {
		extern (C) private void* workerMain(void* arg) {
			workerLoop(cast(ThreadPool*) arg);
			return null;
		}
	} else version (Windows) {
		extern (Windows) private DWORD workerMain(void* arg) {
			workerLoop(cast(ThreadPool*) arg);
			return 0;
		}
	}


	/// Stops and joins every worker once its current job returns, then frees `pool`; does nothing if `pool` is null. Queued jobs that have not started never run, so `wait` first to finish them.
	///
	/// Examples:
	/// ---
	/// free(create(2));
	/// free(null);
	/// ---
	void free(ThreadPool* pool) @trusted {
		if (pool is null) return;
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

	/// Starts a pool of `workerCount` workers, or `bc.thread.hardwareConcurrency()` of them if it is 0. Starting threads is the costly part, so create a pool once and reuse it.
	///
	/// Returns null, having stopped and freed whatever it started, if allocation or creating a semaphore, lock or thread fails.
	///
	/// Examples:
	/// ---
	/// ThreadPool* pool = create(2);
	/// assert(pool !is null);
	/// assert(workerCount(pool) == 2);
	/// free(pool);
	/// ---
	ThreadPool* create(size_t workerCount = 0) @trusted {
		auto pool = fp.pointer.malloc!ThreadPool(1);
		if (pool is null) return null;
		*pool = ThreadPool.init;

		auto wake = bc.semaphore.create();
		if (wake.isNull) {
			fp.pointer.free(pool);
			return null;
		}
		auto done = bc.semaphore.create();
		if (done.isNull) {
			bc.semaphore.free(wake.get);
			fp.pointer.free(pool);
			return null;
		}
		pool.queueLock = bc.mutex.create();
		if (pool.queueLock is null) {
			bc.semaphore.free(done.get);
			bc.semaphore.free(wake.get);
			fp.pointer.free(pool);
			return null;
		}
		pool.wake = wake.get;
		pool.done = done.get;

		immutable count = workerCount > 0 ? workerCount : bc.thread.hardwareConcurrency();
		if (fp.dynarray.growToSize(pool.handles, count) is null) {
			free(pool);
			return null;
		}
		foreach (i; 0 .. count) {
			auto t = bc.thread.create(&workerMain, pool);
			if (t.isNull) {
				free(pool);
				return null;
			}
			pool.handles[i] = t.get;
			pool.count = i + 1;
		}
		return pool;
	}


	/// Queues a copy of each of `jobs` and returns without waiting for them; without threads, runs them first. A job may call it on its own pool to fork more work, which `wait` and `run` then wait for too.
	///
	/// Returns false, queuing none of `jobs`, if the queue cannot grow to hold them.
	///
	/// Examples:
	/// ---
	/// static void touch(void* arg) @nogc nothrow { *cast(int*) arg = 1; }
	///
	/// auto pool = create(2);
	/// int touched = 0;
	/// Job[1] jobs = [Job(&touch, &touched)];
	/// assert(submit(pool, jobs[]));
	/// wait(pool);
	/// assert(touched == 1);
	/// free(pool);
	/// ---
	bool submit(ThreadPool* pool, scope Job[] jobs) @trusted {
		if (jobs.length == 0) return true;

		bc.mutex.writeLock(pool.queueLock);
		immutable queued = fp.dynarray.concatenate(pool.queue, jobs);
		bc.mutex.writeUnlock(pool.queueLock);
		if (!queued) return false;

		// Count the jobs before waking a worker, or one could finish first and let `wait` see nothing outstanding too early.
		atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		foreach (_; 0 .. jobs.length) bc.semaphore.post(pool.wake);
		return true;
	}


	/// Sleeps until every job submitted to `pool`, by anyone, has finished. A job must never call it on its own pool: the job is itself unfinished, so it would wait forever.
	///
	/// Examples:
	/// ---
	/// auto pool = create(2);
	/// wait(pool);
	/// free(pool);
	/// ---
	void wait(ThreadPool* pool) @trusted {
		while (atomicLoad(pool.outstanding) > 0) bc.semaphore.wait(pool.done);
	}

	/// Spins, rather than sleeping like `wait`, until at most `count` jobs submitted to `pool` have not finished.
	///
	/// Examples:
	/// ---
	/// auto pool = create(2);
	/// waitJobCount(pool, 0);
	/// free(pool);
	/// ---
	void waitJobCount(ThreadPool* pool, size_t count) @trusted {
		while (atomicLoad(pool.outstanding) > cast(ptrdiff_t) count) {}
	}

	/// Submits `jobs`, then sleeps until they and every other job submitted to `pool` have finished. Like `wait`, a job must never call it on its own pool.
	///
	/// Returns false at once, running none of `jobs`, if `submit` fails.
	///
	/// Examples:
	/// ---
	/// static void touch(void* arg) @nogc nothrow { *cast(int*) arg = 1; }
	///
	/// auto pool = create(2);
	/// int[3] touched;
	/// Job[3] jobs = [Job(&touch, &touched[0]), Job(&touch, &touched[1]), Job(&touch, &touched[2])];
	/// assert(run(pool, jobs[]));
	/// assert(touched == [1, 1, 1]);
	/// free(pool);
	/// ---
	bool run(ThreadPool* pool, scope Job[] jobs) @trusted {
		if (!submit(pool, jobs)) return false;
		wait(pool);
		return true;
	}

} else {

	struct ThreadPool {}


	size_t workerCount(const ThreadPool* pool) { return 1; }

	size_t pendingJobs(const ThreadPool* pool) { return 0; }


	void free(ThreadPool* pool) @trusted {
		fp.pointer.free(pool);
	}

	ThreadPool* create(size_t workerCount = 0) @trusted {
		return fp.pointer.malloc!ThreadPool(1);
	}


	bool submit(ThreadPool* pool, scope Job[] jobs) {
		foreach (ref job; jobs) job.fn(job.arg);
		return true;
	}


	void wait(ThreadPool* pool) {}

	void waitJobCount(ThreadPool* pool, size_t count) {}

	bool run(ThreadPool* pool, scope Job[] jobs) {
		return submit(pool, jobs);
	}
}


unittest {
	static void bump(void* arg) @nogc nothrow { atomicOp!"+="(*cast(shared int*) arg, 1); }

	// Acquisitions go pool, both semaphores, the lock (and with pthreads its rwlock), the handles, then each worker, so these fail each in turn.
	static if (!threadingSupported) enum acquisitions = 1;
	else version (PthreadBackend) enum acquisitions = 8;
	else enum acquisitions = 7;
	debug foreach (i; 0 .. acquisitions) {
		bc.platform.failAfter(i);
		assert(create(2) is null);
	}
	free(null);

	auto pool = create(2);
	assert(pool !is null);
	scope(exit) free(pool);
	assert(workerCount(pool) == (threadingSupported ? 2 : 1));

	shared int runs = 0;
	Job[3] jobs = Job(&bump, cast(void*) &runs);
	// The queue has never held a job, so must grow, and a refused allocation fails the `run` before it queues anything.
	debug static if (threadingSupported) {
		bc.platform.failAfter(0);
		assert(!run(pool, jobs[]));
		assert(pendingJobs(pool) == 0);
	}
	assert(run(pool, jobs[]));
	assert(atomicLoad(runs) == 3);
	assert(submit(pool, jobs[]));
	waitJobCount(pool, 0);
	assert(atomicLoad(runs) == 6);
}
