/// A fork-join thread pool: worker threads pulling `Job`s from one shared stack, so the newest submitted start first.
/// Without threads, a pool runs each job inline on the calling thread, so callers need not branch on the platform.
///
/// `createDeterministic` makes a pool with no threads that runs its jobs on the waiting thread in an order a seed decides, so a test of parallel work replays exactly.
module bc.threadpool;

static import bc.mutex;
static import bc.platform;
static import bc.semaphore;
static import bc.thread;
static import fp.algorithms;
static import fp.dynarray;
static import fp.pointer;
public import bc.platform : threadingSupported;
static import core.atomic;

@nogc nothrow:

mixin(bc.platform.backendSelection);
version(Windows) static import core.sys.windows.windows;


/// The function a `Job` runs, called with the job's `arg` on a worker thread.
alias JobFunction = void function(void*) @nogc nothrow;

/// One unit of work: a worker calls `work(arg)`.
struct Job {
	JobFunction work;
	void* arg;
}


static if(threadingSupported) {

	/// A pool of worker threads sharing one job stack, used through the pointer `create` returns.
	/// Its fields belong to the implementation.
	struct ThreadPool {
		bc.semaphore.Semaphore* wake;
		bc.semaphore.Semaphore* done;

		Job* stack = null;
		bc.mutex.Mutex* stackLock;

		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;
		// Threads blocked, or about to block, in `wait`, guarded by `stackLock`; whoever posts `done` takes one off, so no post outlives its waiter.
		size_t waiters = 0;
		// Threads inside `wait` or `waitUntilPending`, so `free` can wait for them to leave before destroying what they read.
		shared ptrdiff_t users = 0;

		bc.thread.Thread* handles = null;
		size_t count = 0;

		// A pool from `createDeterministic` has no threads, semaphores or handles: `wait` runs its jobs, in an order drawn from `order`.
		bool deterministic = false;
		fp.algorithms.Random order;
	}


	// wrapper: reads a field of an opaque pool
	/// How many worker threads `pool` has; always 1 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(3);
	/// assert(workerCount(pool) == 3);
	/// free(pool);
	/// ---
	size_t workerCount(const ThreadPool* pool) { return pool.count; }

	// wrapper: reads a field of an opaque pool
	/// How many jobs submitted to `pool`, waiting or running, have not finished; always 0 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// assert(pendingJobs(pool) == 0);
	/// free(pool);
	/// ---
	size_t pendingJobs(const ThreadPool* pool) @trusted {
		immutable outstanding = core.atomic.atomicLoad(pool.outstanding);
		assert(outstanding >= 0, "bc.threadpool: more jobs finished than were submitted");
		return cast(size_t) outstanding;
	}


	private Job claimJob(ThreadPool* pool) @trusted {
		bc.mutex.lockForWriting(pool.stackLock);
		assert(fp.dynarray.length(pool.stack) > 0, "bc.threadpool: woken for a job the stack does not hold");
		assert(fp.dynarray.length(pool.stack) <= core.atomic.atomicLoad(pool.outstanding), "bc.threadpool: more jobs stacked than outstanding");
		Job job = *fp.dynarray.back(pool.stack);
		cast(void) fp.dynarray.removeLast(pool.stack);
		bc.mutex.unlockForWriting(pool.stackLock);
		assert(job.work !is null, "bc.threadpool: claimed a job with no work");
		return job;
	}

	// The pool the calling thread works for, if it is a worker: a job waiting on or freeing it would wait on itself.
	version(assert) private ThreadPool* servingPool;

	private void workerLoop(ThreadPool* pool) @trusted {
		assert(!pool.deterministic, "bc.threadpool: a worker thread for a deterministic pool");
		version(assert) servingPool = pool;
		while(true) {
			// Every post to `wake` either stops the pool or follows one pushed job, so the stack is not empty here.
			bc.semaphore.wait(pool.wake);
			if(core.atomic.atomicLoad(pool.stopping)) return;
			Job job = claimJob(pool);
			job.work(job.arg);
			immutable left = core.atomic.atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
			assert(left >= 0, "bc.threadpool: more jobs finished than were submitted");
			if(left == 0) {
				bc.mutex.lockForWriting(pool.stackLock);
				immutable woken = pool.waiters;
				pool.waiters = 0;
				bc.mutex.unlockForWriting(pool.stackLock);
				foreach(_; 0 .. woken) bc.semaphore.post(pool.done);
			}
		}
	}

	version(PthreadBackend) {
		extern(C) private void* workerMain(void* arg) {
			workerLoop(cast(ThreadPool*) arg);
			return null;
		}
	} else version(Windows) {
		extern(Windows) private core.sys.windows.windows.DWORD workerMain(void* arg) {
			workerLoop(cast(ThreadPool*) arg);
			return 0;
		}
	}


	/// Stops and joins every worker once its current job returns, then frees `pool`; does nothing if `pool` is null.
	/// Jobs still on the stack never run, so `wait` first to finish them.
	/// Threads blocked in `wait` or spinning in `waitUntilPending` are woken, and nothing is destroyed until all of them have returned, so freeing a pool others are waiting on is safe.
	/// A job must never call it on its own pool: it would join its own worker, so wait forever.
	/// Freeing `pool` twice is undefined.
	///
	/// Examples:
	/// ---
	/// free(bc.threadpool.create(2));
	/// free(null);
	/// ---
	void free(ThreadPool* pool) @trusted {
		if(pool is null) return;
		version(assert) assert(servingPool !is pool, "bc.threadpool.free: a job freeing its own pool, which would join its own worker");
		assert(pool.count <= fp.dynarray.length(pool.handles) || pool.deterministic, "bc.threadpool.free: more workers than handles");
		if(pool.deterministic) {
			assert(pool.handles is null && pool.wake is null && pool.done is null, "bc.threadpool.free: a deterministic pool with threads");
			bc.mutex.free(pool.stackLock);
			fp.dynarray.free(pool.stack);
			fp.pointer.free(pool);
			return;
		}
		// `create` can leave `stackLock` null on a partial failure, and nobody can be waiting without it.
		if(pool.stackLock !is null) {
			bc.mutex.lockForWriting(pool.stackLock);
			core.atomic.atomicStore(pool.stopping, true);
			immutable woken = pool.waiters;
			pool.waiters = 0;
			bc.mutex.unlockForWriting(pool.stackLock);
			foreach(_; 0 .. woken) bc.semaphore.post(pool.done);
		} else core.atomic.atomicStore(pool.stopping, true);
		foreach(i; 0 .. pool.count) bc.semaphore.post(pool.wake);
		foreach(i; 0 .. pool.count) bc.thread.join(pool.handles[i]);
		// A woken waiter still reads the pool, so it must leave before any part of it is destroyed.
		while(core.atomic.atomicLoad(pool.users) > 0) core.atomic.pause();
		assert(pool.waiters == 0, "bc.threadpool.free: a thread still waits on a stopped pool");
		bc.semaphore.free(pool.wake);
		bc.semaphore.free(pool.done);
		bc.mutex.free(pool.stackLock);
		fp.dynarray.free(pool.stack);
		fp.dynarray.free(pool.handles);
		fp.pointer.free(pool);
	}

	/// Starts a pool of `workerCount` workers, or `bc.thread.processorCount()` of them if it is 0. Starting threads is the costly part, so create a pool once and reuse it.
	/// Several `bc` modules define `create`, so call it fully qualified, as `bc.threadpool.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
	///
	/// Returns null, having stopped and freed whatever it started, if allocation or creating a semaphore, lock or thread fails.
	///
	/// Examples:
	/// ---
	/// ThreadPool* pool = bc.threadpool.create(2);
	/// assert(pool !is null);
	/// assert(workerCount(pool) == 2);
	/// free(pool);
	/// ---
	ThreadPool* create(size_t workerCount = 0) @trusted {
		auto pool = fp.pointer.allocate!ThreadPool(1);
		if(pool is null) return null;
		*pool = ThreadPool.init;

		pool.wake = bc.semaphore.create();
		pool.done = bc.semaphore.create();
		pool.stackLock = bc.mutex.create();
		immutable count = workerCount > 0 ? workerCount : bc.thread.processorCount();
		// `free` takes a pool with no workers and any of these null, so it can undo a partial `create`.
		if(pool.wake is null || pool.done is null || pool.stackLock is null || fp.dynarray.growToSize(pool.handles, count) is null) {
			free(pool);
			return null;
		}
		foreach(i; 0 .. count) {
			auto t = bc.thread.create(&workerMain, pool);
			if(t.isNull) {
				free(pool);
				return null;
			}
			pool.handles[i] = t.get;
			pool.count = i + 1;
		}
		assert(pool.count == count && count > 0, "bc.threadpool.create: the wrong number of workers");
		assert(!pool.deterministic && core.atomic.atomicLoad(pool.outstanding) == 0, "bc.threadpool.create: a new pool with jobs");
		return pool;
	}

	/// A pool with no threads, for tests that must replay: `submit` only queues, and `wait`, `waitUntilPending` and `run` run the queued jobs on the calling thread, one at a time, each picked at random by a sequence `seed` alone decides.
	/// `workerCount` reports `workerCount`, so code that shares work out by it takes the same paths as with threads.
	/// Only one thread may use it, and a job that blocks until another job runs never returns.
	/// Without threads it is `create`, whose jobs run as they are submitted.
	///
	/// Returns null, having freed whatever it made, if allocation or creating the lock fails.
	///
	/// Examples:
	/// ---
	/// static void touch(void* arg) @nogc nothrow { *cast(int*) arg = 1; }
	///
	/// auto pool = createDeterministic(7, 4);
	/// int touched = 0;
	/// Job[1] jobs = [Job(&touch, &touched)];
	/// assert(submit(pool, jobs[]) && touched == 0);
	/// wait(pool);
	/// assert(touched == 1 && workerCount(pool) == 4);
	/// free(pool);
	/// ---
	ThreadPool* createDeterministic(ulong seed, size_t workerCount = 1) @trusted {
		assert(workerCount > 0, "bc.threadpool.createDeterministic: a pool needs a worker to stand for");
		auto pool = fp.pointer.allocate!ThreadPool(1);
		if(pool is null) return null;
		*pool = ThreadPool.init;
		pool.deterministic = true;
		pool.order = fp.algorithms.createRandom(seed);
		pool.count = workerCount;
		pool.stackLock = bc.mutex.create();
		if(pool.stackLock is null) {
			fp.pointer.free(pool);
			return null;
		}
		assert(pool.count == workerCount && pool.handles is null, "bc.threadpool.createDeterministic: a deterministic pool with threads");
		return pool;
	}

	// Runs a deterministic pool's queued jobs, each picked by its seeded sequence, until at most `count` are left.
	private void runQueued(ThreadPool* pool, size_t count) @trusted {
		assert(pool.deterministic, "bc.threadpool: running the queue of a pool with threads");
		while(fp.dynarray.length(pool.stack) > count) {
			immutable picked = fp.algorithms.randomBelow(pool.order, fp.dynarray.length(pool.stack));
			Job job = pool.stack[picked];
			pool.stack[picked] = *fp.dynarray.back(pool.stack);
			cast(void) fp.dynarray.removeLast(pool.stack);
			job.work(job.arg);
			immutable left = core.atomic.atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
			assert(left == fp.dynarray.length(pool.stack), "bc.threadpool: a deterministic pool used from two threads, or from inside its own job's wait");
		}
	}


	/// Pushes a copy of each of `jobs` onto the job stack and returns without waiting for them; without threads, runs them first.
	/// They start in the order given, but before any jobs left from earlier submits.
	/// A job may call it on its own pool to fork more work, which `wait` and `run` then wait for too.
	///
	/// Returns false, pushing none of `jobs`, if the stack cannot grow to hold them.
	///
	/// Examples:
	/// ---
	/// static void touch(void* arg) @nogc nothrow { *cast(int*) arg = 1; }
	///
	/// auto pool = bc.threadpool.create(2);
	/// int touched = 0;
	/// Job[1] jobs = [Job(&touch, &touched)];
	/// assert(submit(pool, jobs[]));
	/// wait(pool);
	/// assert(touched == 1);
	/// free(pool);
	/// ---
	bool submit(ThreadPool* pool, scope Job[] jobs) @trusted {
		assert(pool !is null, "bc.threadpool.submit: no pool");
		if(jobs.length == 0) return true;
		foreach(ref job; jobs) assert(job.work !is null, "bc.threadpool.submit: a job with no work");

		bc.mutex.lockForWriting(pool.stackLock);
		immutable base = fp.dynarray.length(pool.stack);
		immutable pushed = fp.dynarray.grow(pool.stack, jobs.length) !is null;
		if(pushed) {
			// Workers pop from the top, so push in reverse to have `jobs[0]` claimed first.
			foreach(i, ref job; jobs) pool.stack[base + jobs.length - 1 - i] = job;
			// Count the jobs before unlocking: a worker woken for an earlier job could claim one, finish it, and let `wait` return too early.
			core.atomic.atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		}
		bc.mutex.unlockForWriting(pool.stackLock);
		if(!pushed) return false;
		assert(!core.atomic.atomicLoad(pool.stopping), "bc.threadpool.submit: submitting to a pool being freed");

		if(!pool.deterministic) foreach(_; 0 .. jobs.length) bc.semaphore.post(pool.wake);
		return true;
	}


	/// Sleeps until every job submitted to `pool`, by anyone, has finished, or until `pool` is being freed, whose queued jobs then never run.
	/// Several threads may wait at once.
	/// A job must never call it on its own pool: the job is itself unfinished, so it would wait forever.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// wait(pool);
	/// free(pool);
	/// ---
	void wait(ThreadPool* pool) @trusted {
		if(pool.deterministic) return runQueued(pool, 0);
		version(assert) assert(servingPool !is pool, "bc.threadpool.wait: a job waiting on its own pool, which never finishes while it waits");
		core.atomic.atomicOp!"+="(pool.users, 1);
		while(true) {
			// The last job decrements `outstanding` before taking the lock, so one checked under it cannot miss that job's posts.
			bc.mutex.lockForWriting(pool.stackLock);
			if(core.atomic.atomicLoad(pool.outstanding) <= 0 || core.atomic.atomicLoad(pool.stopping)) {
				bc.mutex.unlockForWriting(pool.stackLock);
				break;
			}
			pool.waiters++;
			bc.mutex.unlockForWriting(pool.stackLock);
			bc.semaphore.wait(pool.done);
		}
		assert(core.atomic.atomicLoad(pool.users) > 0, "bc.threadpool.wait: left a pool more often than entered");
		core.atomic.atomicOp!"-="(pool.users, 1);
	}

	/// Spins, rather than sleeping like `wait`, until at most `count` jobs submitted to `pool` have not finished, or until `pool` is being freed, whose queued jobs then never run.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// waitUntilPending(pool, 0);
	/// free(pool);
	/// ---
	void waitUntilPending(ThreadPool* pool, size_t count) @trusted {
		if(pool.deterministic) return runQueued(pool, count);
		core.atomic.atomicOp!"+="(pool.users, 1);
		while(core.atomic.atomicLoad(pool.outstanding) > cast(ptrdiff_t) count && !core.atomic.atomicLoad(pool.stopping)) core.atomic.pause();
		assert(core.atomic.atomicLoad(pool.users) > 0, "bc.threadpool.waitUntilPending: left a pool more often than entered");
		core.atomic.atomicOp!"-="(pool.users, 1);
	}

	/// Submits `jobs`, then sleeps until they and every other job submitted to `pool` have finished.
	/// Like `wait`, a job must never call it on its own pool.
	///
	/// Returns false at once, running none of `jobs`, if `submit` fails.
	///
	/// Examples:
	/// ---
	/// static void touch(void* arg) @nogc nothrow { *cast(int*) arg = 1; }
	///
	/// auto pool = bc.threadpool.create(2);
	/// int[3] touched;
	/// Job[3] jobs = [Job(&touch, &touched[0]), Job(&touch, &touched[1]), Job(&touch, &touched[2])];
	/// assert(run(pool, jobs[]));
	/// assert(touched == [1, 1, 1]);
	/// free(pool);
	/// ---
	bool run(ThreadPool* pool, scope Job[] jobs) @trusted {
		if(!submit(pool, jobs)) return false;
		wait(pool);
		return true;
	}

} else {

	struct ThreadPool {}


	// wrapper: reads a field of an opaque pool
	size_t workerCount(const ThreadPool* pool) { return 1; }

	// wrapper: reads a field of an opaque pool
	size_t pendingJobs(const ThreadPool* pool) { return 0; }


	// wrapper: the threadless build keeps the threaded API
	void free(ThreadPool* pool) @trusted {
		fp.pointer.free(pool);
	}

	// wrapper: the threadless build keeps the threaded API
	ThreadPool* create(size_t workerCount = 0) @trusted {
		return fp.pointer.allocate!ThreadPool(1);
	}


	// wrapper: the threadless build keeps the threaded API
	ThreadPool* createDeterministic(ulong seed, size_t workerCount = 1) @trusted {
		return create(workerCount);
	}


	bool submit(ThreadPool* pool, scope Job[] jobs) {
		assert(pool !is null, "bc.threadpool.submit: no pool");
		foreach(ref job; jobs) {
			assert(job.work !is null, "bc.threadpool.submit: a job with no work");
			job.work(job.arg);
		}
		return true;
	}


	void wait(ThreadPool* pool) {}

	void waitUntilPending(ThreadPool* pool, size_t count) {}

	// wrapper: the threadless build keeps the threaded API
	bool run(ThreadPool* pool, scope Job[] jobs) {
		return submit(pool, jobs);
	}
}


