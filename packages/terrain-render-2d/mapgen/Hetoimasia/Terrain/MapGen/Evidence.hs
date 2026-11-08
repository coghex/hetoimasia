-- | The CPU comparison evidence of the generated catalog (TRA-14).
--
-- 'evidenceFiles' draws, from the regenerated catalog and the retained
-- reference-only masks, labeled comparison sheets and an index, all
-- deterministic bytes:
--
-- * @comparison-<facing>.png@: for every world shape at one facing, the original
--   legacy face-weight mask the reference selects, the corrected unit-normal map,
--   the alpha change between them, the corrected cutout over the unchanged loam
--   artwork, and the known solid (loam) with its cover (blank) side by side,
--   with the shape's name, the catalog shape the facing selects and the wall
--   coverage of that shape. Matched scale (2x, nearest).
-- * @joined-<facing>-normals.png@ and @joined-<facing>-art.png@: the sixteen
--   shapes as one joined block of cells, drawn far to near by the exact key
--   @(viewX + viewY, viewX, viewY)@, as normals and as cutout loam.
-- * @evidence-index.json@: every file's SHA-256, the recipe, the reproduced
--   reference defect with its coordinates and hashes, and for every shape and
--   facing the alpha texels the correction changes.
--
-- Every image is CPU generated-image evidence. None is an engine screenshot, a
-- shader output or GPU qualification, and no lighting is applied: the normal
-- images are the maps' own bytes.
--
-- State, ownership and lifetime: none beyond the directory 'writeEvidence' is
-- told to fill.
module Hetoimasia.Terrain.MapGen.Evidence
  ( writeEvidence
  , evidenceFiles
  , defectRecord
  ) where

import Codec.Picture (Image, PixelRGBA8 (..), encodePng)
import Codec.Picture.Types (MutableImage, createMutableImage, freezeImage, writePixel)
import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (toUpper)
import Data.List (find, sortOn)
import Data.Maybe (fromMaybe)
import Data.Ratio (denominator, numerator)
import Data.Word (Word8)
import Hetoimasia.Terrain.Geometry (Coverage (..), V3 (..), rotatePoint, sideCoverage)
import Hetoimasia.Terrain.MapBake.Bake (canvasHeight, canvasWidth)
import Hetoimasia.Terrain.MapBake.Catalog (Lookup (..), MapKey, allLookups, facingName, mapBytes)
import Hetoimasia.Terrain.MapGen.Generate (inventory, recipeVersion)
import Hetoimasia.Terrain.MapGen.Inputs (ColourArt (..), Inputs (..), ReferenceMask (..), sha256Hex, sourceRevision)
import Hetoimasia.Terrain.MapGen.Json (Json (..), renderJson)
import Hetoimasia.Terrain.Shape (ShapeId, Side (..), ViewFacing, allViewFacings, facingTurns, shapeFromSides, shapeIdValue, shapeName, turnCount, turns)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | Write every evidence file into the directory and return what to print.
writeEvidence ∷ Inputs → FilePath → IO [String]
writeEvidence inputs directory = do
  createDirectoryIfMissing True directory
  let files = evidenceFiles inputs
  forM_ files $ \(name, bytes) → ByteString.writeFile (directory </> name) bytes
  pure (("wrote " <> show (length files) <> " CPU generated-image evidence files to " <> directory) : inventory files)

-- | Every evidence file by name, images first, then the index.
evidenceFiles ∷ Inputs → [(FilePath, ByteString)]
evidenceFiles inputs = images <> [("evidence-index.json", renderJson (evidenceIndex inputs images))]
  where
    images =
      [("comparison-" <> facingName facing <> ".png", png (comparisonSheet inputs facing)) | facing ← allViewFacings]
        <> concat
          [ [ ("joined-" <> facingName facing <> "-normals.png", png (joinedSheet inputs facing NormalsView))
            , ("joined-" <> facingName facing <> "-art.png", png (joinedSheet inputs facing ArtView))
            ]
          | facing ← allViewFacings
          ]
    png = Lazy.toStrict . encodePng

-- ---------------------------------------------------------------------------
-- Inputs as pixel sources

type Rgb = (Word8, Word8, Word8)

data Source = Source
  { sourceAlpha ∷ !(Int → Int → Word8)
  , sourceRgb ∷ !(Int → Int → Rgb)
  }

sourceOf ∷ ByteString → Source
sourceOf bytes = Source (\x y → at x y 3) (\x y → (at x y 0, at x y 1, at x y 2))
  where
    at x y channel = ByteString.index bytes (4 * (y * canvasWidth + x) + channel)

