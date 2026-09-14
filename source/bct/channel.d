/// A minimal, Go-style bounded blocking channel for passing values of type
/// `T` between threads - the natural counterpart to `bct.threadpool`'s
/// worker pool when jobs need to hand results(or further work) back rather
/// than just mutate shared memory through a pointer. Backed by the same
/// primitives as the pool: POSIX semaphores + an unnamed spinlock on Linux,
/// Win32 semaphore objects on Windows, and a plain, non-blocking ring
/// buffer on any other platform, since there's nothing else running
/// concurrently there to ever unblock a wait.
///
/// `Channel!T` is a plain heap-allocated struct (see `create`); every
/// operation on it is a free function taking the `Channel!T*` returned by
/// `create()` as its first argument - `bct.threadpool`'s convention,
/// carried over from `fp.dynarray`.
///
/// `send` blocks while the channel is full; `receive` blocks while it's
/// empty. `close` wakes every `send`/`receive` currently blocked on the
/// channel: a `receive` on a closed channel keeps draining whatever's still
/// buffered(returning a non-null value) until it's empty, then returns
/// `Nullable!T.init` - the same `v, ok := <-ch` contract Go gives you, just
/// spelled as a `Nullable!T` instead of a tuple, so `if(auto v =
/// receive(ch))` scopes the received value to just the branch that got one.
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

