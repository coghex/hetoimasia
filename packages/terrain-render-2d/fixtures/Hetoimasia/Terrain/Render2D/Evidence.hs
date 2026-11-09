-- | Scenes and independent expectations for the terrain material's evidence (TRA-17): the cells
-- of a fixture, the camera it is seen from, the discovery knowledge of its cells, and what a
-- viewer must see at every pixel centre, worked out here without the planner, its depth keys,
-- its picker, the material's model or the render-2d oracle.
--
-- The CPU suite and the native evidence scenario both build their scenes and their hand-stated
-- expectations from this component, through the public terrain and planner interfaces, so neither
-- imports the other's spec. It is a test component's support library; no engine library depends
-- on it.
--
-- == The independent model
--
-- The cell-quad contract draws, for each potentially visible cell, one whole 96 x 64 canvas (or, for
-- a known solid beside an undiscovered void, two: the fog part then the known part) through two
-- atlas regions: a colour region and a map region of the view-turned shape. A texel is drawn where
-- the colour texel and the map texel are both opaque. Quads are painted far to near, nearer being
-- the larger of the integer key @(viewX + viewY, z, viewX, viewY)@ of the cell in the view frame,
-- and at one cell fog is behind the known solid. A pixel therefore shows the nearest quad whose
-- two texels are both opaque, and its colour is lit by the map texel's normal and given the depth
-- effects of the presentation settings.
--
-- Everything is stated here by hand. The identities' lowered sides are bits (1 north, 2 east,
-- 4 south, 8 west); a view turns the scene about the anchor tile by whole quarter turns, taking
-- north to east to south to west and an offset @(dx, dy)@ to @(-dy, dx)@; a cell keeps its identity
-- and the viewer sees the map of its turned shape. A canvas sits with its top-left corner at
-- @(48 (vx - vy) - 48, 24 (vx + vy - 1) - 16 (z - ref) - 16)@ in the render world, where @(vx, vy)@
-- is the cell's offset from the anchor in the view frame and @ref@ the camera's vertical
-- reference; a pixel centre is a render-world point (through the view's own mapping, which has its
-- own tests and oracle), and the canvas texel under it is the floor of its offset from that corner.
-- The art is supplied by the caller from the independently decoded source images: this module
-- reads no file and calls neither the atlas nor the planner.
--
-- A pixel centre within a sixteenth of a texel of a texel boundary of a quad it depends on is
-- 'Ambiguous', never a guess, unless the caller states that the scene's centres lie exactly on
-- boundaries (then the rule decides: the higher texel on an interior boundary).
--
-- State, ownership and lifetime: none. Every value is immutable.
module Hetoimasia.Terrain.Render2D.Evidence
  ( -- * Scenes
    Cell (..)
  , Scene (..)
  , Mode (..)
  , Know (..)
  , newScene
  , sceneSource
  , sceneFacts
  , sceneKnowledge
  , sceneCamera
  , sceneCameraFollowed
  , sceneSetup
  , sceneInputs
  , scenePlan
  , sceneMaterials

    -- * Art
  , Rgba
  , ArtSource (..)

    -- * The independent model
  , HandLight (..)
  , defaultHandLight
  , Role (..)
  , HandQuad (..)
  , Expected (..)
  , handQuads
  , expectedAt
  , expectedImage
  , handSides
  , handTurnSide
  , handViewShape
  , turnsOf
  , pixelWorldPoint
  , srgbDecode
  , srgbEncode
  , handShade
  , shadedByte
  ) where

import qualified Data.Map.Strict as Map
import Data.List (nub, sortOn)
import Data.Ord (Down (..))
import Data.Word (Word8)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (targetToWorld, viewportContains)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (axisFromInteger, axisValue)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rvMapping, rvSetup)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source

-- ---------------------------------------------------------------------------
-- Scenes

-- | A run of levels @[cellZ0, cellZ1)@ of one shape and material at a column.
data Cell = Cell
  { cellX ∷ !Integer
  , cellY ∷ !Integer
  , cellZ0 ∷ !Integer
  , cellZ1 ∷ !Integer
  , cellShape ∷ !Int
  , cellMaterial ∷ !String
  }
  deriving stock (Eq, Ord, Show)