colourSource ∷ Inputs → String → Source
colourSource inputs name =
  sourceOf (fromMaybe ByteString.empty (fmap (\(_, _, texels) → texels) (find (\(art, _, _) → artName art == name) (inputColour inputs))))

legacySource ∷ Inputs → ShapeId → Source
legacySource inputs shape =
  sourceOf (fromMaybe ByteString.empty (fmap (\(_, _, texels) → texels) (find (\(mask, _, _) → referenceShape mask == shapeIdValue shape) (inputReference inputs))))

mapSource ∷ MapKey → Source
mapSource = sourceOf . mapBytes

-- ---------------------------------------------------------------------------
-- A tiny canvas: a mutable RGBA image with rectangles, scaled sprites and text

type Canvas s = MutableImage s PixelRGBA8

background, ink, panel ∷ PixelRGBA8
background = PixelRGBA8 44 46 52 255
ink = PixelRGBA8 235 235 235 255
panel = PixelRGBA8 70 72 80 255

fillRect ∷ Canvas s → Int → Int → Int → Int → PixelRGBA8 → ST s ()
fillRect canvas x0 y0 w h colour =
  forM_ [y0 .. y0 + h - 1] $ \y → forM_ [x0 .. x0 + w - 1] $ \x → writePixel canvas x y colour

-- | A 96 × 64 sprite at a scale, written where the source says a texel exists.
sprite ∷ Canvas s → Int → Int → Int → (Int → Int → Maybe Rgb) → ST s ()
sprite canvas x0 y0 scale texel =
  forM_ [0 .. canvasHeight - 1] $ \y → forM_ [0 .. canvasWidth - 1] $ \x →
    case texel x y of
      Nothing → pure ()
      Just (r, g, b) →
        forM_ [0 .. scale - 1] $ \dy → forM_ [0 .. scale - 1] $ \dx →
          writePixel canvas (x0 + x * scale + dx) (y0 + y * scale + dy) (PixelRGBA8 r g b 255)

-- | Text in a 3 × 5 pixel face at an integer scale, upper-cased; characters the
-- face lacks draw as a box.
text ∷ Canvas s → Int → Int → Int → String → ST s ()
text canvas x0 y0 scale string =
  forM_ (zip [0 ..] string) $ \(n, character) →
    forM_ (zip [0 ..] (glyph (toUpper character))) $ \(row, bits) →
      forM_ (zip [0 ..] bits) $ \(column, on) →
        when on $
          fillRect canvas (x0 + (4 * n + column) * scale) (y0 + row * scale) scale scale ink

glyph ∷ Char → [[Bool]]
glyph character = map (map (== '#')) (fromMaybe box (lookup character glyphs))
  where
    box = ["###", "#.#", "#.#", "#.#", "###"]

