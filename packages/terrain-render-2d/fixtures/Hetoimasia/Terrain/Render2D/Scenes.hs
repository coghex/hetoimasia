-- | The terrain material evidence's fixtures (TRA-8): every scene the CPU suite
-- and the native scenario judge, by name, built from the public terrain
-- interfaces with hand-stated cells. Nothing here calls the planner to produce
-- an expectation; the layout helper 'fitScene' sizes a target from the cells'
-- own hexagons.
--
-- The scenes, and what each distinguishes:
--
-- * 'shapeMatrix', 'singleShape': all 16 shape identities in a facing, each in a
--   cell of its own, with the two materials alternating, so every silhouette
--   and face orientation can be read and compared;
-- * 'roofOverCavity': a floor, a ring of walls and a roof over a cavity, cut at
--   the roof and below it (caps, and the cavity revealed);
-- * 'disconnectedSpans': a column with air between two solid spans beside
--   nearer columns whose projections overlap its upper span;
-- * 'rampsCorners': ramps and corners around a tall block, partial contacts;
-- * 'staircase': manual cutaways at several depths;
-- * 'followHeadroom': the automatic follow with the separate 25-level
--   headroom over authored varied heights;
-- * 'deepFloor': a surface 34 levels below the cut, deeper than a 32-level
--   storage band and inside the 250-level visibility cap, at zoom 1/8;
-- * the view variants: zoom endpoints, intermediate and fractional camera
--   settings, a viewport offset, a target's content scale and pixel snapping.
module Hetoimasia.Terrain.Render2D.Scenes
  ( -- * The matrix
    shapeMatrix
  , singleShape
    -- * Occlusion and cutaway
  , roofOverCavity
  , disconnectedSpans
  , rampsCorners
  , staircase
  , followHeadroom
  , deepFloor
  , diagnosticOverlap
    -- * View variants
  , zoomEndpoint
  , atZoom
  , capTarget
  , fractionalCamera
  , viewportOffset
  , scaledTarget
  , snapped
    -- * Layout
  , fitScene
  ) where

import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Render2D.Camera (camAnchorX, camAnchorY, camClip, camFacing, camRef)
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Shape (ViewFacing (..))

-- | The authored materials of the evidence: the approved loam and granite.
loam, granite ∷ String
loam = "loam"
granite = "granite"

flat ∷ Integer → Integer → Integer → Integer → String → Cell
flat x y z0 z1 = Cell x y z0 z1 0

-- ---------------------------------------------------------------------------
-- The matrix

-- | The sixteen shape identities, shape @4 r + c@ in row @r@ and column @c@, in
-- staggered rows of four whose hexagons touch but never overlap (rows 72 pixels
-- apart, every other row half a tile off), loam and granite alternating by row.
-- Sized and centred on its own hexagons.
shapeMatrix ∷ ViewFacing → Float → Scene
shapeMatrix facing zoom =
  fitScene 8 $
    (newScene ("matrix-" <> show facing <> "-" <> show zoom) cells (64, 64))
      { sceneFacing = facing
      , sceneZoom = zoom
      , sceneAnchor = (1, 1)
      }
  where
    cells =
      [ Cell x y 0 1 (fromInteger (4 * r + c)) (if even r then loam else granite)
      | r ← [0 .. 3]
      , c ← [0 .. 3]
      , let s = r `mod` 2
      , let x = (3 * r + 2 * c + s) `div` 2
      , let y = (3 * r - 2 * c - s) `div` 2
      ]

-- | One cell of a shape in a facing, in a target sized to its hexagon.
singleShape ∷ Int → ViewFacing → Scene
singleShape shape facing =
  fitScene 4 $
    (newScene ("shape-" <> show shape <> "-" <> show facing) [Cell 0 0 0 1 shape loam] (64, 64))
      {sceneFacing = facing}

-- ---------------------------------------------------------------------------
-- Occlusion and cutaway

