# bc-threads

A minimal, `-betterC`-compatible fork-join thread pool for D (module
`bc.threadpool`). Backed by POSIX threads + unnamed semaphores on Linux,
POSIX threads + Mach semaphores on macOS(unnamed POSIX semaphores are
declared there but never implemented - `sem_init` always fails with
`ENOSYS`), or Win32 threads + semaphore objects on Windows; any other
platform gets a degenerate single-"worker" pool that runs jobs inline. See
the module doc comment in
[source/bc/threadpool.d](source/bc/threadpool.d) for the full design
notes (queue ownership, reentrant `submit`, why a job must never call
`wait` on itself, etc).

## Building

```sh
dub build --config=library   # static library
dub test                     # build and run the unittests
```

Works with both LDC and DMD (`--compiler=ldc2` / `--compiler=dmd`).

## Testing

`-betterC` has no unittest runner of its own, so
[tests/runner.d](tests/runner.d) walks each `bc` module with
`__traits(getUnitTests)` and calls the tests itself. It reports each module
and test index to `stderr` as it goes and prints the total at the end.
`stderr` is unbuffered, so a deadlocked pool or a semaphore that never posts
shows up as a run that stopped at a named test rather than as silence.

The `unittest` configuration is the default for `dub test`, so a bare
`dub test` picks up the runner. Note that `dub test -c` with a *non-default*
configuration substitutes dub's own druntime-based `main`, which registers
nothing under `-betterC` and then reports success having run no tests; build
and run such a configuration directly instead.

## Coverage

```sh
tools/coverage.sh        # per-module summary
tools/coverage.sh -v     # ... and every uncovered line
DC=dmd tools/coverage.sh # measure with DMD instead of the default LDC
```

`-cov` records its line counts through druntime, which `-betterC` does not
have, so the script builds the same sources and the same tests as ordinary D —
[tests/runner.d](tests/runner.d) supplies a druntime `main` when
`BctCoverage` is set, and disables druntime's own test pass so the tests
still run exactly once. It asks `dub describe` where the sources and import
paths are rather than repeating `dub.json`, compiles libfp in alongside
(`-I` alone would leave its symbols undefined at link time), and then drops
libfp's `.lst` files from the report so the numbers cover `bc` only.

The platform backends are selected by `version`, so a run only measures the
host's: on Linux the Windows and Mach branches of `bc.semaphore` and
`bc.mutex` are never compiled, and lines that were compiled out are left
out of the totals rather than counted as missed.

## Dependency on libfp

This library uses [libfp](https://github.com/doir-lang/libfp) (`D` branch)
for its `@nogc`/`-betterC`-friendly dynamic array (`fp.dynarray`).

`dub.json` pins it by commit hash rather than by branch name
(`"version": "~D"`), which would be the natural way to depend on a branch.
That's a workaround, not a preference: dub has a long-standing bug where
resolving a git dependency by branch name fails with
`fatal: '--detach' cannot be used with '-b/-B/--orphan'`
(see [dlang/dub#2697](https://github.com/dlang/dub/issues/2697) and
[dlang/dub#3047](https://github.com/dlang/dub/issues/3047), both still open).
Pinning a specific commit sidesteps the buggy code path. To pick up new
commits from the `D` branch, update the pinned hash in `dub.json`:

```sh
git ls-remote https://github.com/doir-lang/libfp.git refs/heads/D
```
