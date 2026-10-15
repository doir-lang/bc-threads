/// A fork-join thread pool: worker threads pulling `Job`s from one shared stack, so the newest submitted start first. Without threads, a pool runs each job inline on the calling thread, so callers need not branch on the platform.
module bc.threadpool;

static import bc.mutex;
static import bc.platform;
static import bc.semaphore;
static import bc.thread;
static import fp.dynarray;
static import fp.pointer;
public import bc.platform : threadingSupported;
import core.atomic : atomicOp, atomicLoad, atomicStore, pause;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);
version(Windows) import core.sys.windows.windows : DWORD;


/// The function a `Job` runs, called with the job's `arg` on a worker thread.
alias JobFunction = void function(void*) @nogc nothrow;

/// One unit of work: a worker calls `fn(arg)`.
struct Job {
	JobFunction fn;
	void* arg;
}


static if(threadingSupported) {

	/// A pool of worker threads sharing one job stack, used through the pointer `create` returns. Its fields belong to the implementation.
	struct ThreadPool {
		bc.semaphore.Semaphore* wake;
		bc.semaphore.Semaphore* done;

		Job* stack = null;
		bc.mutex.Mutex* stackLock;

		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;
		// Threads blocked, or about to block, in `wait`, guarded by `stackLock`; whoever posts `done` takes one off, so no post outlives its waiter.
		size_t waiters = 0;
		// Threads inside `wait` or `waitJobCount`, so `free` can wait for them to leave before destroying what they read.
		shared ptrdiff_t users = 0;

		bc.thread.Thread* handles = null;
		size_t count = 0;
	}


	/// How many worker threads `pool` has; always 1 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(3);
	/// assert(workerCount(pool) == 3);
	/// free(pool);
	/// ---
	size_t workerCount(const ThreadPool* pool) { return pool.count; }

	/// How many jobs submitted to `pool`, waiting or running, have not finished; always 0 without threads.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// assert(pendingJobs(pool) == 0);
	/// free(pool);
	/// ---
	size_t pendingJobs(const ThreadPool* pool) @trusted {
		return cast(size_t) atomicLoad(pool.outstanding);
	}


	private Job claimJob(ThreadPool* pool) @trusted {
		bc.mutex.writeLock(pool.stackLock);
		Job job = *fp.dynarray.back(pool.stack);
		cast(void) fp.dynarray.popBack(pool.stack);
		bc.mutex.writeUnlock(pool.stackLock);
		return job;
	}

	private void workerLoop(ThreadPool* pool) @trusted {
		while(true) {
			// Every post to `wake` either stops the pool or follows one pushed job, so the stack is not empty here.
			bc.semaphore.wait(pool.wake);
			if(atomicLoad(pool.stopping)) return;
			Job job = claimJob(pool);
			job.fn(job.arg);
			if(atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1) == 0) {
				bc.mutex.writeLock(pool.stackLock);
				immutable woken = pool.waiters;
				pool.waiters = 0;
				bc.mutex.writeUnlock(pool.stackLock);
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
		extern(Windows) private DWORD workerMain(void* arg) {
			workerLoop(cast(ThreadPool*) arg);
			return 0;
		}
	}


	/// Stops and joins every worker once its current job returns, then frees `pool`; does nothing if `pool` is null. Jobs still on the stack never run, so `wait` first to finish them. Threads blocked in `wait` or spinning in `waitJobCount` are woken, and nothing is destroyed until all of them have returned, so freeing a pool others are waiting on is safe. A job must never call it on its own pool: it would join its own worker, so wait forever. Freeing `pool` twice is undefined.
	///
	/// Examples:
	/// ---
	/// free(bc.threadpool.create(2));
	/// free(null);
	/// ---
	void free(ThreadPool* pool) @trusted {
		if(pool is null) return;
		// `create` can leave `stackLock` null on a partial failure, and nobody can be waiting without it.
		if(pool.stackLock !is null) {
			bc.mutex.writeLock(pool.stackLock);
			atomicStore(pool.stopping, true);
			immutable woken = pool.waiters;
			pool.waiters = 0;
			bc.mutex.writeUnlock(pool.stackLock);
			foreach(_; 0 .. woken) bc.semaphore.post(pool.done);
		} else atomicStore(pool.stopping, true);
		foreach(i; 0 .. pool.count) bc.semaphore.post(pool.wake);
		foreach(i; 0 .. pool.count) bc.thread.join(pool.handles[i]);
		// A woken waiter still reads the pool, so it must leave before any part of it is destroyed.
		while(atomicLoad(pool.users) > 0) pause();
		bc.semaphore.free(pool.wake);
		bc.semaphore.free(pool.done);
		bc.mutex.free(pool.stackLock);
		fp.dynarray.free(pool.stack);
		fp.dynarray.free(pool.handles);
		fp.pointer.free(pool);
	}

	/// Starts a pool of `workerCount` workers, or `bc.thread.hardwareConcurrency()` of them if it is 0. Starting threads is the costly part, so create a pool once and reuse it. Several `bc` modules define `create`, so call it fully qualified, as `bc.threadpool.create`, the preferred style throughout these libraries; after `import bc;` an unqualified call is ambiguous.
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
		auto pool = fp.pointer.malloc!ThreadPool(1);
		if(pool is null) return null;
		*pool = ThreadPool.init;

		pool.wake = bc.semaphore.create();
		pool.done = bc.semaphore.create();
		pool.stackLock = bc.mutex.create();
		immutable count = workerCount > 0 ? workerCount : bc.thread.hardwareConcurrency();
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
		return pool;
	}


	/// Pushes a copy of each of `jobs` onto the job stack and returns without waiting for them; without threads, runs them first. They start in the order given, but before any jobs left from earlier submits. A job may call it on its own pool to fork more work, which `wait` and `run` then wait for too.
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
		if(jobs.length == 0) return true;

		bc.mutex.writeLock(pool.stackLock);
		immutable base = fp.dynarray.length(pool.stack);
		immutable pushed = fp.dynarray.grow(pool.stack, jobs.length) !is null;
		if(pushed) {
			// Workers pop from the top, so push in reverse to have `jobs[0]` claimed first.
			foreach(i, ref job; jobs) pool.stack[base + jobs.length - 1 - i] = job;
			// Count the jobs before unlocking: a worker woken for an earlier job could claim one, finish it, and let `wait` return too early.
			atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		}
		bc.mutex.writeUnlock(pool.stackLock);
		if(!pushed) return false;

		foreach(_; 0 .. jobs.length) bc.semaphore.post(pool.wake);
		return true;
	}


	/// Sleeps until every job submitted to `pool`, by anyone, has finished, or until `pool` is being freed, whose queued jobs then never run. Several threads may wait at once. A job must never call it on its own pool: the job is itself unfinished, so it would wait forever.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// wait(pool);
	/// free(pool);
	/// ---
	void wait(ThreadPool* pool) @trusted {
		atomicOp!"+="(pool.users, 1);
		while(true) {
			// The last job decrements `outstanding` before taking the lock, so one checked under it cannot miss that job's posts.
			bc.mutex.writeLock(pool.stackLock);
			if(atomicLoad(pool.outstanding) <= 0 || atomicLoad(pool.stopping)) {
				bc.mutex.writeUnlock(pool.stackLock);
				break;
			}
			pool.waiters++;
			bc.mutex.writeUnlock(pool.stackLock);
			bc.semaphore.wait(pool.done);
		}
		atomicOp!"-="(pool.users, 1);
	}

	/// Spins, rather than sleeping like `wait`, until at most `count` jobs submitted to `pool` have not finished, or until `pool` is being freed, whose queued jobs then never run.
	///
	/// Examples:
	/// ---
	/// auto pool = bc.threadpool.create(2);
	/// waitJobCount(pool, 0);
	/// free(pool);
	/// ---
	void waitJobCount(ThreadPool* pool, size_t count) @trusted {
		atomicOp!"+="(pool.users, 1);
		while(atomicLoad(pool.outstanding) > cast(ptrdiff_t) count && !atomicLoad(pool.stopping)) pause();
		atomicOp!"-="(pool.users, 1);
	}

	/// Submits `jobs`, then sleeps until they and every other job submitted to `pool` have finished. Like `wait`, a job must never call it on its own pool.
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


	size_t workerCount(const ThreadPool* pool) { return 1; }

	size_t pendingJobs(const ThreadPool* pool) { return 0; }


	void free(ThreadPool* pool) @trusted {
		fp.pointer.free(pool);
	}

	ThreadPool* create(size_t workerCount = 0) @trusted {
		return fp.pointer.malloc!ThreadPool(1);
	}


	bool submit(ThreadPool* pool, scope Job[] jobs) {
		foreach(ref job; jobs) job.fn(job.arg);
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
	assert(atomicLoad(runs) == 3);
	assert(submit(pool, jobs[]));
	waitJobCount(pool, 0);
	assert(atomicLoad(runs) == 6);
	// Nobody was in `wait` as the last job finished, so no post may be left to make a later `wait` spin.
	static if(threadingSupported) version(linux) assert(bc.semaphore.value(pool.done) == 0);

	// With one worker, jobs from one submit run one at a time in the order given.
	static __gshared size_t[3] order;
	static shared size_t finished = 0;
	static void record(void* arg) @nogc nothrow { order[atomicOp!"+="(finished, 1) - 1] = cast(size_t) arg; }
	auto serial = create(1);
	assert(serial !is null);
	scope(exit) free(serial);
	Job[3] ordered = [Job(&record, cast(void*) 0), Job(&record, cast(void*) 1), Job(&record, cast(void*) 2)];
	assert(run(serial, ordered[]));
	assert(order == [0, 1, 2]);

	static if(threadingSupported) {
		static void gate(void* arg) @nogc nothrow { while(!atomicLoad(*cast(shared bool*) arg)) {} }
		static void waitOn(ThreadPool* p) @nogc nothrow { wait(p); }

		// Two threads wait on one job, so the one its `done` wakes must wake the other. One that starts late still passes.
		shared bool open = false;
		Job[1] gated = Job(&gate, cast(void*) &open);
		assert(submit(pool, gated[]));
		auto first = bc.thread.create(&waitOn, pool);
		auto second = bc.thread.create(&waitOn, pool);
		assert(!first.isNull && !second.isNull);
		bc.platform.nap(10);
		atomicStore(open, true);
		bc.thread.join(first.get);
		bc.thread.join(second.get);

		// `free` wakes a thread blocked in `wait` and waits for it to return before destroying the semaphore it was blocked on.
		static shared bool returned;
		static void waitAndMark(ThreadPool* p) @nogc nothrow { wait(p); atomicStore(returned, true); }
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
		assert(atomicLoad(returned));
	}
}
