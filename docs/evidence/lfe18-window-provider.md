# LFE-18 window provider: evidence

Issue [#533](https://github.com/coghex/hetoimasia/issues/533). Contract: [`packages/lua-engine-graphics/README.md`](../../packages/lua-engine-graphics/README.md#the-window-provider-lfe-18).

## Real windows (native subgroup `window provider`)

Command (macOS, under the owner's standing native-session approval, confirmed on `#het-lfsolve` for this suite):

```sh
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --match 'window provider'
```

| Field | Value |
| --- | --- |
| revision | `430a5f1641eaecd87b78a82009bd0dabcd9db6de` (source digest `bbe169d8c97cf64c71c4e16a0aecc20aaf8e8b6a41cbedf2fe92af89fff3b5af`); the later commits only add the recorded-step masks and docs |
| platform | darwin/aarch64, GHC 9.14.1 |
| driver | MoltenVK (`icd.d/MoltenVK_icd.json` of the private native prefix), loader `libvulkan.1.dylib` of that prefix, held to the recorded loader by the suite |
| validation | `VK_LAYER_KHRONOS_validation`, synchronization validation |
| examples | 3 run, 0 failed (a nonzero count is enforced: `configFailOnEmpty`) |
| windows | 5 native windows made by the examples, each destroyed before its example ended |
| diagnostic verdict | clean, 68 records delivered, computed after the last teardown callback |
| native calls | 237; swapchains and surfaces destroyed before the device, device before messenger, instance last |

What the examples showed: two instances' windows exist at once; each success followed the owner's admission
(`readTargetStanding == TargetUsable`) and an empty scene was published to it; ending one instance destroyed only its window
after retirement while the peer's remained usable and no session stop was requested; a real creation cancelled before its
ticket was collected left the slot occupied until the late window had been closed and destroyed, after which a fresh
request succeeded; a genuine native close request made by the platform (`Hetoimasia.GLFW.NativeCheck.requestNativeClose`,
answer `NativeCloseDelivered`) was routed to exactly one session stop, left the window in place, and the instance's own
cleanup close added no second stop. No visual pixel and no completed GPU frame is claimed: readiness is the owner's
admission and the right to publish, as the contract says.

## Negative controls (broken once locally, never committed)

Each mutation was applied to the provider, the headless `window provider` group was rebuilt and run under
`HETOIMASIA_EXAMPLE_BOUND_SECONDS=6`, and the source was restored.

| Mutation | Result |
| --- | --- |
| a window counted retired once graphics retired, without the native window's destruction | 1 example failed: "closes a late native result once, and frees the slot only after native retirement" |
| the genuine close not routed to the stop endpoint | 2 failed: the routing examples (pending setup with capacity full; the race with the cleanup close) |
| the provider's own cleanup close routed to the stop endpoint | 3 failed: the late-result example, the peer-retirement example and "does not stop the session or a peer when only an instance's cleanup closes its window" |

Each failed within its bound and unwound its cleanup (the rig opens every hold and the provider's scope drains).

## Same-shape sweep

Shapes fixed: *a native thing exists before the record that tracks it.*

| Site | Shape | Result |
| --- | --- | --- |
| `Provider.issue` | creation command admitted by the host queue → token recorded | closed: the whole step is masked; `portIssueCreate` is a nonblocking submission |
| `Host.portIssueCreate` | `submitWindowCommand` accepted → ticket stored in the port's table | closed: masked in one step (found by this sweep) |
| `Host.attach` | `handOverVulkanTarget` returned an attachment → its service stored | closed: masked in one step; otherwise a second handover would meet an occupied slot, which is fatal (found by this sweep) |
| `Provider.stepOf` (created) | ticket outcome → window token recorded | one pump transaction reads the outcome and writes the token |
| `Provider.stepOf` (admitted → offered) | standing and target read → success claimed | one pump transaction; the answer runs after, and a non-adopted answer ends the acquisition |
| `adoptionFor` | resource built into the lease → acquisition marked adopted | one transaction on the owner's thread |
| `windowMainStep` | `portAttach` answered → phase recorded | a lost record repeats the attach, which the port turns into an announcement on the same attachment, never a second surface |
| `route` | stop endpoint called → newest number recorded | idempotent endpoint: a repeat is safe, a lost record only repeats it |
