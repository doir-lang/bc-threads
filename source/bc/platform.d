/// Platform detection shared by every `bc` module.
module bc.platform;

@nogc nothrow:

/// Whether the target has OS threads, semaphores and locks. Where it does not, pools run jobs inline and `bc.mutex` spins.
version(linux) enum bool threadingSupported = true;
else version(OSX) enum bool threadingSupported = true;
else version(Windows) enum bool threadingSupported = true;
else enum bool threadingSupported = false;

/// Mixed in, declares `version(PthreadBackend)` on Linux and macOS. Version identifiers are module-local, so each module that branches on it mixes this in.
enum string pthreadBackendMixin = q{
	version(linux) version = PthreadBackend;
	else version(OSX) version = PthreadBackend;
};


debug {
	static import fp.pointer;

	private __gshared bool failureArmed;
	private __gshared size_t acquisitionsLeft;
	private __gshared fp.pointer.AllocFunction realAllocFunction;

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

	/// Lets the next `n` acquisitions on this thread succeed and makes the one after fail, then lets later ones succeed. Acquisitions are allocations through `fp.pointer` and OS objects whose creation checks `simulatedFailure`. It exists only in debug unittest builds.
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
		realAllocFunction = fp.pointer.allocFunction;
		acquisitionsLeft = n;
		failureArmed = true;
		fp.pointer.allocFunction = &failingAllocFunction;
	}
}
