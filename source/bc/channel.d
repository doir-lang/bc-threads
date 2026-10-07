/// Go-style channels between threads: a fixed ring buffer, or with `dynamicExtent` an unbounded queue.
module bc.channel;

static import bc.mutex;
static import bc.platform;
static import bc.semaphore;
static import fp.dynarray;
static import fp.pointer;

import core.atomic : atomicOp, atomicLoad, atomicStore;
import std.typecons : Nullable, nullable;

@nogc nothrow:

mixin(bc.platform.pthreadBackendMixin);

/// Passed to `create` as the capacity, makes the channel unbounded, so `send` never waits.
enum size_t dynamicExtent = size_t.max;


static if(bc.platform.threadingSupported) {

	/// A channel of `T` values, used through the pointer `create` returns. Its fields belong to the implementation.
	///
	/// Examples:
	/// ---
	/// Channel!int* ch = create!int(2);
	/// assert(send(ch, 1));
	/// assert(receive(ch).get == 1);
	/// free(ch);
	/// ---
	struct Channel(T) {
		bc.semaphore.Semaphore itemAvailable;
		bc.semaphore.Semaphore spaceAvailable;

		T* buffer = null;
		size_t capacity = 0;
		size_t head = 0;
		size_t count = 0;
		bc.mutex.Mutex* lock;

		shared bool closed = false;

		shared ptrdiff_t sendersWaiting = 0;
		shared ptrdiff_t receiversWaiting = 0;
	}

	private void acquire(T)(Channel!T* ch) @trusted { bc.mutex.writeLock(ch.lock); }
	private void release(T)(Channel!T* ch) @trusted { bc.mutex.writeUnlock(ch.lock); }


	/// The capacity `ch` was created with.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(dynamicExtent);
	/// assert(capacity(ch) == dynamicExtent);
	/// free(ch);
	/// ---
	size_t capacity(T)(const Channel!T* ch) { return ch.capacity; }

	/// How many values `ch` holds.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(4);
	/// assert(send(ch, 1));
	/// assert(length(ch) == 1);
	/// free(ch);
	/// ---
	size_t length(T)(Channel!T* ch) @trusted {
		acquire(ch);
		immutable n = ch.count;
		release(ch);
		return n;
	}

	/// Whether `close` has been called on `ch`.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(1);
	/// close(ch);
	/// assert(isClosed(ch));
	/// free(ch);
	/// ---
	bool isClosed(T)(const Channel!T* ch) @trusted { return atomicLoad(ch.closed); }


	/// Creates an open, empty channel holding up to `capacity` values, which must be above zero, or any number of them with `dynamicExtent`.
	///
	/// Returns null, having freed what it allocated, if allocation or creating its semaphores or lock fails.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(4);
	/// assert(ch !is null);
	/// assert(capacity(ch) == 4);
	/// free(ch);
	/// ---
	Channel!T* create(T)(size_t capacity) @trusted {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		if(ch is null) return null;
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent) {
			ch.buffer = fp.dynarray.create!T(capacity);
			if(ch.buffer is null) {
				fp.pointer.free(ch);
				return null;
			}
		}

		// Both counts start at zero: every waiter rechecks the buffer under the lock, so a semaphore only needs to wake it.
		auto itemAvailable = bc.semaphore.create();
		if(itemAvailable.isNull) {
			fp.dynarray.free(ch.buffer);
			fp.pointer.free(ch);
			return null;
		}
		auto spaceAvailable = bc.semaphore.create();
		if(spaceAvailable.isNull) {
			bc.semaphore.free(itemAvailable.get);
			fp.dynarray.free(ch.buffer);
			fp.pointer.free(ch);
			return null;
		}
		ch.lock = bc.mutex.create();
		if(ch.lock is null) {
			bc.semaphore.free(spaceAvailable.get);
			bc.semaphore.free(itemAvailable.get);
			fp.dynarray.free(ch.buffer);
			fp.pointer.free(ch);
			return null;
		}
		ch.itemAvailable = itemAvailable.get;
		ch.spaceAvailable = spaceAvailable.get;
		return ch;
	}


	/// Appends `value` to `ch`, first waiting for room if `ch` is full. Without threads, `ch` never fills, so `send` never waits.
	///
	/// Returns false, leaving `ch` unchanged, if `ch` is closed before `value` fits, or if `ch` is unbounded and its buffer cannot grow.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(1);
	/// assert(send(ch, 1));
	/// close(ch);
	/// assert(!send(ch, 2));
	/// free(ch);
	/// ---
	bool send(T)(Channel!T* ch, T value) @trusted {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(atomicLoad(ch.closed)) { release(ch); return false; }
			if(dynamic || ch.count < ch.capacity) {
				if(dynamic) {
					if(!fp.dynarray.pushBack(ch.buffer, value)) {
						release(ch);
						return false;
					}
				} else ch.buffer[(ch.head + ch.count) % ch.capacity] = value;
				ch.count++;
				release(ch);
				bc.semaphore.post(ch.itemAvailable);
				return true;
			}
			atomicOp!"+="(ch.sendersWaiting, cast(ptrdiff_t) 1);
			release(ch);
			bc.semaphore.wait(ch.spaceAvailable);
			atomicOp!"-="(ch.sendersWaiting, cast(ptrdiff_t) 1);
		}
	}

	/// Removes and returns the oldest value in `ch`, first waiting for one if `ch` is empty.
	///
	/// Returns an empty `Nullable` once `ch` is closed and empty. Without threads, nothing could fill an empty `ch`, so it does so whenever `ch` is empty.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(2);
	/// assert(send(ch, 7));
	/// close(ch);
	/// assert(receive(ch).get == 7);
	/// assert(receive(ch).isNull);
	/// free(ch);
	/// ---
	Nullable!T receive(T)(Channel!T* ch) @trusted {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(ch.count > 0) {
				T value;
				if(dynamic) {
					value = *fp.dynarray.front(ch.buffer);
					cast(void) fp.dynarray.removeAt(ch.buffer, 0);
				} else {
					value = ch.buffer[ch.head];
					ch.head = (ch.head + 1) % ch.capacity;
				}
				ch.count--;
				release(ch);
				if(!dynamic) bc.semaphore.post(ch.spaceAvailable);
				return nullable(value);
			}
			if(atomicLoad(ch.closed)) { release(ch); return Nullable!T.init; }
			atomicOp!"+="(ch.receiversWaiting, cast(ptrdiff_t) 1);
			release(ch);
			bc.semaphore.wait(ch.itemAvailable);
			atomicOp!"-="(ch.receiversWaiting, cast(ptrdiff_t) 1);
		}
	}


	/// Closes `ch`: later sends fail, and threads waiting in `send` or `receive` on it wake. Values already in `ch` can still be received.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(1);
	/// close(ch);
	/// assert(!send(ch, 1));
	/// free(ch);
	/// ---
	void close(T)(Channel!T* ch) @trusted {
		acquire(ch);
		atomicStore(ch.closed, true);
		immutable senders = atomicLoad(ch.sendersWaiting);
		immutable receivers = atomicLoad(ch.receiversWaiting);
		release(ch);
		foreach(_; 0 .. senders) bc.semaphore.post(ch.spaceAvailable);
		foreach(_; 0 .. receivers) bc.semaphore.post(ch.itemAvailable);
	}

	/// Closes and frees `ch`, which no thread may still be using; does nothing if `ch` is null.
	///
	/// Examples:
	/// ---
	/// auto ch = create!int(1);
	/// free(ch);
	/// free!int(null);
	/// ---
	void free(T)(Channel!T* ch) @trusted {
		if(ch is null) return;
		if(!isClosed(ch)) close(ch);
		bc.semaphore.free(ch.itemAvailable);
		bc.semaphore.free(ch.spaceAvailable);
		bc.mutex.free(ch.lock);
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}

} else {

	// Without threads nothing could fill an empty channel or drain a full one, so every capacity behaves as `dynamicExtent`.
	struct Channel(T) {
		T* buffer = null;
		size_t capacity = 0;
		bool closed = false;
	}


	size_t capacity(T)(const Channel!T* ch) { return ch.capacity; }
	size_t length(T)(Channel!T* ch) @trusted { return fp.dynarray.length(ch.buffer); }
	bool isClosed(T)(const Channel!T* ch) { return ch.closed; }


	Channel!T* create(T)(size_t capacity) @trusted {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		if(ch is null) return null;
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent && fp.dynarray.reserve(ch.buffer, capacity) is null) {
			fp.pointer.free(ch);
			return null;
		}
		return ch;
	}


	bool send(T)(Channel!T* ch, T value) @trusted {
		if(ch.closed) return false;
		return fp.dynarray.pushBack(ch.buffer, value);
	}

	Nullable!T receive(T)(Channel!T* ch) @trusted {
		if(fp.dynarray.length(ch.buffer) == 0) return Nullable!T.init;
		T value = *fp.dynarray.front(ch.buffer);
		cast(void) fp.dynarray.removeAt(ch.buffer, 0);
		return nullable(value);
	}


	void close(T)(Channel!T* ch) { ch.closed = true; }

	void free(T)(Channel!T* ch) @trusted {
		if(ch is null) return;
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}
}