glyphs ∷ [(Char, [String])]
glyphs =
  [ ('A', [".#.", "#.#", "###", "#.#", "#.#"])
  , ('B', ["##.", "#.#", "##.", "#.#", "##."])
  , ('C', [".##", "#..", "#..", "#..", ".##"])
  , ('D', ["##.", "#.#", "#.#", "#.#", "##."])
  , ('E', ["###", "#..", "##.", "#..", "###"])
  , ('F', ["###", "#..", "##.", "#..", "#.."])
  , ('G', [".##", "#..", "#.#", "#.#", ".##"])
  , ('H', ["#.#", "#.#", "###", "#.#", "#.#"])
  , ('I', ["###", ".#.", ".#.", ".#.", "###"])
  , ('J', ["..#", "..#", "..#", "#.#", ".#."])
  , ('K', ["#.#", "#.#", "##.", "#.#", "#.#"])
  , ('L', ["#..", "#..", "#..", "#..", "###"])
  , ('M', ["#.#", "###", "###", "#.#", "#.#"])
  , ('N', ["##.", "#.#", "#.#", "#.#", "#.#"])
  , ('O', [".#.", "#.#", "#.#", "#.#", ".#."])
  , ('P', ["##.", "#.#", "##.", "#..", "#.."])
  , ('Q', [".#.", "#.#", "#.#", "##.", ".##"])
  , ('R', ["##.", "#.#", "##.", "#.#", "#.#"])
  , ('S', [".##", "#..", ".#.", "..#", "##."])
  , ('T', ["###", ".#.", ".#.", ".#.", ".#."])
  , ('U', ["#.#", "#.#", "#.#", "#.#", "###"])
  , ('V', ["#.#", "#.#", "#.#", "#.#", ".#."])
  , ('W', ["#.#", "#.#", "###", "###", "#.#"])
  , ('X', ["#.#", "#.#", ".#.", "#.#", "#.#"])
  , ('Y', ["#.#", "#.#", ".#.", ".#.", ".#."])
  , ('Z', ["###", "..#", ".#.", "#..", "###"])
  , ('0', ["###", "#.#", "#.#", "#.#", "###"])
  , ('1', [".#.", "##.", ".#.", ".#.", "###"])
  , ('2', ["##.", "..#", ".#.", "#..", "###"])
  , ('3', ["##.", "..#", ".#.", "..#", "##."])
  , ('4', ["#.#", "#.#", "###", "..#", "..#"])
  , ('5', ["###", "#..", "##.", "..#", "##."])
  , ('6', [".##", "#..", "###", "#.#", "###"])
  , ('7', ["###", "..#", ".#.", ".#.", ".#."])
  , ('8', ["###", "#.#", "###", "#.#", "###"])
  , ('9', ["###", "#.#", "###", "..#", "##."])
  , (' ', ["...", "...", "...", "...", "..."])
  , ('-', ["...", "...", "###", "...", "..."])
  , ('.', ["...", "...", "...", "...", ".#."])
  , (':', ["...", ".#.", "...", ".#.", "..."])
  , ('/', ["..#", "..#", ".#.", "#..", "#.."])
  , ('(', [".#.", "#..", "#..", "#..", ".#."])
  , (')', [".#.", "..#", "..#", "..#", ".#."])
  , (',', ["...", "...", "...", ".#.", "#.."])
  , ('=', ["...", "###", "...", "###", "..."])
  , ('+', ["...", ".#.", "###", ".#.", "..."])
  , ('>', ["#..", ".#.", "..#", ".#.", "#.."])
  , ('/', ["..#", "..#", ".#.", "#..", "#.."])
  ]

-- ---------------------------------------------------------------------------
-- The comparison sheet

cell ∷ Int
cell = 2

spriteW, spriteH, margin, rowHeight, headerHeight, columns ∷ Int
spriteW = canvasWidth * cell
spriteH = canvasHeight * cell
margin = 8
rowHeight = 22 + spriteH + margin
headerHeight = 44
columns = 5

comparisonSheet ∷ Inputs → ViewFacing → Image PixelRGBA8
comparisonSheet inputs facing = runST $ do
  let width = margin + columns * (spriteW + margin)
      height = headerHeight + 16 * rowHeight
  canvas ← createMutableImage width height background
  text canvas margin 6 2 ("CPU GENERATED IMAGE EVIDENCE - NOT AN ENGINE SCREENSHOT - FACING " <> map toUpper (facingName facing) <> " - " <> recipeVersion)
  forM_ (zip [0 ..] ["ORIGINAL LEGACY", "CORRECTED NORMALS", "CHANGE", "CUTOUT ON LOAM", "KNOWN LOAM + FOG BLANK"]) $ \(n, title) →
    text canvas (margin + n * (spriteW + margin)) 26 2 title
  forM_ (zip [0 ..] (filter ((== facing) . lookupFacing) allLookups)) $ \(row, entry) → do
    let top = headerHeight + row * rowHeight
        view = lookupView entry
        legacy = legacySource inputs view
        corrected = mapSource (lookupOrdinary entry)
        loam = colourSource inputs "loam"
        blank = colourSource inputs "blanktexture"
        column n = margin + n * (spriteW + margin)
    text canvas margin top 2 ("ID " <> show (shapeIdValue (lookupWorld entry)) <> " " <> shapeName (lookupWorld entry) <> " -> VIEW " <> show (shapeIdValue view) <> " " <> shapeName view <> "  WALLS " <> wallCoverage view)
    forM_ [0 .. columns - 1] $ \n → fillRect canvas (column n) (top + 12) spriteW spriteH panel
    sprite canvas (column 0) (top + 12) cell $ \x y →
      if sourceAlpha legacy x y == 0 then Nothing else Just (sourceRgb legacy x y)
    sprite canvas (column 1) (top + 12) cell $ \x y →
      if sourceAlpha corrected x y == 0 then Nothing else Just (sourceRgb corrected x y)
    sprite canvas (column 2) (top + 12) cell $ \x y →
      case (sourceAlpha legacy x y /= 0, sourceAlpha corrected x y /= 0) of
        (True, True) → Just (120, 120, 120)
        (True, False) → Just (255, 0, 255)
        (False, True) → Just (0, 255, 255)
        (False, False) → Nothing
    sprite canvas (column 3) (top + 12) cell $ \x y →
      if sourceAlpha corrected x y /= 0 && sourceAlpha loam x y /= 0 then Just (sourceRgb loam x y) else Nothing
    let mixed = case lookupMixed entry of
          Just (known, fog) → (mapSource known, mapSource fog)
          Nothing → (sourceOf (ByteString.replicate (4 * canvasWidth * canvasHeight) 0), mapSource (lookupFullFog entry))
        (knownMap, fogMap) = mixed
    sprite canvas (column 4) (top + 12) cell $ \x y →
      if sourceAlpha fogMap x y /= 0 && sourceAlpha blank x y /= 0
        then Just (sourceRgb blank x y)
        else
          if sourceAlpha knownMap x y /= 0 && sourceAlpha loam x y /= 0
            then Just (sourceRgb loam x y)
            else Nothing
  freezeImage canvas