-- | A 3 × 3 floor at level 0, a ring of walls around a 1 × 1 cavity at level 1
-- and a roof over all of it at level 2, cut at the given level (2 shows the roof;
-- 1 removes it and shows the walls' caps and the cavity's floor).
roofOverCavity ∷ Integer → ViewFacing → Scene
roofOverCavity cut facing =
  fitScene 8 $
    (newScene ("roof-cut" <> show cut <> "-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = ManualAt cut cut
      , sceneAnchor = (1, 1)
      }
  where
    square = [(x, y) | x ← [0 .. 2], y ← [0 .. 2]]
    cells =
      [flat x y 0 1 loam | (x, y) ← square]
        <> [flat x y 1 2 granite | (x, y) ← square, x `elem` [0, 2] || y `elem` [0, 2]]
        <> [flat x y 2 3 loam | (x, y) ← square]

-- | A column with solid levels 0..1 and 4..5 and air between, with columns
-- toward the camera whose projections overlap the upper span, and a column away
-- from it.
disconnectedSpans ∷ ViewFacing → Scene
disconnectedSpans facing =
  fitScene 8 $
    (newScene ("spans-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = ManualAt 5 5
      }
  where
    cells =
      [ flat 0 0 0 2 loam
      , flat 0 0 4 6 granite
      , flat 1 1 0 3 loam
      , flat 1 0 2 4 granite
      , flat (-1) (-1) 0 7 loam
      , flat 2 2 0 1 granite
      ]

-- | A 3 × 3 patch of ramps and corners around a flat block two levels high, and
-- a tall block behind it: every one of the eight ramp and corner identities
-- around it meets a neighbour partially.
rampsCorners ∷ ViewFacing → Scene
rampsCorners facing =
  fitScene 8 $
    (newScene ("ramps-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = ManualAt 3 3
      , sceneAnchor = (1, 1)
      }
  where
    cells =
      [ Cell 0 0 0 1 3 loam
      , Cell 1 0 0 1 1 granite
      , Cell 2 0 0 1 9 loam
      , Cell 0 1 0 1 8 granite
      , Cell 1 1 0 2 0 loam
      , Cell 2 1 0 1 2 granite
      , Cell 0 2 0 1 12 loam
      , Cell 1 2 0 1 4 granite
      , Cell 2 2 0 1 6 loam
      , Cell (-1) (-1) 0 4 5 granite
      ]

-- | Columns of height 1 to 6 along a row, cut at the given level: the cut
-- exposes caps on every column at least that tall.
staircase ∷ Integer → ViewFacing → Scene
staircase cut facing =
  fitScene 8 $
    (newScene ("stairs-cut" <> show cut <> "-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = ManualAt cut cut
      , sceneAnchor = (2, 0)
      }
  where
    cells = [flat i 0 0 (i + 1) (if even i then loam else granite) | i ← [0 .. 5]]

-- | The anchor column four levels high (surface 3) in the middle of columns
-- 12 to 40 levels high, following: the clip level is the surface plus 25 (28),
-- so the tall columns are cut flat at level 28 and the lower ones show their
-- own tops.
followHeadroom ∷ ViewFacing → Scene
followHeadroom facing =
  fitScene 8 $
    (newScene ("follow-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = FollowSurface
      }
  where
    cells =
      [ flat 0 0 0 4 loam
      , flat 2 1 0 40 granite
      , flat (-2) 1 0 12 loam
      , flat 1 (-2) 0 30 granite
      ]

-- | A tower 34 levels high on a floor, cut at its top, seen with the vertical
-- reference on the floor at zoom 1/8: the floor is 34 levels below the cut, more
-- than a 32-level storage band and inside the 250-level visibility cap.
deepFloor ∷ ViewFacing → Scene
deepFloor facing =
  fitScene 8 $
    (newScene ("deep-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneZoom = 0.125
      , sceneMode = ManualAt 0 (-34)
      }
  where
    cells =
      [flat x y (-34) (-33) granite | x ← [0 .. 2], y ← [0 .. 2]]
        <> [flat 1 1 (-33) 1 loam]

-- | Four cells of the technical diagnostic sheet (not artwork) whose
-- projections overlap with no two sharing a face, so a transparent part of a
-- nearer cell's sheet shows what lies behind: a flat cell, a ramp one level above
-- and one over diagonally, a corner and a ramp to either side of it.
diagnosticOverlap ∷ ViewFacing → Scene
diagnosticOverlap facing =
  fitScene 8 $
    (newScene ("diagnostic-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneMode = ManualAt 2 2
      }
  where
    cells =
      [ Cell 0 0 0 1 0 "diagnostic"
      , Cell 0 0 2 3 0 "diagnostic"
      , Cell 1 1 1 2 3 "diagnostic"
      , Cell (-1) 1 0 1 5 "diagnostic"
      , Cell 2 0 1 2 9 "diagnostic"
      ]

-- ---------------------------------------------------------------------------
-- View variants

-- | The ramps and corners at the given zoom (the configured endpoints 0.125 and 8
-- and the values between), the target no larger than 192 × 128 pixels so that a
-- zoomed-in view shows the middle of the patch rather than all of it.
zoomEndpoint ∷ Float → Scene
zoomEndpoint zoom = capTarget (192, 128) (fitScene 8 ((rampsCorners FaceSouth) {sceneName = "zoom-" <> show zoom, sceneZoom = zoom, sceneMode = ManualAt 2 1}))

-- | A scene's target no larger than this extent, aimed at its anchor tile (a
-- fraction of a pixel off its centre, as 'fitScene' leaves it) rather than at the
-- middle of its cells, so a zoomed-in view shows the tile it is anchored on.
capTarget ∷ (Int, Int) → Scene → Scene
capTarget (cw, ch) sc =
  sc
    { sceneTarget = (w, h)
    , sceneLogical = (w `div` scaleOf, h `div` scaleOf)
    , sceneViewport = (0, 0, fromIntegral w, fromIntegral h)
    , scenePan = if sceneSnap sc then (0.2, 0.12) else (0.0048, 0.0226)
    }
  where
    (w0, h0) = sceneTarget sc
    scaleOf = round (sceneScale sc) ∷ Int
    w = min w0 cw
    h = min h0 ch

-- | A pan that leaves the camera a fraction of a tile off the anchor's centre,
-- at an intermediate zoom.
fractionalCamera ∷ Scene
fractionalCamera =
  let fitted = fitScene 40 ((rampsCorners FaceWest) {sceneName = "fractional", sceneZoom = 1.5})
      (px, py) = scenePan fitted
   in fitted {scenePan = (px + 0.3, py - 0.2)}

-- | The ramps and corners in a viewport that starts away from the target's
-- corner and stops short of its far edge: the rest of the target is the clear
-- colour.
viewportOffset ∷ Float → Scene
viewportOffset zoom =
  base
    { sceneName = "viewport@" <> show zoom
    , sceneViewport = (fromIntegral x, fromIntegral y, fromIntegral (w - x - x'), fromIntegral (h - y - y'))
    }
  where
    -- Fitted first: the viewport is set after the refit would have overwritten it.
    base = atZoom zoom (rampsCorners FaceNorth)
    (w, h) = sceneTarget base
    (x, y) = (w `div` 4, h `div` 8)
    (x', y') = (w `div` 8, h `div` 4)

-- | The ramps and corners on a target of content scale 2: its logical extent is
-- half its framebuffer's.
scaledTarget ∷ Scene
scaledTarget = fitScene 8 ((rampsCorners FaceEast) {sceneName = "scaled", sceneScale = 2})

-- | The ramps and corners with pixel snapping on at zoom 2 (a whole multiple of
-- 1/8, which every face origin needs, and one at which no sample falls near a
-- texel boundary), the camera a fraction of a pixel off the
-- pixel grid ('capTarget' gives a snapping scene one), so that snapping moves the
-- view's translation to the pixel grid and the image differs from the unsnapped
-- one.
snapped ∷ Scene
snapped = capTarget (96, 64) (fitScene 3 ((rampsCorners FaceSouth) {sceneName = "snapped", sceneSnap = True, sceneZoom = 2, sceneMode = ManualAt 2 1}))

-- ---------------------------------------------------------------------------
-- Layout

-- | A scene at another zoom, sized and aimed again from its own cells.
atZoom ∷ Float → Scene → Scene
atZoom zoom sc = fitScene 3 sc {sceneZoom = zoom, sceneName = sceneName sc <> "@" <> show zoom}

-- | Size a scene's target, and aim its camera, from the hexagons of its own
-- cells: the camera is panned so the union of the hexagons is centred, and the
-- target is that union, in pixels at the scene's zoom, with a margin of this
-- many framebuffer pixels (rounded up to an even extent). A layout helper only:
-- no expectation depends on it.
fitScene ∷ Int → Scene → Scene
fitScene margin input =
  sc
    { sceneTarget = (w, h)
    , sceneLogical = (w `div` scaleOf, h `div` scaleOf)
    , sceneViewport = (0, 0, fromIntegral w, fromIntegral h)
    , scenePan = (fromRational px + nudgeX, fromRational py + nudgeY)
    }
  where
    -- A fraction of a pixel, so that no pixel centre of a zoom that divides the
    -- tile lattice falls exactly on a texel boundary or an edge (not with pixel
    -- snapping, which would round the camera away).
    (nudgeX, nudgeY) = if sceneSnap input then (0, 0) else (0.0048, 0.0226)
    -- The camera as the anchor's centre sees it, before any pan.
    sc = input {scenePan = (0, 0)}
    camera = sceneCameraFollowed sc
    count = case camFacing camera of
      FaceSouth → 0
      FaceWest → 3
      FaceNorth → 2
      FaceEast → 1 ∷ Int
    anchorX = toInteger (axisValue (camAnchorX camera))
    anchorY = toInteger (axisValue (camAnchorY camera))
    clip = toInteger (axisValue (camClip camera))
    ref = camRef camera
    turn ∷ Num a ⇒ Int → (a, a) → (a, a)
    turn n (dx, dy) = iterate (\(a, b) → (negate b, a)) (dx, dy) !! (n `mod` 4)
    -- The hexagon of a unit cell: 96 × 64 from (-48, -16) of its origin's projection.
    hexagons =
      [ (ox - 48, ox + 48, oy - 16, oy + 48)
      | c ← sceneCells sc
      , z ← [cellZ0 c .. min (cellZ1 c - 1) clip]
      , let (vx, vy) = turn count (cellX c - anchorX, cellY c - anchorY)
      , let ox = 48 * fromInteger (vx - vy) ∷ Rational
      , let oy = 24 * (fromInteger (vx + vy) - 1) - 16 * fromInteger (z - ref) ∷ Rational
      ]
    x0 = minimum [a | (a, _, _, _) ← hexagons]
    x1 = maximum [b | (_, b, _, _) ← hexagons]
    y0 = minimum [c | (_, _, c, _) ← hexagons]
    y1 = maximum [d | (_, _, _, d) ← hexagons]
    -- A following scene stays on its anchor column, which decides the surface it
    -- follows: the camera is not panned away, and the target is made large enough
    -- about the anchor to hold every hexagon instead.
    follow = sceneMode sc == FollowSurface
    centre = if follow then (0, 0) else ((x0 + x1) / 2, (y0 + y1) / 2)
    halfWidth = if follow then max (abs x0) (abs x1) else (x1 - x0) / 2
    halfHeight = if follow then max (abs y0) (abs y1) else (y1 - y0) / 2
    zoom = toRational (sceneZoom sc)
    evenUp n = let m = ceiling n ∷ Integer in fromInteger (m + m `mod` 2) ∷ Int
    w = evenUp (zoom * 2 * halfWidth + 2 * fromIntegral margin) * scaleOf
    h = evenUp (zoom * 2 * halfHeight + 2 * fromIntegral margin) * scaleOf
    scaleOf = round (sceneScale sc) ∷ Int
    -- The view-frame shift that puts the camera at the centre, then back to the world axes.
    vx' = (fst centre / 48 + snd centre / 24) / 2
    vy' = (snd centre / 24 - fst centre / 48) / 2
    (px, py) = turn (4 - count) (vx', vy')