/// Pass this to `create()` for an unbounded channel - see the module doc
/// comment.
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

	/// An MPMC blocking channel, fixed-capacity or(with `dynamicExtent`)
	/// unbounded. Heap allocated by `create()` (with `fp.pointer.malloc`, a
	/// single fixed instance rather than a growable array) so its address
	/// stays stable across every handle to it. Backed by a ring
	/// buffer(or, when `capacity == dynamicExtent`, a plain growable
	/// `fp.dynarray`), guarded entirely by `lock` - same convention as
	/// `bct.threadpool.ThreadPool.queueLock`. Fixed capacity: a
	/// `capacity`-slot ring buffer, `head`/`count` indexing modulo
	/// `capacity`. Dynamic extent: `head` stays 0 and unused - values are
	/// appended with `pushBack` and removed from the front with
	/// `removeAt(..., 0)` instead, same as the no-threading fallback below.
	struct Channel(T) {
		version(linux) sem_t itemAvailable;
		else version(Windows) HANDLE itemAvailable;

		version(linux) sem_t spaceAvailable;
		else version(Windows) HANDLE spaceAvailable;

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

	private void acquire(T)(Channel!T* ch) @trusted @nogc nothrow {
		while(!cas(&ch.lock, cast(uint) 0, cast(uint) 1)) {}
	}
	private void release(T)(Channel!T* ch) @trusted @nogc nothrow {
		atomicStore(ch.lock, cast(uint) 0);
	}

	/// `capacity` must be at least 1, or `dynamicExtent` for an
	/// unbounded channel - see the module doc comment.
	Channel!T* create(T)(size_t capacity) @trusted @nogc nothrow {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		*ch = Channel!T.init;
		ch.capacity = capacity;
		if(capacity != dynamicExtent)
			ch.buffer = fp.dynarray.create!(T)(capacity);
		semInit(ch.itemAvailable);
		semInit(ch.spaceAvailable);
		return ch;
	}

	size_t capacity(T)(const Channel!T* ch) @nogc nothrow { return ch.capacity; }

	/// Number of values currently buffered.
	size_t length(T)(Channel!T* ch) @trusted @nogc nothrow {
		acquire(ch);
		immutable n = ch.count;
		release(ch);
		return n;
	}

	bool isClosed(T)(const Channel!T* ch) @trusted @nogc nothrow { return atomicLoad(ch.closed); }

	/// Blocks while the channel is full - never, when `capacity ==
	/// dynamicExtent`, since there's no ring buffer to fill: it just
	/// grows instead. Returns `false` instead of sending if the channel
	/// is(or becomes, while blocked) closed - see `Channel.sendersWaiting`
	/// for why a blocked call is always woken by a matching `close()`.
	bool send(T)(Channel!T* ch, T value) @trusted @nogc nothrow {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(atomicLoad(ch.closed)) { release(ch); return false; }
			if(dynamic) {
				fp.dynarray.pushBack(ch.buffer, value);
				ch.count++;
				release(ch);
				semPost(ch.itemAvailable);
				return true;
			}
			if(ch.count < ch.capacity) {
				ch.buffer[(ch.head + ch.count) % ch.capacity] = value;
				ch.count++;
				release(ch);
				semPost(ch.itemAvailable);
				return true;
			}
			atomicOp!"+="(ch.sendersWaiting, cast(ptrdiff_t) 1);
			release(ch);
			semWait(ch.spaceAvailable);
			atomicOp!"-="(ch.sendersWaiting, cast(ptrdiff_t) 1);
		}
	}

	/// Blocks while the channel is empty and open. Returns the next value
	/// once something's available - buffered values included, even
	/// after `close()` - or `Nullable!T.init` once the channel is closed
	/// and fully drained, mirroring Go's `v, ok := <-ch`.
	Nullable!T receive(T)(Channel!T* ch) @trusted @nogc nothrow {
		immutable dynamic = ch.capacity == dynamicExtent;
		while(true) {
			acquire(ch);
			if(ch.count > 0) {
				T value;
				if(dynamic) {
					value = *fp.dynarray.front(ch.buffer);
					fp.dynarray.removeAt(ch.buffer, 0);
				} else {
					value = ch.buffer[ch.head];
					ch.head =(ch.head + 1) % ch.capacity;
				}
				ch.count--;
				release(ch);
				// Nobody ever blocks on `spaceAvailable` in dynamic
				// mode - `send` never waits there - so posting it would
				// just accumulate unconsumed permits forever.
				if(!dynamic) semPost(ch.spaceAvailable);
				return nullable(value);
			}
			if(atomicLoad(ch.closed)) { release(ch); return Nullable!T.init; }
			atomicOp!"+="(ch.receiversWaiting, cast(ptrdiff_t) 1);
			release(ch);
			semWait(ch.itemAvailable);
			atomicOp!"-="(ch.receiversWaiting, cast(ptrdiff_t) 1);
		}
	}

	/// Marks the channel closed and wakes every `send`/`receive`
	/// currently blocked on it. Closing an already-closed channel is
	/// undefined(matches Go).
	void close(T)(Channel!T* ch) @trusted @nogc nothrow {
		acquire(ch);
		atomicStore(ch.closed, true);
		immutable senders = atomicLoad(ch.sendersWaiting);
		immutable receivers = atomicLoad(ch.receiversWaiting);
		release(ch);
		foreach(_; 0 .. senders) semPost(ch.spaceAvailable);
		foreach(_; 0 .. receivers) semPost(ch.itemAvailable);
	}

	void free(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(ch is null) return;
		if(!isClosed(ch)) close(ch);
		semDestroy(ch.itemAvailable);
		semDestroy(ch.spaceAvailable);
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}

} else {

	/// Degenerate fallback for platforms without a real thread backend:
	/// there's nothing else running concurrently to ever fill an empty
	/// channel or drain a full one, so `send`/`receive` never block - they
	/// just report failure instead. Amounts to `dynamicExtent` behavior
	/// unconditionally, regardless of what `capacity` was requested.
	struct Channel(T) {
		T* buffer = null;
		size_t capacity = 0;
		bool closed = false;
	}

	Channel!T* create(T)(size_t capacity) @trusted @nogc nothrow {
		assert(capacity > 0);
		auto ch = fp.pointer.malloc!(Channel!T)(1);
		*ch = Channel!T.init;
		ch.capacity = capacity;
		// `capacity` is only ever a reservation hint here - `send`
		// grows the buffer regardless - so a literal `dynamicExtent`
		//(`size_t.max`) reservation must be skipped rather than
		// attempted.
		if(capacity != dynamicExtent)
			fp.dynarray.reserve(ch.buffer, capacity);
		return ch;
	}

	size_t capacity(T)(const Channel!T* ch) @nogc nothrow { return ch.capacity; }
	size_t length(T)(Channel!T* ch) @trusted @nogc nothrow { return fp.dynarray.length(ch.buffer); }
	bool isClosed(T)(const Channel!T* ch) @nogc nothrow { return ch.closed; }

	/// Grows the buffer instead of blocking - see the module doc comment.
	bool send(T)(Channel!T* ch, T value) @trusted @nogc nothrow {
		if(ch.closed) return false;
		fp.dynarray.pushBack(ch.buffer, value);
		return true;
	}

	/// Reports an empty channel the same whether or not it's closed,
	/// rather than blocking forever waiting for a value that nothing is
	/// ever going to send.
	Nullable!T receive(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(fp.dynarray.length(ch.buffer) == 0) return Nullable!T.init;
		T value = *fp.dynarray.front(ch.buffer);
		fp.dynarray.removeAt(ch.buffer, 0);
		return nullable(value);
	}

	void close(T)(Channel!T* ch) @nogc nothrow { ch.closed = true; }

	void free(T)(Channel!T* ch) @trusted @nogc nothrow {
		if(ch is null) return;
		fp.dynarray.free(ch.buffer);
		fp.pointer.free(ch);
	}
}


