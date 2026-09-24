# Vulkan validation diagnostics

Buildable package: `hetoimasia-gpu-vulkan-diagnostics`, in
`packages/gpu-vulkan/diagnostics`.

The header-free half of the backend's validation capture. A debug-utils
messenger's C callback copies capped records into storage this package owns —
latching an error before it attempts admission, counting what it drops, cuts or
cannot capture, and never waiting, allocating, writing, calling Vulkan or
raising — and a drain worker, in a foundation worker group the diagnostic
lifetime owns, delivers them through the caller's existing logger. The lifetime
is joined explicitly after the last callback-producing destruction, and its
verdict says whether the diagnostic evidence is complete and clean.

It includes no Vulkan header and depends on `hetoimasia-foundation` alone: no
binding, no loader, no GLFW, no runtime. It is listed in `cabal.project` and
`cabal.project.cpu`, so it builds and its suite runs with no Vulkan SDK present.
The native backend package in [`../native`](../native/README.md) installs its
callback on real messengers and checks its layout mirror against the Vulkan
headers at compile time.

| Component | What it is |
| --- | --- |
| `library capture` (private) | `capture/cbits/`: the C storage and producer; `Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture`, the Haskell view of both and the package-local producer entry its suite uses |
| `library outcome` (private) | `Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Outcome`: the lifetime's pure precedence between a body failure, a finalization cancellation and a worker-group closing failure, and the evidence kept beside the primary; private so its suite can drive it directly |
| `library` | `Hetoimasia.GPU.Vulkan.Diagnostics`: configuration, the lifetime, status, the verdict |
| `test-suite diagnostics-tests` | The `Vulkan diagnostics` group |

[`docs/vulkan_diagnostics.md`](../../../docs/vulkan_diagnostics.md) is the
contract in prose.

## Testing

`diagnostics-tests` is registered in `tools/validation/catalog.json` as the
non-optional CPU group `test.vulkan-diagnostics`, which runs through
`cabal.project.cpu`:

```
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-diagnostics:diagnostics-tests --test-show-details=direct
```
