/// Platform detection shared by every `bc` module.
module bc.platform;

@nogc nothrow:

/// Whether the target has OS threads, semaphores and locks. Where it does not, pools run jobs inline and `bc.mutex` spins.
version(linux) enum bool threadingSupported = true;
else version(OSX) enum bool threadingSupported = true;
else version(Windows) enum bool threadingSupported = true;
// wasm has threads only when built with shared memory and atomics, as for `wasm32-wasip1-threads`.
else version(WASI) enum bool threadingSupported = __traits(targetHasFeature, "atomics");
else enum bool threadingSupported = false;

/// Mixed in, declares `version(PthreadBackend)` on Linux, macOS and WASI. Version identifiers are module-local, so each module that branches on it mixes this in.
enum string pthreadBackendMixin = q{
	version(linux) version = PthreadBackend;
	else version(OSX) version = PthreadBackend;
	else version(WASI) version = PthreadBackend;
};


version(unittest) {
	version(Windows) import core.sys.windows.winbase : Sleep;
	else version(WASI) private extern(C) int usleep(uint);
	else import core.sys.posix.unistd : usleep;

	/// Sleeps the calling thread for about `ms` milliseconds, for tests that give another thread time to act. It exists only in unittest builds.
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

	// Thread-local, like `fp.pointer.allocFunction`, so a failure armed on one thread is never consumed by another.
	private bool failureArmed;
	private size_t acquisitionsLeft;
	private fp.pointer.AllocFunction realAllocFunction;

	/// Whether the acquisition the caller is about to make, an allocation or an OS object, should fail as `failAfter` arranged. It exists only in debug builds, so callers check it under `debug`.
	///
	/// Examples:
	/// ---
	/// debug assert(!simulatedFailure());
	/// ---
	pragma(inline, true)
	package bool simulatedFailure() {
		if(!failureArmed || acquisitionsLeft-- > 0) return false;
		failureArmed = false;
		fp.pointer.allocFunction = realAllocFunction;
		return true;
	}
}

debug version(unittest) {
	private void* failingAllocFunction(void* p, size_t size) {
		// A size of 0 is a free, which must neither fail nor count.
		if(size != 0 && simulatedFailure()) return null;
		return realAllocFunction(p, size);
	}

	/// Lets the next `n` acquisitions on this thread succeed and makes the one after fail, then lets later ones succeed. Acquisitions are allocations through `fp.pointer` and anything else, such as creating an OS object, that checks `simulatedFailure`. Calling it again before the failure happens replaces the earlier arrangement. It exists only in debug unittest builds.
	///
	/// Examples:
	/// ---
	/// debug {
	/// 	failAfter(1);
	/// 	int* p = fp.pointer.malloc!int(1);
	/// 	assert(p !is null);
	/// 	assert(simulatedFailure());
	/// 	assert(!simulatedFailure());
	/// 	fp.pointer.free(p);
	/// }
	/// ---
	package void failAfter(size_t n) {
		// Re-arming must not save the failing allocator as the real one, or every allocation would recurse forever.
		if(!failureArmed) realAllocFunction = fp.pointer.allocFunction;
		acquisitionsLeft = n;
		failureArmed = true;
		fp.pointer.allocFunction = &failingAllocFunction;
	}
}

debug unittest {
	failAfter(3);
	failAfter(0);
	assert(fp.pointer.malloc!int(1) is null);
	int* p = fp.pointer.malloc!int(1);
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
