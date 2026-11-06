/// A value kept behind the reader-writer lock that guards it: `read` hands out `const` access under a shared hold, and `write` mutable access under the exclusive one, so the value cannot be reached without the lock.
///
/// The lock is any type meeting `isLock`, such as `bc.spinlock.SpinLock` (the default) or `bc.mutex.Mutex*`.
///
/// Examples:
/// ---
/// Monitor!int counter;
/// { auto w = write(counter); w.value += 1; }
/// { auto r = read(counter); assert(r.value == 1); }
/// ---
module bc.monitor;

static import core.stdc.string;

static import fp.lifecycle;
static import fp.pointer;

static import bc.platform;
static import bc.spinlock;

@nogc nothrow:


// --- the lock concept --------------------------------------------------------

// Where a lock's functions live: the scope declaring it, or its pointee for a pointer lock.
private template lockScope(L) {
	static if(is(L == P*, P)) alias lockScope = __traits(parent, P);
	else alias lockScope = __traits(parent, L);
}

private enum bool hasCreate(L) = __traits(compiles, lockScope!L.create());

private enum bool hasTryLocks(L) = __traits(compiles, (ref L l) @nogc nothrow {
	bool r = lockScope!L.tryLockForReading(l);
	bool w = lockScope!L.tryLockForWriting(l);
});

private enum bool hasFree(L) = __traits(compiles, (ref L l) @nogc nothrow { lockScope!L.free(l); });

/// Whether `L` can lock a `Monitor`: the module (or other scope) declaring `L`, or its pointee when `L` is a pointer, has free functions `lockForReading`, `unlockForReading`, `lockForWriting` and `unlockForWriting`, each `@nogc nothrow` and taking an `L` by value or `ref`. A pointer lock's scope also has `L create()`, since its `.init` is null; any other lock's `.init` must be unlocked, and a `create` it has instead makes the monitor's lock.
///
/// The scope may also have `bool tryLockForReading(L)` and `bool tryLockForWriting(L)`, which give the monitor `tryRead` and `tryWrite`, and `free(L)`, which `Monitor.finalize` calls on the lock.
///
/// Examples:
/// ---
/// static assert(isLock!(bc.spinlock.SpinLock));
/// static assert(isLock!(bc.mutex.Mutex*));
/// static assert(!isLock!(bc.mutex.Mutex));
/// static assert(!isLock!int);
/// ---
enum bool isLock(L) = __traits(compiles, lockScope!L) && (hasCreate!L ? is(typeof(lockScope!L.create()) == L) : !is(L == P*, P)) && __traits(compiles, (ref L l) @nogc nothrow {
	lockScope!L.lockForReading(l);
	lockScope!L.unlockForReading(l);
	lockScope!L.lockForWriting(l);
	lockScope!L.unlockForWriting(l);
});


// --- types and layout --------------------------------------------------------

/// A `T` reachable only through the guards `read` and `write` give, under a `Lock` meeting `isLock`.
///
/// With the default `bc.spinlock.SpinLock`, `.init` is ready, holding `T.init`, so a `__gshared` monitor needs no `create`; going out of scope runs `T`'s destructor, but a `T` with a libfp `finalize` needs `fp.lifecycle.endLifetime` on the monitor. A pointer lock comes from its `create`, so its monitors do too, since its `.init` is null. Like the plain data holding it, a monitor copies its lock and value bytewise: never copy a held one, and end only one copy of a pointer lock's monitor. It has the reentrancy and starvation caveats of its lock: under either lock in this library, a thread already holding it must not take it again.
///
/// Examples:
/// ---
/// __gshared Monitor!int shared_;
/// { auto w = write(shared_); w.value = 5; }
/// assert(read(shared_).value == 5);
/// ---
struct Monitor(T, Lock = bc.spinlock.SpinLock) {
	static assert(isLock!Lock, "bc.monitor: " ~ Lock.stringof ~ " is not a lock; see `isLock` for the functions its module must define");

	private Lock lock;
	private T value;

