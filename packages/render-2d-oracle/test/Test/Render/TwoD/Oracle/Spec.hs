-- | The render-2d-oracle suite: its components, in order.
--
-- Select one with @--match@: @Placement@, @Sampling@, @Colour@, @Probes@, @Depth@,
-- @Chunks@, @Clip@, @Materials@, @Animation@ or @Verdicts@.
module Test.Render.TwoD.Oracle.Spec (spec) where

import qualified Test.Render.TwoD.Oracle.Animation as Animation
import qualified Test.Render.TwoD.Oracle.Chunks as Chunks
import qualified Test.Render.TwoD.Oracle.Clip as Clip
import qualified Test.Render.TwoD.Oracle.Colour as Colour
import qualified Test.Render.TwoD.Oracle.Depth as Depth
import qualified Test.Render.TwoD.Oracle.Materials as Materials
import qualified Test.Render.TwoD.Oracle.Placement as Placement
import qualified Test.Render.TwoD.Oracle.Probes as Probes
import qualified Test.Render.TwoD.Oracle.Sampling as Sampling
import qualified Test.Render.TwoD.Oracle.Verdicts as Verdicts
import Test.Hspec

spec ∷ Spec
spec = do
  describe "Placement" Placement.spec
  describe "Sampling" Sampling.spec
  describe "Colour" Colour.spec
  describe "Probes" Probes.spec
  describe "Depth" Depth.spec
  describe "Clip" Clip.spec
  describe "Chunks" Chunks.spec
  describe "Materials" Materials.spec
  describe "Animation" Animation.spec
  describe "Verdicts" Verdicts.spec
