# TRA-7 CPU evidence for Q-13: ordering and picking of terrain faces

Issue #643 (TRA-7), epic #636. This records what the pure planner
(`packages/terrain-render-2d`) establishes on the CPU about ordering the shared
terrain faces through the existing instance ABI, which cases it found
unsupported, and what remains for TRA-8 (#644). It is not an offscreen or pixel
result and makes no performance claim.

## What was checked

The existing ABI gives each instance one transformed unit square and one depth
key in `[0, 2^24)`, a larger key nearer (`packages/render-2d/README.md`, "The
quad an instance places" and "Ordering within a layer"). A terrain face is a
convex polygon in a plane, so each is planned as a quad (the image of the unit
square) plus a coverage mask (the polygon in the unit square). The planner derives
a total order from the exact front/back relation between overlapping faces and
uses each face's position as its key.

Every planned scene was compared with an independent oracle that casts an exact
ray through every cell of the scene at or below the cut with the terrain
package's `castRay`, and reports the nearest face entered. For a lattice of
render-world points the plan's pick had to name the same tile and the same
view-frame face kind, or report open sky.

## Fixture matrix (committed, `terrain-render-2d-tests`)

Each scene is compared at a lattice of 36 x 24 = 864 render-world points (step 13
pixels, offset off the lattice lines) in each of the four facings: 24
scene/facing examples. Each example also requires that more than 60 of its
lattice points meet terrain, so agreement cannot be vacuous.

| Scene | Cut | What it exercises |
| --- | --- | --- |
| Ground with a floating tower | 10 | roofs over a gap, a disconnected span whose projection overlaps the ground behind it |
| Ramps, corners and a high block | 10 | ramp, corner and tent tops meeting a two-level block, wall contacts |
| Roof over a cavity, cut below the roof | 1 | a cavity ceiling hidden or removed by the cut, floor and wall exposure |
| Roof over a cavity, cut at the roof | 2 | the roof's cap, the cavity hidden |
| All sixteen shapes | 5 | every shape ID in a grid with a stepped block behind, in all four facings |
| Disconnected spans | 8 | separate spans in one column and neighbouring columns at different levels |

In addition, a generated property plans 150 random scenes (a nonempty list of
distinct cells of any of the 16 shapes in a 4 x 4 x 4 box, random facing and a cut
from 0 to 4) and requires no refusal and agreement with the oracle at a 28 x 18
lattice. The same property was run once locally with 2,500 scenes of a larger box
(6 x 6 x 5 cells, two generated lists joined), which is not committed.

## Result

- **No ordering counterexample was found.** No scene, facing or generated case was
  refused as `OrderingCycle`, `OrderingCrossing` or `OrderingCoincident`, and
  every sampled pick equalled the oracle's nearest face. The Q-13 stop path was
  therefore not taken for the geometry the CPU can reach.
- **No unsupported case is retained.** The refusal path is present and typed; the
  committed suite does not contain a failing fixture because none was found. The
  refusals carry the faces involved as the counterexample if one occurs.
- The order is total and distinct per plan: keys `0 .. n - 1`, below `2^24`,
  independent of the enumeration order of the input cells (checked by reversing
  and permuting the cell list).

## Negative controls

Pixel snapping at world scales that are not a multiple of 1/8 is refused, because the
recorder's separate rounding of each instance origin opens cracks between
adjacent faces (found in review round 1). Each protected behaviour was broken once locally, keeping the scenario, and the
suite failed; none is committed.

| Mutation | Examples that failed |
| --- | --- |
| Reverse the back-to-front key order | 25 |
| Drop the cutaway caps | 29 |
| Pick the backmost face | 23 |
| Treat an unavailable neighbour as air | 1 |
| Full-block shortcut for wall contacts | 10 |
| Include cells above the cut | 12 |
| Accept mixed versions | 1 |
| Ignore the configured band depth | 2 |
| Show a top covered by a solid | 4 |
| Accept snapped views at any zoom (adjacent faces then crack) | 2 |
| Symmetric chunk range (drops the lowest chunk of the margin) | 1 |
| Collect every pair of a bucket before checking the pair bound | 1 |
| Ignore the framebuffer extent | 1 |
| No maximum visibility depth | 1 |
| Skip the representability check | 1 |
| Judge snapping by the camera zoom, not the mapping's scale | 1 |
| Ask for levels outside the supported range | 1 |
| `refollow` skips configuration validation | 1 |
| `completeJump` skips configuration validation | 1 |
| Stamp the camera revision against the clamped camera | 1 |

## Claims left for TRA-8

This evidence is about geometry, order and picking. TRA-8 still has to qualify,
offscreen, the actual material and transparent-coverage behaviour of the masks, the
depth-buffer and ordered-path behaviour with these keys, the cutout/ordered
routing of the planned instances, and the visual matrix of all 16 identities in all
four facings. A planned face whose mask is not a full parallelogram (a triangle, a
trapezoid) relies on the material discarding or blending outside the mask; that
is TRA-8's to prove and is not asserted here.
