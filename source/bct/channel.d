/// A minimal, Go-style bounded blocking channel for passing values of type
/// `T` between threads - the natural counterpart to `bct.threadpool`'s
/// worker pool when jobs need to hand results(or further work) back rather
/// than just mutate shared memory through a pointer. Backed by the same
/// primitives as the pool: POSIX semaphores + an unnamed spinlock on Linux,
/// Win32 semaphore objects on Windows, and a plain, non-blocking ring
/// buffer on any other platform, since there's nothing else running
/// concurrently there to ever unblock a wait.
///
/// `send` blocks while the channel is full; `receive` blocks while it's
/// empty. `close` wakes every `send`/`receive` currently blocked on the
/// channel: a `receive` on a closed channel keeps draining whatever's still
/// buffered(returning a non-null value) until it's empty, then returns
/// `Nullable!T.init` - the same `v, ok := <-ch` contract Go gives you, just
/// spelled as a `Nullable!T` instead of a tuple, so `if(auto v =
/// ch.receive())` scopes the received value to just the branch that got one.
/// `send` on a closed channel always fails immediately(`false`) instead of
/// blocking, since nothing will ever come along to unblock it. Unlike Go,
/// there's no unbuffered(capacity 0) mode - `create()` requires at least
/// one slot, unless that slot count is `dynamicExtent`: pass that as the
/// capacity for an unbounded channel whose `send` never blocks - it just
/// grows the backing store instead, the same tradeoff `bct.threadpool`
/// makes for its own job queue. Only `receive` still blocks then, while the
/// channel is empty. Every platform without a thread backend already behaves
/// this way unconditionally(see below), since nothing else runs there to
/// make blocking on a full buffer meaningful in the first place.
module bct.channel;

import fp.dynarray;
import fp.pointer;
import core.atomic : atomicOp, atomicLoad, atomicStore, cas;
import std.typecons : Nullable, nullable;

@nogc nothrow:

version(linux) {
	import core.sys.posix.semaphore : sem_t, sem_init, sem_wait, sem_post, sem_destroy;
	enum bool threadingSupported = true;
} else version(Windows) {
	import core.sys.windows.windows : HANDLE, CreateSemaphoreA, ReleaseSemaphore, WaitForSingleObject, CloseHandle, INFINITE;
	enum bool threadingSupported = true;
} else {
	enum bool threadingSupported = false;
}

/// Pass this to `Channel.create()` for an unbounded channel - see the
/// module doc comment.
enum size_t dynamicExtent = size_t.max;


