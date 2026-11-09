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

import Data.List (intercalate)
import Data.Word (Word8)
import Hetoimasia.Terrain.Render2D.Evidence (HandLight (..), defaultHandLight, handShade, shadedByte)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Hspec

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
  it "writes the labelled comparison when asked" $ do
    destination ← lookupEnv "HETOIMASIA_TRA17_REFERENCE_DIR"
    let text = renderComparison
    length (lines text) `shouldSatisfy` (> 15)
    case destination of
      Nothing → pure ()
      Just directory → do
        createDirectoryIfMissing True directory
        writeFile (directory </> "reference-tint-comparison.md") text

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
