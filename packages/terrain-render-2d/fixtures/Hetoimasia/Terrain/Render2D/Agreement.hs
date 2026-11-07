-- | At determinate pixel centres, three answers must agree with a fourth that
-- shares no code with them (a support component of the terrain material's CPU
-- suite and its native evidence scenario, which both judge with it): the planner's face coverage and depth order, the
-- terrain material's pure model, and the pure pick's frontmost cell and face,
-- against the hand-stated line-of-sight expectation of
-- "Hetoimasia.Terrain.Render2D.Evidence".
--
-- 'judge' walks a scene's pixel centres, on a stride, and reports every
-- disagreement; the negative controls hand it a deliberately wrong set of faces
-- or a wrong picker, keeping the scene that makes the protected behaviour matter,
-- and require it to disagree.
module Hetoimasia.Terrain.Render2D.Agreement
  ( Env (..)
  , envWith
  , Judged (..)
  , Config (..)
  , normal
  , backmost
  , judge
  , stride
  , surfaces
  , handleFor
  , styleOf
  , faceSurface
  , surfaceTint
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Hetoimasia.Math.Affine2 (columns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Mapping (targetToWorld)
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialInput (..), MaterialModel (..), ModelFault (..))
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Data.Word (Word8)
import Hetoimasia.Terrain.Geometry (Face (..), FaceKind (..), Plane (..), V3 (..), shapeSolid, solidFaces)
import Hetoimasia.Terrain.Render2D.Camera (camFacing)
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Pick
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (Rect (..), rvMapping)
import Hetoimasia.Terrain.Shape (Side (..), ViewFacing, viewShape)

-- | The sheets of an environment, by authored material name.
newtype Env = Env (Map.Map String ArtPixels)

-- | An environment of these named sheets.
envWith ∷ [(String, ArtPixels)] → Env
envWith = Env . Map.fromList

-- | The handle a material's sheet is registered under in these checks.
handleFor ∷ Env → String → TextureHandle
handleFor (Env sheets) name = textureHandle (fromIntegral (1 + length (takeWhile (/= name) (Map.keys sheets)))) 1

-- | The style the checks adapt faces with.
styleOf ∷ Env → TerrainStyle
styleOf env@(Env sheets) =
  styleFromList
    [ (either (error . show) id (mkMaterialId name), isoSheet (handleFor env name))
    | name ← Map.keys sheets
    ]

-- | The sheet registered under a handle.
sheetBy ∷ Env → TextureHandle → Maybe ArtPixels
sheetBy env@(Env sheets) handle = case [sheet | (name, sheet) ← Map.toList sheets, handleFor env name == handle] of
  sheet : _ → Just sheet
  [] → Nothing

-- | What one scene's judgement found.
data Judged = Judged
  { judgedCompared ∷ !Int
  -- ^ Pixels with a determinate expectation, a decided coverage and a decided model.
  , judgedSkipped ∷ !Int
  -- ^ Pixels left out as ambiguous: the hand-stated expectation, an edge, a texel
  -- boundary or a mask edge decided nothing there.
  , judgedMismatches ∷ ![String]
  , judgedHoles ∷ !Int
  -- ^ Compared pixels at which the geometric frontmost cell's sheet is transparent:
  -- what is seen is a cell behind it, or the clear colour.
  , judgedReveals ∷ !Int
  -- ^ Of those, the pixels at which a cell behind the frontmost is what is seen.
  , judgedCovered ∷ !Int
  }

-- | What a judgement is given besides the scene: how the plan's faces are changed
-- before they are adapted and judged, and how a pick is answered.
data Config = Config
  { configFaces ∷ [PlannedFace] → [PlannedFace]
  , configPick ∷ Plan → V2 → Maybe (Integer, Integer, Integer, FaceKind)
  }

-- | The plan as it is, and the pure pick as it is.
normal ∷ Config
normal = Config id realPick
  where
    realPick plan point = case pickPlan plan (PickQuery (planIdentity plan) point) of
      Right (PickHit face) → Just (cellOf face)
      _ → Nothing

-- | A deliberately wrong picker, for a negative control: the backmost face whose
-- polygon holds the point, as if a nearer face were transparent to picking.
backmost ∷ Config
backmost = normal {configPick = pickBackmost}
  where
    pickBackmost plan (V2 x y) = case targetToWorld (rvMapping (planView plan)) (V2 x y) of
      Just (V2 wx wy) → case [f | f ← sortOn faceDepthKey (planFaces plan), locate (facePolygon f) (toRational wx, toRational wy) == In] of
        f : _ → Just (cellOf f)
        [] → Nothing
      Nothing → Nothing

-- | The plane of a planned face as the hand-stated expectation names it, from
-- the view-frame solid of its shape: @e@ and @s@ the East and South walls, @F@ the
-- flat top, and a ramp by the side it is lowered on, read from its outward
-- normal's horizontal part (north @(0, -1)@, east @(1, 0)@, south @(0, 1)@, west
-- @(-1, 0)@).
faceSurface ∷ ViewFacing → PlannedFace → Char
faceSurface facing face = case drop (faceIndex face) (solidFaces (shapeSolid (viewShape facing (faceShape face)))) of
  Face {faceKind = WallFace East} : _ → 'e'
  Face {faceKind = WallFace _} : _ → 's'
  Face {faceKind = TopFace, facePlane = Plane (V3 nx ny _) _} : _ →
    case (signum nx, signum ny) of
      (0, 0) → 'F'
      (0, -1) → 'N'
      (1, 0) → 'E'
      (0, 1) → 'S'
      (-1, 0) → 'W'
      _ → '?'
  _ → '?'

