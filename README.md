# bc-threads

A minimal, `-betterC`-compatible fork-join thread pool for D (module `bc.threadpool`).
Backed by POSIX threads + unnamed semaphores on Linux, POSIX threads + Mach semaphores on macOS (unnamed POSIX semaphores are declared there but never implemented - `sem_init` always fails with `ENOSYS`), or Win32 threads + semaphore objects on Windows; any other platform gets a degenerate single-"worker" pool that runs jobs inline.
See the DDoc on `submit`, `wait` and `run` in [source/bc/threadpool.d](source/bc/threadpool.d) for forking work from inside a job, and why a job must never wait on its own pool.

Alongside the pool: `bc.mutex` (a reader-writer lock), `bc.semaphore`, `bc.channel`, `bc.thread`, and `bc.spinlock`, a reader-writer spinlock whose `.init` is unlocked, so a `__gshared` one needs no `create` or lazy initialization.
On platforms without OS locks, `bc.mutex` falls back to it.

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