static if(threadingSupported) {

	version(linux) {
		private void semInit(ref sem_t s) @trusted @nogc nothrow { sem_init(&s, 0, 0); }
		private void semWait(ref sem_t s) @trusted @nogc nothrow { sem_wait(&s); }
		private void semPost(ref sem_t s) @trusted @nogc nothrow { sem_post(&s); }
		private void semDestroy(ref sem_t s) @trusted @nogc nothrow { sem_destroy(&s); }
	} else version(Windows) {
		private void semInit(ref HANDLE h) @trusted @nogc nothrow { h = CreateSemaphoreA(null, 0, int.max, null); }
		private void semWait(ref HANDLE h) @trusted @nogc nothrow { WaitForSingleObject(h, INFINITE); }
		private void semPost(ref HANDLE h) @trusted @nogc nothrow { ReleaseSemaphore(h, 1, null); }
		private void semDestroy(ref HANDLE h) @trusted @nogc nothrow { CloseHandle(h); }
	}

	/// Ring buffer(or, when `capacity == dynamicExtent`, a plain growable
	/// `fp.dynarray`) + synchronization shared by every `send`/`receive` on
	/// a channel. The state itself is one fixed instance, not a growable
	/// array, so it's heap allocated with `fp.pointer.malloc` rather than
	/// `fp.dynarray` (like `ThreadPool`'s `PoolState`) - its address stays
	/// stable across copies of the `Channel` handle either way.
	private struct ChannelState(T) {
		version(linux) sem_t itemAvailable;
		else version(Windows) HANDLE itemAvailable;

		version(linux) sem_t spaceAvailable;
		else version(Windows) HANDLE spaceAvailable;

		// Fixed capacity: a `capacity`-slot ring buffer, `head`/`count`
		// indexing modulo `capacity`. Dynamic extent: `head` stays 0 and
		// unused - values are appended with `pushBack` and removed from the
		// front with `removeAt(..., 0)` instead, same as the no-threading
		// fallback below. Either way, guarded entirely by `lock` - same
		// convention as `PoolState.queue`/`queueLock`.
		T* buffer = null;
		size_t capacity = 0;
		size_t head = 0;
		size_t count = 0;
		shared uint lock = 0;

		shared bool closed = false;

		// How many `send`/`receive` calls are parked on `spaceAvailable` /
		// `itemAvailable` right now, incremented under `lock` right before
		// releasing it to wait. `close()` reads these(also under `lock`) and
		// posts exactly that many times, which is always enough: any call
		// that observes `closed == false` under the lock - and so decides to
		// register and wait - does so strictly before `close()`'s own
		// critical section(the lock serializes the two), so `close()` is
		// guaranteed to see it. Nothing registers afterwards, since every
		// call made once `closed` is visibly `true` short-circuits under the
		// same lock instead of waiting.
		shared ptrdiff_t sendersWaiting = 0;
		shared ptrdiff_t receiversWaiting = 0;
	}

	private void acquire(T)(ChannelState!T* state) @trusted @nogc nothrow {
		while(!cas(&state.lock, cast(uint) 0, cast(uint) 1)) {}
	}
	private void release(T)(ChannelState!T* state) @trusted @nogc nothrow {
		atomicStore(state.lock, cast(uint) 0);
	}

	/// An MPMC blocking channel, fixed-capacity or(with `dynamicExtent`)
	/// unbounded. Non-copyable(like `ThreadPool`) - destructing the last
	/// handle's owner should call `free()` to release the semaphores and
	/// backing buffer.
	struct Channel(T) {
		private ChannelState!T* state = null;

		/// `capacity` must be at least 1, or `dynamicExtent` for an
		/// unbounded channel - see the module doc comment.
		static Channel!T create(size_t capacity) @trusted @nogc nothrow {
			assert(capacity > 0);
			Channel!T ch;
			ch.state = fp.pointer.malloc!(ChannelState!T)(1);
			*ch.state = ChannelState!T.init;
			ch.state.capacity = capacity;
			if(capacity != dynamicExtent)
				ch.state.buffer = fp.dynarray.create!(T)(capacity);
			semInit(ch.state.itemAvailable);
			semInit(ch.state.spaceAvailable);
			return ch;
		}

		@disable this(this);

		size_t capacity() const @nogc nothrow { return state.capacity; }

		/// Number of values currently buffered.
		size_t length() @trusted @nogc nothrow {
			acquire(state);
			immutable n = state.count;
			release(state);
			return n;
		}

		bool isClosed() const @trusted @nogc nothrow { return atomicLoad(state.closed); }

		/// Blocks while the channel is full - never, when `capacity ==
		/// dynamicExtent`, since there's no ring buffer to fill: it just
		/// grows instead. Returns `false` instead of sending if the channel
		/// is(or becomes, while blocked) closed - see
		/// `ChannelState.sendersWaiting` for why a blocked call is always
		/// woken by a matching `close()`.
		bool send(T value) @trusted @nogc nothrow {
			immutable dynamic = state.capacity == dynamicExtent;
			while(true) {
				acquire(state);
				if(atomicLoad(state.closed)) { release(state); return false; }
				if(dynamic) {
					fp.dynarray.pushBack(state.buffer, value);
					state.count++;
					release(state);
					semPost(state.itemAvailable);
					return true;
				}
				if(state.count < state.capacity) {
					state.buffer[(state.head + state.count) % state.capacity] = value;
					state.count++;
					release(state);
					semPost(state.itemAvailable);
					return true;
				}
				atomicOp!"+="(state.sendersWaiting, cast(ptrdiff_t) 1);
				release(state);
				semWait(state.spaceAvailable);
				atomicOp!"-="(state.sendersWaiting, cast(ptrdiff_t) 1);
			}
		}

		/// Blocks while the channel is empty and open. Returns the next value
		/// once something's available - buffered values included, even
		/// after `close()` - or `Nullable!T.init` once the channel is closed
		/// and fully drained, mirroring Go's `v, ok := <-ch`.
		Nullable!T receive() @trusted @nogc nothrow {
			immutable dynamic = state.capacity == dynamicExtent;
			while(true) {
				acquire(state);
				if(state.count > 0) {
					T value;
					if(dynamic) {
						value = *fp.dynarray.front(state.buffer);
						fp.dynarray.removeAt(state.buffer, 0);
					} else {
						value = state.buffer[state.head];
						state.head =(state.head + 1) % state.capacity;
					}
					state.count--;
					release(state);
					// Nobody ever blocks on `spaceAvailable` in dynamic
					// mode - `send` never waits there - so posting it would
					// just accumulate unconsumed permits forever.
					if(!dynamic) semPost(state.spaceAvailable);
					return nullable(value);
				}
				if(atomicLoad(state.closed)) { release(state); return Nullable!T.init; }
				atomicOp!"+="(state.receiversWaiting, cast(ptrdiff_t) 1);
				release(state);
				semWait(state.itemAvailable);
				atomicOp!"-="(state.receiversWaiting, cast(ptrdiff_t) 1);
			}
		}

		/// Marks the channel closed and wakes every `send`/`receive`
		/// currently blocked on it. Closing an already-closed channel is
		/// undefined(matches Go).
		void close() @trusted @nogc nothrow {
			acquire(state);
			atomicStore(state.closed, true);
			immutable senders = atomicLoad(state.sendersWaiting);
			immutable receivers = atomicLoad(state.receiversWaiting);
			release(state);
			foreach(_; 0 .. senders) semPost(state.spaceAvailable);
			foreach(_; 0 .. receivers) semPost(state.itemAvailable);
		}

		void free() @trusted @nogc nothrow {
			if(state is null) return;
			if(!isClosed()) close();
			semDestroy(state.itemAvailable);
			semDestroy(state.spaceAvailable);
			fp.dynarray.free(state.buffer);
			fp.pointer.free(state);
		}
	}

} else {

	/// Degenerate fallback for platforms without a real thread backend:
	/// there's nothing else running concurrently to ever fill an empty
	/// channel or drain a full one, so `send`/`receive` never block - they
	/// just report failure instead. Amounts to `dynamicExtent` behavior
	/// unconditionally, regardless of what `capacity` was requested.
	private struct ChannelState(T) {
		T* buffer = null;
		size_t capacity = 0;
		bool closed = false;
	}

	struct Channel(T) {
		private ChannelState!T* state = null;

		static Channel!T create(size_t capacity) @trusted @nogc nothrow {
			assert(capacity > 0);
			Channel!T ch;
			ch.state = fp.pointer.malloc!(ChannelState!T)(1);
			*ch.state = ChannelState!T.init;
			ch.state.capacity = capacity;
			// `capacity` is only ever a reservation hint here - `send`
			// grows the buffer regardless - so a literal `dynamicExtent`
			//(`size_t.max`) reservation must be skipped rather than
			// attempted.
			if(capacity != dynamicExtent)
				fp.dynarray.reserve(ch.state.buffer, capacity);
			return ch;
		}

		@disable this(this);

		size_t capacity() const @nogc nothrow { return state.capacity; }
		size_t length() @trusted @nogc nothrow { return fp.dynarray.length(state.buffer); }
		bool isClosed() const @trusted @nogc nothrow { return state.closed; }

		/// Grows the buffer instead of blocking - see the module doc comment.
		bool send(T value) @trusted @nogc nothrow {
			if(state.closed) return false;
			fp.dynarray.pushBack(state.buffer, value);
			return true;
		}

		/// Reports an empty channel the same whether or not it's closed,
		/// rather than blocking forever waiting for a value that nothing is
		/// ever going to send.
		Nullable!T receive() @trusted @nogc nothrow {
			if(fp.dynarray.length(state.buffer) == 0) return Nullable!T.init;
			T value = *fp.dynarray.front(state.buffer);
			fp.dynarray.removeAt(state.buffer, 0);
			return nullable(value);
		}

		void close() @trusted @nogc nothrow { state.closed = true; }

		void free() @trusted @nogc nothrow {
			if(state is null) return;
			fp.dynarray.free(state.buffer);
			fp.pointer.free(state);
		}
	}
}