-- | How a scene's camera is set.
data Mode
  = -- | Manual at a slice level, the vertical reference at the top plane of another level.
    ManualAt !Integer !Integer
  | -- | Following the surface of the anchor column, with the automatic headroom.
    FollowSurface
  deriving stock (Eq, Show)

-- | A scene: cells, and the view they are seen through.
data Scene = Scene
  { sceneName ∷ !String
  , sceneCells ∷ ![Cell]
  , sceneAnchor ∷ !(Integer, Integer)
  , sceneMode ∷ !Mode
  , sceneFacing ∷ !ViewFacing
  , sceneZoom ∷ !Float
  , scenePan ∷ !(Double, Double)
  -- ^ A pan from the anchor tile's centre, in tiles on the world axes.
  , sceneTarget ∷ !(Int, Int)
  -- ^ The target's framebuffer extent in pixels.
  , sceneLogical ∷ !(Int, Int)
  -- ^ The extent window coordinates are measured in; equal to the target's
  -- unless the content scale is not 1.
  , sceneScale ∷ !Float
  -- ^ The target's content scale.
  , sceneViewport ∷ !(Float, Float, Float, Float)
  -- ^ Origin and extent in framebuffer pixels.
  , sceneSnap ∷ !Bool
  -- ^ Whether the view snaps to the device pixel grid.
  , sceneKnow ∷ ![((Integer, Integer, Integer), Know)]
  -- ^ The unit cells whose knowledge is not the default discovered: a solid known beside an
  -- undiscovered void, or a confirmed undiscovered cell (whose terrain, if any, is never read).
  , sceneFogOnly ∷ ![(Integer, Integer, Integer)]
  -- ^ Cells that hold no terrain at all and are confirmed undiscovered: hidden air.
  }
  deriving stock (Eq, Show)

-- | A scene of these cells in the target of this extent, whole target as the
-- viewport, anchored at the origin, manual at slice 0, facing south at native
-- scale.
newScene ∷ String → [Cell] → (Int, Int) → Scene
newScene name cells (w, h) =
  Scene
    { sceneName = name
    , sceneCells = cells
    , sceneAnchor = (0, 0)
    , sceneMode = ManualAt 0 0
    , sceneFacing = FaceSouth
    , sceneZoom = 1
    , scenePan = (0, 0)
    , sceneTarget = (w, h)
    , sceneLogical = (w, h)
    , sceneScale = 1
    , sceneViewport = (0, 0, fromIntegral w, fromIntegral h)
    , sceneSnap = False
    , sceneKnow = []
    , sceneFogOnly = []
    }

-- | The authored materials of a scene's cells, each once.
sceneMaterials ∷ Scene → [String]
sceneMaterials = nub . map cellMaterial . sceneCells

-- | The source holding exactly a scene's cells.
sceneSource ∷ Scene → Source
sceneSource sc =
  either (\e → error ("scene source refused: " <> show e)) id $
    mkSource
      defaultSourceLimits
      SourceSpec
        { specMaterials = sceneMaterials sc
        , specLayers = []
        , specPatches = [PatchSpec (cellX c) (cellY c) (cellZ0 c) (cellZ1 c) (SpecSolid (cellMaterial c) (cellShape c)) | c ← sceneCells sc]
        }

sceneFacts ∷ Scene → TerrainFacts
sceneFacts sc = TerrainFacts (Versions 1 1 1) (sceneSource sc) emptyChanges AllKnown

