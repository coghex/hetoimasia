# Linux confinement and resource-limit feasibility: the verdict

**Verdict: inconclusive.**

The candidate profile below was exercised in one of the two environments
[#147](https://github.com/coghex/hetoimasia/issues/147) requires. The ordinary
unprivileged Linux launch was not available to the solver, so the deployment
baseline a person's own machine would use is **not proven** by this slice, and a
`supported` verdict is not available on the evidence that exists. Nothing here
weakens D-6, D-8, D-9, or P-13; what it does is name the one thing still missing
and what it would take to get it.

This is the record LUA-14 owes Q-5. It is not a selected backend: under D-11 an
inconclusive verdict returns the design to `exploring`, and the reference that
records it in [the Lua runtime design](lua_runtime_design.md) is a later
documentation step rather than this pull request's.

## What the evidence covers

| Proof | Environment 1: the Linux CI worker container | Environment 2: an ordinary unprivileged Linux launch |
| --- | --- | --- |
| Launch and isolation | See *Observed*, below | **Not attempted — no such environment was available** |
| Whole-process memory | See *Observed*, below | **Not attempted** |
| Lifetime and identity | See *Observed*, below | **Not attempted** |
| Deployment and CI | Recorded by the run itself | **Not attempted** |

Environment 2's absence is the whole of the inconclusive verdict. P-13 says in
as many words that *a container used for CI is not proof that the same
application launch is confined on a user's machine*, and the container this
repository's validation runs in is the only Linux this slice could reach: the
solver worked from macOS, and no unprivileged Linux machine, VM, or account was
available to it. Requirement 8 of the issue provides for exactly this case and
requires the verdict to say so rather than claim the user-machine profile. It
says so.

## The candidate profile

One child process per admitted `(mod identity, execution domain, session
generation)`, launched by a trusted parent, with these layers installed in this
order. The order is load-bearing: each layer's prerequisite is the one above it.

1. **`PR_SET_NO_NEW_PRIVS`**, so that an unprivileged process may install a
   seccomp filter at all and no later `execve` can regain privilege.
2. **A user namespace**, entered by a child that has just `fork`ed and is
   therefore single-threaded — `unshare(CLONE_NEWUSER)` is refused to a process
   with more than one thread, and the threaded runtime always has several. It
   is skipped when the process already holds `CAP_SYS_ADMIN`, which is recorded
   rather than assumed either way.
3. **Mount, network, IPC, and UTS namespaces.**
4. **A private root**: a fresh `tmpfs`, into which the runtime's own read-only
   directories and the probe binary are bind-mounted, with `/work` as the
   child's private disposable working area, reached by `pivot_root`. No host
   path outside that set is nameable from inside.
5. **Resource limits**: descriptors, core size, file size, and — where the
   caller asks for one — an address-space ceiling.
6. **A seccomp filter**, installed from inside the child before any Lua state
   exists, with `SECCOMP_FILTER_FLAG_TSYNC` so that it covers every thread the
   runtime has already started and, by inheritance, every thread it starts
   afterwards.

Launch is fail-closed at every step: a layer that cannot be installed reports
`{layer, errno}` to the parent over a close-on-exec pipe and the pre-exec child
exits. There is no path on which a child runs unconfined, and the parent reaps
the failed one itself before returning the refusal.

### What each denial is denied by

| Operation | Mechanism |
| --- | --- |
| Reading a host file outside the view | The mount namespace: the path does not exist in the private root |
| Opening a network socket | The seccomp filter: `socket` is refused outside `AF_UNIX` |
| Connecting to another instance's IPC endpoint | The network namespace: an abstract `AF_UNIX` name is scoped to one |
| Executing another program | The seccomp filter: `execve` and `execveat` are refused |
| Loading a native module | The seccomp filter: a file-backed `PROT_EXEC` mapping is refused |

Every one of those has a control that must pass beside it: the child reads its
own sentinel, binds and connects to its own endpoint, and maps the same file
without `PROT_EXEC`. The parent, unconfined, reads every host sentinel and loads
the same native module before any child is launched. A denial whose control
failed is a report about a broken fixture, not about confinement, and the suite
asserts the controls first for that reason.

`AF_UNIX` is deliberately left open. The child's own endpoint and the
peer-reachability question are both `AF_UNIX`, and a unix socket inside an empty
network namespace reaches nothing the child does not already hold.

## Observed

*This section is completed from the validation run of the pull request that
introduces the probe; the run's own output is the retained evidence, and the
lines quoted here are that output.*

<!-- The run's ENVIRONMENT, AVAILABILITY, CONTROLS, PROVED, and BLOCKED lines,
     and the workflow run they came from, are recorded here. -->

## Accounting semantics of the memory limit

The ceiling installed is `RLIMIT_AS`, a per-process address-space limit shared
by every thread, which is what makes it one limit over Lua's allocator, ordinary
native allocation, and the Haskell runtime rather than three.

What follows from that choice, and what a reader must not assume it means:

- **It measures address space, not resident size.** A child under a 512 MiB
  ceiling may have far less than 512 MiB resident. It is a bound on what the
  process can map, which is the bound that makes allocation fail.
- **Runtime reservations count.** The runtime's two-step allocator reserves a
  terabyte of address space by default, which would exhaust any useful ceiling
  before `main` ran. The probe's child is therefore built with `-xr256m`, and
  that flag is a prerequisite of the experiment rather than a tuning choice. A
  production child would carry the same constraint.
- **Swap is not separately accounted.** `RLIMIT_AS` has no notion of it.
- **It is not a cgroup.** `memory.max` would account resident memory and page
  cache for a whole process tree and would kill on violation rather than refuse
  an allocation, but it requires a delegated subtree the deployment baseline
  cannot assume. What this run observed of the available controllers and of
  whether the subtree was writable is in *Observed*.
- **A violation surfaces as allocation failure, not termination.** Lua reports
  memory exhaustion as a Lua error the bridge converts into a typed fault, and
  native allocation answers `ENOMEM`. It becomes terminal because the child
  treats either as terminal and exits with a dedicated status; the parent's
  evidence is the exit status it observed through `waitpid`, not the fact that
  it sent something.

## The execution bound

The parent owns it. The child holds `SIGTERM` with a handler that only records
it and then enters a Lua chunk that never yields — which LUA-1 established
cannot be interrupted from Haskell — so a cooperative stop provably cannot end
it and the escalation is the path actually exercised rather than a default
action that happens to be terminal. The parent requests a stop, waits out a
configured grace period, sends `SIGKILL`, and then **waits for the termination**.
A successfully sent signal is never treated as an ended child.

## Lifetime and quota

An admitted owner is released only after the parent has observed a termination.
The probe's ledger is arranged so that observing is the only way to release one,
which is what makes the three lifetime cases — initialization failure, the
owner cancelled while the child runs, and a forced kill — checkable rather than
asserted. Initialization failure never admits an owner at all, because the
refusal happens before any child exists to admit.

## Residual limits

These are true of the candidate as it stands, and each is a thing a production
profile would have to close rather than inherit.

- **The seccomp filter is a denylist.** It refuses an enumerated set of
  syscalls, so a syscall nobody thought of is allowed. The real restriction in
  this profile comes from the namespaces and the private root; the filter is
  what makes specific denials attributable and what closes `execve` and native
  module loading. A shipped profile should move to an allowlist, which is a
  larger piece of work than a feasibility probe and one that needs the finished
  child's syscall surface to exist first.
- **`mprotect` is not filtered.** A child could map a file readable and then
  make it executable. Filtering it risks the runtime's own executable
  allocations, and settling that needs measurement the probe did not do.
- **There is no PID namespace.** The children have distinct process identities
  and no `/proc` in their view, so neither can enumerate the other, but process
  isolation is not established by a namespace of its own. Adding one needs a
  second fork and a scheme for forwarding the grandchild's exit status, which
  would have complicated the very evidence these experiments exist to produce.
- **The read-only runtime view is coarse.** The child sees the host's runtime
  library directories read-only so that its loader and its locale support work.
  No user data is in that set, but it is wider than a shipped profile's should
  be: that one would ship a minimal library set instead.
- **`x86_64` and `aarch64` only.** The filter names syscall numbers, and a call
  arriving on any other architecture is refused outright rather than allowed.
- **The probe is private.** No library, executable, or public interface of this
  repository depends on it, and the only Lua source it loads is a fixture chunk
  compiled into it. It admits nothing.

## What would make this verdict `supported`

One thing: running the same experiments on an ordinary unprivileged Linux
machine and recording the result. The probe needs no change to do it — the suite
measures whether the profile installs and writes its evidence either way, so the
same command produces the second environment's record:

```bash
cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
```

If that run installs the profile and every example proves its property, the two
environments together satisfy the proof matrix and Q-5's Linux half can be
selected on the evidence. If it does not, what it refuses and why is the
concrete obstacle to bring back to the owner, and the alternatives that would
then be worth considering are a helper with a raised capability, a delegated
cgroup as a deployment requirement, or an externally managed container — each of
which the issue reserves as a material change requiring a new recorded decision
rather than a solver's choice.
