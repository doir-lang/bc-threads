/// A minimal fork-join thread pool used by `bct.parallel`. Backed directly
/// by POSIX threads + unnamed semaphores on Linux, or Win32 threads +
/// semaphore objects on Windows - `core.thread` needs druntime's GC-backed
/// TLS/fiber setup, which isn't available under `-betterC`. Any other
/// platform gets a degenerate single-"worker" pool that just runs jobs
/// inline on the calling thread, so callers never need to branch on
/// platform themselves.
///
/// `ThreadPool` is a plain heap-allocated struct (see `create`); every
/// operation on it is a free function taking a `ThreadPool*` as its first
/// argument - `fp.dynarray`'s own convention, extended to this module's
/// types.
///
/// `run` queues its jobs and returns once every one of them has completed:
/// workers pull the next job off the shared queue as soon as they finish
/// their current one (parking on a semaphore, so an idle worker sleeps
/// rather than spins when the queue is empty), so `jobs.length` need not
/// match `workerCount(pool)` and faster workers naturally pick up more jobs
/// than slower ones. Create a pool once (e.g. at startup) and reuse it via
/// `run` - that's what makes this cheaper than spawning/joining OS threads
/// on every call.
///
/// `run` is just `submit` (queue jobs, return immediately) followed by
/// `wait` (block until every job submitted so far - by anyone - has
/// completed). `submit` is safe to call reentrantly - i.e. from within a
/// job that's currently executing on this pool, to fork more work after
/// seeing partial results - because the queue is owned by the pool (not
/// the caller), and every access to it (an append from `submit`, a pop
/// from a worker claiming its next job) goes through the same small
/// spinlock, with a WaitGroup-style counter tracking how many submitted
/// jobs are still outstanding; `wait` blocks on that counter rather than a
/// fixed job count, so a job forking more work just needs to `submit` it
/// and return -
/// the counter already covers it, and whichever `wait` call is already
/// blocked (from the `run` that's driving this whole wave) picks it up
/// automatically. A job must never call `wait` itself, though: that counter
/// includes the calling job (it isn't done until the function running it
/// returns), so a job blocked in its own `wait` can never see it reach
/// zero - worse, it also stops that worker from looping back to help drain
/// the very queue it's waiting on. Fork-and-forget via `submit`, not
/// fork-and-join via `run`/`wait`, is the reentrant-safe pattern here.
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
} else version (Windows) {
	import core.sys.windows.windows :
		HANDLE, DWORD, CreateThread, WaitForSingleObject, CloseHandle,
		INFINITE, GetSystemInfo, SYSTEM_INFO, CreateSemaphoreA, ReleaseSemaphore;
	enum bool threadingSupported = true;
} else {
	enum bool threadingSupported = false;
}


/// Number of hardware threads available, at least 1. Platforms
/// `threadingSupported` is false for have nothing to query, so this is
/// always 1 there - which also keeps `create()`'s default worker count
/// meaningful without callers needing to special-case it.
size_t hardwareConcurrency() @trusted @nogc nothrow {
	version (linux) {
		immutable n = sysconf(_SC_NPROCESSORS_ONLN);
		return n > 0 ? cast(size_t) n : 1;
	} else version (Windows) {
		SYSTEM_INFO info;
		GetSystemInfo(&info);
		return info.dwNumberOfProcessors > 0 ? cast(size_t) info.dwNumberOfProcessors : 1;
	} else
		return 1;
}


alias JobFn = void function(void*) @nogc nothrow;

/// One unit of work: `fn(arg)` is run on a pool worker.
struct Job {
	JobFn fn;
	void* arg;
}