unittest {
	static void bump(void* arg) @nogc nothrow { core.atomic.atomicOp!"+="(*cast(shared int*) arg, 1); }
	// Fails each acquisition in turn: pool, each semaphore and its OS object, the lock and any rwlock, the handles, then each worker.
	static if(!threadingSupported) enum acquisitions = 1;
	else version(PthreadBackend) enum acquisitions = 10;
	else enum acquisitions = 9;
	debug foreach(i; 0 .. acquisitions) {
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
	// The stack has never held a job, so must grow, and a refused allocation fails the `run` before it pushes anything.
	debug static if(threadingSupported) {
		bc.platform.failAfter(0);
		assert(!run(pool, jobs[]));
		assert(pendingJobs(pool) == 0);
	}
	assert(run(pool, jobs[]));
	assert(core.atomic.atomicLoad(runs) == 3);
	assert(submit(pool, jobs[]));
	waitUntilPending(pool, 0);
	assert(core.atomic.atomicLoad(runs) == 6);
	// Nobody was in `wait` as the last job finished, so no post may be left to make a later `wait` spin.
	static if(threadingSupported) version(linux) assert(bc.semaphore.value(pool.done) == 0);

	// With one worker, jobs from one submit run one at a time in the order given.
	static __gshared size_t[3] order;
	static shared size_t finished = 0;
	static void record(void* arg) @nogc nothrow { order[core.atomic.atomicOp!"+="(finished, 1) - 1] = cast(size_t) arg; }
	auto serial = create(1);
	assert(serial !is null);
	scope(exit) free(serial);
	Job[3] ordered = [Job(&record, cast(void*) 0), Job(&record, cast(void*) 1), Job(&record, cast(void*) 2)];
	assert(run(serial, ordered[]));
	assert(order == [0, 1, 2]);

	// A deterministic pool queues until waited on, then runs in an order its seed decides: the same for one seed, and not always the order given.
	static __gshared size_t[8][3] ran;
	static __gshared size_t[3] ranCount;
	static struct Recorded { size_t pool, job; }
	static void recordRun(void* arg) @nogc nothrow {
		auto r = cast(Recorded*) arg;
		ran[r.pool][ranCount[r.pool]++] = r.job;
	}
	Recorded[8][3] recorded;
	immutable ulong[3] seeds = [5, 5, 6];
	foreach(p; 0 .. 3) {
		auto replayed = createDeterministic(seeds[p], 4);
		assert(replayed !is null && workerCount(replayed) == (threadingSupported ? 4 : 1));
		Job[8] queued;
		foreach(i, ref job; queued) {
			recorded[p][i] = Recorded(p, i);
			job = Job(&recordRun, &recorded[p][i]);
		}
		assert(submit(replayed, queued[0 .. 5]) && submit(replayed, queued[5 .. 8]));
		static if(threadingSupported) {
			assert(ranCount[p] == 0 && pendingJobs(replayed) == 8);
			waitUntilPending(replayed, 3);
			assert(ranCount[p] == 5 && pendingJobs(replayed) == 3);
		}
		wait(replayed);
		assert(ranCount[p] == 8 && pendingJobs(replayed) == 0);
		// Jobs still queued when the pool is freed never run; without threads nothing is ever queued.
		static if(threadingSupported) {
			assert(submit(replayed, queued[0 .. 2]));
			free(replayed);
			assert(ranCount[p] == 8);
		} else free(replayed);
	}
	static if(threadingSupported) {
		static immutable size_t[8] given = [0, 1, 2, 3, 4, 5, 6, 7];
		assert(ran[0] == ran[1] && ran[0] != ran[2] && ran[0] != given);
		debug foreach(i; 0 .. 2) {
			bc.platform.failAfter(i);
			assert(createDeterministic(1) is null);
		}
	}

	static if(threadingSupported) {
		static void gate(void* arg) @nogc nothrow { while(!core.atomic.atomicLoad(*cast(shared bool*) arg)) {} }
		static void waitOn(ThreadPool* pool) @nogc nothrow { wait(pool); }

		// Two threads wait on one job, so the one its `done` wakes must wake the other.
		// One that starts late still passes.
		shared bool open = false;
		Job[1] gated = Job(&gate, cast(void*) &open);
		assert(submit(pool, gated[]));
		auto first = bc.thread.create(&waitOn, pool);
		auto second = bc.thread.create(&waitOn, pool);
		assert(!first.isNull && !second.isNull);
		bc.platform.nap(10);
		core.atomic.atomicStore(open, true);
		bc.thread.join(first.get);
		bc.thread.join(second.get);

		// `free` wakes a thread blocked in `wait` and waits for it to return before destroying the semaphore it was blocked on.
		static shared bool returned;
		static void waitAndMark(ThreadPool* p) @nogc nothrow { wait(p); core.atomic.atomicStore(returned, true); }
		static void slow(void*) @nogc nothrow { bc.platform.nap(1); }
		auto closing = create(1);
		assert(closing !is null);
		Job[100] queued;
		foreach(ref job; queued) job = Job(&slow, null);
		assert(submit(closing, queued[]));
		auto blocked = bc.thread.create(&waitAndMark, closing);
		assert(!blocked.isNull);
		bc.platform.nap(10);
		free(closing);
		bc.thread.join(blocked.get);
		assert(core.atomic.atomicLoad(returned));
	}
}