-- | The diagnostic tint of each plane, stated by hand: a technical aid that makes
-- every face of every shape visibly its own colour, not artwork. Opaque.
surfaceTint ∷ Char → (Word8, Word8, Word8)
surfaceTint = \case
  'F' → (255, 255, 255)
  'N' → (255, 150, 150)
  'E' → (150, 255, 150)
  'S' → (150, 150, 255)
  'W' → (255, 255, 130)
  'e' → (255, 190, 80)
  's' → (100, 200, 255)
  _ → (255, 0, 255)

cellOf ∷ PlannedFace → (Integer, Integer, Integer, FaceKind)
cellOf face = (coordinate tileX, coordinate tileY, coordinate tileZ, faceViewKind face)
  where
    coordinate axisOf = toInteger (axisValue (axisOf (faceCell face)))

-- | A stride that leaves about this many pixels of a target.
stride ∷ Int → (Int, Int) → Int
stride wanted (w, h) = max 1 (ceiling (sqrt (fromIntegral (w * h) / fromIntegral wanted ∷ Double)))

-- | Which side of an edge a point is, exactly, for a convex polygon of either
-- orientation: inside (every cross product of one sign or zero), outside, or on an edge.
data Where = In | Out | OnEdge
  deriving stock (Eq)

locate ∷ [(Rational, Rational)] → (Rational, Rational) → Where
locate polygon (px, py)
  | any (== 0) crosses && not clearlyOut = OnEdge
  | any (> 0) crosses && any (< 0) crosses = Out
  | otherwise = In
  where
    edges = zip polygon (drop 1 polygon <> take 1 polygon)
    crosses = [(bx - ax) * (py - ay) - (by - ay) * (px - ax) | ((ax, ay), (bx, by)) ← edges]
    clearlyOut = any (> 0) crosses && any (< 0) crosses

-- | The pixel centres judged: every @stride@-th column and row, from an offset.
sampled ∷ Int → (Int, Int) → [(Int, Int)]
sampled step (w, h) = [(x, y) | y ← [2, 2 + step .. h - 1], x ← [2, 2 + step .. w - 1]]

-- | The plane the hand-stated expectation finds at each covered pixel of a scene,
-- on a stride: the scene's partition into faces, which two shapes with the same
-- outline do not share.
surfaces ∷ Env → Scene → Int → [((Int, Int), Char)]
surfaces (Env sheets) sc step =
  [ (pixel, hitSurface hit)
  | pixel ← sampled step (sceneTarget sc)
  , ExpectedHit {expectedFront = hit} ← [expectedAt (`Map.lookup` sheets) sc camera plan pixel]
  ]
  where
    camera = sceneCameraFollowed sc
    plan = either (\e → error ("surfaces plan: " <> show e)) id (scenePlan sc)

