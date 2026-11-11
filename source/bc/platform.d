/// Platform detection shared by every `bc` module.
module bc.platform;

@nogc nothrow:

/// Whether the target has OS threads, semaphores and locks.
/// Where it does not, pools run jobs inline and `bc.mutex` spins.
version(linux) enum bool threadingSupported = true;
else version(OSX) enum bool threadingSupported = true;
else version(Windows) enum bool threadingSupported = true;
// wasm has threads only when built with shared memory and atomics, as for `wasm32-wasip1-threads`.
else version(WASI) enum bool threadingSupported = __traits(targetHasFeature, "atomics");
else enum bool threadingSupported = false;

/// The bytes a value is padded to so threads writing neighbouring ones never share a cache line: 64 on the x86-64 and ARM cores this library targets.
enum size_t cacheLineBytes = 64;

/// Mixed in, declares `version(PthreadBackend)` on Linux, macOS and WASI.
/// Version identifiers are module-local, so each module that branches on it mixes this in.
enum string backendSelection = q{
	version(linux) version = PthreadBackend;
	else version(OSX) version = PthreadBackend;
	else version(WASI) version = PthreadBackend;
};


// --- atomics -------------------------------------------------------------------

// wrapper: names the shared view core.atomic needs of a field declared without `shared`
/// `value` viewed as `shared`, for `core.atomic.atomicLoad`, `atomicStore`, `atomicOp` and `cas`.
/// Every access to the field while other threads may touch it must go through such a view; a plain read or write races.
/// A `const` field gives a `shared(const)` view, which only loads.
///
/// Examples:
/// ---
/// static import core.atomic;
/// bool flag;
/// core.atomic.atomicStore(asShared(flag), true);
/// const bool* view = &flag;
/// assert(core.atomic.atomicLoad(asShared(*view)));
/// ---
ref shared(T) asShared(T)(return ref T value) @trusted {
	return *cast(shared(T)*) &value;
}

unittest { // views of different widths and qualifiers act on the field itself
	static import core.atomic;
	static struct Plain { ubyte small; ulong wide; void* pointer; }
	Plain p;
	core.atomic.atomicStore(asShared(p.small), cast(ubyte) 7);
	assert(core.atomic.cas(&asShared(p.wide), 0UL, 9UL) && p.wide == 9 && p.small == 7);
	int target;
	core.atomic.atomicStore(asShared(p.pointer), cast(shared(void*)) &target);
	assert(p.pointer is &target);
	const Plain frozen = p;
	assert(core.atomic.atomicLoad(asShared(frozen.wide)) == 9);
}

version(unittest) {
	version(Windows) import core.sys.windows.winbase : Sleep;
	else version(WASI) private extern(C) int usleep(uint);
	else import core.sys.posix.unistd : usleep;

	/// Sleeps the calling thread for about `ms` milliseconds, for tests that give another thread time to act.
	/// It exists only in unittest builds.
	///
	/// Examples:
	/// ---
	/// nap(1);
	/// ---
	package void nap(uint ms) {
		version(Windows) Sleep(ms);
		else cast(void) usleep(ms * 1_000);
	}
}


debug {
	static import fp.pointer;

	// Thread-local, like `fp.pointer.allocator`, so a failure armed on one thread is never consumed by another.
	private bool failureArmed;
	private size_t acquisitionsLeft;
	private fp.pointer.Allocator realAllocFunction;

	/// Whether the acquisition the caller is about to make, an allocation or an OS object, should fail as `failAfter` arranged.
	/// It exists only in debug builds, so callers check it under `debug`.
	///
	/// Examples:
	/// ---
	/// debug assert(!simulatedFailure());
	/// ---
	pragma(inline, true)
	package bool simulatedFailure() {
		if(!failureArmed || acquisitionsLeft-- > 0) return false;
		assert(realAllocFunction !is null, "bc.platform: a failure armed with no allocator to restore");
		failureArmed = false;
		fp.pointer.allocator = realAllocFunction;
		return true;
	}
}

debug version(unittest) {
	private void* failingAllocFunction(void* p, size_t size) {
		// A size of 0 is a free, which must neither fail nor count.
		if(size != 0 && simulatedFailure()) return null;
		return realAllocFunction(p, size);
	}

	/// Lets the next `n` acquisitions on this thread succeed and makes the one after fail, then lets later ones succeed.
	/// Acquisitions are allocations through `fp.pointer` and anything else, such as creating an OS object, that checks `simulatedFailure`.
	/// Calling it again before the failure happens replaces the earlier arrangement.
	/// It exists only in debug unittest builds.
	///
	/// Examples:
	/// ---
	/// debug {
	/// 	failAfter(1);
	/// 	int* p = fp.pointer.allocate!int(1);
	/// 	assert(p !is null);
	/// 	assert(simulatedFailure());
	/// 	assert(!simulatedFailure());
	/// 	fp.pointer.free(p);
	/// }
	/// ---
	package void failAfter(size_t n) {
		// Re-arming must not save the failing allocator as the real one, or every allocation would recurse forever.
		if(!failureArmed) realAllocFunction = fp.pointer.allocator;
		acquisitionsLeft = n;
		failureArmed = true;
		fp.pointer.allocator = &failingAllocFunction;
	}
}

debug unittest {
	failAfter(3);
	failAfter(0);
	assert(fp.pointer.allocate!int(1) is null);
	int* p = fp.pointer.allocate!int(1);
	assert(p !is null);
	fp.pointer.free(p);

	static if(threadingSupported) {
		static import bc.semaphore;
		static import bc.thread;
		static void acquire(bool* ok) @nogc nothrow {
			auto s = bc.semaphore.create();
			*ok = s !is null;
			bc.semaphore.free(s);
		}

		// Starting the thread takes two acquisitions here; the thread's own neither fail nor use up the failure armed.
		bool ok = false;
		failAfter(2);
		auto t = bc.thread.create(&acquire, &ok);
		assert(!t.isNull);
		bc.thread.join(t.get);
		assert(ok);
		assert(simulatedFailure());
	}
}