unittest {
	// Single-threaded FIFO ordering, `length`/`capacity`, and the
	// buffered-values-survive-close contract: `receive` keeps draining
	// whatever's already buffered after `close`, only reporting `false`
	// once that's exhausted.
	auto ch = create!int(4);
	scope(exit) free(ch);

	assert(capacity(ch) == 4);
	assert(length(ch) == 0);
	assert(!isClosed(ch));

	foreach(i; 0 .. 3) assert(send(ch, i));
	assert(length(ch) == 3);

	close(ch);
	assert(isClosed(ch));
	assert(!send(ch, 99)); // closed: no new sends, even though there's room

	foreach(i; 0 .. 3) {
		auto v = receive(ch);
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(receive(ch).isNull); // drained and closed
}


unittest {
	// `dynamicExtent`: `send` always succeeds - no ring buffer to fill, no
	// blocking - and `capacity()` reports the sentinel back unchanged.
	// `receive` still preserves FIFO order and the drain-then-null-on-close
	// contract exactly as the fixed-capacity case does.
	auto ch = create!int(dynamicExtent);
	scope(exit) free(ch);

	assert(capacity(ch) == dynamicExtent);
	assert(length(ch) == 0);

	enum n = 500; // far more than any reasonable fixed ring buffer
	foreach(i; 0 .. n) assert(send(ch, i));
	assert(length(ch) == n);

	close(ch);
	assert(!send(ch, 99)); // closed: still no new sends

	foreach(i; 0 .. n) {
		auto v = receive(ch);
		assert(!v.isNull);
		assert(v.get() == i);
	}
	assert(receive(ch).isNull); // drained and closed
}


unittest {
	// Exercises real cross-thread blocking: a single-slot channel forces the
	// producer to block on `send` until the consumer's `receive` catches up,
	// and vice versa - the pool's worker threads stand in for independent
	// goroutines here.
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct ProducerArg { Channel!int* ch; int count; }
	static void produce(void* arg) @nogc nothrow {
		auto a = cast(ProducerArg*) arg;
		foreach(i; 0 .. a.count) send(a.ch, i);
		close(a.ch);
	}

	static struct ConsumerArg { Channel!int* ch; int sum; int received; }
	static void consume(void* arg) @nogc nothrow {
		auto a = cast(ConsumerArg*) arg;
		while(auto v = receive(a.ch)) { a.sum += v.get(); a.received++; }
	}

	enum n = 50;
	auto producerArg = ProducerArg(ch, n);
	auto consumerArg = ConsumerArg(ch, 0, 0);

	bct.threadpool.Job[2] jobs = [bct.threadpool.Job(&produce, &producerArg), bct.threadpool.Job(&consume, &consumerArg)];
	pool.run(jobs[]);

	assert(consumerArg.received == n);
	int expectedSum = 0;
	foreach(i; 0 .. n) expectedSum += i;
	assert(consumerArg.sum == expectedSum);
}


unittest {
	// `close` must wake a `receive` that's already blocked on an empty
	// channel, not just ones that show up afterwards.
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct Result { Channel!int* ch; bool ok; }
	static void receiveOnce(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		r.ok = !receive(r.ch).isNull;
	}

	Result result = Result(ch, true);
	bct.threadpool.Job[1] jobs = [bct.threadpool.Job(&receiveOnce, &result)];
	pool.submit(jobs[]); // receiver blocks: nothing's been sent

	close(ch);
	pool.wait();

	assert(!result.ok);
}


unittest {
	// Symmetric case: `close` must also wake a `send` blocked on a full
	// channel, since nothing is ever going to `receive` to make room again.
	import bct.threadpool;

	auto pool = bct.threadpool.create(2);
	scope(exit) bct.threadpool.free(pool);

	auto ch = create!int(1);
	scope(exit) free(ch);

	static struct Result { Channel!int* ch; bool ok; }
	static void sendTwice(void* arg) @nogc nothrow {
		auto r = cast(Result*) arg;
		send(r.ch, 1);          // fills the one slot, doesn't block
		r.ok = send(r.ch, 2);   // blocks: no room, no receiver
	}

	Result result = Result(ch, true);
	bct.threadpool.Job[1] jobs = [bct.threadpool.Job(&sendTwice, &result)];
	pool.submit(jobs[]);

	close(ch);
	pool.wait();

	assert(!result.ok);
}
