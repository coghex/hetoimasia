# Require explicit opt-in before native tests use the local desktop

Approved and filed as [#124](https://github.com/coghex/hetoimasia/issues/124).
Implemented in PR #128 and closed. Labels: `tests`, `glfw`. The body below is
the historical approved draft, not a current defect or a new filing candidate.
Archived on 2026-09-22 from `docs/native_test_approval_issue_draft.md`.
The implemented contract is in [glfw.md](../glfw.md#the-native-suite).

## Background

At `master@e2d30ea`, running `glfw-native-tests` can request focus, show windows,
minimize/maximize them, and enter fullscreen on the developer's desktop. The
owner permits necessary disruption, but requires an agent to ask the human user
for explicit approval and wait for acceptance before starting that test session.

Verified by tracing `packages/glfw/native-tests/Main.hs` into the native fixture
and `Test.GLFW.Native.Control`/`Mode`: there is no local-execution opt-in gate.
The executable also has a direct private-session child entry point. No native
windows were launched to establish this gap. `test.glfw-native` is already
required only when affected/requested and runs inside isolated Linux X11 in CI;
that useful coverage should remain.

## Requirements

1. Before any native GLFW initialization or native child launch, require an
   explicit per-run desktop opt-in or execution through the project's isolated
   X11 test path. This includes direct invocation of private-session scenarios.
   Conservatively gate all local native initialization, including nominally
   hidden-window tests. A bare `DISPLAY` or `CI=true` is not desktop consent.
2. Missing authorization must fail clearly before native effects. Do not hang
   automated tests waiting for stdin, silently skip examples, or claim a pass.
   Hspec discovery/dry runs and scripted-only selections must remain runnable
   without approval, creating no native session or child process. Empty
   selections must retain the existing failure behavior.
3. Document the explicit invocation after approval. Agents must first describe
   the expected desktop disruption, ask the human user for explicit approval,
   and wait for acceptance. Approval covers only the agreed session; do not
   reprompt during it. An issue acceptance command, PR approval, persistent shell
   setting, or periodic testing request is not permission for unrelated future
   desktop disruption. The opt-in is an operational guard, not software proof
   that a human conversation occurred.
4. Preserve the affected Linux native group's full existing coverage through
   `tools/display/x11.sh`. Its isolated-display authorization must apply only
   to the child command after successful isolation; do not modify the caller's
   environment or authorize a real desktop when isolation fails. Keep local
   Cocoa runs optional/explicit and do not add hosted macOS CI.
5. Add headless Hspec regressions for refusal before acquisition/child launch,
   dry runs and scripted selection, private-entry handling, and permitted
   execution using a fake native boundary. Verify the isolated Linux positive
   path in CI. Keep the fixture's protected cancellation/drain tests intact.
6. Update `AGENTS.md`, `MEMORY.md`, `docs/glfw.md`, `docs/validation.md`, and
   affected suite comments in the implementation PR, so ordinary examples never
   instruct agents to enable desktop execution automatically. Do not expand
   this issue into the deferred `test`/`autotest` integration.

## Acceptance

With the documented native build environment prepared:

```bash
cabal build all
cabal test hetoimasia-tests --test-show-details=direct
cabal test workflow-tests --test-show-details=direct
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "with a scripted owner"'
python3 tools/validation/plan.py --base origin/master --head HEAD
```

All commands above pass without acquiring a native session. With no explicit
opt-in and outside the isolated wrapper, the full native-suite command must
fail before native initialization, with a clear explanation. Direct private
entry must follow the same policy. Prove the zero-effect condition through the
headless regressions before exercising a direct local refusal check.

On Linux, this existing invocation must pass the real native examples:

```bash
bash tools/display/x11.sh -- cabal test glfw-native-tests --test-show-details=direct
```

Record positive CI evidence and the new documented opt-in invocation. A live
Cocoa positive run is optional for this harness-only change and requires prior
human approval; a refusal test must not pretend to be Cocoa native coverage.

## Out of scope

Removing native coverage, changing required affected Linux selection, rebuilding
the test fixture, new platform support, timing/scheduling, Vulkan, or automation
that grants itself permission to disrupt the desktop.

## Related

- #93 / epic #49: delivered the shared native fixture and test separation.
- #118 / PR #122: protected fixture drain to preserve.
- #123: independent monitor-recovery repair; may land before this guard and
  still follows the owner's explicit-approval rule for local native testing.

<!-- issue-origin:codex -->
