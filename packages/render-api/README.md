# hetoimasia-render-api

Backend-independent rendering contracts. Today the package holds one: the
opaque texture handle that game code stores and a backend resolves. The
decision record is [the 2D renderer design](../../docs/designs/render_2d_design.md)
(D-12, R2D-1); the package's place among the others is
[the foundation design](../../docs/engine_foundation_design.md).

| Module | Audience | Contents |
| --- | --- | --- |
| `Hetoimasia.Render.Api.Texture` | game code | `TextureHandle`, abstract: `Eq`, `Ord` and `Show` only |
| `Hetoimasia.Render.Api.Texture.Backend` | backends, and tests standing in for one | `textureHandle ∷ Word32 → Word32 → TextureHandle`; `handleIndex` and `handleGeneration` read both numbers back |

There is no collecting module and no prelude: import the module that owns what
you use.

## Boundary

The library's `build-depends` names `base` alone. It imports no Vulkan, Lua,
runtime or game package and no other local package, reads no file and performs
no IO. A change that needs more belongs in a package that depends on this one.
The package builds and tests in the CPU project (`cabal.project.cpu`).

## The handle

A `TextureHandle` is a 32-bit lookup index and a 32-bit generation, the
representation `Hetoimasia.GPU.Model.TextureTable`'s handle has (#343). The
GPU model is a Vulkan-side package and game code cannot depend on it, so this
package carries the backend-independent twin; migrating the GPU table to it is
outside this package.

- **Opaque to game code.** The public module exports the type and, through its
  instances, comparison, ordering and `show`. It exports neither the
  constructor nor a field reader, so game code can neither build a handle nor
  take one apart, and record update cannot reach one either. Handles order by
  index, then by generation, and `show` prints both numbers, index first.
- **Backend-facing construction.** `Hetoimasia.Render.Api.Texture.Backend` is
  the deliberate door: a backend that registers textures mints handles with
  `textureHandle`, and reads them back with `handleIndex` and
  `handleGeneration`. It checks nothing and every pair of `Word32` values is a
  handle, a zero generation included, because what an index and a generation
  mean belongs to the backend that issues them. The GPU model's table never
  issues a zero generation and resolves one that arrives to its placeholder.
- **No run-time cost for opacity.** The handle is a record of two strict,
  unpacked `Word32` fields; opacity comes only from what the public module
  exports, so constructing, comparing and encoding a handle cost what the raw
  values cost.

## Owned state, threads and lifetimes

None: every value is pure and immutable. The package starts no thread, owns no
resource and holds no mutable state. A handle names a texture a backend owns;
holding one keeps nothing alive, and whether it still resolves is the
backend's question.

## Tests

`render-api-tests` is the package's Hspec suite, registered as the CPU
validation group `test.render-api`:

```bash
cabal test --project-file cabal.project.cpu hetoimasia-render-api:render-api-tests --test-show-details=direct
```

It checks construction and access at every `Word32` edge in every pairing of
index and generation, and over generated values; equality, ordering and
`show`; and, through separately compiled external clients that expose only
`base` and this package, that the public module supplies the instances but not
the constructor, a field reader, record update or the backend's construction
function, while the backend-facing module builds and reads a handle. Hspec,
QuickCheck and the external-client harness are the suite's dependencies, not
the library's.
