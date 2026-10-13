-- | The evidence's probe record (R2D-8): its shape, what it states of the
-- target and the swap demonstration, the counts it keeps, and how it escapes
-- a failure's message.
module Test.Sample.Image2d.Record (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Render.TwoD.Oracle (Expectation (..), Probe (..), Verdict (..))
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance (..))
import Hetoimasia.Sample.Image2d.Evidence
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "the probe record" $ do
  it "escapes a failure's message and states no swap when the run stopped early" $ do
    let record = renderRecord (Just "the \"batch\"\nfailed") 0 [] [] Nothing
    record `shouldSatisfy` Text.isInfixOf "\"failure\": \"the \\\"batch\\\"\\nfailed\""
    record `shouldSatisfy` Text.isInfixOf "\"swap\": null"
    record `shouldSatisfy` Text.isInfixOf "\"probes\": 0"
    countBraces record `shouldBe` 0

  it "records the target's metrics, the counts of what passed and what failed, and the swap demonstration" $ do
    let probes =
          [ ProbeResult (Probe 0 0 0) (Expected (Rgba8 0 0 0 255) (Tolerance 0 0 0 0)) (Just (Rgba8 0 0 0 255)) Passed
          , ProbeResult (Probe 0 1 0) (Expected (Rgba8 9 9 9 255) (Tolerance 0 0 0 0)) (Just (Rgba8 0 0 0 255)) (OutOfTolerance [])
          ]
        swap = SwapDemonstration (Just (True, False)) (Just True) True (Just True)
        record = renderRecord Nothing 262144 probes [] (Just swap)
    mapM_
      (\fragment → (fragment, Text.isInfixOf fragment record) `shouldBe` (fragment, True))
      [ "\"logical_extent\": [128, 128]"
      , "\"framebuffer_extent\": [256, 256]"
      , "\"content_scale\": [2.0, 2.0]"
      , "\"readback_bytes\": 262144"
      , "\"probes\": 2"
      , "\"determinate\": 2"
      , "\"determinate_passed\": 1"
      , "\"failed\": 1"
      , "\"refused_with_marks\": [true, false]"
      , "\"keep_accepted\": true"
      ]
    countBraces record `shouldBe` 0

-- | Opening braces and brackets less closing ones, outside strings: zero for
-- a balanced document.
countBraces ∷ Text → Int
countBraces = go False 0 . Text.unpack
  where
    go _ depth [] = depth
    go inString depth ('\\' : _ : rest) | inString = go inString depth rest
    go inString depth ('"' : rest) = go (not inString) depth rest
    go True depth (_ : rest) = go True depth rest
    go False depth (c : rest)
      | c `elem` ("{[" ∷ String) = go False (depth + 1) rest
      | c `elem` ("}]" ∷ String) = go False (depth - 1) rest
      | otherwise = go False depth rest