	/// Ends the value's lifetime and frees the lock if `Lock`'s scope defines `free`, leaving the monitor empty; libfp calls it when it ends a monitor's lifetime, as `fp.pointer.free` does. No thread may hold the monitor.
	///
	/// Examples:
	/// ---
	/// auto m = bc.monitor.create!(bc.mutex.Mutex*)(1);
	/// static import fp.pointer;
	/// fp.pointer.free(m); // calls `finalize`
	/// ---
	void finalize() {
		fp.lifecycle.endLifetime(value);
		static if(hasFree!Lock) lockScope!Lock.free(lock);
		lock = Lock.init;
	}
}

/// A shared hold on a monitor, released when the guard is destroyed, giving `const` access to its value. An empty guard, from a failed `tryRead`, holds nothing and converts to `false`. The `ref` that `value` returns must not outlive the guard, and a temporary guard, as in `read(m).value`, holds until the end of the whole expression.
///
/// Examples:
/// ---
/// Monitor!int m;
/// ReadGuard!(int, bc.spinlock.SpinLock) r = read(m);
/// assert(r && r.value == 0);
/// ---
struct ReadGuard(T, Lock) {
	private Monitor!(T, Lock)* monitor = null;

	@disable this(this);

	~this() {
		if(monitor !is null) lockScope!Lock.unlockForReading(monitor.lock);
	}

	// wrapper: the guarded value, as the alias this target
	/// The guarded value, which a shared hold may only read.
	///
	/// Examples:
	/// ---
	/// Monitor!int m;
	/// assert(read(m).value == 0);
	/// ---
	ref const(T) value() return { return monitor.value; }

	alias value this;

	/// Whether the guard holds the monitor.
	///
	/// Examples:
	/// ---
	/// Monitor!int m;
	/// assert(read(m));
	/// ---
	bool opCast(B : bool)() const { return monitor !is null; }
}

/// The exclusive hold on a monitor, released when the guard is destroyed, giving mutable access to its value. An empty guard, from a failed `tryWrite`, holds nothing and converts to `false`. The `ref` that `value` returns must not outlive the guard, and a temporary guard, as in `write(m).value = 1`, holds until the end of the whole expression.
///
/// Examples:
/// ---
/// Monitor!int m;
/// WriteGuard!(int, bc.spinlock.SpinLock) w = write(m);
/// w.value = 3;
/// ---
struct WriteGuard(T, Lock) {
	private Monitor!(T, Lock)* monitor = null;

	@disable this(this);

	~this() {
		if(monitor !is null) lockScope!Lock.unlockForWriting(monitor.lock);
	}

	// wrapper: the guarded value, as the alias this target
	/// The guarded value, which the exclusive hold may change.
	///
	/// Examples:
	/// ---
	/// Monitor!int m;
	/// write(m).value = 2;
	/// assert(read(m).value == 2);
	/// ---
	ref T value() return { return monitor.value; }

	alias value this;

	/// Whether the guard holds the monitor.
	///
	/// Examples:
	/// ---
	/// Monitor!int m;
	/// assert(write(m));
	/// ---
	bool opCast(B : bool)() const { return monitor !is null; }
}


// --- creation ----------------------------------------------------------------

/// Allocates a monitor holding `value`, which is moved in, under a lock from `Lock`'s `create`, or `Lock.init` if it has none. Free it with `fp.pointer.free`, which ends the value's lifetime and frees the lock through `Monitor.finalize`, once no thread holds it.
///
/// Returns null, having freed what it allocated and leaving `value` as it was, if allocation is refused or `Lock` is a pointer and its `create` returns null.
///
/// Examples:
/// ---
/// auto m = bc.monitor.create!(bc.mutex.Mutex*)(1);
/// assert(m !is null);
/// scope(exit) fp.pointer.free(m);
/// assert(read(*m).value == 1);
/// ---
Monitor!(T, Lock)* create(Lock = bc.spinlock.SpinLock, T)(T value) @trusted if(isLock!Lock) {
	alias monitorType = Monitor!(T, Lock);
	auto m = fp.pointer.allocate!monitorType(1);
	if(m is null) return null;
	// Copy `.init`'s bytes rather than assign it, which would run `T`'s destructor on the uninitialized block.
	auto blank = __traits(initSymbol, monitorType);
	if(blank.ptr is null) core.stdc.string.memset(m, 0, monitorType.sizeof);
	else core.stdc.string.memcpy(m, blank.ptr, monitorType.sizeof);

	static if(hasCreate!Lock) m.lock = lockScope!Lock.create();
	static if(is(Lock == P*, P)) if(m.lock is null) {
		fp.pointer.free(m);
		return null;
	}
	fp.lifecycle.moveInto(m.value, value);
	return m;
}