-- | Judge one scene on a stride of its pixel centres. For a scene whose view snaps,
-- only the pick is compared (see below).
judge ∷ Env → Config → Int → Scene → Judged
judge env config step sc = foldr tally (Judged 0 0 [] 0 0 0) (map one (sampled step (sceneTarget sc)))
  where
    camera = sceneCameraFollowed sc
    plan = either (\e → error ("judged scene plan: " <> show e)) id (scenePlan sc)
    Env sheets = env
    faces = sortOn (Down . faceDepthKey) (configFaces config (planFaces plan))
    adapted = either (\e → error ("judged scene adaptation: " <> show e)) id (adaptFaces (styleOf env) faces)
    entries = zip faces (adaptedFaces adapted)
    scale = sceneScale sc

    tally verdict (Judged n s ms h r c) = case verdict of
      Skipped → Judged n (s + 1) ms h r c
      Compared ms' hole reveal covered' → Judged (n + 1) s (ms' <> ms) (h + fromEnum hole) (r + fromEnum reveal) (c + fromEnum covered')

    one pixel@(px, py) = case expectedAt (`Map.lookup` sheets) sc camera plan pixel of
      Ambiguous _ → Skipped
      expectation → case pixelWorldPoint plan pixel of
        Nothing → Compared [name pixel "outside the viewport but not clear" | expectation /= ExpectedClear] False False False
        Just point → compareAt pixel expectation point (V2 ((fromIntegral px + 0.5) / scale) ((fromIntegral py + 0.5) / scale))

    name (x, y) why = sceneName sc <> " " <> show (x, y) <> ": " <> why

    -- The faces a point is inside, nearest first, or Nothing when it is on an edge of one.
    containing point@(sx, sy) =
      let candidates = [(face, entry) | (face, entry) ← entries, inBox (faceBounds face)]
          inBox (Rect x0 x1 y0 y1) = sx >= x0 && sx <= x1 && sy >= y0 && sy <= y1
          located = [(face, entry, locate (facePolygon face) point) | (face, entry) ← candidates]
       in if any (\(_, _, w) → w == OnEdge) located then Nothing else Just [(face, entry) | (face, entry, In) ← located]

    -- The faces whose quad the point is inside, nearest first: what the renderer
    -- rasterizes at the pixel, whatever the mask then covers. Nothing on a quad's edge.
    rasterized point@(sx, sy) =
      let candidates = [(face, entry) | (face, entry) ← entries, inBox (quadBounds face)]
          inBox (x0, x1, y0, y1) = sx >= x0 && sx <= x1 && sy >= y0 && sy <= y1
          located = [(face, entry, locateQuad face point) | (face, entry) ← candidates]
       in if any (\(_, _, w) → w == OnEdge) located then Nothing else Just [(face, entry) | (face, entry, In) ← located]

    compareAt pixel expectation point windowPoint = case (containing point, rasterized point) of
      (Nothing, _) → Skipped
      (_, Nothing) → Skipped
      (Just inside, Just drawn) →
        let front = case inside of
              (face, _) : _ → Just (cellOf face)
              [] → Nothing
            shown = firstShown point drawn
            expectedFront = case expectation of
              ExpectedHit {expectedFront = hit} → Just (let (x, y, z) = hitCell hit in (x, y, z, kindOf (hitKind hit)))
              _ → Nothing
            picked = configPick config plan windowPoint
            frontProblem = [name pixel ("the plan's frontmost face is " <> show front <> ", expected " <> show expectedFront) | front /= expectedFront]
            surfaceProblem = case (inside, expectation) of
              ((face, _) : _, ExpectedHit {expectedFront = hit}) → [name pixel ("the plan's frontmost face lies in plane " <> [faceSurface (camFacing camera) face] <> ", expected " <> [hitSurface hit]) | faceSurface (camFacing camera) face /= hitSurface hit]
              _ → []
            pickProblem = [name pixel ("the pick is " <> show picked <> ", expected " <> show expectedFront) | picked /= expectedFront]
         in case shown of
              Left _ → Skipped
              Right seen →
                let shownProblem = case (expectation, seen) of
                      (ExpectedClear, Nothing) → []
                      (ExpectedClear, Just _) → [name pixel "the material shows a face where nothing is expected"]
                      (ExpectedHit {expectedShown = Nothing}, Nothing) → []
                      (ExpectedHit {expectedShown = Nothing}, Just _) → [name pixel "the material shows a face where every texel on the line is transparent"]
                      (ExpectedHit {expectedShown = Just (hit, rgba)}, Just (face, colour)) →
                        [ name pixel ("the material shows " <> show (cellOf face) <> " " <> show colour <> ", expected " <> show hit <> " " <> show rgba)
                        | not (sameColour rgba colour) || cellOf face /= (let (x, y, z) = hitCell hit in (x, y, z, kindOf (hitKind hit)))
                        ]
                      (ExpectedHit {expectedShown = Just _}, Nothing) → [name pixel "the material shows nothing where a texel is expected"]
                      (Ambiguous _, _) → []
                    revealed = case expectation of
                      ExpectedHit {expectedFront = f, expectedShown = Just (h, _)} → hitCell f /= hitCell h || hitKind f /= hitKind h
                      _ → False
                    hole = case expectation of
                      ExpectedHit {expectedShown = Nothing} → True
                      _ → revealed
                 in Compared
                      -- Pixel snapping moves each instance's origin to the pixel grid separately, which
                      -- this judge's polygons and quads, in the unsnapped render world, do not model; the
                      -- pick does (it draws the outline as the recorder places it), and the device's
                      -- pixels are judged by the oracle and the independent expectation, both of which do.
                      (if sceneSnap sc then pickProblem else frontProblem <> surfaceProblem <> pickProblem <> shownProblem)
                      hole
                      revealed
                      (expectedFront /= Nothing)

    -- The nearest face whose texel is not transparent, through the pure model:
    -- Left when the model is undecided (a mask edge or a texel boundary) before one is found.
    firstShown point inside = go inside
      where
        go [] = Right Nothing
        go ((face, entry) : rest) = case modelAt point face entry of
          Left decided → Left decided
          Right (Colour _ _ _ a, colour)
            | a >= 0.75 → Right (Just (face, colour))
            | a > 0.25 → Left "the mask edge"
            | otherwise → go rest

    modelAt point face entry =
      let record = either (error . show) id (faceRecord (adaptedSheet entry) face)
          (u, v) = uvAt face point
          input =
            MaterialInput
              { materialTexel = Colour 0 0 0 0
              , materialUv = (u, v)
              , materialParameter = adaptedParameter entry
              , materialRecord = record
              , materialPush = mempty
              , materialSample = \handle coordinates → sampleSheet handle coordinates
              , materialSampleScaled = \handle coordinates _ → sampleSheet handle coordinates
              }
       in case runMaterialModel terrainModel input of
            Left fault → Left (show fault)
            Right colour@(Colour _ _ _ a) → Right (Colour 0 0 0 a, colour)

    sampleSheet handle (u, v) = case sheetBy env handle of
      Nothing → Right (Colour 0 0 0 0)
      Just sheet →
        let fx = u * fromIntegral (artWidth sheet)
            fy = v * fromIntegral (artHeight sheet)
            nearBoundary t = abs (t - fromIntegral (round t ∷ Integer)) < 1.0e-6
            column = max 0 (min (artWidth sheet - 1) (floor fx))
            row = max 0 (min (artHeight sheet - 1) (floor fy))
         in if nearBoundary fx || nearBoundary fy
              then Left (SampleNearTexelBoundary handle)
              else
                let (r, g, b, a) = artTexel sheet column row
                 in Right (Colour (fromIntegral r / 255) (fromIntegral g / 255) (fromIntegral b / 255) (fromIntegral a / 255))

    sameColour (r, g, b, a) (Colour cr cg cb ca) = all (\(byte, c) → abs (fromIntegral byte / 255 - c) < 1.0e-9) [(r, cr), (g, cg), (b, cb), (a, ca)]

    kindOf = \case
      Top → TopFace
      EastWall → WallFace East
      SouthWall → WallFace South

