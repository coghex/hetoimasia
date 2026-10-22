-- | The content suite: its components, in order.
--
-- Select one with @--match@: @Names@, @Types@, @Roots@, @Links@, @Reading@,
-- @Enumeration@, @Lifecycle@ or @Opacity@.
module Test.Content.Spec (spec) where

import qualified Test.Content.Enumeration as Enumeration
import qualified Test.Content.Lifecycle as Lifecycle
import qualified Test.Content.Links as Links
import qualified Test.Content.Names as Names
import qualified Test.Content.Opacity as Opacity
import qualified Test.Content.Reading as Reading
import qualified Test.Content.Roots as Roots
import qualified Test.Content.Types as Types
import Test.Hspec

spec ∷ Spec
spec = do
  describe "Names" Names.spec
  describe "Types" Types.spec
  describe "Roots" Roots.spec
  describe "Links" Links.spec
  describe "Reading" Reading.spec
  describe "Enumeration" Enumeration.spec
  describe "Lifecycle" Lifecycle.spec
  describe "Opacity" Opacity.spec
