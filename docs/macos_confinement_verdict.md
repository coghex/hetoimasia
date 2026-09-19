# macOS confinement and resource-limit feasibility: LUA-15's verdict

**Verdict: `inconclusive`.**
**OS build tested: macOS 26.6 (`25G5065a`), arm64, Command Line Tools only.**
**Signing arrangement: the linker's own ad-hoc signature (`adhoc,linker-signed`).
No signing identity, no keychain access, no entitlement, no bundle, no
privileged installation, and no interactive consent at any point.**

Every proof row the epic's matrix asks for was demonstrated on this host, by the
probe in `packages/scripting-lua/macos/` and its Hspec target
`hetoimasia-scripting-lua:macos-confinement-probe`. The verdict is not
`supported` anyway, and the reason is one sentence: **the only arrangement that
satisfies all of the rows is built on two interfaces Apple does not support** —
one the active SDK marks "No longer supported", one absent from the public SDK
altogether — and Q-5 asks for a *supported, verified* profile, not a working one.

That is a decision for the owner, not for this slice. Section
[What the owner has to decide](#what-the-owner-has-to-decide) states it.

Nothing here was weakened to make a test pass, and no proof row was reclassified
as optional. Under [D-11](lua_runtime_design.md#d-11-gate-process-delivery-on-two-preliminary-platform-proofs)
an `inconclusive` macOS verdict leaves the design at `exploring` and leaves
LUA-9 through LUA-13 undraftable, whatever the Linux proof (#147) concludes.

## What was measured, and how

| Proof | Result | Where |
| --- | --- | --- |
| Launch and isolation | **Demonstrated.** Two simultaneous helpers, distinct pids, distinct private directories, distinct IPC endpoints; neither could read the other's sentinel or connect to the other's endpoint; ending one left the other running. All four forbidden accesses are refused from native helper code before any mod source is read, and again from Lua after it loads. | `Test.MacOS.Confinement`, `Test.MacOS.Isolation` |
| Whole-process memory | **Demonstrated.** A parent-installed, fatal, whole-process footprint cap terminated a threaded-RTS helper holding Lua strings and native buffers, at 59 MiB of physical footprint against a 64 MiB cap, before the workload's own 256 MiB ceiling and before the parent's external guard. | `Test.MacOS.Limits` |
| Lifetime and identity | **Demonstrated.** Initialization failure, parent cancellation, and a forced kill each leave no live process and no admitted owner; the parent's quota is released from the reaped status, never from the signal send; nothing restarts or replays. | `Test.MacOS.Lifetime` |
| Deployment | **Demonstrated, and this is where the verdict turns.** The whole probe reproduces from an ordinary command-line `cabal test`, headless, with the linker's ad-hoc signature and nothing else. Both load-bearing mechanisms are unsupported interfaces. | this document |

Run it, on macOS:

```bash
cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct
```

Each of the 22 examples prints what it proved. The
[local validation receipt](validation.md#the-macos-confinement-probe) records
`Darwin` as its runner OS.

## The candidate profile

A trusted parent process, per admitted `(mod, domain, generation)`:

1. **Installs a fatal whole-process memory limit at spawn** with
   `posix_spawnattr_setjetsam_ext`, flags `0x0C`, and spawns the helper
   **directly** — see [the exec trap](#the-exec-trap) for why directly.
2. The helper, before it reads anything, **installs a per-instance sandbox
   profile on itself** with `sandbox_init_with_parameters`. The profile is
   `(deny default)` plus `system.sb`, then explicit denials of network, write,
   and exec, then three parameterised grants: exec of the helper's own image,
   read and write inside *this instance's* private directory, and outbound
   connection to *this instance's* endpoint.
3. The helper then **verifies** the profile by attempting each forbidden access
   and requiring each to be refused, and by requiring its *own* endpoint to
   still be reachable. Either way round, it refuses rather than continue: a
   mechanism that reported success and enforced nothing, and a profile whose
   parameters did not resolve, are both caught here. Only then does it read mod
   source.
4. The parent ends a helper through signal escalation and **observes** the exit
   with `waitpid`, releasing the owner's budget from that observation.

Refusals are typed and terminal, each with its own exit status
(`Hetoimasia.Scripting.Lua.Internal.MacOS.Report.Refusal`): the mechanism is
absent, the profile was rejected, the profile enforced nothing, the module
source was unreadable, initialization failed. There is no path that continues as
a plain unconfined child.

### Verified policy, per proof row

| Access | Attempted by | Denied by |
| --- | --- | --- |
| Read a sentinel in the user's home directory | native, before load; Lua `io.open`, after load | `EPERM` |
| Connect to another instance's IPC endpoint | native, before and after load | `EPERM` |
| Execute another program (`/bin/echo`) | native, before load; Lua `os.execute`, after load | `EPERM`; Lua sees the shell's exit 127 |
| Load a native module (an on-disk dylib) | native, before load; Lua `package.loadlib`, after load | dyld: *blocked by sandbox* |
| Read another instance's sentinel | native, before load; Lua `io.open`, after load | `EPERM` |
| Connect to **its own** endpoint | native, before and after load | allowed — the control |

Lua's standard library has no socket API, so the network row cannot be attempted
from Lua at all. It is attempted natively a second time once untrusted source is
resident, recorded under its own origin, rather than pretending a Lua call made
it.

The Lua-side denials are evidence about the operating system and not about
`Library`, because the probe's VM opens `io`, `os`, and `package`
**deliberately**. A VM built without them would answer every row with "attempt
to index a nil value", which proves only that the allowlist works.

### Accounting semantics of the memory limit

The limit is on **physical footprint** — the same ledger jetsam uses — and not
on address space. That distinction is the whole reason the row passes:

- The confined threaded-RTS helper reserves **≈1.44 TiB of virtual address
  space** and was killed at **59 MiB of physical footprint** against its 64 MiB
  cap. The probe reports both numbers at every step of the workload.
- The violation is **terminal, not catchable**: the process is killed with
  `SIGKILL`. It never surfaces to the child as a failed allocation it could
  swallow, and the parent learns of it by reaping signal 9.
- The cap covers Lua allocations, native allocations, and the RTS together,
  because it is a property of the process rather than of an allocator. The
  workload grows all three.

The public alternative does not work at all. `RLIMIT_AS` and `RLIMIT_DATA` are
[routed through the virtual-map size limit](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_resource.c#L1560),
and the probe measures the consequence directly: **the smallest `RLIMIT_AS` the
confined helper can install is ≈1.44 TiB**, and anything below that is rejected
with `EINVAL` before the child runs a line of its own code. (A *trivial C
process* on this host bottoms out at ≈415 GiB, from the shared-cache
reservations alone; the RTS adds the rest.) There is no per-mod budget that the
documented interface can express.

The two bounds that are **not** the mechanism, kept separate on purpose: the
workload carries its own finite 256 MiB ceiling, and the parent carries an
external 60-second termination guard. A run that ended at either is reported as
a failure, because neither is evidence that the cap did anything. The same
workload with no cap installed reaches its ceiling and exits 0 — that control
runs as its own example, immediately before the capped one.

### The exec trap

**A spawn-time jetsam memory limit does not survive `exec`.** Measured
directly: `posix_spawn(eater)` under a 64 MiB cap is killed at 64 MiB;
`posix_spawn(wrapper)` where the wrapper `execv`s the same eater survives 512
MiB. A plain `execv` wrapper and `/usr/bin/sandbox-exec` behave identically
here, so the two obvious ways to apply confinement *from outside* the helper
both silently discard the only whole-process memory limit this platform offers.

That is why the helper confines itself in-process rather than being launched
through a wrapper, and it is a constraint any production design on this platform
inherits.

## Why the verdict is not `supported`

Both load-bearing mechanisms are unsupported interfaces, and neither has a
supported replacement that satisfies the matrix.

**`sandbox_init_with_parameters`** is not declared by the active SDK's
`sandbox.h` at all. What that header does declare — `sandbox_init` with
`SANDBOX_NAMED` — is marked `API_DEPRECATED("No longer supported", macos(10.5,
10.8))`, with a warning that the header may be removed. The symbol is exported
by the shared cache and works; `sandbox-exec(1)`, the same machinery through a
command, documents itself as `DEPRECATED` in its first line and points at App
Sandbox instead.

**`posix_spawnattr_setjetsam_ext`** is not declared by `spawn.h`. It is exported
by `libsystem_kernel` and works. Its flag semantics are observed rather than
documented: `0x04` alone makes the cap fatal for an active process, `0x08` alone
never fires because a spawned child is active, and the probe sets both.

Both are therefore resolved with `dlsym` at run time rather than linked, so a
system that stops exporting one produces the probe's typed refusal instead of a
link error. That is a way of failing safely, not a way of being supported.

### The supported alternative was evaluated, and does not satisfy the matrix

App Sandbox — a `.app` bundle carrying `com.apple.security.app-sandbox`,
ad-hoc-signed with `codesign --sign -` — is the arrangement
[D-10](lua_runtime_design.md#d-10-allow-evaluation-of-signed-bundled-macos-helpers)
permits and the one Apple documents. It was evaluated manually on this host
during this slice's investigation. It is not what the committed probe runs, for
the reason in the last row below.

| Row | App Sandbox result |
| --- | --- |
| Memory limit | **Works.** The spawn-time cap applies to a directly spawned bundle executable exactly as it does to a plain one — the bundle is the spawned image, so there is no intervening exec. |
| Read the home sentinel | **Denied** (`EPERM`). |
| Open a network socket | **Denied** (`EPERM`). |
| Load an on-disk native module | **Denied** (dyld: blocked by sandbox). |
| Execute another program | **Allowed.** The default profile permits exec, and the child inherits the sandbox. Defensible as a design, but it is not the denial requirement 4 asks for, and it cannot be tightened without private entitlements. |
| Per-instance storage isolation | **Not satisfied as documented.** Every instance of one bundle identifier shares one container. Distinct identifiers give distinct containers — at the cost below. |
| Container hygiene | **Disqualifying for a mod host.** A sandboxed run creates a permanent `~/Library/Containers/<bundle-id>` in the user's home, with `HOME` and the working directory redirected into it. It is **not removable by an ordinary unprivileged process**: `rm -rf` fails with `EPERM` on `.com.apple.containermanagerd.metadata.plist`. One container per mod instance means unbounded, undeletable state in the user's Library. |

The last row is also why the committed test suite does not execute an App
Sandbox bundle: a test that left an undeletable directory in the user's home on
every run is not a test this repository should ship. The evidence above is from
the manual investigation, recorded here rather than re-created on each run.

### Residual limits of the profile that does pass

- `dlopen` of a library resident in the **dyld shared cache** succeeds under
  both candidates, because no file read is mediated. Only on-disk modules are
  refused. A mod cannot supply a cache-resident library, so this is a bound on
  what the denial proves rather than a hole a mod can reach through — but it is
  a bound.
- `process-exec` of the helper's **own image** is permitted, because a
  self-confining helper cannot deny the exec that is already running it. No
  other program is reachable.
- A Unix-domain address is 104 bytes of `sun_path`. The per-user `TMPDIR` on
  this host is long enough on its own that an endpoint under it is rejected with
  `ENAMETOOLONG` before the sandbox has any say. The probe uses a short root;
  production transport has the same ceiling.
- `system.sb` is imported wholesale. It is the smallest import a threaded
  Haskell child actually starts under, and it was not audited rule by rule.
- The probe proves confinement of a helper the parent launched. It does not
  address kernel or hardware vulnerabilities, side channels, or whether a mod
  granted gameplay authority behaves fairly — as
  [P-13](lua_runtime_design.md#p-13-untrusted-processes-permissions-and-enforced-limits)
  already says.
- One instance, one profile, one host, one OS build. Nothing here establishes a
  minimum supported macOS version, and nothing here was run on Intel.

## Deployment baseline

| | |
| --- | --- |
| OS | macOS 26.6, build `25G5065a`, arm64 |
| Toolchain | Command Line Tools only; no Xcode |
| Signature | `adhoc,linker-signed` — what the linker applies to every arm64 binary. `codesign` was not invoked. |
| Entitlements | none |
| Privilege | none. No `sudo`, no keychain, no system-settings change, no interactive prompt. |
| Bundle | none |
| A distributed build would additionally need | nothing for the profile that passes — which is exactly the problem: it needs no signing arrangement because it uses no supported one. The App Sandbox alternative would need a Developer ID, notarization, and a per-instance container strategy this slice found no acceptable form of. |
| Missing prerequisites | produce a typed refusal (`confinement-unavailable`, exit 70) and no launch. |

No step of the ordinary run needs a signing identity, keychain access, a
privileged installation, or a person's desktop consent, so the issue's human
approval checkpoint was never reached and nothing under it was performed.

## What the owner has to decide

Q-5's macOS row cannot be closed by this slice. The choice is between:

1. **Accept an unsupported-SPI profile** for the macOS platform target, with the
   residual limits above and the standing risk that a future macOS stops
   exporting either symbol. The failure mode is at least safe: a missing symbol
   is a typed refusal at launch, not a silently unconfined mod.
2. **Accept App Sandbox with a weaker contract** — no exec denial, and either
   one shared container for all instances (which
   [D-8](lua_runtime_design.md#d-8-isolate-each-mod-and-execution-domain)
   forbids) or an undeletable per-instance container in the user's Library. Both
   are material changes to accepted decisions and would need fresh readiness
   signoff.
3. **Drop macOS from the untrusted-mod platform targets** for this arc, and ship
   the process branch where a supported confinement exists.

Nothing in this document chooses. Under D-11 the design returns to `exploring`
until one of these is decided, and LUA-9 through LUA-13 stay undrafted.

## Related

- [`docs/lua_runtime_design.md`](lua_runtime_design.md): LUA-15, Q-5 and its
  2026-09-16 follow-up, P-13, D-6, D-8, D-9, D-10, D-11. Recording this
  verdict's reference in that document is the documentation lane's work after
  this pull request merges, before LUA-9 is drafted.
- [`docs/validation.md`](validation.md#the-macos-confinement-probe): the
  optional `test.macos-confinement` group, why Linux never selects it, and the
  local run that produces its `Darwin` receipt.
- [`packages/scripting-lua/README.md`](../packages/scripting-lua/README.md#the-macos-confinement-probe):
  the probe's own components.
- Issue #147 (LUA-14) owns the Linux proof. Both verdicts must be successful
  before the process branch is drafted; this one is not.