-- | The camera of a scene: its anchor, the slice and reference or the follow,
-- the facing, the zoom and the pan.
sceneCamera ∷ Scene → CameraState
sceneCamera sc = foldl step start commands
  where
    (ax, ay) = sceneAnchor sc
    facts = sceneFacts sc
    axis n = either (\e → error ("scene axis: " <> show e)) id (axisFromInteger n)
    start = either (\e → error ("scene camera: " <> show e)) id (newCamera defaultCameraConfig (axis ax) (axis ay) (axis initial))
    initial = case sceneMode sc of
      ManualAt _ ref → ref
      FollowSurface → 0
    commands =
      [SelectSlice (axis cut) | ManualAt cut _ ← [sceneMode sc]]
        <> [SetFacing (sceneFacing sc), SetZoom (sceneZoom sc), uncurry Pan (scenePan sc)]
    step camera command = either (\e → error ("scene camera command: " <> show e)) stepCamera (applyCommand defaultCameraConfig facts command camera)

-- | The scene's view setup.
sceneSetup ∷ Scene → ViewSetup
sceneSetup sc =
  ViewSetup
    { setupMetrics = TargetMetrics (PixelExtent lw lh) (PixelExtent w h) (sceneScale sc) (sceneScale sc)
    , setupViewport = Viewport (V2 vx vy) (V2 vw vh)
    , setupSettings = defaultViewSettings {settingPixelSnap = sceneSnap sc}
    }
  where
    (w, h) = sceneTarget sc
    (lw, lh) = sceneLogical sc
    (vx, vy, vw, vh) = sceneViewport sc

-- | 'sceneCamera', then, for a following scene, the adoption of the surface.
sceneCameraFollowed ∷ Scene → CameraState
sceneCameraFollowed sc = case sceneMode sc of
  FollowSurface → either (\e → error ("scene follow: " <> show e)) stepCamera (refollow defaultCameraConfig (sceneFacts sc) (sceneCamera sc))
  ManualAt _ _ → sceneCamera sc

-- | What the discovery knowledge says of a unit cell.
data Know
  = -- | Discovered whole: ordinary.
    KnownAll
  | -- | The solid is known, its empty component is not: mixed for a shaped solid.
    KnownSolid
  | -- | Confirmed undiscovered: generic fog, whatever the terrain holds.
    Undisc
  deriving stock (Eq, Ord, Show)

-- | The discovery knowledge of a scene: every cell discovered except those it lists.
sceneKnowledge ∷ Scene → Knowledge
sceneKnowledge sc =
  either (\e → error ("scene knowledge: " <> show e)) id $
    mkKnowledge
      KnowledgeSpec
        { specRevision = 1
        , specDefault = CellDiscovered
        , specRegions = []
        , specColumns =
            [ (Column (axis x) (axis y), [(z, z + 1, state) | ((x', y', z), state) ← entries, (x', y') == (x, y)])
            | (x, y) ← nub [(x, y) | ((x, y, _), _) ← entries]
            ]
        }
  where
    axis n = either (\e → error ("scene axis: " <> show e)) id (axisFromInteger n)
    entries = [(p, stateOf k) | (p, k) ← sceneKnow sc] <> [(p, CellUndiscovered) | p ← sceneFogOnly sc]
    stateOf = \case
      KnownAll → CellDiscovered
      KnownSolid → CellSolidKnown
      Undisc → CellUndiscovered

-- | The inputs a planner reads for a scene and an adopted style.
sceneInputs ∷ AssetSnapshot → Scene → CellInputs
sceneInputs assets sc =
  CellInputs
    { inputsRequest =
        CellRequest
          { crVersions = Versions 1 1 1
          , crCamera = sceneCameraFollowed sc
          , crSetup = sceneSetup sc
          , crConfig = defaultCellConfig
          }
    , inputsFacts = sceneFacts sc
    , inputsKnowledge = sceneKnowledge sc
    , inputsAssets = assets
    }

-- | The cell-quad plan of a scene against a style's assets.
scenePlan ∷ AssetSnapshot → Scene → Either CellError CellPlan
scenePlan assets = planCells . sceneInputs assets

-- ---------------------------------------------------------------------------
-- Art

type Rgba = (Word8, Word8, Word8, Word8)

-- | The independently decoded source images a caller supplies: a colour canvas by its authored
-- material name (@blanktexture@ for fog) and a map by its identifier (@shape.07@, @mixed.07.known@),
-- each as the texel at a column and a row of its 96 x 64 canvas.
data ArtSource = ArtSource
  { artColour ∷ String → Int → Int → Rgba
  , artMap ∷ String → Int → Int → Rgba
  }