-- | The coverage of each wall of a shape as the logical catalog states it:
-- none (-), partial (P) or full (F).
wallCoverage ∷ ShapeId → String
wallCoverage shape = unwords [letter side : ':' : [mark (sideCoverage shape side)] | side ← [North, East, South, West]]
  where
    letter North = 'N'
    letter East = 'E'
    letter South = 'S'
    letter West = 'W'
    mark NoCoverage = '-'
    mark PartialCoverage = 'P'
    mark FullCoverage = 'F'

-- ---------------------------------------------------------------------------
-- The joined sheet

data JoinedView = NormalsView | ArtView

joinedSheet ∷ Inputs → ViewFacing → JoinedView → Image PixelRGBA8
joinedSheet inputs facing view = runST $ do
  let placed =
        sortOn
          (\(dx, dy, _) → (dx + dy, dx, dy))
          [ (dx, dy, entry)
          | (index, entry) ← zip [0 ∷ Int ..] (filter ((== facing) . lookupFacing) allLookups)
          , let (wx, wy) = (index `mod` 4, index `div` 4)
          , let (dx, dy) = turnedOffset facing (toInteger wx, toInteger wy)
          ]
      xs = [fromInteger (48 * (dx - dy)) | (dx, dy, _) ← placed]
      ys = [fromInteger (24 * (dx + dy)) | (dx, dy, _) ← placed]
      left = minimum xs
      top = minimum ys
      width = maximum xs - left + canvasWidth + 2 * margin
      height = maximum ys - top + canvasHeight + 2 * margin + 28
      loam = colourSource inputs "loam"
  canvas ← createMutableImage width height background
  text canvas margin 6 2 ("CPU GENERATED IMAGE EVIDENCE - JOINED " <> (case view of NormalsView → "NORMALS"; ArtView → "LOAM CUTOUT") <> " - FACING " <> map toUpper (facingName facing))
  forM_ placed $ \(dx, dy, entry) → do
    let source = mapSource (lookupOrdinary entry)
        ox = margin + fromInteger (48 * (dx - dy)) - left
        oy = 28 + margin + fromInteger (24 * (dx + dy)) - top
    sprite canvas ox oy 1 $ \x y →
      if sourceAlpha source x y == 0
        then Nothing
        else case view of
          NormalsView → Just (sourceRgb source x y)
          ArtView → if sourceAlpha loam x y /= 0 then Just (sourceRgb loam x y) else Nothing
  freezeImage canvas

-- | A world offset between cells as the view frame sees it (one positive
-- quarter turn takes @(dx, dy)@ to @(-dy, dx)@), as the planner's projection does.
turnedOffset ∷ ViewFacing → (Integer, Integer) → (Integer, Integer)
turnedOffset facing offset = iterate quarter offset !! turnCount (facingTurns facing)
  where
    quarter (dx, dy) = (negate dy, dx)

-- ---------------------------------------------------------------------------
-- The index

