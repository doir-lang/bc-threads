# bc-threads

A minimal, `-betterC`-compatible fork-join thread pool for D (module `bc.threadpool`).
Backed by POSIX threads + unnamed semaphores on Linux, POSIX threads + Mach semaphores on macOS (unnamed POSIX semaphores are declared there but never implemented - `sem_init` always fails with `ENOSYS`), Win32 threads + semaphore objects on Windows, or wasi-libc's POSIX threads + unnamed semaphores on WASI built with atomics; any other platform gets a degenerate single-"worker" pool that runs jobs inline.
See the DDoc on `submit`, `wait` and `run` in [source/bc/threadpool.d](source/bc/threadpool.d) for forking work from inside a job, and why a job must never wait on its own pool.

Alongside the pool: `bc.mutex` (a reader-writer lock), `bc.semaphore`, `bc.channel`, `bc.thread`, and `bc.spinlock`, a reader-writer spinlock whose `.init` is unlocked, so a `__gshared` one needs no `create` or lazy initialization.
On platforms without OS locks, `bc.mutex` falls back to it.
`bc.interner` builds on it: a table any thread may intern sequences into at once, handing out dense ids and giving back each id's sequence without a lock.

Call these modules' functions fully qualified, as in `bc.threadpool.create(4)` or `bc.semaphore.post(s)`.
Several modules define `create`, so after `import bc;` an unqualified `create` is ambiguous and does not compile.

## Building

```sh
dub build --config=library --compiler=ldc2   # static library
dub test --compiler=ldc2                     # build and run the unittests
```

LDC only: libfp, which this depends on, refuses DMD at compile time (see its README, including the analysis-only `FpAllowDMD` escape hatch), so `dub.json` declares DMD unsupported and dub rejects it up front.

## Testing

`-betterC` has no unittest runner of its own, so [tests/runner.d](tests/runner.d) walks each `bc` module with `__traits(getUnitTests)` and calls the tests itself.
It reports each module and test index to `stderr` as it goes and prints the total at the end.
`stderr` is unbuffered, so a deadlocked pool or a semaphore that never posts shows up as a run that stopped at a named test rather than as silence.

The `unittest` configuration is the default for `dub test`, so a bare `dub test` picks up the runner.
Note that `dub test -c` with a *non-default* configuration substitutes dub's own druntime-based `main`, which registers nothing under `-betterC` and then reports success having run no tests; build and run such a configuration directly instead.

## WebAssembly

```sh
python3 tools/wasi.py --serve                      # build for wasm32-wasi with threads and serve a page that runs the tests in a browser
python3 tools/wasi.py --node                       # build and run the same tests headlessly under Node
python3 tools/wasi.py --node --single-threaded     # the same without threads, testing the inline fallback
```

`bc.platform` enables threads on WASI exactly when the target has atomics, so the threaded build compiles with `-mattr=+atomics,+bulk-memory` and links against [wasi-sdk](https://github.com/WebAssembly/wasi-sdk)'s `wasm32-wasip1-threads` libc with a shared, imported memory; without atomics, pools run jobs inline and `bc.mutex` spins.
The script downloads wasi-sdk into `bin/wasi-sdk` on first use (or set `WASI_SYSROOT` and `WASI_BUILTINS`), and compiles libfp in from the paths `dub describe` reports.

Threads need an LDC newer than 1.43: until [ldc-developers/ldc#5268](https://github.com/ldc-developers/ldc/pull/5268), LDC compiled D's thread-locals on wasm as ordinary globals, which every thread would share.
The script checks for this and refuses a threaded build with such a compiler; set `DC` to an LDC master build (CI uses `ldc-master`), or pass `--single-threaded`.

The tests run through [@bjorn3/browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim)'s WASI and [@emnapi/wasi-threads](https://github.com/toyobayashi/emnapi/tree/main/packages/wasi-threads), which starts each thread on a Web Worker (or a Node worker thread); the script installs both into `bin/wasi`, where the page and [tests/wasi/node.mjs](tests/wasi/node.mjs) import them alike.
A page may block only off its main thread, so [tests/wasi/run.mjs](tests/wasi/run.mjs) runs the tests on a worker, and every thread reports its output and failures over a `BroadcastChannel`, since the thread that would otherwise hear of them may be blocked joining.
Shared memory also needs a cross-origin isolated page, so `--serve` sends the `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers.
Output arrives a line at a time, so a hung test shows the module it stopped in but not the test index.
A failed assertion on any thread aborts, which in wasm is a trap; the runner reports it as exit status 134.
`bc.thread.hardwareConcurrency` reports 1 on WASI, which has no way to ask.

## Coverage

```sh
python3 tools/coverage.py        # per-module summary
python3 tools/coverage.py -v     # ... and every uncovered line
```

`-cov` records its line counts through druntime, which `-betterC` does not have, so the script builds the same sources and the same tests as ordinary D — [tests/runner.d](tests/runner.d) supplies a druntime `main` when `BctCoverage` is set, and disables druntime's own test pass so the tests still run exactly once.
It asks `dub describe` where the sources and import paths are rather than repeating `dub.json`, compiles libfp in alongside (`-I` alone would leave its symbols undefined at link time), and then drops libfp's `.lst` files from the report so the numbers cover `bc` only.

The platform backends are selected by `version`, so a run only measures the host's: on Linux the Windows and Mach branches of `bc.semaphore` and `bc.mutex` are never compiled, and lines that were compiled out are left out of the totals rather than counted as missed.
Each host therefore needs its own run to say anything about its own backend.

## Documentation

```sh
python3 tools/doctest.py
```

Compiles and runs every DDoc `---` example under `-betterC`, and reports public definitions missing documentation or an example; see [AGENTS.md](AGENTS.md) for the conventions it checks.

## Dependency on libfp

This library uses [libfp](https://github.com/doir-lang/libfp) (`D` branch) for its `@nogc` / `-betterC`-friendly dynamic array (`fp.dynarray`).

`dub.json` pins it by commit hash rather than by branch name (`"version": "~D"`), which would be the natural way to depend on a branch.
That's a workaround, not a preference: dub has a long-standing bug where resolving a git dependency by branch name fails with `fatal: '--detach' cannot be used with '-b/-B/--orphan'` (see [dlang/dub#2697](https://github.com/dlang/dub/issues/2697) and [dlang/dub#3047](https://github.com/dlang/dub/issues/3047), both still open).
Pinning a specific commit sidesteps the buggy code path.
To pick up new commits from the `D` branch, update the pinned hash in `dub.json`:

```sh
git ls-remote https://github.com/doir-lang/libfp.git refs/heads/D
```