unittest {
	// Acquisitions go channel, buffer, then with threads both semaphores and the lock (and with pthreads its rwlock), so these fail each in turn.
	static if(!bc.platform.threadingSupported) enum acquisitions = 2;
	else version(PthreadBackend) enum acquisitions = 6;
	else enum acquisitions = 5;
	debug foreach(i; 0 .. acquisitions) {
		bc.platform.failAfter(i);
		assert(create!int(1) is null);
	}
	free!int(null);

	auto queue = create!int(dynamicExtent);
	assert(queue !is null);
	scope(exit) free(queue);
	assert(capacity(queue) == dynamicExtent);
	debug {
		bc.platform.failAfter(0);
		assert(!send(queue, 1));
		assert(length(queue) == 0);
	}
	assert(send(queue, 1) && send(queue, 2));
	close(queue);
	assert(isClosed(queue) && !send(queue, 3));
	assert(receive(queue).get == 1 && receive(queue).get == 2);
	assert(receive(queue).isNull);

	static if(bc.platform.threadingSupported) {
		static import bc.thread;

		static void sendTwo(Channel!int* ch, bool* ok) @nogc nothrow { *ok = send(ch, 2); }
		static void receiveOne(Channel!int* ch, bool* ok) @nogc nothrow { *ok = !receive(ch).isNull; }

		auto ch = create!int(1);
		assert(ch !is null);
		scope(exit) free(ch);
		assert(send(ch, 1));

		// The sender waits on the full channel until a receive makes room; the receiver waits on the empty one until `close` wakes it.
		bool sent = false, received = true;
		auto t = bc.thread.create(&sendTwo, ch, &sent);
		assert(!t.isNull);
		while(atomicLoad(ch.sendersWaiting) == 0) {}
		assert(receive(ch).get == 1);
		bc.thread.join(t.get);
		assert(sent && receive(ch).get == 2);

		t = bc.thread.create(&receiveOne, ch, &received);
		assert(!t.isNull);
		while(atomicLoad(ch.receiversWaiting) == 0) {}
		close(ch);
		bc.thread.join(t.get);
		assert(!received);
	}
}