-- | The bounds of a face's quad: its unit square's four corners in the render world.
quadBounds ∷ PlannedFace → (Rational, Rational, Rational, Rational)
quadBounds face = (minimum xs, maximum xs, minimum ys, maximum ys)
  where
    (V2 a b, V2 c d, V2 tx ty) = columns (faceQuad face)
    corners = [(toRational (u * a + v * c + tx), toRational (u * b + v * d + ty)) | u ← [0, 1], v ← [0, 1]]
    xs = map fst corners
    ys = map snd corners

-- | Where a point is against a face's quad: the unit square's preimage.
locateQuad ∷ PlannedFace → (Rational, Rational) → Where
locateQuad face point
  | any (\t → t == 0 || t == 1) [u, v] && all (\t → t >= 0 && t <= 1) [u, v] = OnEdge
  | all (\t → t > 0 && t < 1) [u, v] = In
  | otherwise = Out
  where
    (u, v) = uvExact face point

-- | One pixel's judgement.
data Verdict = Skipped | Compared [String] Bool Bool Bool

-- | The face's unit-square coordinates at a render-world point, exactly: the quad's inverse.
uvExact ∷ PlannedFace → (Rational, Rational) → (Rational, Rational)
uvExact face (sx, sy) = (u, v)
  where
    (V2 a b, V2 c d, V2 tx ty) = columns (faceQuad face)
    (qa, qb, qc, qd, qtx, qty) = (toRational a, toRational b, toRational c, toRational d, toRational tx, toRational ty)
    det = qa * qd - qc * qb
    dx = sx - qtx
    dy = sy - qty
    u = (qd * dx - qc * dy) / det
    v = (qa * dy - qb * dx) / det

-- | 'uvExact' as the model takes it.
uvAt ∷ PlannedFace → (Rational, Rational) → (Double, Double)
uvAt face point = let (u, v) = uvExact face point in (fromRational u, fromRational v)