-- ---------------------------------------------------------------------------
-- The independent model

-- | The lowered sides of a stored shape identity, by hand: bit 1 north, 2 east, 4 south, 8 west.
handSides ∷ Int → [Char]
handSides shape = [name | (bit, name) ← [(1, 'N'), (2, 'E'), (4, 'S'), (8, 'W')], shape `div` bit `mod` 2 == 1]

-- | A side after a number of positive quarter turns: north to east to south to west to north.
handTurnSide ∷ Int → Char → Char
handTurnSide count side = order !! ((index + count) `mod` 4)
  where
    order = "NESW"
    index = length (takeWhile (/= side) order)

-- | The shape identity a view shows: the lowered sides turned, by hand.
handViewShape ∷ Int → Int → Int
handViewShape count shape = sum [bit | side ← map (handTurnSide count) (handSides shape), (bit, name) ← [(1, 'N'), (2, 'E'), (4, 'S'), (8, 'W')], name == side]

-- | The positive quarter turns a facing applies: south 0, west 3, north 2, east 1.
turnsOf ∷ ViewFacing → Int
turnsOf = \case
  FaceSouth → 0
  FaceWest → 3
  FaceNorth → 2
  FaceEast → 1

turnPair ∷ Int → (Integer, Integer) → (Integer, Integer)
turnPair count (dx, dy) = iterate (\(a, b) → (negate b, a)) (dx, dy) !! (count `mod` 4)

-- | The presentation settings as the expectation takes them: plain numbers, stated here, so no
-- value is read from the production settings type.
data HandLight = HandLight
  { lightAzimuth ∷ !Double
  , lightElevation ∷ !Double
  , lightAmbient ∷ !Double
  , lightStrength ∷ !Double
  , lightRange ∷ !Double
  , lightDarkening ∷ !Double
  , lightHaze ∷ !Double
  , lightHazeSrgb ∷ !(Double, Double, Double)
  }
  deriving stock (Eq, Show)

-- | The approved defaults, stated again.
defaultHandLight ∷ HandLight
defaultHandLight = HandLight 225 45 0.35 1 250 0.15 0.60 (0.72, 0.85, 0.95)

-- | The sRGB transfer function's decoding of a byte.
srgbDecode ∷ Word8 → Double
srgbDecode byte = decode (fromIntegral byte / 255)
  where
    decode c
      | c <= 0.04045 = c / 12.92
      | otherwise = ((c + 0.055) / 1.055) ** 2.4

-- | The encoding of a linear component to an 8-bit sRGB byte, clamped.
srgbEncode ∷ Double → Word8
srgbEncode l = round (max 0 (min 255 (255 * encode (max 0 (min 1 l)))))
  where
    encode v
      | v <= 0.0031308 = 12.92 * v
      | otherwise = 1.055 * v ** (1 / 2.4) - 0.055

-- | What a quad shows.
data Role = Ordinary | MixedKnown | MixedFog | FullFog
  deriving stock (Eq, Ord, Show)

-- | One quad the model expects the plan to draw, stated by hand.
data HandQuad = HandQuad
  { hqCell ∷ !(Integer, Integer, Integer)
  , hqRole ∷ !Role
  , hqColour ∷ !String
  -- ^ The colour canvas: an authored material, or @blanktexture@.
  , hqMap ∷ !String
  -- ^ The map identifier.
  , hqCorner ∷ !(Integer, Integer)
  -- ^ The canvas's top-left corner in the render world.
  , hqKey ∷ !(Integer, Integer, Integer, Integer, Int)
  -- ^ The painter's key: nearer is larger.
  , hqDepth ∷ !Integer
  -- ^ The cell's depth below the cut.
  }
  deriving stock (Eq, Show)

two ∷ Int → String
two n = (if n < 10 then "0" else "") <> show n

