/// A reader-writer lock for data mostly read, sharded so readers on different threads never touch one cache line: a reader holds its thread's shard alone, a writer every shard.
///
/// It meets `bc.monitor.isLock`, so a `bc.monitor.Monitor!(T, ReaderLock)` keeps a value behind it.
///
/// Examples:
/// ---
/// static import bc.monitor;
/// bc.monitor.Monitor!(int, ReaderLock) m;
/// bc.monitor.write(m).value = 3;
/// assert(bc.monitor.read(m).value == 3);
/// ---
module bc.readerlock;

static import core.atomic;

static import bc.monitor;
static import bc.spinlock;

@nogc nothrow:


/// How many shards a `ReaderLock` has.
enum size_t readerShards = 16;

/// A reader-writer lock whose `.init` is unlocked. A thread already holding it must not take it again.
///
/// Examples:
/// ---
/// ReaderLock l;
/// readLock(l);
/// readUnlock(l);
/// ---
struct ReaderLock {
	private static struct Shard {
		align(64) bc.spinlock.SpinLock lock;
	}
	private Shard[readerShards] shards;
}

private shared size_t shardsGiven; // threads given a shard, round-robin
private size_t ownShard = size_t.max; // module scope, so one per thread; the shard this thread reads under

private ref bc.spinlock.SpinLock shardOf(return ref ReaderLock self) {
	if(ownShard == size_t.max) ownShard = core.atomic.atomicOp!"+="(shardsGiven, 1) % readerShards;
	return self.shards[ownShard].lock;
}


/// An unlocked lock, the same as `ReaderLock.init`, which `bc.monitor` makes its locks with. Never fails.
///
/// Examples:
/// ---
/// ReaderLock l = bc.readerlock.create();
/// writeLock(l);
/// writeUnlock(l);
/// ---
ReaderLock create() { return ReaderLock.init; }

/// Spins until no writer holds `self`, then takes a shared hold on the calling thread's shard.
///
/// Examples:
/// ---
/// ReaderLock l;
/// readLock(l);
/// assert(!tryWriteLock(l));
/// readUnlock(l);
/// ---
void readLock(ref ReaderLock self) { bc.spinlock.readLock(shardOf(self)); }

/// Releases the calling thread's shared hold on `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// readLock(l);
/// readUnlock(l);
/// assert(tryWriteLock(l));
/// writeUnlock(l);
/// ---
void readUnlock(ref ReaderLock self) { bc.spinlock.readUnlock(shardOf(self)); }

/// Takes a shared hold on the calling thread's shard without waiting; returns false, taking nothing, if a writer holds `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// assert(tryReadLock(l));
/// readUnlock(l);
/// ---
bool tryReadLock(ref ReaderLock self) { return bc.spinlock.tryReadLock(shardOf(self)); }


/// Spins until nobody holds `self`, then takes every shard exclusively, in order, so two writers cannot each hold part of it.
///
/// Examples:
/// ---
/// ReaderLock l;
/// writeLock(l);
/// assert(!tryReadLock(l));
/// writeUnlock(l);
/// ---
void writeLock(ref ReaderLock self) {
	foreach(ref shard; self.shards) bc.spinlock.writeLock(shard.lock);
}

/// Releases the exclusive hold on `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// writeLock(l);
/// writeUnlock(l);
/// assert(tryReadLock(l));
/// readUnlock(l);
/// ---
void writeUnlock(ref ReaderLock self) {
	foreach(ref shard; self.shards) bc.spinlock.writeUnlock(shard.lock);
}

/// Takes every shard exclusively without waiting; returns false, taking nothing, if anyone holds `self`.
///
/// Examples:
/// ---
/// ReaderLock l;
/// assert(tryWriteLock(l));
/// assert(!tryWriteLock(l));
/// writeUnlock(l);
/// ---
bool tryWriteLock(ref ReaderLock self) {
	foreach(i, ref shard; self.shards)
		if(!bc.spinlock.tryWriteLock(shard.lock)) {
			foreach(ref taken; self.shards[0 .. i]) bc.spinlock.writeUnlock(taken.lock);
			return false;
		}
	return true;
}


unittest {
	static assert(bc.monitor.isLock!ReaderLock);
	ReaderLock l = create();
	readLock(l);
	assert(!tryWriteLock(l));
	readUnlock(l);
	// Held on the last shard, a write hold fails after taking every other, and gives them back.
	bc.spinlock.readLock(l.shards[$ - 1].lock);
	assert(!tryWriteLock(l));
	foreach(ref shard; l.shards) assert(!bc.spinlock.isWriteLocked(shard.lock));
	bc.spinlock.readUnlock(l.shards[$ - 1].lock);
	assert(tryWriteLock(l));
	assert(!tryReadLock(l) && !tryWriteLock(l));
	writeUnlock(l);
	writeLock(l);
	writeUnlock(l);
	foreach(ref shard; l.shards) assert(!bc.spinlock.isLocked(shard.lock));

	static import bc.platform;
	static if(bc.platform.threadingSupported) {
		static import bc.thread;
		enum threads = 4, rounds = 10_000;
		static struct Pair { long a, b; }
		static void bump(bc.monitor.Monitor!(Pair, ReaderLock)* m) @nogc nothrow {
			foreach(i; 0 .. rounds) {
				auto w = bc.monitor.write(*m);
				++w.value.a;
				++w.value.b;
			}
		}
		bc.monitor.Monitor!(Pair, ReaderLock) m;
		typeof(bc.thread.create(&bump, &m).get())[threads] ts;
		foreach(ref t; ts) {
			auto made = bc.thread.create(&bump, &m);
			assert(!made.isNull);
			t = made.get;
		}
		// Each writer moves both halves in one hold, so a reader on any shard never sees them apart.
		foreach(i; 0 .. rounds) {
			auto r = bc.monitor.read(m);
			assert(r.value.a == r.value.b);
		}
		foreach(ref t; ts) bc.thread.join(t);
		assert(bc.monitor.read(m).value.a == threads * rounds);
	}
}
