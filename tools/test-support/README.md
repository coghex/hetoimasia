# hetoimasia-test-support

A test-only library for what more than one independently built test suite
needs. Only `test-suite` components depend on it; no library or executable
does.

- `Test.Support.ExternalClient` compiles a separate single-module client with
  the `ghc` on `PATH`, required to match the suite's own compiler, against the
  package database found by walking up from the running test executable. It
  passes `-package-env -` and `-hide-all-packages`, exposes exactly the packages
  an example names, and exposes an `-inplace` unit id with `-package-id`.
  `rejectedBecause` requires a rejection to name its intended cause and never an
  environment failure such as a missing package or module.
  `withStorePackageClient` exposes the dependency store `cabal` reports as well,
  for a package whose own libraries depend on a Hackage package rather than on
  the boot libraries alone: the compiler has to resolve the whole unit graph,
  and without the store such a client is rejected for a reason about the
  environment rather than about the boundary. It widens nothing a client may
  say, because `-hide-all-packages` still applies and the example still lists
  every package by name.
- `Test.Support.Bounded` bounds a call that must return, so a stuck example
  fails instead of hanging the run.
- `Test.Support.Owned` is the one way a test starts a helper thread:
  `withOwnedThread action body` forks the thread and registers its
  stop-and-join in one masked step, runs the body with the caller's
  interruptibility restored, and on every way out (a return, an exception, a
  timeout of the example, a cancellation, including one delivered while the
  thread is starting) kills the thread, which does nothing to one that already
  ended, and waits for its end without being interruptible. The end is announced
  however it happened, by the step that started the thread. A thread that waits
  at a gate it keeps waiting at after a kill is started with
  `withOwnedThreadOpening open`, whose idempotent, non-blocking `open` the same
  release runs first; a `finally` inside the body is too late for a cancellation
  delivered as the body begins. It sleeps nowhere and needs `base` alone.
  A test that asserts boundness (a seam that rejects entry from a bound worker and
  from an unbound thread, a thread designated as the process main thread) starts
  its thread with `withOwnedBoundThread action body`, or
  `withOwnedBoundThreadOpening open action body`: the same ownership, on an
  OS-bound thread (`isCurrentThreadBound` holds on it), and no unowned `forkOS` to
  reach for (#593). The start differs in one place. `forkOS` waits, interruptibly
  even under `mask`, for the new OS thread to report itself, so a cancellation
  delivered there would abandon a thread that already exists; the start is made
  uninterruptibly instead, a wait for the operating system and for nothing the
  example controls, and the thread still begins masked and unmasks only inside the
  step that announces its end. The facility is generic: it designates nothing, and
  a suite that must designate the thread (GLFW's process main thread) does so as
  the first step of the action it passes.
  `Test.Support.Cancel` builds on it the cancellation delivered to the example at
  a chosen moment (`withCancellationAfter`, `withCancellationWhenBlocked`), and
  `Test.Support.Parked` the parked-release orchestration of the native suite's
  child helper examples. `tools/validation/owned_starts.py` fails a test source
  that starts a thread or subprocess any other way, except for the debt recorded
  in its checked-in baseline and the helpers it exempts by name; see
  [validation.md](../../docs/validation.md#the-owned-start-guard).

## What belongs here

A utility belongs here only when it is already used by examples that will be
owned by different suites, or is the one definition of a rule every suite that
starts a thread must follow (the owned thread: several suites had written their
own), and it is neutral: it registers no Hspec examples,
depends on no `hetoimasia-*` package, initializes nothing native, holds no
mutable global fixture, and offers no production service API. Keep sources in
`src/` alone; no other component may list this directory in `hs-source-dirs`.

Everything else stays beside its owning suite. Domain fixtures — a logger
collector and fixed metadata, a supervision gate or trace, a native session —
are built by the suite that asserts on them through the public API of the
package under test, even when that repeats a few simple values another suite
also defines. Do not import a helper from another component's spec module, and
do not grow this library into a generic fixture framework to remove trivial
duplication.
