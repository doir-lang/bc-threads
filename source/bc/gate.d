/// A stop-the-world gate: many threads work inside it at once, sharing a structure, and one thread at a time takes it exclusively to change that structure, which waits until every sharing thread has paused at a safepoint.
/// A sharing thread pauses only where it calls `yieldToExclusive`, so a structural change never lands in the middle of its work.
///
/// Unlike a reader-writer lock, a waiting exclusive holder holds off new sharers, so it cannot starve, and a sharer may take the gate exclusively itself without leaving its own work.
/// What a thread holds is the caller's to track, and is passed in where it matters; the gate keeps only counts.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// yieldToExclusive(gate); // a safepoint: lets a waiting exclusive holder in
/// beginExclusive(gate, true);
/// endExclusive(gate, true);
/// leaveShared(gate);
/// ---
module bc.gate;

static import core.atomic;

static import bc.platform;
static import bc.spinlock;
static import bc.thread;

@nogc nothrow:


/// The gate: how many threads are inside it sharing, how many wait for or hold it exclusively, and the lock exclusive holders take in turn.
/// Its `.init` is open and empty.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// leaveShared(gate);
/// ---
struct Gate {
	private size_t sharers;
	private size_t exclusiveWaiters;
	private bc.spinlock.SpinLock exclusive;
}

/// Enters the gate to share it, first waiting out every thread that waits for or holds it exclusively.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// leaveShared(gate);
/// ---
void enterShared(ref Gate gate) {
	for(;;) {
		while(core.atomic.atomicLoad(bc.platform.asShared(gate.exclusiveWaiters)) != 0) bc.thread.yield();
		immutable sharers = core.atomic.atomicOp!"+="(bc.platform.asShared(gate.sharers), 1);
		assert(sharers > 0, "bc.gate: the sharer count wrapped");
		if(core.atomic.atomicLoad(bc.platform.asShared(gate.exclusiveWaiters)) == 0) return;
		assert(core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) > 0, "bc.gate: backing out of a share no thread holds");
		core.atomic.atomicOp!"-="(bc.platform.asShared(gate.sharers), 1);
	}
}

// wrapper: names the inverse of enterShared
/// Leaves the gate, which the calling thread shares.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// leaveShared(gate);
/// ---
void leaveShared(ref Gate gate) {
	assert(core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) > 0, "bc.gate: leaving a gate no thread shares");
	core.atomic.atomicOp!"-="(bc.platform.asShared(gate.sharers), 1);
}

/// A safepoint for a thread sharing the gate: if another thread waits to take it exclusively, steps out until that thread is done, then back in.
/// Call it where the caller's work can tolerate the shared structure changing.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// yieldToExclusive(gate); // no one waits, so it returns at once
/// leaveShared(gate);
/// ---
void yieldToExclusive(ref Gate gate) {
	assert(core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) > 0, "bc.gate: yielding a share this thread does not hold");
	if(core.atomic.atomicLoad(bc.platform.asShared(gate.exclusiveWaiters)) == 0) return;
	leaveShared(gate);
	enterShared(gate);
	assert(core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) > 0, "bc.gate: came back from yielding without a share");
}

/// Takes the gate exclusively, waiting until every other sharing thread has paused at a safepoint and every earlier exclusive holder is done.
/// `sharing` says whether the calling thread itself shares the gate, in which case it steps out for the exclusive hold.
/// It does not nest; a caller that holds the gate exclusively must count its own nested holds.
///
/// Examples:
/// ---
/// Gate gate;
/// beginExclusive(gate, false);
/// endExclusive(gate, false);
/// ---
void beginExclusive(ref Gate gate, bool sharing) {
	assert(!sharing || core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) > 0, "bc.gate: giving up a share this thread does not hold");
	core.atomic.atomicOp!"+="(bc.platform.asShared(gate.exclusiveWaiters), 1);
	if(sharing) leaveShared(gate);
	bc.spinlock.lockForWriting(gate.exclusive);
	while(core.atomic.atomicLoad(bc.platform.asShared(gate.sharers)) != 0) bc.thread.yield();
	assert(bc.spinlock.isLockedForWriting(gate.exclusive) && core.atomic.atomicLoad(bc.platform.asShared(gate.exclusiveWaiters)) > 0, "bc.gate: an exclusive hold without the lock or its count");
}

/// Releases the exclusive hold `beginExclusive` took; with `sharing`, as passed to it, the calling thread enters the gate to share it again.
///
/// Examples:
/// ---
/// Gate gate;
/// enterShared(gate);
/// beginExclusive(gate, true);
/// endExclusive(gate, true);
/// leaveShared(gate);
/// ---
void endExclusive(ref Gate gate, bool sharing) {
	assert(bc.spinlock.isLockedForWriting(gate.exclusive), "bc.gate: ending an exclusive hold that was not begun");
	bc.spinlock.unlockForWriting(gate.exclusive);
	assert(core.atomic.atomicLoad(bc.platform.asShared(gate.exclusiveWaiters)) > 0, "bc.gate: ending an exclusive hold no thread began");
	core.atomic.atomicOp!"-="(bc.platform.asShared(gate.exclusiveWaiters), 1);
	if(sharing) enterShared(gate);
}


version(unittest) {
	static import bc.platform;
	static import bc.threadpool;

	private struct Shared {
		Gate gate;
		size_t[2] pair; // an exclusive holder changes both halves together; sharers check they always match
		size_t mismatches;
	}

	private void work(void* arg) @trusted {
		auto s = cast(Shared*) arg;
		enterShared(s.gate);
		foreach(i; 0 .. 2000) {
			if(core.atomic.atomicLoad(bc.platform.asShared(s.pair[0])) != core.atomic.atomicLoad(bc.platform.asShared(s.pair[1])))
				core.atomic.atomicOp!"+="(bc.platform.asShared(s.mismatches), 1);
			if(i % 50 == 0) {
				beginExclusive(s.gate, true);
				++s.pair[0];
				bc.thread.yield(); // widen the window a sharer would see a half-changed pair in
				++s.pair[1];
				endExclusive(s.gate, true);
			}
			yieldToExclusive(s.gate);
		}
		leaveShared(s.gate);
	}
}

unittest { // an exclusive holder's changes are never seen half-made by sharing threads
	static if(bc.platform.threadingSupported) {
		Shared s;
		auto pool = bc.threadpool.create(4);
		assert(pool !is null);
		scope(exit) bc.threadpool.free(pool);
		bc.threadpool.Job[4] jobs;
		foreach(ref job; jobs) job = bc.threadpool.Job(&work, &s);
		assert(bc.threadpool.run(pool, jobs[]));
		assert(s.mismatches == 0 && s.pair[0] == 4 * 40 && s.pair[1] == s.pair[0] && s.gate.sharers == 0 && s.gate.exclusiveWaiters == 0);
	}
}
