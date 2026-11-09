-- | TRA-17: the labelled comparison of the terrain material's depth treatment with the reference's
-- multiplicative blue depth tint. The comparison claims no Synarchy lighting parity: it shows, for a
-- white texel under full light, what each treatment does as the depth below the cut grows, so the
-- owner can see where they agree (no change at the cut) and where they differ (the specified order
-- and linear-light haze against the reference's per-channel sRGB tint).
--
-- The reference formula is copied by hand from Synarchy at @3777d437@
-- (@src/World/Render/TileQuads.hs@, lines 66 to 87, the dry-tile branch):
--
-- > fadeT      = clamp01 (depth / max 1 effDepth)
-- > brightness = clamp01 (1 - fadeT * 0.15)
-- > hazeT      = fadeT * fadeT * 0.6          haze (0.72, 0.85, 0.95)
-- > tint_c     = brightness * (1 - hazeT) + haze_c * hazeT      -- the vertex tint, multiplied into the texel
--
-- The terrain material's value is the independent hand model's ('handShade'): with ambient 1 and a
-- flat top the lighting term is one, leaving only @(1 - H) D + H F@ in linear light, encoded to sRGB.
--
-- When @HETOIMASIA_TRA17_REFERENCE_DIR@ names a directory the labelled table is written there as
-- @reference-tint-comparison.md@; otherwise nothing is written.
module Test.TerrainRender2D.ReferenceTint (spec) where

import qualified Data.ByteString as ByteString
import Data.List (intercalate)
import Data.Word (Word8)
import Hetoimasia.Terrain.MapGen.Png (encodeRgba)
import Hetoimasia.Terrain.Render2D.Cells (CellPlan)
import Hetoimasia.Terrain.Render2D.Evidence (ArtSource, Expected (..), HandLight (..), HandQuad (..), Scene (..), defaultHandLight, expectedAt, handShade, sceneCameraFollowed, scenePlan, shadedByte)
import Hetoimasia.Terrain.Render2D.Scenes (depthStack)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Hspec
import Test.TerrainRender2D.Art (loadFile, sha256Hex, texturesDirectory)
import Test.TerrainRender2D.Expectation (setupAll)

-- | The reference's tint at a depth below the cut for a fade range, per channel.
referenceTint ∷ Double → Integer → (Double, Double, Double)
referenceTint range depth = (channel 0.72, channel 0.85, channel 0.95)
  where
    fadeT = clamp01 (fromInteger depth / max 1 range)
    brightness = clamp01 (1 - fadeT * 0.15)
    hazeT = fadeT * fadeT * 0.6
    channel haze = brightness * (1 - hazeT) + haze * hazeT
    clamp01 = max 0 . min 1

-- | The reference's tint as the display byte it leaves a white texel.
referenceBytes ∷ Double → Integer → (Word8, Word8, Word8)
referenceBytes range depth = (byte r, byte g, byte b)
  where
    (r, g, b) = referenceTint range depth
    byte v = round (255 * v)

-- | The terrain material's value for a white texel under full light, in display bytes.
terrainBytes ∷ Double → Integer → (Word8, Word8, Word8)
terrainBytes range depth = shadedByte (handShade light 0 (1, 1, 1) (128, 128, 255) depth)
  where
    light = defaultHandLight {lightAmbient = 1, lightRange = range}

rows ∷ [(Double, Integer)]
rows = [(4, d) | d ← [0 .. 4]] <> [(250, d) | d ← [0, 62, 125, 187, 250]]

spec ∷ Spec
spec = describe "TRA-17 reference depth-tint comparison" $ do
  it "agrees with the reference at the cut: neither treatment changes a white texel" $
    mapM_ (\range → (terrainBytes range 0, referenceBytes range 0) `shouldBe` ((255, 255, 255), (255, 255, 255))) [4, 250]
  it "states the reference's tint at full depth by hand: (0.772, 0.85, 0.91)" $ do
    let (r, g, b) = referenceTint 4 4
    (r, g, b) `shouldSatisfy` \(r', g', b') → abs (r' - 0.772) < 1e-12 && abs (g' - 0.85) < 1e-12 && abs (b' - 0.91) < 1e-12
    referenceBytes 4 4 `shouldBe` (197, 217, 232)
  it "states the terrain material's value at full depth by hand: D = 0.85, H = 0.6, haze in linear light" $ do
    -- (1 - 0.6) * 0.85 + 0.6 * linear haze = (0.6262, 0.7551, 0.8739), encoded: (207, 225, 240).
    let (r, g, b) = terrainBytes 4 4
    [r, g, b] `shouldSatisfy` and . zipWith (\want got → abs (fromIntegral got - want) <= (1 ∷ Double)) [207, 225, 240]
  it "differs from the reference at full depth, so no Synarchy lighting parity is claimed" $
    terrainBytes 4 4 `shouldNotBe` referenceBytes 4 4
  it "renders the depth stack under both treatments, equal at the cut and different below it" $ do
    (_, assets, art) ← setupAll
    let scene = depthStack FaceSouth
    plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
    let captures = capturesOf art scene plan
    length [() | (_, _, d, o, r) ← cells captures, d == 0, o == r] `shouldSatisfy` (> 0)
    length [() | (_, _, d, o, r) ← cells captures, d == 0, o /= r] `shouldBe` 0
    length [() | (_, _, d, o, r) ← cells captures, d > 0, o /= r] `shouldSatisfy` (> 100)
  it "writes the labelled comparison and the lossless captures when asked" $ do
    destination ← lookupEnv "HETOIMASIA_TRA17_REFERENCE_DIR"
    (_, assets, art) ← setupAll
    let scene = depthStack FaceSouth
    plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
    let captures = capturesOf art scene plan
        text = renderComparison
    length (lines text) `shouldSatisfy` (> 15)
    colourSha ← sha256Hex <$> loadFile (texturesDirectory </> "terrain-atlas" </> "colour.png")
    normalSha ← sha256Hex <$> loadFile (texturesDirectory </> "terrain-atlas" </> "normal.png")
    case destination of
      Nothing → pure ()
      Just directory → do
        createDirectoryIfMissing True directory
        writeFile (directory </> "reference-tint-comparison.md") text
        let (w, h) = (capW captures, capH captures)
        ByteString.writeFile (directory </> "reference-tint-terrain.png") (encodeRgba w h (capTerrain captures))
        ByteString.writeFile (directory </> "reference-tint-reference.png") (encodeRgba w h (capReference captures))
        let (sw, sh, sheet) = sideBySide 4 w h (capTerrain captures) (capReference captures)
        ByteString.writeFile (directory </> "reference-tint-sheet.png") (encodeRgba sw sh sheet)
        writeFile (directory </> "reference-tint-captures.md") (renderCaptures colourSha normalSha captures)

renderComparison ∷ String
renderComparison =
  unlines $
    [ "# TRA-17: the terrain depth treatment against the reference's multiplicative blue tint"
    , ""
    , "**Labelled reference comparison, not parity.** The reference is Synarchy at `3777d437`,"
    , "`src/World/Render/TileQuads.hs` lines 66 to 87 (dry-tile branch), whose vertex tint is multiplied"
    , "into the sampled texel: `fadeT = clamp01 (depth / max 1 range)`, `brightness = clamp01 (1 - 0.15 fadeT)`,"
    , "`hazeT = 0.6 fadeT^2`, `tint_c = brightness (1 - hazeT) + haze_c hazeT`, haze `(0.72, 0.85, 0.95)`."
    , "The terrain material's treatment is the specified one: depth below the cut `t`, `D = 1 - 0.15 t`,"
    , "`H = 0.6 t^2`, output `(1 - H) T B D + H F` in premultiplied linear light with the haze colour converted once."
    , "The values below are the display bytes each leaves a WHITE texel under full light (the terrain's lighting"
    , "term is one: ambient 1, flat top), the terrain's from the independent hand model (`handShade`), the"
    , "reference's as `round (255 tint_c)`. The reference multiplies in the space its pipeline holds, which this"
    , "comparison does not claim to reproduce for coloured texels. Reproduce:"
    , "`HETOIMASIA_TRA17_REFERENCE_DIR=<dir> cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-options='--match \"reference depth-tint\"'`"
    , ""
    , "| range | depth | terrain (R, G, B) | reference (R, G, B) | terrain minus reference |"
    , "| ---: | ---: | --- | --- | --- |"
    ]
      <> [ "| " <> show range <> " | " <> show depth <> " | " <> triple (terrainBytes range depth) <> " | " <> triple (referenceBytes range depth) <> " | " <> difference (terrainBytes range depth) (referenceBytes range depth) <> " |"
         | (range, depth) ← rows
         ]
      <> [ ""
         , "Both treatments leave a texel unchanged at the cut and both pull it toward the pale blue as depth grows."
         , "They differ where the specification differs from the reference: haze is converted to linear light and"
         , "composed after darkening (`(1 - H) D + H F`), not folded into one per-channel sRGB tint. At full depth"
         , "the terrain material gives (207, 225, 240) and the reference (197, 217, 232) for the same white texel."
         ]
  where
    triple (r, g, b) = intercalate ", " (map show [r, g, b])
    difference (a, b, c) (d, e, f) = intercalate ", " [show (signed x - signed y) | (x, y) ← [(a, d), (b, e), (c, f)]]
    signed = fromIntegral ∷ Word8 → Int


-- | The two renderings of one scene and the per-pixel facts they were made from.
data Captures = Captures
  { capW ∷ !Int
  , capH ∷ !Int
  , capTerrain ∷ !ByteString.ByteString
  , capReference ∷ !ByteString.ByteString
  , cells ∷ ![((Int, Int), Integer, Integer, (Word8, Word8, Word8), (Word8, Word8, Word8))]
  -- ^ For every covered pixel: its coordinates, the front cell's level, its depth below the cut, the
  -- terrain's byte colour and the reference's.
  }

-- | The scene rendered twice from the independent hand model: the terrain treatment (lit, darkened and
-- hazed in linear light by the specified equations, range 4), and the reference's (the same lit colour
-- with the depth effects off, multiplied per channel by the reference's tint for the front cell's depth,
-- on the display bytes). Both use the independently decoded source art.
capturesOf ∷ ArtSource → Scene → CellPlan → Captures
capturesOf art scene plan = Captures w h (pack terrainPx) (pack referencePx) covered
  where
    (w, h) = sceneTarget scene
    camera = sceneCameraFollowed scene
    range = 8
    withEffects = defaultHandLight {lightRange = range}
    litOnly = withEffects {lightDarkening = 0, lightHaze = 0}
    pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
    at light pixel = expectedAt art light scene camera plan pixel
    bytesOf = \case
      ExpectedHit {expectedLinear = linear} → shadedByte linear
      _ → (0, 0, 0)
    terrainPx = [bytesOf (at withEffects p) | p ← pixels]
    referencePx = [referenceOf p | p ← pixels]
    referenceOf p = case at litOnly p of
      e@ExpectedHit {expectedFront = q} →
        let (r, g, b) = bytesOf e
            (tr, tg, tb) = referenceTint range (hqDepth q)
            mul c t = round (fromIntegral c * t ∷ Double)
         in (mul r tr, mul g tg, mul b tb)
      _ → (0, 0, 0)
    pack = ByteString.pack . concatMap (\(r, g, b) → [r, g, b, 255])
    covered =
      [ (p, z, hqDepth q, bytesOf (at withEffects p), referenceOf p)
      | p ← pixels
      , ExpectedHit {expectedFront = q} ← [at withEffects p]
      , let (_, _, z) = hqCell q
      ]

