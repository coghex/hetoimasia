-- | The content suite: its components, in order.
--
-- Select one with @--match@: @Names@, @Types@, @Roots@, @Links@, @Reading@,
-- @Enumeration@, @Lifecycle@, @Opacity@, or, for the logical identity policy,
-- @Identity@ (with the components @Reference@, @Unicode@, @Mapping@ and
-- @Identity boundary@).
module Test.Content.Spec (spec) where

import qualified Test.Content.Enumeration as Enumeration
import qualified Test.Content.Identity.Boundary as IdentityBoundary
import qualified Test.Content.Identity.Mapping as IdentityMapping
import qualified Test.Content.Identity.Reference as IdentityReference
import qualified Test.Content.Identity.Unicode as IdentityUnicode
import qualified Test.Content.Inventory.Changes as InventoryChanges
import qualified Test.Content.Inventory.Limits as InventoryLimits
import qualified Test.Content.Inventory.Scan as InventoryScan
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
  describe "Identity" $ do
    describe "Reference" IdentityReference.spec
    describe "Unicode" IdentityUnicode.spec
    describe "Mapping" IdentityMapping.spec
    describe "Identity boundary" IdentityBoundary.spec
  describe "Inventory" $ do
    describe "Scan" InventoryScan.spec
    describe "Limits" InventoryLimits.spec
    describe "Changes" InventoryChanges.spec
