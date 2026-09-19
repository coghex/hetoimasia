# Linux confinement and resource-limit feasibility: the verdict

**Verdict: inconclusive.**

The candidate profile works. On an ordinary unprivileged Linux machine every row
of Q-5's proof matrix was demonstrated, by a non-root user holding no
capability, with the forbidden operations refused by named mechanisms and the
whole-process memory and execution limits enforced and observed.

It works only where the distribution permits an unprivileged process to create a
*usable* user namespace, and neither environment this slice was required to
reproduce in permits that as shipped. Ubuntu 24.04 restricts it by default, and
this repository's Linux CI container refuses it outright. Making the profile
work on a stock machine needs an administrative change to the user's system, and
that is a deployment requirement [#147](https://github.com/coghex/hetoimasia/issues/147)
reserves for the owner rather than one a solver may adopt. So the mechanism is
proven and the deployment baseline is not, which is what `inconclusive` means
here.

Under D-11 that returns the Lua design to `exploring`. Recording the reference
in [the Lua runtime design](lua_runtime_design.md) is a later documentation step
rather than this pull request's, and nothing here weakens D-6, D-8, D-9, or
P-13. The concrete obstacle and the alternatives are at the end.

## The two environments

| | Environment 1: the Linux CI worker container | Environment 2: an ordinary unprivileged Linux launch |
| --- | --- | --- |
| Kernel | `6.17.0-1022-azure` | `6.8.0-101-generic` |
| Distribution | Ubuntu 24.04.4 LTS | Ubuntu 24.04.4 LTS |
| Architecture | `x86_64` | `aarch64` |
| Ran as root | yes (uid 0) | **no** (uid 501) |
| `CAP_SYS_ADMIN` | no | no |
| In a container | yes | no |
| User namespace | **denied, `EPERM`** | **denied, `EACCES`** as shipped; available with the restriction relaxed |
| Restriction in force | the container runtime's default syscall filter | `kernel.apparmor_restrict_unprivileged_userns=1` |
| cgroup v2 controllers | `cpuset cpu io memory hugetlb pids rdma misc dmem` | `cpuset cpu io memory hugetlb pids rdma misc` |
| `cgroup.subtree_control` writable | no | no |
| Profile installed | **no** | **no** as shipped; **yes** with the restriction relaxed |

**All three runs are kept verbatim in
[the retained runs](lua_linux_confinement_evidence.md)**, and every line quoted
below is from one of them.

Environment 1 is the `haskell-engine` worker of `.github/workflows/validation.yml`,
running the pinned image with `options: --init` and nothing else. The record is
workflow run
[35458938753](https://github.com/coghex/hetoimasia/actions/runs/35458938753) at
commit `87f020b`, whose plan step resolved the candidate's input identity as
`249c6b60…f5ba04` and whose `receipt-test.lua-confinement-linux-<identity>`
artifact is that group's receipt. Every later commit on this branch changes
Markdown alone, which the catalog classes as non-affecting, so that run stays
input-equivalent to the head this verdict ships with — `plan.py --base 87f020b
--head HEAD` reports the group `unaffected`.

Its containers declare no added capability and no relaxed syscall filter, and
the container runtime's default filter is what refuses `unshare(CLONE_NEWUSER)`
there with `EPERM`. **No change was made to the CI image recipe or to those
container options**: its pinned descriptor and toolchain identity contract are
untouched, and requirement 11 therefore has nothing to record.

Environment 2 is a plain Ubuntu 24.04 virtual machine, outside any container,
with the qualified toolchain installed and the probe run as an ordinary user
from the ordinary command. It is not a CI worker and holds nothing a person's
own machine would not. Its refusal is `EACCES` rather than `EPERM`, and the
difference is the point: the two environments refuse the same profile at the
same layer for different reasons, and the section below is about the second.

### What the restriction actually does

Ubuntu 24.04 ships `kernel.apparmor_restrict_unprivileged_userns=1`. Under it
`unshare(CLONE_NEWUSER)` *succeeds* and the process is transitioned into an
AppArmor profile that denies every capability, so the namespace it just created
is one it holds nothing inside:

```
apparmor="AUDIT"  operation="userns_create" info="Userns create - transitioning profile"
                  profile="unconfined" target="unprivileged_userns"
apparmor="DENIED" operation="capable" class="cap" profile="unprivileged_userns"
                  capability=21 capname="sys_admin"
```

That is why the probe does not ask whether a user namespace can be *created*. It
forks a child that attempts the whole sequence — the namespace, the identity
maps, and a mount namespace under it — and reports the first failure, so the
environment record says `user-namespace=denied:errno=13` on a machine where
`unshare -U true` succeeds. A check that stopped at the `unshare` would have
recorded this machine as capable and then been contradicted by every experiment.

## The candidate profile

One child process per admitted `(mod identity, execution domain, session
generation)`, launched by a trusted parent, with these layers installed in this
order. The order is load-bearing: each layer's prerequisite is the one above it.

1. **`PR_SET_NO_NEW_PRIVS`**, so that an unprivileged process may install a
   seccomp filter at all and no later `execve` can regain privilege.
2. **A user namespace**, entered by a child that has just `fork`ed and is
   therefore single-threaded — `unshare(CLONE_NEWUSER)` is refused to a process
   with more than one thread, and the threaded runtime always has several. It is
   skipped when the process already holds `CAP_SYS_ADMIN`, which is recorded
   rather than assumed either way.
3. **Mount, network, IPC, UTS, and PID namespaces.** The PID namespace is what
   makes "cannot reach another instance" a property of the kernel rather than
   of the child's ignorance: sharing the host's process numbering and the
   caller's own user id, a child could signal a sibling, the engine, or
   anything else that user is running, and a syscall filter cannot tell those
   apart from a process signalling itself because it cannot see who is asking.
   `unshare` moves the caller's *children* into the new namespace rather than
   the caller, so the confined program is one fork further down and what remains
   above it is a supervisor holding no Lua, forwarding a cooperative stop
   inwards and reproducing the confined process's own termination as its own.
4. **A private root**: a fresh `tmpfs`, into which the runtime's own read-only
   directories, the probe binary, and this instance's own state are
   bind-mounted, with `/work` as the child's private disposable working area,
   reached by `pivot_root`. No host path outside that set is nameable from
   inside. The instance's state is at `/state`, a name every instance shares
   and no two of which are the same directory: that one path resolving to
   different bytes in each child is what makes "neither can read the other's
   state" a claim with two observable halves rather than a shared absence.
5. **Resource limits**: descriptors, core size, file size, and — where the caller
   asks for one — an address-space ceiling.
6. **A seccomp filter**, installed from inside the child before any Lua state
   exists, with `SECCOMP_FILTER_FLAG_TSYNC`.

Between the limits and the exec, every descriptor above the four the child is
given is closed — the whole range rather than a guess at it, through
`close_range` where the kernel has it and to the descriptor ceiling read before
the limits narrowed it where it does not. Lowering `RLIMIT_NOFILE` closes
nothing that is already open, so a caller's descriptor at any number its own
limit allowed would otherwise survive the `execve` as an ambient capability.

Launch is fail-closed at every step: a layer that cannot be installed reports
`{layer, errno}` to the parent over a close-on-exec pipe and the pre-exec child
exits. There is no path on which a child runs unconfined, and the parent reaps
the failed one itself before returning the refusal. Both refusing environments
demonstrated that, each with its own errno — the CI container's `EPERM`:

```text
PROVED typed-refusal layer=user-namespace errno=1 admitted-owners=0 unconfined-child=never-started
PROVED lifetime-initialization-failure layer=user-namespace errno=1 admitted-owners-unchanged=yes
```

and the unprivileged machine's `EACCES`:

```text
PROVED typed-refusal layer=user-namespace errno=13 admitted-owners=0 unconfined-child=never-started
PROVED lifetime-initialization-failure layer=user-namespace errno=13 admitted-owners-unchanged=yes
```

A refusal is only an acceptable outcome for the obstacle that machine's own
environment record independently measured. The record forks a child and attempts
the namespace, the identity maps, and a mount namespace under it; the launcher
attempts the whole profile; and an example accepts "blocked" only where the two
agree on the layer and the errno. A refusal anywhere else, or any refusal at all
on a machine whose record says the namespace is usable, fails the suite rather
than reporting itself as unproven.

## Observed, with the profile installed

Environment 2, `apparmor_restrict_unprivileged_userns=0`, 21 examples, 0
failures. Each line below is the run's own output; the whole of it, including
the trial child's own report, is in
[the retained runs](lua_linux_confinement_evidence.md#3-the-same-machine-with-that-restriction-relaxed).

```text
ENVIRONMENT kernel="6.8.0-101-generic" distribution="Ubuntu 24.04.4 LTS" uid="501 501 501 501"
            cap-sys-admin=no user-namespace=available
            userns-restriction="apparmor_restrict_unprivileged_userns=0"
            cgroup-controllers="cpuset cpu io memory hugetlb pids rdma misc"
            cgroup-subtree-writable=no container=no
AVAILABILITY profile=installed
CONTROLS sentinels=readable inet-socket=created native-module=libbz2.so.1.0
         inherited-descriptor=1100
PROVED confinement-installed layers=513 before-source=yes controls=allowed
PROVED pid-namespace child-pid=1
PROVED read-outside-sentinel:…/alpha-sentinel denied-in=native,existing-thread,started-thread,lua
       errno=2 mechanism=mount-namespace:the path is not in the private root
PROVED open-inet-socket denied-in=native,existing-thread,started-thread,lua
       errno=13 mechanism=seccomp-filter:socket refused outside AF_UNIX
PROVED execute-program denied-in=native,existing-thread,started-thread,lua
       errno=13 mechanism=seccomp-filter:execve refused
PROVED load-native-module denied-in=native,existing-thread,started-thread,lua
       errno=-1 mechanism=seccomp-filter:file-backed PROT_EXEC mapping refused
PROVED signal-outside-process denied-in=native,existing-thread,started-thread
       errno=3 mechanism=pid-namespace:no process outside it has a number in here
PROVED inherited-descriptor number=1100 visible-in-child=no errno=9
       mechanism=launcher:every descriptor above the four it is given is closed before the exec
PROVED executable-file-mapping mechanism=seccomp-filter:file-backed PROT_EXEC mapping refused
       control=allowed errno=13
PROVED two-instance-isolation owners=[82368,82370] peer-endpoint=denied peer-state=denied
       peer-process=denied own-state=state owned by alpha alone|state owned by beta alone
       own-endpoint=allowed
PROVED independent-termination ended=Terminated 9 False survivor-finished=Exited ExitSuccess
       admitted-owners=0
PROVED whole-process-memory ceiling=1073741824 measures=address-space lua=refused
       native-errno=12 surfaced-as=allocation-failure terminal=exited:ExitFailure 20
PROVED execution-bound reason=deadline-exceeded grace-microseconds=750000 escalated=yes
       confined-process-gone=yes observed=signalled:9
PROVED lifetime-cancellation owner=cancelled child=reaped admitted-owners=0
PROVED lifetime-immediate-force observed=signalled:9 confined-process-gone=yes
       waited-for-readiness=no admitted-owners=0
PROVED lifetime-forced-exit observed=signalled:9 confined-process-gone=yes
       release-followed-observation=yes admitted-owners=0
```

`layers=513` is `NO_NEW_PRIVS | SECCOMP`, the two the child installs itself; the
namespaces, the private root, and the limits went in before it existed.

### The proof matrix

| Proof | Environment 1 | Environment 2, as shipped | Environment 2, restriction relaxed |
| --- | --- | --- | --- |
| Launch and isolation | unproven: refused, `EPERM` | unproven: refused, `EACCES` | **proven** |
| Whole-process memory | unproven: refused | unproven: refused | **proven** |
| Lifetime and identity | fail-closed half proven | fail-closed half proven | **proven** |
| Deployment and CI | [recorded](lua_linux_confinement_evidence.md#1-the-linux-ci-worker-container) | [recorded](lua_linux_confinement_evidence.md#2-an-ordinary-unprivileged-linux-launch-as-the-distribution-ships) | [recorded](lua_linux_confinement_evidence.md#3-the-same-machine-with-that-restriction-relaxed) |

### What each denial is denied by

| Operation | Mechanism | Observed |
| --- | --- | --- |
| Reading a host file outside the view | The mount namespace: the path does not exist in the private root | `ENOENT` |
| Opening a network socket | The seccomp filter: `socket` is refused outside `AF_UNIX` | `EACCES` |
| Connecting to another instance's IPC endpoint | The network namespace: an abstract `AF_UNIX` name is scoped to one | `ECONNREFUSED` |
| Executing another program | The seccomp filter: `execve` and `execveat` are refused | `EACCES` |
| Loading a native module | The seccomp filter: a file-backed `PROT_EXEC` mapping is refused | `dlopen`: *failed to map segment from shared object* |
| Signalling a process outside the child | The PID namespace: nothing outside it has a number in here | `ESRCH` |
| Reading another instance's own state | The mount namespace: that instance's directory is bound into its root and no other | `ENOENT` |
| Seeing a descriptor the caller left open | The launcher: every descriptor above the four it is given is closed before the exec | `EBADF` |

Every one has a control that passes beside it: the child reads its own sentinel,
binds and connects to its own endpoint, and maps the same file without
`PROT_EXEC`. The parent, unconfined, reads every host sentinel, creates an
`AF_INET` socket, and loads the same native module before any child is launched
— the socket because the filter treats that domain differently from `AF_UNIX`,
so the child's `AF_UNIX` control says nothing about it and a machine with no
network stack would otherwise produce the same refusal for its own reasons. A denial whose control failed is a
report about a broken fixture, not about confinement, and the suite asserts the
controls first for that reason.

Three of those controls are sharper than they look. The peer endpoint and the
child's own endpoint are the same operation on the same kind of name, differing
only in whose network namespace the name lives in — in a shared namespace both
would connect. The native module is chosen at run time from modules the program does *not*
already link, because `dlopen` on one the program links takes a reference to
what is already mapped without mapping a file, and would have succeeded inside
the child while proving nothing. And the signalling probe is adversarial rather
than a guess: each child is told, over its inherited endpoint after both are
bound, exactly where its sibling is on the host, so a refusal is the kernel's
and not the child's ignorance.

`AF_UNIX` is deliberately left open. The child's own endpoint and the
peer-reachability question are both `AF_UNIX`, and a unix socket inside an empty
network namespace reaches nothing the child does not already hold.

### The filter covers the whole child, and this was observed

The review amendment asked that confinement be shown to cover the actual
threaded child, including threads that already existed and threads created
afterwards. Each forbidden operation is therefore attempted from four places and
refused in all four: native helper code on the installing thread, **a bound OS
thread started before the filter existed and parked until afterwards**,
**a bound OS thread started after it**, and Lua once the source was loaded. The
first pair is `TSYNC`'s claim about running threads, observed rather than
asserted; the second is inheritance.

## Accounting semantics of the memory limit

The ceiling installed is `RLIMIT_AS`, a per-process address-space limit shared by
every thread, which is what makes it one limit over Lua's allocator, ordinary
native allocation, and the Haskell runtime rather than three.

What follows from that choice, and what a reader must not assume it means:

- **It measures address space, not resident size.** A child under a 1 GiB ceiling
  may have far less than 1 GiB resident. It is a bound on what the process can
  map, which is the bound that makes allocation fail.
- **Runtime reservations count, and startup is not free.** The runtime's two-step
  allocator reserves a terabyte of address space by default, which would exhaust
  any useful ceiling before `main` ran; the probe's child is therefore built with
  `-xr256m`, and that is a prerequisite of the experiment rather than a tuning
  choice. Eight megabytes of reserved stack for every thread the threaded runtime
  creates comes out of the ceiling too — a 512 MiB ceiling was tried first and
  the child died with *failed to create OS thread: Cannot allocate memory*, which
  is the experiment measuring its own startup. A production child inherits both
  constraints.
- **Swap is not separately accounted.** `RLIMIT_AS` has no notion of it.
- **It is not a cgroup.** `memory.max` would account resident memory and page
  cache for a whole process tree and would kill on violation rather than refuse
  an allocation. Neither environment offered it: both list a `memory` controller
  and neither has a writable `cgroup.subtree_control`, so no delegated subtree
  exists to put a child in. That is recorded, not worked around.
- **A violation surfaces as allocation failure, not termination.** Lua reported
  memory exhaustion as a Lua error the bridge converted into a typed fault, and
  the native allocation that followed answered `ENOMEM`. It became terminal
  because the child treats either as terminal and exits with a dedicated status;
  the parent's evidence is the exit status it observed through `waitpid`, not the
  fact that it sent something.

## The execution bound

The parent owns it. The child holds `SIGTERM` with a handler that only records it
and then enters a Lua chunk that never yields — which LUA-1 established cannot be
interrupted from Haskell — so a cooperative stop provably cannot end it and the
escalation is the path actually exercised rather than a default action that
happens to be terminal.

What the escalation must not be is `SIGKILL` aimed at the handle the parent
holds. That handle is the supervisor outside the child's PID namespace, and
`SIGKILL` cannot be caught: the supervisor would die without passing anything on
or waiting for anything, and the parent would reap a supervisor while the process
it stands for was still being killed asynchronously by its parent-death signal.
Every claim about observed termination would then be a claim about the wrong
process. So the escalation is a signal the supervisor *can* catch; the supervisor
`SIGKILL`s the confined process, waits for it, and only then reproduces its
termination as its own. A parent whose wait has returned is a parent whose
confined process was reaped first.

The run recorded `escalated=yes observed=signalled:9`, and beside it
`confined-process-gone=yes`: after the termination was observed, the child's
output reached end-of-file, which it cannot while anything still holds the far
end of that pipe. That is the confined process itself, and not the supervisor,
being gone.

## Lifetime and quota

An admitted owner is released only after the parent has observed a termination.
The probe's ledger is arranged so that observing is the only way to release one,
which is what makes the three cases checkable rather than asserted:
initialization failure never admits an owner at all, because the refusal happens
before any child exists to admit; a cancelled owner's teardown reaped its child
and left the ledger empty; and a force-killed child was still admitted after the
kill and released only after `waitpid` answered.

## Residual limits

Each is a thing a production profile would have to close rather than inherit.

- **The seccomp filter is a denylist.** It refuses an enumerated set of syscalls,
  so a syscall nobody thought of is allowed. The real restriction comes from the
  namespaces and the private root; the filter is what makes specific denials
  attributable and what closes `execve` and native module loading. A shipped
  profile should move to an allowlist, which needs the finished child's syscall
  surface to exist first.
- **`mprotect` is not filtered.** A child could map a file readable and then make
  it executable. Filtering it risks the runtime's own executable allocations, and
  settling that needs measurement this slice did not do.
- **The caller's handle is the supervisor, not the confined process.** A PID
  namespace's init must have a parent outside it, so what the caller waits on
  and signals is one process further out. It reproduces the confined process's
  exit status and terminating signal as its own, forwards a cooperative stop
  inwards, and on the force signal kills the confined process and waits for it
  before ending — so an observation is never ahead of what it is about. A
  caller that sent an uncatchable signal to that handle instead would get the
  supervisor's own death and no guarantee about the process behind it; the
  probe's cleanup keeps that as a last resort and no example asserts on it.
- **The read-only runtime view is coarse.** The child sees the host's runtime
  library directories read-only so that its loader and its locale support work.
  No user data is in that set, but a shipped profile would ship a minimal library
  set instead.
- **Read-only is not recursive.** The bind mounts are remounted read-only at
  their top mount only; a submount under one of those directories would not be.
- **`x86_64` and `aarch64` only.** The filter names syscall numbers, and a call
  arriving on any other architecture is refused outright rather than allowed. The
  x32 ABI is refused before the table, because its numbers are the ordinary ones
  with a bit set and would otherwise match nothing and fall through to the allow.
- **The evidence is `aarch64`.** Environment 2 is an ARM machine. The filter
  compiles and is exercised there; its `x86_64` branch is compiled in CI but has
  never had a profile installed under it.
- **The probe is private.** No library, executable, or public interface of this
  repository depends on it, and the only Lua source it loads is a fixture chunk
  compiled into the child. It admits nothing.

## The obstacle, and the alternatives

**The obstacle:** the profile's foundation is an unprivileged user namespace, and
a current Linux distribution does not give one to an ordinary user by default.
Everything above it — the private root, the network isolation, the limits — needs
`CAP_SYS_ADMIN` inside that namespace, and Ubuntu 24.04's AppArmor restriction
grants the namespace while denying the capability.

Closing it means choosing one of these, and every one of them is a material
change the issue reserves for the owner rather than a solver's choice:

1. **Require the user to relax the restriction** (`kernel.apparmor_restrict_unprivileged_userns=0`).
   Simple, and a deployment requirement that weakens the user's whole machine to
   run one game. Named here to be rejected explicitly rather than by silence.
2. **Ship an AppArmor profile** granting the engine `userns create`. Narrower
   than 1, and an installation step needing root, so the supported deployment
   baseline would include a packaged profile and a distribution that uses
   AppArmor.
3. **A helper with a file capability**, holding `CAP_SYS_ADMIN` to build the
   namespace and dropping it before any source loads. A raised capability as a
   deployment requirement, which Q-5's stop list names directly.
4. **Landlock instead of namespaces.** The most promising, and the one worth
   evaluating next: it is an unprivileged LSM needing no namespace and no
   capability, it restricts the filesystem view directly, and since kernel 6.7 it
   restricts TCP bind and connect. It would replace the mount and network layers
   while the seccomp filter and `RLIMIT_AS` stay as they are. What it does not
   give is a private root, an empty network namespace, or IPC isolation, so
   whether the P-13 boundary survives the substitution is a real question and not
   a foregone one. A minimum kernel of 6.7 would become part of the baseline.
5. **Require a container or VM.** Explicitly reserved by Q-5 as a material
   alternative.

The probe needs no change to evaluate 1, 2, or 3: it measures whether the profile
installs and writes its evidence either way, so the same command produces the
record on any machine.

```bash
cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
```

Option 4 would be a new candidate profile beside this one, and this probe is the
harness it would be measured in.
