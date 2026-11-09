-- | The terrain scenario's judging, proven without a
-- session, a display or consent.
--
-- When a target cannot be made, a batch cannot be recorded, completion is not awaited or a
-- readback is not read, the evidence harness returns a failed result with no probes. The
-- scenario must keep that failure as the fixture's, never replace it by an exception from
-- looking a pixel up, and never judge pixels against a readback that is not there.
--
-- Select them with @--match "a readback that is not there"@.
module Test.GPU.Vulkan.Native.TerrainJudgeSpec (spec) where

import Hetoimasia.Render.TwoD.Oracle (Probe (..), Verdict (..))
import qualified Hetoimasia.Render.TwoD.Oracle as Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance (..))
import Hetoimasia.Terrain.Render2D.Evidence (Expected (..), HandQuad (..), Role (..), shadedByte)
import Test.GPU.Vulkan.Native.OrderedPath (ProbeResult (ProbeResult))
import Test.GPU.Vulkan.Native.TerrainJudge
import Test.Hspec (Spec, describe, it, shouldBe)

black ∷ Rgba8
black = Rgba8 0 0 0 255

-- | A probe of pass 0 that read opaque black.
readAt ∷ Int → Int → ProbeResult
readAt x y = ProbeResult (Probe 0 x y) (Oracle.Expected black (Tolerance 0 0 0 0)) (Just black) Passed

spec ∷ Spec
spec = describe "judging a readback that is not there (the terrain scenario)" $ do
  it "looks a pixel up as nothing, in or out of the extent, rather than failing" $ do
    observedFrom 4 [] 0 0 `shouldBe` Nothing
    observedFrom 4 [] 3 2 `shouldBe` Nothing
    observedFrom 4 [readAt 0 0] 1 0 `shouldBe` Nothing
    observedFrom 4 [readAt 0 0] 0 0 `shouldBe` Just black
    observedFrom 4 [readAt 0 0] (-1) 0 `shouldBe` Nothing

  it "says a readback is incomplete unless it holds every pixel of every target" $ do
    completeReadback [(4, 3)] [] `shouldBe` False
    completeReadback [(4, 3)] (replicate 11 (readAt 0 0)) `shouldBe` False
    completeReadback [(4, 3)] (replicate 12 (readAt 0 0)) `shouldBe` True
    completeReadback [(2, 2), (3, 1)] (replicate 7 (readAt 0 0)) `shouldBe` True
    completeReadback [] [] `shouldBe` True

  it "splits the probes by pass without failing on too few" $ do
    map length (splitPasses [(2, 2), (3, 1)] (replicate 7 (readAt 0 0))) `shouldBe` [4, 3]
    map length (splitPasses [(2, 2), (3, 1)] (replicate 5 (readAt 0 0))) `shouldBe` [4, 1]
    map length (splitPasses [(2, 2), (3, 1)] []) `shouldBe` [0, 0]

  it "judges an empty readback as every pixel unread, without an exception" $ do
    let judged = judgeIndependent (4, 3) (const ExpectedClear) (observedFrom 4 [])
    indCompared judged `shouldBe` 12
    indMismatchCount judged `shouldBe` 12
    take 1 (indMismatches judged) `shouldBe` ["pixel (0,0) was not read"]

  describe "the independent judge's decisions (the terrain scenario)" $ do
    let quad = HandQuad (0, 0, 0) Ordinary "loam" "shape.00" (0, 0) (0, 0, 0, 0, 0) 0
        -- Linear 0.5 encodes to sRGB byte 188 (1.055 * 0.5 ^ (1 / 2.4) - 0.055 = 0.7354, times 255).
        hit = ExpectedHit {expectedFront = quad, expectedSkipped = [quad], expectedBehind = [], expectedLinear = (0.5, 0.5, 0.5), expectedTexel = (0, 0)}
        reading r = \_ _ → Just (Rgba8 r r r 255)
    it "encodes the hand-computed linear colour to its sRGB byte" $
      shadedByte (0.5, 0.5, 0.5) `shouldBe` (188, 188, 188)
    it "accepts a read within the declared tolerance and rejects one a step beyond it" $ do
      tolerance `shouldBe` 3
      indMismatchCount (judgeIndependent (1, 1) (const hit) (reading 191)) `shouldBe` 0
      indMismatchCount (judgeIndependent (1, 1) (const hit) (reading 185)) `shouldBe` 0
      indMismatchCount (judgeIndependent (1, 1) (const hit) (reading 192)) `shouldBe` 1
      indMismatchCount (judgeIndependent (1, 1) (const hit) (reading 184)) `shouldBe` 1
    it "counts an ambiguous pixel and never compares it" $ do
      let judged = judgeIndependent (2, 1) (const (Ambiguous "a texel boundary")) (reading 0)
      (indCompared judged, indAmbiguous judged, indMismatchCount judged) `shouldBe` (0, 2, 0)
    it "counts the covered pixels and the reveals a nearer transparent texel makes" $ do
      let judged = judgeIndependent (1, 1) (const hit) (reading 188)
      (indCompared judged, indCovered judged, indReveals judged, indMismatchCount judged) `shouldBe` (1, 1, 1, 0)
    it "expects the clear colour where nothing covers the pixel" $ do
      indMismatchCount (judgeIndependent (1, 1) (const ExpectedClear) (\_ _ → Just black)) `shouldBe` 0
      indMismatchCount (judgeIndependent (1, 1) (const ExpectedClear) (reading 40)) `shouldBe` 1
