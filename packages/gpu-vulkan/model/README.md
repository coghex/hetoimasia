# GPU retention and frame-ownership model

Buildable package: `hetoimasia-gpu-vulkan-model`, in `packages/gpu-vulkan/model`.

This is the binding-independent half of the Vulkan backend component, and it is
a separate package on purpose. The library's only project dependency is
`hetoimasia-foundation`, and its suite adds only the neutral
`hetoimasia-test-support` library; it depends on neither the Vulkan binding,
GLFW, the runtime nor a game, and nothing in it names a native type or performs
a native call. It is listed in both `cabal.project` and `cabal.project.cpu`, so its suite
stays buildable and runnable without a Vulkan SDK permanently. The later native
backend package under `packages/gpu-vulkan/` depends on this one; this one never
depends on it.

`packages/gpu-vulkan/README.md` describes the component as a whole.

## What it owns

One graphics session's bookkeeping, as a value the owning boundary threads:

- typed, unforgeable identities for the session, device, rendering targets and
  their incarnations, swapchain generations, image records, frame slots,
  recorded batches, submission records, presentation records, managed resource
  generations and allocation attempts;
- five separately tracked holds per generation and per managed resource, so a
  subject becomes eligible for disposal only when every one of them has ended;
- frame ownership phases with the obligations each retains and the exits that
  are legal from it;
- validated finite admission budgets whose exhaustion is typed backpressure;
- per-episode recovery accounting and a single-retry allocation attempt;
- bounded round-robin owner progress and the absolute deadline of the next turn.

## What it does not own

It proves no native completion and cannot: a submitted use and a presentation
obligation end only when the owning boundary supplies the fact through the
injected `EvidenceSource`. Elapsed time, a returned call, a cancellation and a
CPU scope exit are none of them evidence. Which native mechanism proved a fact is
deliberately absent from the fact.

The public API is `Hetoimasia.GPU.Model`, with the identities in
`Hetoimasia.GPU.Model.Identity` and the configuration in
`Hetoimasia.GPU.Model.Budget`. The implementation modules under
`Hetoimasia.GPU.Model.Internal` are hidden, which is what makes an identity
unforgeable: no client can build one. A validated `Budgets` is closed the same
way and for the same reason — no constructor and no field label reaches a
client, so the limits a model enforces are read-only to it and can only be the
ones `validateBudgets` accepted.

[`docs/gpu_model.md`](../../../docs/gpu_model.md) is the contract in prose.

## Testing

`gpu-model-tests` owns the `GPU model` group and is registered in
`tools/validation/catalog.json` as the non-optional CPU group `test.vulkan`,
which runs through `cabal.project.cpu`:

```
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-model:gpu-model-tests --test-show-details=direct
```

Every example is deterministic and ordering-based. Time enters through the
foundation's scripted clock, never through a sleep.

The budget opacity examples compile external single-module clients against this
build's own package database, so they need the qualified `ghc` on `PATH` — the
same compiler this suite was built with. They assert on the specific diagnostic
each rejection produces, so a missing package or an absent compiler fails rather
than passing as the boundary holding.
