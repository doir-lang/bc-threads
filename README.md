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
