# Linux confinement feasibility: the retained runs

The three records [the verdict](lua_linux_confinement_verdict.md) draws on, kept
here verbatim because a run's own output is the evidence and a log that expires
is not a record. Each is the whole of what
`cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct`
printed on the machine named above it.

Nothing here draws a conclusion. The verdict does that, and quotes these.

## 1. The Linux CI worker container

Workflow run [35462003355](https://github.com/coghex/hetoimasia/actions/runs/35462003355),
job `haskell-engine`, group `test.lua-confinement-linux`, at commit `6d88ec7` —
the merge that brought master's own platform probe alongside this one. The plan
step resolved that candidate's input identity as
`d37235cb5e1724456e1053779aad56fad18f9cc3168237fe87b9eafdb42987a1`,
and the group's receipt is published by that run as
`receipt-test.lua-confinement-linux-<identity>`.

Only Markdown changes after that commit, which the catalog classes as
non-affecting, so this run stays input-equivalent to the head it ships with.
That is a checked claim rather than an asserted one:
`plan.py --base 6d88ec7 --head HEAD` reports the group `unaffected`. It has to
be rechecked whenever the head moves for any other reason — the merge above is
exactly the case that invalidated an earlier citation, because a package
description and a catalog are inputs of this group even when a probe's own
sources have not moved.

The profile does not install here. `unshare(CLONE_NEWUSER)` is refused with
`EPERM` by the container runtime's default syscall filter — the job declares
only `--init`, adds no capability, and relaxes no filter — so every experiment
is recorded as unproven in this environment, and what is proven is the
fail-closed refusal.

```text
Linux confinement
  record
ENVIRONMENT kernel="6.17.0-1022-azure" distribution="Ubuntu 24.04.4 LTS" uid="0 0 0 0" cap-sys-admin=no user-namespace=denied:errno=1 userns-restriction="apparmor_restrict_unprivileged_userns=1" cgroup-controllers="cpuset cpu io memory hugetlb pids rdma misc dmem" cgroup-subtree-writable=no container=yes
AVAILABILITY profile=refused layer=user-namespace errno=1
COMMAND cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
    names the machine, the permissions, and the command this run used [✔]
CONTROLS sentinels=readable inet-socket=created native-module=libbz2.so.1.0 inherited-descriptor=1100
    established every control before drawing a conclusion from a denial [✔]
  profile
BLOCKED experiment=confinement-installed unproven-here layer=user-namespace errno=1
    installs the confinement profile before any mod source is loaded [✔]
PROVED typed-refusal layer=user-namespace errno=1 admitted-owners=0 unconfined-child=never-started
    refuses the launch with a typed reason when a prerequisite is withheld [✔]
BLOCKED experiment=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-6e8db1d8a221624f/alpha-sentinel unproven-here layer=user-namespace errno=1
    is refused reading a host file outside its view, and names what refused it [✔]
BLOCKED experiment=open-inet-socket unproven-here layer=user-namespace errno=1
    is refused opening a network socket, and names what refused it [✔]
BLOCKED experiment=execute-program unproven-here layer=user-namespace errno=1
    is refused executing another program, and names what refused it [✔]
BLOCKED experiment=load-native-module unproven-here layer=user-namespace errno=1
    is refused loading a native module, and names what refused it [✔]
BLOCKED experiment=pid-namespace unproven-here layer=user-namespace errno=1
    runs as the first process of a namespace that holds nothing else [✔]
BLOCKED experiment=signal-outside-process unproven-here layer=user-namespace errno=1
    is refused signalling a process outside its namespace, and names what refused it [✔]
BLOCKED experiment=inherited-descriptor unproven-here layer=user-namespace errno=1
    cannot see a descriptor the parent left open above any swept range [✔]
BLOCKED experiment=executable-file-mapping unproven-here layer=user-namespace errno=1
    refuses a file-backed executable mapping while allowing the same file unmapped [✔]
CONTROL native-module=libbz2.so.1.0 loaded-by-parent=yes
    names the native module its denial is about, and loads it here first [✔]
  isolation
BLOCKED experiment=two-instance-isolation unproven-here layer=user-namespace errno=1
    gives two simultaneous instances distinct owners that cannot reach each other [✔]
BLOCKED experiment=independent-termination unproven-here layer=user-namespace errno=1
    lets the parent end one instance without disturbing the other [✔]
  limits
BLOCKED experiment=whole-process-memory unproven-here layer=user-namespace errno=1
    enforces one whole-process memory ceiling over Lua, native, and runtime allocation [✔]
BLOCKED experiment=execution-bound unproven-here layer=user-namespace errno=1
    ends a child that never yields, through the escalation the profile uses [✔]
  lifetime
PROVED lifetime-initialization-failure layer=user-namespace errno=1 admitted-owners-unchanged=yes
    leaves no admitted owner when initialization fails [✔]
BLOCKED experiment=lifetime-cancellation unproven-here layer=user-namespace errno=1
    leaves no live child when the parent's owner is cancelled mid-run [✔]
BLOCKED experiment=lifetime-immediate-force unproven-here layer=user-namespace errno=1
    ends a child that has only just started, before it has said anything [✔]
BLOCKED experiment=lifetime-forced-exit unproven-here layer=user-namespace errno=1
    reaps a force-killed child and releases its owner only after observing it [✔]

Finished in 0.0066 seconds
21 examples, 0 failures
```

## 2. An ordinary unprivileged Linux launch, as the distribution ships

Ubuntu 24.04.4 LTS, kernel `6.8.0-101-generic`, `aarch64`, run by an ordinary
user (uid 501) outside any container, with
`kernel.apparmor_restrict_unprivileged_userns=1` as Ubuntu sets it.

The profile does not install here either, and for a different reason: the
`unshare` succeeds and AppArmor then denies `CAP_SYS_ADMIN` inside the namespace
it created, so the identity maps cannot be written. `EACCES`, not `EPERM`.

```text
Linux confinement
  record
ENVIRONMENT kernel="6.8.0-101-generic" distribution="Ubuntu 24.04.4 LTS" uid="501 501 501 501" cap-sys-admin=no user-namespace=denied:errno=13 userns-restriction="apparmor_restrict_unprivileged_userns=1" cgroup-controllers="cpuset cpu io memory hugetlb pids rdma misc" cgroup-subtree-writable=no container=no
AVAILABILITY profile=refused layer=user-namespace errno=13
COMMAND cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
    names the machine, the permissions, and the command this run used [✔]
CONTROLS sentinels=readable inet-socket=created native-module=libbz2.so.1.0 inherited-descriptor=1100
    established every control before drawing a conclusion from a denial [✔]
  profile
BLOCKED experiment=confinement-installed unproven-here layer=user-namespace errno=13
    installs the confinement profile before any mod source is loaded [✔]
PROVED typed-refusal layer=user-namespace errno=13 admitted-owners=0 unconfined-child=never-started
    refuses the launch with a typed reason when a prerequisite is withheld [✔]
BLOCKED experiment=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-de54b3b339e5ade6/alpha-sentinel unproven-here layer=user-namespace errno=13
    is refused reading a host file outside its view, and names what refused it [✔]
BLOCKED experiment=open-inet-socket unproven-here layer=user-namespace errno=13
    is refused opening a network socket, and names what refused it [✔]
BLOCKED experiment=execute-program unproven-here layer=user-namespace errno=13
    is refused executing another program, and names what refused it [✔]
BLOCKED experiment=load-native-module unproven-here layer=user-namespace errno=13
    is refused loading a native module, and names what refused it [✔]
BLOCKED experiment=pid-namespace unproven-here layer=user-namespace errno=13
    runs as the first process of a namespace that holds nothing else [✔]
BLOCKED experiment=signal-outside-process unproven-here layer=user-namespace errno=13
    is refused signalling a process outside its namespace, and names what refused it [✔]
BLOCKED experiment=inherited-descriptor unproven-here layer=user-namespace errno=13
    cannot see a descriptor the parent left open above any swept range [✔]
BLOCKED experiment=executable-file-mapping unproven-here layer=user-namespace errno=13
    refuses a file-backed executable mapping while allowing the same file unmapped [✔]
CONTROL native-module=libbz2.so.1.0 loaded-by-parent=yes
    names the native module its denial is about, and loads it here first [✔]
  isolation
BLOCKED experiment=two-instance-isolation unproven-here layer=user-namespace errno=13
    gives two simultaneous instances distinct owners that cannot reach each other [✔]
BLOCKED experiment=independent-termination unproven-here layer=user-namespace errno=13
    lets the parent end one instance without disturbing the other [✔]
  limits
BLOCKED experiment=whole-process-memory unproven-here layer=user-namespace errno=13
    enforces one whole-process memory ceiling over Lua, native, and runtime allocation [✔]
BLOCKED experiment=execution-bound unproven-here layer=user-namespace errno=13
    ends a child that never yields, through the escalation the profile uses [✔]
  lifetime
PROVED lifetime-initialization-failure layer=user-namespace errno=13 admitted-owners-unchanged=yes
    leaves no admitted owner when initialization fails [✔]
BLOCKED experiment=lifetime-cancellation unproven-here layer=user-namespace errno=13
    leaves no live child when the parent's owner is cancelled mid-run [✔]
BLOCKED experiment=lifetime-immediate-force unproven-here layer=user-namespace errno=13
    ends a child that has only just started, before it has said anything [✔]
BLOCKED experiment=lifetime-forced-exit unproven-here layer=user-namespace errno=13
    reaps a force-killed child and releases its owner only after observing it [✔]

Finished in 0.0080 seconds
21 examples, 0 failures
```

## 3. The same machine, with that restriction relaxed

Identical in every other respect;
`kernel.apparmor_restrict_unprivileged_userns=0` was set for the run and
restored afterwards. The profile installs and every experiment proves its
property.

```text
Linux confinement
  record
ENVIRONMENT kernel="6.8.0-101-generic" distribution="Ubuntu 24.04.4 LTS" uid="501 501 501 501" cap-sys-admin=no user-namespace=available userns-restriction="apparmor_restrict_unprivileged_userns=0" cgroup-controllers="cpuset cpu io memory hugetlb pids rdma misc" cgroup-subtree-writable=no container=no
AVAILABILITY profile=installed
COMMAND cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
    names the machine, the permissions, and the command this run used [✔]
CONTROLS sentinels=readable inet-socket=created native-module=libbz2.so.1.0 inherited-descriptor=1100
    established every control before drawing a conclusion from a denial [✔]
  profile
PROVED confinement-installed layers=513 before-source=yes controls=allowed
    installs the confinement profile before any mod source is loaded [✔]
PROVED typed-refusal layer=private-root errno=2 admitted-owners=0 unconfined-child=never-started
    refuses the launch with a typed reason when a prerequisite is withheld [✔]
PROVED read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/alpha-sentinel denied-in=native,existing-thread,started-thread,lua errno=2 mechanism=mount-namespace:the path is not in the private root
    is refused reading a host file outside its view, and names what refused it [✔]
PROVED open-inet-socket denied-in=native,existing-thread,started-thread,lua errno=13 mechanism=seccomp-filter:socket refused outside AF_UNIX
    is refused opening a network socket, and names what refused it [✔]
PROVED execute-program denied-in=native,existing-thread,started-thread,lua errno=13 mechanism=seccomp-filter:execve refused
    is refused executing another program, and names what refused it [✔]
PROVED load-native-module denied-in=native,existing-thread,started-thread,lua errno=-1 mechanism=seccomp-filter:file-backed PROT_EXEC mapping refused
    is refused loading a native module, and names what refused it [✔]
PROVED pid-namespace child-pid=1
    runs as the first process of a namespace that holds nothing else [✔]
PROVED signal-outside-process denied-in=native,existing-thread,started-thread errno=3 mechanism=pid-namespace:no process outside it has a number in here
    is refused signalling a process outside its namespace, and names what refused it [✔]
PROVED inherited-descriptor number=1100 visible-in-child=no mechanism=launcher:every descriptor above the four it is given is closed before the exec errno=9
    cannot see a descriptor the parent left open above any swept range [✔]
PROVED executable-file-mapping mechanism=seccomp-filter:file-backed PROT_EXEC mapping refused control=allowed errno=13
    refuses a file-backed executable mapping while allowing the same file unmapped [✔]
CONTROL native-module=libbz2.so.1.0 loaded-by-parent=yes
    names the native module its denial is about, and loads it here first [✔]
  isolation
PROVED two-instance-isolation owners=[84016,84018] peer-endpoint=denied peer-state=denied peer-process=denied own-state=state owned by alpha alone|state owned by beta alone own-endpoint=allowed
    gives two simultaneous instances distinct owners that cannot reach each other [✔]
PROVED independent-termination ended=Terminated 9 False survivor-finished=Exited ExitSuccess admitted-owners=0
    lets the parent end one instance without disturbing the other [✔]
  limits
PROVED whole-process-memory ceiling=1073741824 measures=address-space lua=refused native-errno=12 surfaced-as=allocation-failure terminal=exited:ExitFailure 20
    enforces one whole-process memory ceiling over Lua, native, and runtime allocation [✔]
PROVED execution-bound reason=deadline-exceeded grace-microseconds=750000 escalated=yes confined-process-gone=yes observed=signalled:9
    ends a child that never yields, through the escalation the profile uses [✔]
  lifetime
PROVED lifetime-initialization-failure layer=private-root errno=2 admitted-owners-unchanged=yes
    leaves no admitted owner when initialization fails [✔]
PROVED lifetime-cancellation owner=cancelled child=reaped admitted-owners=0
    leaves no live child when the parent's owner is cancelled mid-run [✔]
PROVED lifetime-immediate-force observed=signalled:9 confined-process-gone=yes waited-for-readiness=no admitted-owners=0
    ends a child that has only just started, before it has said anything [✔]
PROVED lifetime-forced-exit observed=signalled:9 confined-process-gone=yes release-followed-observation=yes admitted-owners=0
    reaps a force-killed child and releases its owner only after observing it [✔]

Finished in 1.0520 seconds
21 examples, 0 failures
```

### The trial child's own report from that run

The launcher's first child, verbatim, before any example read it. Four vantage
points per forbidden operation — native helper code, a thread that existed
before the filter, a thread started after it, and Lua once the source loaded —
each beside the control that makes it evidence.

```text
TRIAL PROFILE sealed=yes layers=513 address-space=0 holds-term=yes pid=1
TRIAL STATE token=unreadable
TRIAL OBSERVED phase=control name=read-own-sentinel expected=allowed outcome=allowed errno=0
TRIAL OBSERVED phase=control name=open-unix-socket expected=allowed outcome=allowed errno=0
TRIAL OBSERVED phase=control name=bind-own-endpoint expected=allowed outcome=allowed errno=0
TRIAL OBSERVED phase=control name=connect-own-endpoint expected=allowed outcome=allowed errno=0
TRIAL OBSERVED phase=control name=map-own-file expected=allowed outcome=allowed errno=0
TRIAL OBSERVED phase=native name=map-own-file-executable expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=native name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/alpha-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=native name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/beta-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=native name=signal-outside-process expected=denied outcome=denied errno=3
TRIAL OBSERVED phase=native name=see-inherited-descriptor expected=denied outcome=denied errno=9
TRIAL OBSERVED phase=native name=open-inet-socket expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=native name=connect-peer-endpoint expected=denied outcome=denied errno=111
TRIAL OBSERVED phase=native name=execute-program expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=native name=load-native-module expected=denied outcome=denied errno=-1
TRIAL OBSERVED phase=native name=read-own-sentinel expected=allowed outcome=allowed errno=0
TRIAL DETAIL phase=native name=load-native-module message="libbz2.so.1.0: failed to map segment from shared object"
TRIAL OBSERVED phase=existing-thread name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/alpha-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=existing-thread name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/beta-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=existing-thread name=signal-outside-process expected=denied outcome=denied errno=3
TRIAL OBSERVED phase=existing-thread name=see-inherited-descriptor expected=denied outcome=denied errno=9
TRIAL OBSERVED phase=existing-thread name=open-inet-socket expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=existing-thread name=connect-peer-endpoint expected=denied outcome=denied errno=111
TRIAL OBSERVED phase=existing-thread name=execute-program expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=existing-thread name=load-native-module expected=denied outcome=denied errno=-1
TRIAL OBSERVED phase=existing-thread name=read-own-sentinel expected=allowed outcome=allowed errno=0
TRIAL DETAIL phase=existing-thread name=load-native-module message="libbz2.so.1.0: failed to map segment from shared object"
TRIAL OBSERVED phase=started-thread name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/alpha-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=started-thread name=read-outside-sentinel:/tmp/hetoimasia-confine-fixtures-cf791bb1518e70a2/beta-sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=started-thread name=signal-outside-process expected=denied outcome=denied errno=3
TRIAL OBSERVED phase=started-thread name=see-inherited-descriptor expected=denied outcome=denied errno=9
TRIAL OBSERVED phase=started-thread name=open-inet-socket expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=started-thread name=connect-peer-endpoint expected=denied outcome=denied errno=111
TRIAL OBSERVED phase=started-thread name=execute-program expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=started-thread name=load-native-module expected=denied outcome=denied errno=-1
TRIAL OBSERVED phase=started-thread name=read-own-sentinel expected=allowed outcome=allowed errno=0
TRIAL DETAIL phase=started-thread name=load-native-module message="libbz2.so.1.0: failed to map segment from shared object"
TRIAL OBSERVED phase=lua name=probe_read_outside_sentinel expected=denied outcome=denied errno=2
TRIAL OBSERVED phase=lua name=probe_open_inet_socket expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=lua name=probe_connect_peer_endpoint expected=denied outcome=denied errno=111
TRIAL OBSERVED phase=lua name=probe_execute_program expected=denied outcome=denied errno=13
TRIAL OBSERVED phase=lua name=probe_load_native_module expected=denied outcome=denied errno=-1
TRIAL OBSERVED phase=lua name=probe_read_own_sentinel expected=allowed outcome=allowed errno=0
TRIAL SOURCE loaded=yes probes=denied controls=allowed
TRIAL DONE mode=report
```
