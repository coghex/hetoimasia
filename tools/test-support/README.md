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
  An example whose point is that a cancellation is *pending* against a thread
  before the thread's next effect starts the target and the cancellation's sender
  with `withOwnedThreadOn capability action body` (or
  `withOwnedThreadOpeningOn capability open action body`): the same ownership, on a
  thread pinned to one capability (#610). On one capability `throwTo` to a masked
  thread queues the exception before the sender is recorded as blocked, so a sender
  seen blocked delivering has an exception pending against its target; across
  capabilities it is a message the target's capability takes in later (GHC 9.14.1
  `rts/Schedule.c`, `scheduleProcessInbox` returns at once when the capability's
  lock is busy), and no wait on the sender's status establishes receipt.
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
  that does not observe the exit); production use is `noSeams`. It needs `base`,
  `bytestring`, `stm`, `text` and `unix`, a small C file for the non-reaping look
  at a child, and the bounded wait for a group's end is the one place it polls.

- `Test.Support.Subprocess.Host` is the hosted subprocess (#608), the one thing the
  single-child scopes cannot do: a child whose process group is *not* ended when the
  call that ran it returns. The display-helper suites run a helper whose stub servers
  and clients sit in the helper's group, and assert afterwards that the helper stopped
  what it owned and left alone what it did not start; a one-shot owned call ends the
  group on return and the example could not look. `withHost` opens a scope,
  `hosted` (and `hostedCaptured`, which answers the triple `runCaptured` does) runs a
  child on it under the facility's rules unchanged, and the host ends and reaps every
  child, latest first, when its scope ends. It is a state machine; its owner, readers
  and writers, thread, lifetime and disposal are in the module header. The scopes of
  the children are nested on one owned worker, so they unwind latest first; the stop is
  a cell of its own that no full slot can hide; a submitter cleans up its own unclaimed
  request, the worker its claimed one, the caller a request whose body was entered.
  Hosted bodies must be cancellable (the precondition of `docs/workers.md` and of
  `Test.Support.Owned`): a body that ignores its cancellation holds the scope's join
  until it lets go, and the host reports nothing ended or reaped that is not.

  | State \\ Operation | Submit | Bound passes, or the submitter is cancelled | Stop | Owner fails or is cancelled | The worker ends by itself |
  |---|---|---|---|---|---|
  | **Starting** | one request accepted into the slot, a further submitter waits within its bound, refused (answered at once) if the host stops or ends | expiry: abandoned, fails naming the command and bound, never started, handles closed; cancellation: the same with its own cancellation unchanged | nothing served, queued request answered "stopped", never started, handles closed | as Stop, then the owner's failure or cancellation as itself | Ended; queued request answered "ended", never started, handles closed; a failure that is not a cancellation is raised once by the scope |
  | **Idle** | accepted, served at once | not applicable: nothing waits in Idle | worker ends, children ended latest first, scope returns after every reap is confirmed | as Stop, then the owner's | Ended with its children already reaped; later submissions refused |
  | **Serving, slot empty** | accepted into the slot without blocking | expiry: body cut at its bound, submitter fails naming command and bound, child stays hosted; cancellation: the submitter sees its own cancellation, the body is not cancelled | running body cancelled (not waited for), submitter answered "stopped", child ended and reaped | as Stop, then the owner's | running submitter answered "ended"; Ended |
  | **Serving, one queued** | the submitter waits within its bound, woken and refused if the host stops or ends | queued: abandoned, never started, handles closed, slot free; running: as above, the queued request then served | the stop is recorded though the slot is full; running body cancelled, queued request never started, "stopped", handles closed | as Stop, then the owner's | both answered "ended"; queued never started, handles closed |
  | **Stopping** | refused at once, whatever the slot holds | a waiting submitter is answered "stopped" at once, not at its bound | idempotent | idempotent; a second cancellation is remembered, the cleanup finished, then raised with the owner's failure retained | Ended once the worker has finished; a cleanup that was not confirmed is raised once after every reap |
  | **Ended** | refused at once, whatever the slot held | not applicable: every waiter was answered, every later submission is refused without waiting | idempotent: no child ended twice | idempotent: raised once, as itself | not applicable: Ended is final |

  | Cause | Outcome |
  |---|---|
  | normal end | every child ended and reaped latest first, the body of a running request cancelled first; the owner's result if every cleanup was confirmed, otherwise the unconfirmed-cleanup failure after the others were ended |
  | a child fails to start | only that submitter is told (the failure of starting), its handles closed, the host stays Idle and serves the next, however many fail in a row |
  | a body fails | its submitter receives it as itself; the host goes on, earlier children untouched |
  | a body is cancelled (the host's stop, or the worker) | the submitter is answered; the host is Ended; later submissions refused; the scope raises a cancellation only if it was the owner's own |
  | the owner fails or is cancelled | the host stops as in the table; every child ended and reaped; the owner's own failure raised as itself, with any cleanup failure retained beside it |

  Every cell and every row has its example in `tools/test/OwnedHost.hs`, named
  `<State> × <Operation>: …` or `Cause: …`; a cell that specifies two outcomes has one
  example for each, and a "not applicable" cell has an example of the invariant that
  makes the operation unreachable. The same file holds the three races of a request's
  handles with the worker (taking it, acquiring the child, entering the body), a
  cancellation delivered into each cleanup the host adds, the limit of a body that is
  not cancellable, and the captured run the display-helper suites use. A handle a
  request supplies is closed exactly once by whoever owns it at that moment, before the
  call returns or raises, until its body is entered, and never by the host after.

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
