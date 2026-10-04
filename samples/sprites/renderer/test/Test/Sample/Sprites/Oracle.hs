-- | The sprites scene and its independent oracle, with no device: the draws'
-- structure, the filter distinction, atlas selection, painter order within
-- and across draws, alpha and clear expectations, tolerances, and the
-- probes' verdicts over synthetic readbacks.
module Test.Sample.Sprites.Oracle (spec) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Recording (TableSampler (..))
import Hetoimasia.Sample.Sprites.Fixtures
import Hetoimasia.Sample.Sprites.Oracle
import Hetoimasia.Sample.Sprites.Scene
import Hetoimasia.Sample.Sprites.Swap (swappedTextures)

spec ∷ Spec
spec = describe "Sprites scene and oracle" $ do
  it "draws a nearest-clamp draw of at least 1,000 instances over both RGBA8 textures, then a separate linear-clamp draw, and BC7 only when it is taken" $ do
    let draws = sceneDraws True
    map (\draw → (drawName draw, drawFilter draw)) draws `shouldBe` [(GridDraw, NearestClamp), (LinearDraw, LinearClamp), (Bc7Draw, NearestClamp)]
    case draws of
      grid : _ → do
        length (drawInstances grid) `shouldSatisfy` (>= 1000)
        Map.keys (Map.fromList [(instanceTexture i, ()) | i ← drawInstances grid]) `shouldBe` [Atlas, Translucent]
      [] → expectationFailure "no draws"
    map drawName (sceneDraws False) `shouldBe` [GridDraw, LinearDraw]
    [() | p ← sceneProbes False, probePurpose p == Bc7Texels] `shouldBe` []
    length [() | p ← sceneProbes True, probePurpose p == Bc7Texels] `shouldBe` 2

  it "distinguishes the filters at the same atlas coordinate across the red/green boundary: nearest red, linear a quarter green, unequal" $ do
    let nearest = expect "red/green boundary, nearest"
        linear = expect "red/green boundary, linear"
    nearest `shouldBe` Expectation (Rgba 255 0 0 255) 0
    linear `shouldBe` Expectation (Rgba 191 64 0 255) 1
    expectedRgba nearest `shouldNotBe` expectedRgba linear

  it "expects each atlas region in its own colour, so a wrong rectangle fails, and the large draw's cells likewise" $ do
    map (expectedRgba . expect) ["atlas red region", "atlas green region", "atlas blue region", "atlas yellow region"]
      `shouldBe` [Rgba 255 0 0 255, Rgba 0 255 0 255, Rgba 0 0 255 255, Rgba 255 255 0 255]
    map expect ["grid red region (0,0)", "grid translucent red (7,3)", "grid green region (30,31)"]
      `shouldBe` [Expectation (Rgba 255 0 0 255) 0, Expectation (Rgba 128 0 0 128) 0, Expectation (Rgba 0 255 0 255) 0]

  it "composes premultiplied red then blue as (64,0,128,192) within a draw and across the draw boundary — not the reversed (128,0,64,192) — with the alpha of each region" $ do
    map expect ["red then blue, one draw", "red then blue, across the draw boundary"]
      `shouldBe` replicate 2 (Expectation (Rgba 64 0 128 192) 1)
    let reversed = Rgba 128 0 64 192
    map (\name → within (expect name) reversed) ["red then blue, one draw", "red then blue, across the draw boundary"] `shouldBe` [False, False]
    map (expectedRgba . expect) ["translucent red alone", "translucent blue alone", "translucent red alone, before the boundary", "translucent blue alone, after the boundary"]
      `shouldBe` [Rgba 128 0 0 128, Rgba 0 0 128 128, Rgba 128 0 0 128, Rgba 0 0 128 128]

  it "expects the transparent clear exactly where nothing is drawn, and the BC7 endpoints exactly where it is" $ do
    [expect (probeName p) | p ← sceneProbes False, probePurpose p == Clear] `shouldSatisfy` all (== Expectation transparent 0)
    map (expectation True) [p | p ← sceneProbes True, probePurpose p == Bc7Texels]
      `shouldBe` [Expectation (Rgba 255 1 1 255) 0, Expectation (Rgba 1 1 255 255) 0]

  it "passes a readback holding every expectation, and fails one with the overlap reversed, one channel off by two, or a short readback" $ do
    let probes = sceneProbes True
        image = paint [(probePixel p, expectedRgba (expectation True p)) | p ← probes]
    probesPassed (evaluateProbes True image) `shouldBe` True
    let overlap = head' [probePixel p | p ← probes, probeName p == "red then blue, across the draw boundary"]
    probesPassed (evaluateProbes True (paint ((overlap, Rgba 128 0 64 192) : [(probePixel p, expectedRgba (expectation True p)) | p ← probes, probePixel p /= overlap]))) `shouldBe` False
    let atlas = head' [probePixel p | p ← probes, probeName p == "atlas red region"]
    probesPassed (evaluateProbes True (paint ((atlas, Rgba 253 0 0 255) : [(probePixel p, expectedRgba (expectation True p)) | p ← probes, probePixel p /= atlas]))) `shouldBe` False
    probesPassed (evaluateProbes True (ByteString.take 1024 image)) `shouldBe` False

  it "expects the swap case's replacement atlas, of the same layout, in every atlas region and grid cell it reaches, and the other fixtures unchanged (GRS-9)" $ do
    let swapped name = case [p | p ← sceneProbes False, probeName p == name] of
          p : _ → expectationWith swappedTextures False p
          [] → error ("no probe named " <> show name)
    map (expectedRgba . swapped) ["atlas red region", "atlas green region", "atlas blue region", "atlas yellow region"]
      `shouldBe` [Rgba 0 255 0 255, Rgba 0 0 255 255, Rgba 255 255 0 255, Rgba 255 0 0 255]
    map (expectedRgba . swapped) ["grid red region (0,0)", "grid translucent red (7,3)"] `shouldBe` [Rgba 0 255 0 255, Rgba 128 0 0 128]
    -- Every probe the atlas reaches differs, and no other probe does.
    let probes = sceneProbes True
        differs p = expectationWith swappedTextures True p /= expectation True p
    [probePurpose p | p ← probes, differs p] `shouldSatisfy` all (`elem` [AtlasSelection, FilterDistinction, LargeDraw])
    [probeName p | p ← probes, probePurpose p == AtlasSelection, not (differs p)] `shouldBe` []
    [probeName p | p ← probes, probePurpose p `elem` [Translucency, PainterOrder, Clear, Bc7Texels], differs p] `shouldBe` []
    -- The replacement keeps the atlas's layout, so the linear probe keeps
    -- its margin: a quarter of the next region, within one.
    expectationWith swappedTextures False (head' [p | p ← probes, probeName p == "red/green boundary, linear"]) `shouldBe` Expectation (Rgba 0 191 64 255) 1
    (fixtureWidth swappedAtlasFixture, fixtureHeight swappedAtlasFixture, fixtureFormat swappedAtlasFixture) `shouldBe` (fixtureWidth atlasFixture, fixtureHeight atlasFixture, fixtureFormat atlasFixture)

  it "encodes 40 bytes an instance, its handle's index and generation last" $ do
    let item = Instance Atlas (UvRect 0 0 1 1) (1, 2, 3, 4)
        bytes = encodeInstances (const (7, 9)) [item, item]
    ByteString.length bytes `shouldBe` 2 * fromIntegral instanceStride
    ByteString.unpack (ByteString.take 8 (ByteString.drop 32 bytes)) `shouldBe` [7, 0, 0, 0, 9, 0, 0, 0]
  where
    expect name = case [p | p ← sceneProbes False, probeName p == name] of
      p : _ → expectation False p
      [] → error ("no probe named " <> show name)

-- | A readback of the target, transparent but for these pixels.
paint ∷ [((Int, Int), Rgba)] → ByteString
paint pixels =
  ByteString.pack (concat [maybe [0, 0, 0, 0] channels (lookup (x, y) pixels) | y ← [0 .. targetSide - 1], x ← [0 .. targetSide - 1]])
  where
    channels ∷ Rgba → [Word8]
    channels (Rgba r g b a) = [r, g, b, a]

head' ∷ [a] → a
head' = \case
  x : _ → x
  [] → error "empty"