unittest {
	// Single-threaded FIFO ordering, `length`/`capacity`, and the
	// buffered-values-survive-close contract: `receive` keeps draining
	// whatever's already buffered after `close`, only reporting `false`
	// once that's exhausted.
	auto ch = Channel!int.create(4);
	scope(exit) ch.free();

	assert(ch.capacity() == 4);
	assert(ch.length() == 0);
	assert(!ch.isClosed());

	foreach(i; 0 .. 3) assert(ch.send(i));
	assert(ch.length() == 3);

	ch.close();
	assert(ch.isClosed());
	assert(!ch.send(99)); // closed: no new sends, even though there's room

	foreach(i; 0 .. 3) {
		auto v = ch.receive();
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(ch.receive().isNull); // drained and closed
}


unittest {
	// `dynamicExtent`: `send` always succeeds - no ring buffer to fill, no
	// blocking - and `capacity()` reports the sentinel back unchanged.
	// `receive` still preserves FIFO order and the drain-then-null-on-close
	// contract exactly as the fixed-capacity case does.
	auto ch = Channel!int.create(dynamicExtent);
	scope(exit) ch.free();

	assert(ch.capacity() == dynamicExtent);
	assert(ch.length() == 0);

	enum n = 500; // far more than any reasonable fixed ring buffer
	foreach(i; 0 .. n) assert(ch.send(i));
	assert(ch.length() == n);

	ch.close();
	assert(!ch.send(99)); // closed: still no new sends

	foreach(i; 0 .. n) {
		auto v = ch.receive();
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(ch.receive().isNull); // drained and closed
}


unittest {
	// Exercises real cross-thread blocking: a single-slot channel forces the
	// producer to block on `send` until the consumer's `receive` catches up,
	// and vice versa - the pool's worker threads stand in for independent
	// goroutines here.
	import bct.threadpool : ThreadPool, Job;

	auto pool = ThreadPool.create(2);
	scope(exit) pool.free();

	auto ch = Channel!int.create(1);
	scope(exit) ch.free();

	static struct ProducerArg { Channel!int* ch; int count; }
	static void produce(void* arg) @nogc nothrow {
		auto a = cast(ProducerArg*) arg;
		foreach(i; 0 .. a.count) a.ch.send(i);
		a.ch.close();
	}

	static struct ConsumerArg { Channel!int* ch; int sum; int received; }
	static void consume(void* arg) @nogc nothrow {
		auto a = cast(ConsumerArg*) arg;
		while(auto v = a.ch.receive()) { a.sum += v.get(); a.received++; }
	}

	enum n = 50;
	auto producerArg = ProducerArg(&ch, n);
	auto consumerArg = ConsumerArg(&ch, 0, 0);

	Job[2] jobs = [Job(&produce, &producerArg), Job(&consume, &consumerArg)];
	pool.run(jobs[]);

	assert(consumerArg.received == n);
	int expectedSum = 0;
	foreach(i; 0 .. n) expectedSum += i;
	assert(consumerArg.sum == expectedSum);
}


unittest {
	// `close` must wake a `receive` that's already blocked on an empty
	// channel, not just ones that show up afterwards.
	import bct.threadpool : ThreadPool, Job;

	auto pool = ThreadPool.create(2);
	scope(exit) pool.free();

	auto ch = Channel!int.create(1);
	scope(exit) ch.free();

	static struct Result { Channel!int* ch; bool ok; }
	static void receiveOnce(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		r.ok = !r.ch.receive().isNull;
	}

	Result result = Result(&ch, true);
	Job[1] jobs = [Job(&receiveOnce, &result)];
	pool.submit(jobs[]); // receiver blocks: nothing's been sent

	ch.close();
	pool.wait();

	assert(!result.ok);
}


unittest {
	// Symmetric case: `close` must also wake a `send` blocked on a full
	// channel, since nothing is ever going to `receive` to make room again.
	import bct.threadpool : ThreadPool, Job;

	auto pool = ThreadPool.create(2);
	scope(exit) pool.free();

	auto ch = Channel!int.create(1);
	scope(exit) ch.free();

	static struct Result { Channel!int* ch; bool ok; }
	static void sendTwice(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		r.ch.send(1);          // fills the one slot, doesn't block
		r.ok = r.ch.send(2);   // blocks: no room, no receiver
	}

	Result result = Result(&ch, true);
	Job[1] jobs = [Job(&sendTwice, &result)];
	pool.submit(jobs[]);

	ch.close();
	pool.wait();

	assert(!result.ok);
}
