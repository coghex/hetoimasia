# hetoimasia-math

Vectors, 4×4 matrices, affine transforms, a look-at view matrix and a
perspective projection, in 32-bit `Float`. The boundary this package keeps is
recorded in [module conventions](../../docs/module_conventions.md#an-independent-math-package):
its library depends on `base` alone — no other local package, no graphics
package, no foundation or runtime — and it chooses no graphics API's
conventions.

| Module | Contents |
| --- | --- |
| `Hetoimasia.Math.Vector` | `V2`, `V3`, `V4`; `add`, `sub`, `scale`, `dot`, `cross`, `norm`; checked `normalize` |
| `Hetoimasia.Math.Matrix` | `M44`; `identity`, `fromColumns`, `fromRows`, `columns`, `rows`, `element`, `toColumnMajor`, `multiply`, `apply`, `transpose` |
| `Hetoimasia.Math.Transform` | `translation`, `scaling`, checked `rotation` |
| `Hetoimasia.Math.Projection` | checked `lookAt`; `DepthRange`, `ClipY`, `Frustum` and checked `perspective` |

There is no collecting `Math` module or prelude: import the module that owns
what you use.

## Conventions

- **Scalars.** 32-bit `Float` throughout. Vector and matrix fields are strict.
- **Column vectors.** A matrix multiplies a column vector on its left,
  `M × v` (`apply m v`). In `multiply a b` the right operand, `b`, applies
  first. A `V4` point has `w = 1` and a direction `w = 0`; a translation moves
  a point and leaves a direction unchanged.
- **Handedness.** World and view space are right-handed. `cross x y` is `z`
  for the unit axes, and a positive `rotation` angle turns by the right-hand
  rule about its axis: a quarter turn about +Z takes +X to +Y. Angles are in
  radians.
- **View.** `lookAt eye target up` puts the eye at the origin looking down −Z,
  with +Y the component of `up` perpendicular to the view direction and +X to
  the right. The target lands on −Z at its distance from the eye.
- **Projection.** `perspective range clipY frustum` maps view space to
  homogeneous clip space, with `w` the distance in front of the eye. After
  division by `w`, the near plane reaches depth 0 (`ZeroToOne`) or −1
  (`NegativeOneToOne`) and the far plane depth 1; the top edge of the view
  reaches Y = 1 (`YUp`) or Y = −1 (`YDown`); the right edge reaches X = 1. The
  frustum's vertical field of view is in radians, and its aspect ratio is width
  over height. Which depth range and Y direction a graphics API needs is the
  renderer's choice, never this package's.

## Degenerate and non-finite input

Four operations are checked, and return `Maybe`. A `Just` result never
contains NaN or an infinity; each returns `Nothing` for a NaN or infinite
input, when the result it would calculate is not finite, and in these cases:

| Operation | Also `Nothing` when |
| --- | --- |
| `normalize` | the vector has zero length |
| `rotation axis angle` | the axis has zero length |
| `lookAt eye target up` | the target is the eye; `up` has zero length; `up` is parallel to the view direction, in either sense — the sine of the angle between them is below `parallelTolerance` (`1e-5`) |
| `perspective range clipY frustum` | the field of view is not strictly between 0 and π; the aspect ratio is not positive; the near plane is not positive; the far plane is not beyond the near plane |

`normalize` divides by the largest component magnitude before taking the
length, so a vector whose squared length would overflow or underflow still
normalizes. A rotation's axis need not be unit length.

Everything else — `add`, `sub`, `scale`, `dot`, `cross`, `norm`, the matrix
operations, `translation` and `scaling` — is ordinary IEEE `Float` arithmetic:
it overflows to an infinity and propagates NaN and infinities as its component
arithmetic does, and a caller that must exclude them checks its own inputs.

## No storage guarantee

The package promises no byte layout, alignment, packing or memory order for any
type. `M44`'s representation is private; `toColumnMajor` is a mathematical view
of its sixteen elements, column by column — element `(r, c)` is at position
`4c + r` — and not a description of how a matrix is stored. A backend that
uploads a matrix builds its own buffer from the elements; that packing, like
the choice of clip conventions, belongs to the renderer or backend.

## Tests

`math-tests` is the package's Hspec suite, registered as the CPU validation
group `test.math`:

```bash
cabal test --project-file cabal.project.cpu hetoimasia-math:math-tests --test-show-details=direct
```

It combines hand-written examples with QuickCheck properties over a stated
domain (components in [−100, 100], angles in [−2π, 2π]) and a tolerance of
`1e-4` relative, absolute near zero; `Test.Math.Support` documents both. A
separate generator biased to signed zeros, subnormals, the largest finite
values, infinities and NaN checks that no checked operation returns a
non-finite result. Hspec and QuickCheck are the suite's dependencies, not the
library's.