// --- taking holds ------------------------------------------------------------

/// Waits until no writer holds `m`, then takes a shared hold on it, which the returned guard releases.
///
/// Examples:
/// ---
/// Monitor!int m;
/// auto r = read(m);
/// assert(r.value == 0 && !tryWrite(m));
/// ---
ReadGuard!(T, Lock) read(T, Lock)(return ref Monitor!(T, Lock) m) @trusted {
	lockScope!Lock.lockForReading(m.lock);
	return ReadGuard!(T, Lock)(&m);
}

/// Takes a shared hold on `m` without waiting; returns an empty guard, taking nothing, if a writer holds it. Defined only for a lock whose scope has `tryLockForReading`.
///
/// Examples:
/// ---
/// Monitor!int m;
/// if(auto r = tryRead(m)) assert(r.value == 0);
/// else assert(false);
/// ---
ReadGuard!(T, Lock) tryRead(T, Lock)(return ref Monitor!(T, Lock) m) @trusted if(hasTryLocks!Lock) {
	if(!lockScope!Lock.tryLockForReading(m.lock)) return ReadGuard!(T, Lock).init;
	return ReadGuard!(T, Lock)(&m);
}


/// Waits until nobody holds `m`, then takes the exclusive hold on it, which the returned guard releases.
///
/// Examples:
/// ---
/// Monitor!int m;
/// auto w = write(m);
/// w.value = 4;
/// assert(!tryRead(m));
/// ---
WriteGuard!(T, Lock) write(T, Lock)(return ref Monitor!(T, Lock) m) @trusted {
	lockScope!Lock.lockForWriting(m.lock);
	return WriteGuard!(T, Lock)(&m);
}

/// Takes the exclusive hold on `m` without waiting; returns an empty guard, taking nothing, if anyone holds it. Defined only for a lock whose scope has `tryLockForWriting`.
///
/// Examples:
/// ---
/// Monitor!int m;
/// if(auto w = tryWrite(m)) w.value = 1;
/// assert(read(m).value == 1);
/// ---
WriteGuard!(T, Lock) tryWrite(T, Lock)(return ref Monitor!(T, Lock) m) @trusted if(hasTryLocks!Lock) {
	if(!lockScope!Lock.tryLockForWriting(m.lock)) return WriteGuard!(T, Lock).init;
	return WriteGuard!(T, Lock)(&m);
}


// --- tests -------------------------------------------------------------------

version(unittest) {
	// A lock with only the required functions, declared in a struct to show any scope serves, not only a module.
	private struct toyLock {
		@nogc nothrow:
		static struct Lock { int readers = 0; bool writer = false; }

		static void lockForReading(ref Lock l) { assert(!l.writer); ++l.readers; }
		static void unlockForReading(ref Lock l) { assert(l.readers > 0); --l.readers; }
		static void lockForWriting(ref Lock l) { assert(!l.writer && l.readers == 0); l.writer = true; }
		static void unlockForWriting(ref Lock l) { assert(l.writer); l.writer = false; }
	}

	private struct Tracked {
		int* ends = null;
		~this() @nogc nothrow { if(ends !is null) ++*ends; }
	}

	private struct Finalized {
		int* ends = null;
		void finalize() @nogc nothrow { if(ends !is null) ++*ends; ends = null; }
	}

	private struct Pair { long a = 0, b = 0; }
}

