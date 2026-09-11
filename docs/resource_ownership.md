# Resource ownership proposal

Status: discussion input for FND-1 in the [foundation design](engine_foundation_design.md).
None of the resource APIs below is implemented. The current runtime only logs
and invokes a caller-supplied action.

## Preserve the useful part of Synarchy

Synarchy's `src/Engine/Core/Resource.hs` gives an allocation a continuation scope.
Its `allocResource'` also separates allocation order from cleanup order; the
buffer helper uses this to arrange buffer destruction before releasing backing
memory. Those are useful lifetime decisions. They do not require a monad tied
to the entire EngineEnv, and moving to smaller owners need not discard them.

Evaluate a continuation interface after specifying and testing its semantics.
Implement any such interface over exception-safe acquisition/release primitives.
CPS alone supplies neither asynchronous-exception safety nor GPU synchronization.

## Owners and scopes

One subsystem owns each resource's mutation and destruction. Consumers receive
operations or opaque handles. Private IORefs and mutable arrays are legitimate
implementation choices; exposing them through an application-wide environment
makes the owner and allowed lifetime difficult to enforce.

| Owner | Owns | Ends or resets when |
|---|---|---|
| Application | Service composition | Process shutdown |
| Vulkan backend | Device, allocation machinery, completion tracking | All children and submitted uses have been retired |
| Swapchain generation | Its targets, views, and related state | Replacement is ready and old graphics/presentation uses have completed |
| Frame slot | Command pools, upload slices, transient descriptors | That slot's previous GPU uses have completed |
| Asset store | Shared CPU assets and GPU residency records | Explicit leases are released, then outstanding GPU uses complete |
| Game session | World state, session workers, asset leases | Session exit or load/restart |
| Lua host | VM and its registered bindings | Host scope ends after its users stop |

The asset store knows assets, references, and GPU residency. The game decides
which assets a world needs. A game object holds a mesh/texture identifier or
lease, not a Vulkan pointer. Generational handles can detect stale identifiers;
they do not by themselves establish ownership or keep GPU allocations alive.

Ordinary game state is Haskell data and is reclaimed normally when unreachable.
Foreign allocations, file handles, workers, and GPU resources need explicit
lifetime management. Ending a session cancels and joins its workers before
releasing the services they borrow.

## CPU acquisition and failure

Start with subsystem `with...` functions built on `bracket`. A constructor that
performs several allocations must unwind its own partial initialization. Register
each successful acquisition's cleanup before cancellation can strand it. Keep
each native dependency order inside the subsystem that understands it.
See [Control.Exception](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:bracket)
for acquisition/release masking and its interruption limits.

Illustrative composition, with names that are still proposals:

```haskell
withGpu logger gpuConfig $ \gpu →
  withAssetStore logger gpu $ \assets →
    withGameSession gameConfig assets $ \session →
      runGame session
```

Each callback borrows its arguments. These ordinary types do not statically
prevent a handle from escaping; document borrowing and keep constructors/raw
handles private. Consider region types only if practical misuse warrants them.
Each service gets only its actual dependencies. `withGpu` must quiesce its GPU
work before native destruction; nested callbacks alone do not establish that.

Specify what happens when cleanup itself fails before implementing FND-1.
Remaining cleanup must still be attempted, diagnostics must not obstruct it,
and the failure policy must account for both an original and a cleanup error.
Do not put unbounded GPU waits inside `uninterruptibleMask`.

## GPU retirement

CPU scope exit and GPU completion are separate events. Vulkan requires pending
uses to complete before destruction, and destroying referenced resources also
affects recorded command buffers. See the specification's
[object lifetime rules](https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#fundamentals-objectmodel-lifetime)
and [command buffer lifecycle](https://docs.vulkan.org/spec/latest/chapters/cmdbuffers.html#commandbuffers-lifecycle).

For a dynamic texture, the proposed sequence is:

1. Release its last application lease; prevent new recording/submission from
   acquiring it, and invalidate or rebuild cached recordings that reference it.
2. Transfer its native cleanup to the backend's retirement queue, retaining
   the completion points covering every outstanding use.
3. Run cleanup and recycle allocations/descriptor slots only after those points
   complete. Releasing an application handle is not an immediate Vulkan free.

Publication, submission, and retirement need one defined synchronization owner
so a new use cannot race the last-use decision. Start with a single submission
owner and queue if the first scene permits it. Multiple independent queues need
completion evidence for each; their timeline values are not interchangeable.
Presentation lifetime also needs its own completion reasoning.

For the first device/offscreen probe, an explicit idle wait at teardown is a
reasonable starting point. Introduce deferred retirement when dynamic lifetimes
require it. Do not wait for device idle on every frame or allocation.

## First implementation and Hspec evidence

FND-1 should prove CPU ownership with fake resources before introducing Vulkan:

- Success and action failure release each acquired resource exactly once.
- Failure at each acquisition step cleans up earlier acquisitions in the
  specified dependency order.
- Controlled asynchronous cancellation cannot strand a successful acquisition;
  coordinate with MVars or equivalent signals, without timing sleeps.
- Cleanup failures obey the selected error policy and do not skip other owners.

When GPU retirement is introduced, test its decision logic in Hspec with fake
completion points: no premature free or slot reuse, no double release, correct
handling of shared leases and stale handles. Then exercise the real backend
with Hspec-driven Vulkan validation and offscreen integration tests where possible.
Use Python only where Hspec cannot reasonably drive the required boundary.