-- | Every quad a scene's knowledge and cut draw, by hand: known cells at or below the cut and
-- within the 250-level band, in each role their knowledge gives, and the fog cells.
handQuads ∷ Scene → CameraState → [HandQuad]
handQuads sc camera = concatMap quadsOf cells
  where
    anchorX = toInteger (axisValue (camAnchorX camera))
    anchorY = toInteger (axisValue (camAnchorY camera))
    clip = toInteger (axisValue (camClip camera))
    ref = camRef camera
    count = turnsOf (camFacing camera)
    know = Map.fromList (sceneKnow sc)
    solids = [((cellX c, cellY c, z), (cellShape c, cellMaterial c)) | c ← sceneCells sc, z ← [cellZ0 c .. cellZ1 c - 1]]
    cells =
      [(p, Just solid, Map.findWithDefault KnownAll p know) | (p, solid) ← solids, Map.lookup p know /= Just Undisc]
        <> [(p, Nothing, Undisc) | (p, _) ← solids, Map.lookup p know == Just Undisc]
        <> [(p, Nothing, Undisc) | p ← sceneFogOnly sc]
    inBand (_, _, z) = z <= clip && clip - z <= 250
    corner (x, y, z) =
      let (vx, vy) = turnPair count (x - anchorX, y - anchorY)
       in (48 * (vx - vy) - 48, 24 * (vx + vy - 1) - 16 * (z - ref) - 16, vx, vy)
    quadsOf (p, solid, k)
      | not (inBand p) = []
      | otherwise = case (k, solid) of
          (Undisc, _) → [fog p FullFog 0]
          (KnownAll, Just (shape, material)) → [known p Ordinary material (ordinaryMap shape) 1]
          (KnownSolid, Just (shape, material))
            | shape == 0 → [known p Ordinary material (ordinaryMap shape) 1]
            | otherwise →
                [ fog p MixedFog 0 `withMap` ("mixed." <> two (handViewShape count shape) <> ".fog")
                , known p MixedKnown material ("mixed." <> two (handViewShape count shape) <> ".known") 1
                ]
          _ → []
    ordinaryMap shape = "shape." <> two (handViewShape count shape)
    withMap q m = q {hqMap = m}
    known p role material mapId part =
      let (cx, cy, vx, vy) = corner p
          (_, _, z) = p
       in HandQuad p role material mapId (cx, cy) (vx + vy, z, vx, vy, part) (clip - z)
    fog p role part =
      let (cx, cy, vx, vy) = corner p
          (_, _, z) = p
       in HandQuad p role "blanktexture" "shape.00" (cx, cy) (vx + vy, z, vx, vy, part) (clip - z)

-- | What a pixel centre shows.
data Expected
  = -- | Nothing: the clear colour.
    ExpectedClear
  | -- | The nearest covered quad (what a pick finds), the nearer quads whose canvas holds the
    -- point but whose colour or map texel is transparent (the reveals, nearest first), the colour
    -- drawn (lit premultiplied linear light) and the front quad's texel.
    ExpectedHit
      { expectedFront ∷ !HandQuad
      , expectedSkipped ∷ ![HandQuad]
      , expectedLinear ∷ !(Double, Double, Double)
      , expectedTexel ∷ !(Int, Int)
      }
  | -- | The point is within a sixteenth of a texel boundary, or the model cannot decide it.
    Ambiguous !String
  deriving stock (Eq, Show)

-- | The render-world point of a pixel's centre, through the view's own mapping, or 'Nothing'
-- outside the viewport.
pixelWorldPoint ∷ CellPlan → (Int, Int) → Maybe (Rational, Rational)
pixelWorldPoint plan (px, py)
  | not (viewportContains (setupViewport (rvSetup view)) target) = Nothing
  | otherwise = case targetToWorld (rvMapping view) target of
      Just (V2 x y) → Just (toRational x, toRational y)
      Nothing → Nothing
  where
    view = cellPlanView plan
    target = V2 (fromIntegral px + 0.5) (fromIntegral py + 0.5)

