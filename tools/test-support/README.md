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
  `Test.Support.Cancel` builds on it the cancellation delivered to the example at
  a chosen moment (`withCancellationAfter`, `withCancellationWhenBlocked`), and
  `Test.Support.Parked` the parked-release orchestration of the native suite's
  child helper examples. `tools/validation/owned_starts.py` fails a test source
  that starts a thread or subprocess any other way, except for the debt recorded
  in its checked-in baseline and the helpers it exempts by name; see
  [validation.md](../../docs/validation.md#the-owned-start-guard).
- `Test.Support.Subprocess` is the one way a test starts a subprocess (#588), in
  the two shapes the suites used the library calls for. `runToCompletion` and
  `runCaptured` start a command with a caller-chosen environment, working
  directory and standard input and answer its status and everything it wrote to
  standard output and standard error, the answer `readCreateProcessWithExitCode`
  gave. `withScopedChild` starts a command and lends it to a body: each standard
  stream is `Piped` (read by the facility, line by line with `nextLine` or whole
  with `captured` and `restOfOutput`), `Absent` (closed, and never replaced by
  another stream), `Inherited`, or a `CallerHandle` the caller opened (closed by
  the facility only when the start fails or the call is cancelled before the body
  is entered); the body learns the identifier, sends a signal, waits within a
  bound of its own, and can look at a child that has exited without reaping it
  (`childState`, `awaitUnreapedExit`), so a zombie can be observed and the release
  reaps it. Spawning, creating the pipes, starting the readers and registering the
  release are one masked step; the body runs with the caller's interruptibility
  restored; on every way out (a return, an exception, the call's own run bound, a
  cancellation at any point, including while the child starts and while the
  release runs) the child is ended and *reaped with the wait confirmed* and the
  readers are stopped and joined before the call returns or raises. A
  cancellation that arrives in the release is remembered and raised after it,
  with the body's failure retained beside it in the exception's context
  (`RetainedFailure`); a child that cannot be confirmed reaped, a process group
  that is not observed to be gone, or pipes that do not end fail an otherwise
  passing call and say which.
  The owner decisions of 2026-11-02 are fixed in it. Each child starts in a
  process group of its own (never a session of its own) and the whole group is
  ended: SIGTERM, 2 s of grace, SIGKILL, so a descendant in the group goes with
  its leader, and a leader that exits does not spare one that ignores SIGTERM.
  The group is signalled only while its identifier is still reserved (the leader
  unreaped, or a null signal found a member), never once the leader is reaped and
  none remains. A child can stay in the caller's group, signalled by identifier
  only, in exactly two cases that the caller names (`CallersGroup`): a child that
  inherits the terminal for a person at the keyboard, and the nested private
  compositors, which stay in their owning test process's group so the outer
  launcher's deadline still ends them. Every call states its own run bound
  (`Within microseconds` or an explicit `Unbounded` for a human-paced call; there
  is no default); the reap and drain waits are a fixed 10 s, a descendant that
  keeps a pipe open past the drain is given up on and the answer says so
  (`DrainGivenUp`). `Bounds` and `Seams` are explicit arguments for the facility's
  own examples (a shorter grace, a failed acquisition, a parked release, a wait
  that does not observe the exit); production use is `noSeams`. `withHost` and
  `hosted` keep a scoped child's scope open past the call that ran it, until the
  host's own scope ends, for the display helper examples, which look at what the
  helper left in its process group before anything ends it. It needs `base`,
  `bytestring`, `stm`, `text` and `unix`, a small C file for the non-reaping look
  at a child, and the bounded wait for a group's end is the one place it polls.

## What belongs here

A utility belongs here only when it is already used by examples that will be
owned by different suites, or is the one definition of a rule every suite that
starts a thread or a subprocess must follow (the owned thread and the owned
subprocess: several suites had written their own), and it is neutral: it registers no Hspec examples,
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