-- | The two images side by side, scaled by a whole factor, a grey column between.
sideBySide ∷ Int → Int → Int → ByteString.ByteString → ByteString.ByteString → (Int, Int, ByteString.ByteString)
sideBySide k w h left right = (outW, h * k, ByteString.pack (concat [row y | y ← [0 .. h * k - 1]]))
  where
    gap = 2 * k
    outW = 2 * w * k + gap
    row y = concat [px left (y `div` k) (x `div` k) | x ← [0 .. w * k - 1]] <> concat (replicate gap [128, 128, 128, 255]) <> concat [px right (y `div` k) (x `div` k) | x ← [0 .. w * k - 1]]
    px img yy xx = [ByteString.index img (4 * (yy * w + xx) + i) | i ← [0 .. 3]]

renderCaptures ∷ String → String → Captures → String
renderCaptures colourSha normalSha c =
  unlines $
    [ "# TRA-17: lossless captures of the depth treatment against the reference's multiplicative blue tint"
    , ""
    , "**Labelled reference comparison, not parity.** The scene is `depth-stack-FaceSouth` at zoom 0.25 (nine loam and"
    , "granite cells of shape 5 at levels 0 to 8, the cut at level 8, so the front cell of a pixel has depth `8 - z`"
    , "below the cut), a 64 x 64 target, rendered twice from the independent hand model"
    , "(`Hetoimasia.Terrain.Render2D.Evidence`) over the independently decoded atlas art:"
    , ""
    , "- `reference-tint-terrain.png`: the terrain material's treatment, default light, depth range 8 (the nine levels span it: darkening 0.15,"
    , "  haze 0.60, haze colour sRGB (0.72, 0.85, 0.95)), by the specified equations in linear light."
    , "- `reference-tint-reference.png`: the same lit colour with the depth effects off, multiplied per channel on the"
    , "  display bytes by the reference's tint for the cell's depth (`fadeT = depth / 8`, `brightness = 1 - 0.15 fadeT`,"
    , "  `hazeT = 0.6 fadeT^2`, `tint_c = brightness (1 - hazeT) + haze_c hazeT`, Synarchy `3777d437`"
    , "  `src/World/Render/TileQuads.hs` lines 66 to 87)."
    , "- `reference-tint-sheet.png`: the two side by side at 4x, terrain on the left, reference on the right."
    , ""
    , "Sources: colour atlas `terrain-atlas/colour.png` SHA-256 `" <> colourSha <> "`, normal atlas `terrain-atlas/normal.png`"
    , "SHA-256 `" <> normalSha <> "`, layout identity `263cb64032502aa0`. Both renderings are deterministic (no seed) and"
    , "lossless PNGs. The numeric white-texel table is in `reference-tint-comparison.md`."
    , ""
    , "Covered pixels: " <> show (length (cells c)) <> "; of them at depth 0 (the cut) the two agree on "
        <> show (length [() | (_, _, d, o, r) ← cells c, d == 0, o == r]) <> " of "
        <> show (length [() | (_, _, d, _, _) ← cells c, d == 0]) <> ", and below the cut they differ on "
        <> show (length [() | (_, _, d, o, r) ← cells c, d > 0, o /= r]) <> " of "
        <> show (length [() | (_, _, d, _, _) ← cells c, d > 0]) <> "."
    , ""
    , "| level | depth | pixels | terrain (R, G, B) at the first | reference (R, G, B) at the first |"
    , "| ---: | ---: | ---: | --- | --- |"
    ]
      <> [ "| " <> show z <> " | " <> show d <> " | " <> show n <> " | " <> triple o <> " | " <> triple r <> " |"
         | z ← [0 .. 8]
         , let here = [(d', o', r') | (_, z', d', o', r') ← cells c, z' == z]
         , not (null here)
         , (d, o, r) : _ ← [here]
         , let n = length here
         ]
  where
    triple (a, b, d) = intercalate ", " (map show [a, b, d])