-- | The shaded linear colour by hand: the sampled premultiplied linear colour @t@, the map's unit
-- normal from its bytes, the quarter-turned sun, the cell's depth and the settings, in the
-- specified order (a fresh derivation, sharing nothing with the material's model).
handShade ∷ HandLight → Int → (Double, Double, Double) → (Word8, Word8, Word8) → Integer → (Double, Double, Double)
handShade light count (tr, tg, tb) (nr, ng, nb) depth = (channel tr fr, channel tg fg, channel tb fb)
  where
    a = lightAzimuth light * pi / 180
    e = lightElevation light * pi / 180
    (wx, wy, wz) = (sin a * cos e, negate (cos a) * cos e, sin e)
    (sx, sy) = iterate (\(x, y) → (negate y, x)) (wx, wy) !! (count `mod` 4)
    sunStrength = if lightElevation light > 0 then lightStrength light else 0
    byte b = fromIntegral b - 128 ∷ Double
    (bx, by, bz) = (byte nr, byte ng, byte nb)
    len = sqrt (bx * bx + by * by + bz * bz)
    dotted = (bx * sx + by * sy + bz * wz) / len
    p = max 0 (min 1 dotted)
    bright = lightAmbient light + (1 - lightAmbient light) * sunStrength * p
    t = max 0 (min 1 (fromInteger depth / lightRange light))
    darken = 1 - lightDarkening light * t
    blend = lightHaze light * t * t
    (hr, hg, hb) = lightHazeSrgb light
    toLinear v = if v <= 0.04045 then v / 12.92 else ((v + 0.055) / 1.055) ** 2.4
    (fr, fg, fb) = (toLinear hr, toLinear hg, toLinear hb)
    channel texel haze = (1 - blend) * texel * bright * darken + blend * haze

-- | The 8-bit sRGB bytes of a linear colour.
shadedByte ∷ (Double, Double, Double) → (Word8, Word8, Word8)
shadedByte (r, g, b) = (srgbEncode r, srgbEncode g, srgbEncode b)

-- | What the pixel at this column and row shows.
expectedAt ∷ ArtSource → HandLight → Scene → CameraState → CellPlan → (Int, Int) → Expected
expectedAt art light sc camera plan pixel = case pixelWorldPoint plan pixel of
  Nothing → ExpectedClear
  Just (sx, sy) → decide (fromRational sx ∷ Double) (fromRational sy ∷ Double)
  where
    quads = sortOn (Down . hqKey) (handQuads sc camera)
    count = turnsOf (camFacing camera)
    decide sx sy = go [] quads
      where
        go _ [] = ExpectedClear
        go skipped (q : rest) =
          let (cx, cy) = hqCorner q
              fu = sx - fromInteger cx
              fv = sy - fromInteger cy
              u = floor fu ∷ Int
              v = floor fv ∷ Int
              nearBoundary t = let f = t - fromInteger (floor t) in f < 1 / 16 || f > 15 / 16
           in if u < 0 || v < 0 || u >= 96 || v >= 64
                then go skipped rest
                else
                  if nearBoundary fu || nearBoundary fv
                    then Ambiguous ("a texel boundary of " <> show (hqCell q) <> " " <> show (hqRole q))
                    else
                      let (cr, cg, cb, ca) = artColour art (hqColour q) u v
                          (mr, mg, mb, ma) = artMap art (hqMap q) u v
                       in if ca == 0 || ma == 0
                            then go (skipped <> [q]) rest
                            else
                              let shaded = handShade light count (srgbDecode cr, srgbDecode cg, srgbDecode cb) (mr, mg, mb) (hqDepth q)
                               in ExpectedHit {expectedFront = q, expectedSkipped = skipped, expectedLinear = shaded, expectedTexel = (u, v)}

-- | The expectation at every pixel of a scene's target, row by row, top to bottom.
expectedImage ∷ ArtSource → HandLight → Scene → CellPlan → [[Expected]]
expectedImage art light sc plan = [[expectedAt art light sc camera plan (x, y) | x ← [0 .. w - 1]] | y ← [0 .. h - 1]]
  where
    camera = sceneCameraFollowed sc
    (w, h) = sceneTarget sc