unittest {
	static import bc.mutex;
	static assert(isLock!(bc.spinlock.SpinLock) && isLock!(bc.mutex.Mutex*) && isLock!(toyLock.Lock));
	static assert(!isLock!(bc.mutex.Mutex) && !isLock!int && !isLock!(int*));
	static assert(hasTryLocks!(bc.spinlock.SpinLock) && hasTryLocks!(bc.mutex.Mutex*) && !hasTryLocks!(toyLock.Lock));
	static assert(!hasFree!(bc.spinlock.SpinLock) && hasFree!(bc.mutex.Mutex*));
	static assert(!__traits(compiles, Monitor!(int, int)));

	Monitor!(int, toyLock.Lock) toy;
	{
		auto w = write(toy);
		assert(toy.lock.writer);
		w.value = 7;
	}
	assert(!toy.lock.writer);
	{
		auto r = read(toy);
		auto r2 = read(toy);
		assert(toy.lock.readers == 2 && r.value == 7 && r2.value == 7);
		static assert(!__traits(compiles, r.value = 1));
	}
	assert(toy.lock.readers == 0);
	static assert(!__traits(compiles, tryRead(toy)) && !__traits(compiles, tryWrite(toy)));

	// `double.init` is NaN, so `create` must copy `.init`'s bytes rather than zero the block.
	auto made = create!(toyLock.Lock)(1.5);
	assert(made !is null);
	assert(made.lock.readers == 0 && !made.lock.writer);
	assert(read(*made).value == 1.5);
	fp.pointer.free(made);
}

unittest {
	static import bc.mutex;

	static void check(Lock)(ref Monitor!(Pair, Lock) m) {
		{
			auto w = write(m);
			assert(w);
			w.value.a = 1;
			w.value.b = 1;
			assert(!tryRead(m) && !tryWrite(m));
		}
		{
			auto r = read(m);
			assert(r.value.a == 1 && r.value.b == 1);
			static assert(!__traits(compiles, r.value.a = 2));
			assert(!tryWrite(m));
		}
		if(auto w = tryWrite(m)) w.value.a = 2;
		else assert(false);
		if(auto r = tryRead(m)) assert(r.value.a == 2);
		else assert(false);
		ReadGuard!(Pair, Lock) empty;
		assert(!empty);
	}

	Monitor!Pair spin;
	check(spin);
	assert(!bc.spinlock.isLocked(spin.lock));

	auto mutex = create!(bc.mutex.Mutex*)(Pair.init);
	assert(mutex !is null);
	scope(exit) fp.pointer.free(mutex);
	check(*mutex);

	static if(bc.platform.threadingSupported) {
		static import bc.thread;
		enum threads = 4, rounds = 10_000;

		static void bump(Lock)(Monitor!(Pair, Lock)* m) @nogc nothrow {
			foreach(i; 0 .. rounds) {
				auto w = write(*m);
				++w.value.a;
				++w.value.b;
			}
		}

		static void race(Lock)(ref Monitor!(Pair, Lock) m) {
			write(m).value = Pair.init;
			typeof(bc.thread.create(&bump!Lock, &m).get())[threads] handles;
			foreach(ref handle; handles) {
				auto made = bc.thread.create(&bump!Lock, &m);
				assert(!made.isNull);
				handle = made.get;
			}
			// A writer bumps `a` and `b` in one hold, so a reader never sees them apart.
			foreach(i; 0 .. rounds) {
				auto r = read(m);
				assert(r.value.a == r.value.b);
			}
			foreach(ref handle; handles) bc.thread.join(handle);
			assert(read(m).value.a == threads * rounds);
		}

		race(spin);
		race(*mutex);
	}
}

unittest {
	static import bc.mutex;

	int ends = 0;
	auto m = create(Tracked(&ends));
	assert(m !is null && ends == 0);
	fp.pointer.free(m);
	assert(ends == 1 && m is null);
	{
		Monitor!Tracked byValue;
		write(byValue).value.ends = &ends;
	}
	assert(ends == 2);

	int finalized = 0;
	auto f = create!(bc.mutex.Mutex*)(Finalized(&finalized));
	assert(f !is null);
	fp.pointer.free(f);
	assert(finalized == 1);

	debug {
		bc.platform.failAfter(0);
		assert(create(1) is null);
		// The monitor is allocated, then the mutex's allocation fails, then (on pthreads) its initialization.
		bc.platform.failAfter(1);
		assert(create!(bc.mutex.Mutex*)(1) is null);
		static if(bc.platform.threadingSupported) version(PthreadBackend) {
			bc.platform.failAfter(2);
			assert(create!(bc.mutex.Mutex*)(1) is null);
		}
	}
}