static if (threadingSupported) {

	/// A fixed-size pool of worker threads pulling from one shared job
	/// queue. Heap allocated by `create()` (with `fp.pointer.malloc`, a
	/// single fixed instance rather than a growable array) so its address
	/// stays stable across the lifetime of the pool - workers capture a
	/// pointer to this directly. Every other operation on it is a free
	/// function taking the `ThreadPool*` returned by `create()`; `free()`
	/// stops and joins every worker and releases the pool itself.
	struct ThreadPool {
		version (linux) sem_t wake;
		else version (Windows) HANDLE wake;

		// Posted once per completed job; `wait()` parks on this until
		// `outstanding` reaches zero rather than counting posts itself, so
		// it doesn't matter whether the jobs it's waiting on were queued by
		// this call or by a `submit()` nested inside one of them.
		version (linux) sem_t done;
		else version (Windows) HANDLE done;

		// The job queue itself: a `fp.dynarray` (grows on demand, same as
		// anywhere else it's used), guarded by `queueLock` - the pool's
		// only queue lock, held across both `submit()`'s `pushBack`s and a
		// worker's `popBack`. `fp.dynarray`'s own operations aren't
		// synchronized (`popBack` decrements the stored length with a
		// plain, non-atomic read-modify-write, and `pushBack` can
		// reallocate the backing buffer outright), so without this lock two
		// workers popping concurrently could race on that length, and a
		// `submit()` reallocating the buffer mid-grow could pull it out
		// from under a worker still reading a slot. Holding one lock across
		// every access - copying a claimed job out before releasing it -
		// rules both out.
		Job* queue = null;
		shared uint queueLock = 0;

		// How many submitted jobs (from any wave, including ones nested
		// inside currently-running jobs) haven't completed yet.
		shared ptrdiff_t outstanding = 0;
		shared bool stopping = false;

		version (linux) private pthread_t* handles = null;
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

	version (linux) {
		extern (C) private void* workerMain(void* arg) @nogc nothrow {
			auto pool = cast(ThreadPool*) arg;
			while (true) {
				sem_wait(&pool.wake);
				if (atomicLoad(pool.stopping)) return null;
				Job job = claimJob(pool);
				job.fn(job.arg);
				atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
				sem_post(&pool.done);
			}
		}
	} else version (Windows) {
		extern (Windows) private DWORD workerMain(void* arg) @nogc nothrow {
			auto pool = cast(ThreadPool*) arg;
			while (true) {
				WaitForSingleObject(pool.wake, INFINITE);
				if (atomicLoad(pool.stopping)) return 0;
				Job job = claimJob(pool);
				job.fn(job.arg);
				atomicOp!"-="(pool.outstanding, cast(ptrdiff_t) 1);
				ReleaseSemaphore(pool.done, 1, null);
			}
		}
	}

	/// `workerCount == 0` picks `hardwareConcurrency()`.
	ThreadPool* create(size_t workerCount = 0) @trusted @nogc nothrow {
		auto pool = fp.pointer.malloc!ThreadPool(1);
		*pool = ThreadPool.init;
		pool.count = workerCount > 0 ? workerCount : hardwareConcurrency();
		fp.dynarray.growToSize(pool.handles, pool.count);

		version (linux) {
			sem_init(&pool.wake, 0, 0);
			sem_init(&pool.done, 0, 0);
		} else version (Windows) {
			pool.wake = CreateSemaphoreA(null, 0, int.max, null);
			pool.done = CreateSemaphoreA(null, 0, int.max, null);
		}

		foreach (i; 0 .. pool.count)
			version (linux) pthread_create(&pool.handles[i], null, &workerMain, pool);
			else version (Windows) pool.handles[i] = CreateThread(null, 0, &workerMain, pool, 0, null);
		return pool;
	}

	size_t workerCount(const ThreadPool* pool) @nogc nothrow { return pool.count; }

	/// How many submitted jobs (queued or currently running) haven't
	/// completed yet - the same counter `wait()` blocks on.
	size_t pendingJobs(const ThreadPool* pool) @trusted @nogc nothrow {
		return cast(size_t) atomicLoad(pool.outstanding);
	}

	/// Queues `jobs` and returns immediately without waiting for them to
	/// run - pair with `wait()` once the caller actually needs the
	/// results. Safe to call reentrantly (e.g. from within a job
	/// currently executing on this pool, to fork more work and then
	/// just return - see `wait()` for why forking should never wait on
	/// its own children directly) since the queue is owned by the pool
	/// (not the caller) and every access to it, here and in each
	/// worker, goes through the same lock.
	void submit(ThreadPool* pool, scope Job[] jobs) @trusted @nogc nothrow {
		if (jobs.length == 0) return;

		while (!cas(&pool.queueLock, cast(uint) 0, cast(uint) 1)) {}
		foreach (ref job; jobs) fp.dynarray.pushBack(pool.queue, job);
		atomicStore(pool.queueLock, cast(uint) 0);

		atomicOp!"+="(pool.outstanding, cast(ptrdiff_t) jobs.length);
		foreach (_; 0 .. jobs.length) {
			version (linux) sem_post(&pool.wake);
			else version (Windows) ReleaseSemaphore(pool.wake, 1, null);
		}
	}

	/// Blocks until every job submitted so far - by this call, or by a
	/// concurrent or nested `submit()`, doesn't matter which - has
	/// completed. Never call this from within a job running on this
	/// same pool: that job counts as outstanding until the function
	/// running it returns, so a job blocked in its own `wait()` can
	/// never see the count reach zero, and it also stops that worker
	/// from looping back to help drain the queue it's blocked on. Fork
	/// more work with `submit()` and return - don't `wait()` on it.
	void wait(ThreadPool* pool) @trusted @nogc nothrow {
		while (atomicLoad(pool.outstanding) > 0) {
			version (linux) sem_wait(&pool.done);
			else version (Windows) WaitForSingleObject(pool.done, INFINITE);
		}
	}

	void waitJobCount(ThreadPool* pool, size_t count) @trusted @nogc nothrow {
		while (atomicLoad(pool.outstanding) > cast(ptrdiff_t) count) {}
	}

	/// Queues `jobs` and blocks until every one of them has completed.
	/// Workers pull jobs from the queue as they finish their current
	/// one - `jobs.length` need not match `workerCount(pool)`; a worker
	/// idles (parked on a semaphore) whenever the queue runs dry. Just
	/// `submit()` followed by `wait()` - see `wait()`'s doc comment for
	/// why that means `run()` must not be called from within a job
	/// running on this same pool either (fork with `submit()` there
	/// instead).
	void run(ThreadPool* pool, scope Job[] jobs) @trusted @nogc nothrow {
		immutable pending = pendingJobs(pool);
		submit(pool, jobs);
		waitJobCount(pool, pending);
	}

	void free(ThreadPool* pool) @trusted @nogc nothrow {
		if (pool is null || pool.handles is null) return;
		atomicStore(pool.stopping, true);
		foreach (i; 0 .. pool.count) {
			version (linux) sem_post(&pool.wake);
			else version (Windows) ReleaseSemaphore(pool.wake, 1, null);
		}
		foreach (i; 0 .. pool.count) {
			version (linux) pthread_join(pool.handles[i], null);
			else version (Windows) { WaitForSingleObject(pool.handles[i], INFINITE); CloseHandle(pool.handles[i]); }
		}
		version (linux) { sem_destroy(&pool.wake); sem_destroy(&pool.done); }
		else version (Windows) { CloseHandle(pool.wake); CloseHandle(pool.done); }
		fp.dynarray.free(pool.queue);
		fp.dynarray.free(pool.handles);
		fp.pointer.free(pool);
	}

} else {

	/// Degenerate fallback for platforms without a real thread backend:
	/// a single "worker" that just runs jobs inline on the calling thread.
	struct ThreadPool {}

	ThreadPool* create(size_t workerCount = 0) @trusted @nogc nothrow {
		return fp.pointer.malloc!ThreadPool(1);
	}

	size_t workerCount(const ThreadPool* pool) @nogc nothrow { return 1; }

	/// Jobs run inline within `submit()`/`run()`, so nothing is ever
	/// left pending by the time either returns.
	size_t pendingJobs(const ThreadPool* pool) @nogc nothrow { return 0; }

	/// No real background worker to hand these off to, so they just run
	/// inline before this returns - by the time `submit()` comes back,
	/// `wait()` has nothing left to wait for.
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
	// Jobs running on the pool can fork more jobs themselves (e.g. a
	// divide-and-conquer split) by calling `submit()` - never `run()` or
	// `wait()` - on the way out. A job that called `wait()` instead would
	// block its worker until its own children finished, without that
	// worker ever going back to help drain the very queue it's blocked on;
	// with enough forked work in flight relative to idle workers that's a
	// guaranteed deadlock. `submit()` just extends the current wave: the
	// *outer* `wait()` (from whoever originally called `run()`) ends up
	// covering the whole tree anyway, since `outstanding` counts every job
	// submitted so far regardless of who queued it. Each node caps its own
	// recursion at `maxDepth`, so the pool never sees more than one extra
	// level of forked jobs.
	//
	// Child storage is pre-allocated by the caller (rather than living on
	// `runNode`'s own stack frame) because `runNode` returns as soon as it
	// has submitted its children, well before they've necessarily run.
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

	// Each root plus its `childCount` depth-1 children, and nothing deeper
	// since depth-1 nodes have already hit `maxDepth` and don't fork again.
	assert(totalRuns == rootCount + totalChildren);
}


unittest {
	// `submit` queues jobs and returns immediately without blocking - useful
	// when the caller has other work to do before it actually needs the
	// results. `wait` is what blocks until the queue drains; `run` is just
	// `submit` followed by `wait`.
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

	// Multiple submits before a single wait extend the same wave rather
	// than racing each other.
	submit(pool, jobs[0 .. 8]);
	submit(pool, jobs[8 .. n]);
	wait(pool);
	foreach (ref c; counters) assert(c.value == 2);
}