evidenceIndex ∷ Inputs → [(FilePath, ByteString)] → Json
evidenceIndex inputs images =
  JObject
    [ ("schema", JString "hetoimasia.facemap-evidence/1")
    , ("label", JString "CPU generated-image evidence, not engine screenshots, shader output or GPU qualification")
    , ("recipe", JString recipeVersion)
    , ("referenceRevision", JString sourceRevision)
    , ("images", JArray [JObject [("path", JString name), ("sha256", JString (sha256Hex bytes))] | (name, bytes) ← images])
    , ("defect", defectRecord inputs)
    , ("changes", JArray (map change allLookups))
    ]
  where
    change entry =
      let legacy = legacySource inputs (lookupView entry)
          corrected = mapSource (lookupOrdinary entry)
          counted p = toInteger (length [() | y ← [0 .. canvasHeight - 1], x ← [0 .. canvasWidth - 1], p (sourceAlpha legacy x y /= 0) (sourceAlpha corrected x y /= 0)])
       in JObject
            [ ("facing", JString (facingName (lookupFacing entry)))
            , ("world", JNumber (toInteger (shapeIdValue (lookupWorld entry))))
            , ("view", JNumber (toInteger (shapeIdValue (lookupView entry))))
            , ("legacyOpaque", JNumber (counted (\l _ → l)))
            , ("correctedOpaque", JNumber (counted (\_ c → c)))
            , ("removed", JNumber (counted (\l c → l && not c)))
            , ("added", JNumber (counted (\l c → c && not l)))
            ]

-- | The reproduced reference defect (issue #655's N/E counterexample): E's
-- texel @(48, 2)@ is opaque face-weight green, the unit-cell surface it shows
-- turned three quarter turns lands in N's projection where N's own texels are
-- transparent, and N's first opaque rows are listed. Everything is computed from
-- the retained, hash-checked masks and exact rational arithmetic.
defectRecord ∷ Inputs → Json
defectRecord inputs =
  JObject
    [ ("eMask", maskEntry 2)
    , ("nMask", maskEntry 1)
    , ("eTexel", JArray [JNumber 48, JNumber 2])
    , ("eTexelRgba", JArray (map (JNumber . toInteger) [er, eg, eb, ea]))
    , ("surface", JString "E solid top z = 1 - x, texel footprint u in [48,49], v in [2,3]")
    , ("regionVerticesXY", JArray [JString (pair (x, y)) | (x, y) ← region])
    , ("rotationTurns", JNumber 3)
    , ("nProjectionU", JString (range us))
    , ("nProjectionV", JString (range vs))
    , ("nEnclosingTexelColumns", JArray (map JNumber [floorR (minimum us) .. ceilR (maximum us) - 1]))
    , ("nEnclosingTexelRows", JArray (map JNumber [floorR (minimum vs) .. ceilR (maximum vs) - 1]))
    , ("nEnclosingTexelsAllTransparent", JString (if all (\(c, r) → sourceAlpha nMask (fromInteger c) (fromInteger r) == 0) enclosing then "yes" else "no"))
    , ("nFirstOpaqueRowsColumns0To7", JArray [JNumber (firstOpaque c) | c ← [0 .. 7]])
    ]
  where
    maskEntry shapeValue = case find (\(mask, _, _) → referenceShape mask == shapeValue) (inputReference inputs) of
      Just (mask, bytes, _) → JObject [("file", JString (referenceFile mask)), ("blob", JString (referenceBlob mask)), ("sha256", JString (sha256Hex bytes))]
      Nothing → JObject []
    eMask = legacySource inputs (shapeFromSidesE)
    nMask = legacySource inputs (shapeFromSides [North])
    shapeFromSidesE = shapeFromSides [East]
    (er, eg, eb) = sourceRgb eMask 48 2
    ea = sourceAlpha eMask 48 2
    -- Corners of the unit-cell region of the E ramp (z = 1 - x) that projects to
    -- the texel: x - y in [0, 1/48] and 40 x + 24 y in [2, 3].
    region = [solve d m | d ← [0, 1 / 48], m ← [2, 3]]
    solve d m = let y = (m - 40 * d) / 64 in (y + d, y)
    -- Three positive quarter turns, then N's projection.
    turned = [rotateThrice (V3 x y (1 - x)) | (x, y) ← region]
    rotateThrice p = rotatePoint (turns 3) p
    projected = [(48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z) | V3 x y z ← turned]
    us = map fst projected
    vs = map snd projected
    enclosing = [(c, r) | c ← [floorR (minimum us) .. ceilR (maximum us) - 1], r ← [floorR (minimum vs) .. ceilR (maximum vs) - 1]]
    firstOpaque c = case [r | r ← [0 .. canvasHeight - 1], sourceAlpha nMask (fromInteger c) r /= 0] of
      r : _ → toInteger r
      [] → -1
    floorR ∷ Rational → Integer
    floorR = floor
    ceilR ∷ Rational → Integer
    ceilR = ceiling
    pair (a, b) = ratio a <> "," <> ratio b
    range values = ratio (minimum values) <> ".." <> ratio (maximum values)
    ratio value = case denominator value of
      1 → show (numerator value)
      d → show (numerator value) <> "/" <> show d
