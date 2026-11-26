-- | The terrain facade's examples (TRA-5), over the real terrain service, and the set that runs once more on several capabilities
-- (#692), named in ONE place.
--
-- THE SET is the whole directory. Every module but one runs real Lua instances over 'Test.LuaEngine.Terrain.Support.withRig':
-- the service's owner thread and its storage workers, supervised Lua owners, and the gates and fixtures that hold them; their
-- threads interleave on one capability and can execute at the same instant on two. The pump's own examples
-- ("Test.LuaEngine.Terrain.Pump") run real owners and the world's fake timer without a rig: they are in the set because the pump
-- is what every other member stands on, at every capability count. A module is added to 'entries' with its reason, or the
-- directory is no longer the set.
--
-- THE RULE. Nothing that measures the process may join the set: a live-heap, allocation or runtime-statistic reading is valid on
-- one capability only, beside nothing. No member reads one, compiles an external client or times anything.
--
-- The set runs twice: first in its place in the suite, each example on one capability with the count put back after it ('spec'),
-- so the lab's @+RTS -N<k>@ reaches nothing of the set there; then last, after every other example of the suite, under its own
-- label on the pass's count ('passSpec', "Test.Support.Capabilities"), so selection by exact path stays unambiguous.
module Test.LuaEngine.Terrain.Spec
  ( Entry (..)
  , entries
  , spec
  , passSpec
  , passLabel
  ) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Exception (finally)
import Control.Monad (forM_)
import Test.Hspec (Spec, around_, beforeAll_, describe, runIO)
import Test.Support.Capabilities (PassSetting, enterPass, inPass, passLine)
import qualified Test.LuaEngine.Terrain.Basics as Basics
import qualified Test.LuaEngine.Terrain.Composition as Composition
import qualified Test.LuaEngine.Terrain.Corners as Corners
import qualified Test.LuaEngine.Terrain.Domain as Domain
import qualified Test.LuaEngine.Terrain.Fixture as Fixture
import qualified Test.LuaEngine.Terrain.HostPublished as HostPublished
import qualified Test.LuaEngine.Terrain.Isolation as Isolation
import qualified Test.LuaEngine.Terrain.Limits as Limits
import qualified Test.LuaEngine.Terrain.Matrix as Matrix
import qualified Test.LuaEngine.Terrain.Model as Model
import qualified Test.LuaEngine.Terrain.Names as Names
import qualified Test.LuaEngine.Terrain.Ownership as Ownership
import qualified Test.LuaEngine.Terrain.Picks as Picks
import qualified Test.LuaEngine.Terrain.Pump as Pump
import qualified Test.LuaEngine.Terrain.Races as Races
import qualified Test.LuaEngine.Terrain.Region as Region
import qualified Test.LuaEngine.Terrain.Storage as Storage
import qualified Test.LuaEngine.Terrain.StorageFaults as StorageFaults
import qualified Test.LuaEngine.Terrain.Validation as Validation
import qualified Test.LuaEngine.Terrain.Windows as Windows

-- | A module of the set, why it is in it, and its examples.
data Entry = Entry
  { entryModule ∷ String
  , entryReason ∷ String
  , entrySpec ∷ Spec
  }

-- | The set, in the order it runs.
entries ∷ [Entry]
entries =
  [ Entry "Pump" "the pump every member steps its scripts with: real owners and the fake timer" Pump.spec
  , Entry "Basics" rig Basics.spec
  , Entry "Fixture" rig Fixture.spec
  , Entry "Composition" rig Composition.spec
  , Entry "Validation" rig Validation.spec
  , Entry "Corners" (rig <> ", a corner-mask definition authored in Lua against the native reads") Corners.spec
  , Entry "Domain" rig Domain.spec
  , Entry "Ownership" rig Ownership.spec
  , Entry "Names" rig Names.spec
  , Entry "HostPublished" (rig <> ", an arena the host published, with its windows held by gates and hooks") HostPublished.spec
  , Entry "Races" (rig <> ", ordered by gates") Races.spec
  , Entry "Limits" rig Limits.spec
  , Entry "Region" (rig <> ", a regional copy against the native snapshot, with the storage seam and gates held") Region.spec
  , Entry "Isolation" rig Isolation.spec
  , Entry "Picks" rig Picks.spec
  , Entry "Windows" (rig <> ", held at the adapter's hooks") Windows.spec
  , Entry "Matrix" rig Matrix.spec
  , Entry "Model" (rig <> ": two VMs against an independent model") Model.spec
  , Entry "Storage" (rig <> " and its storage workers") Storage.spec
  , Entry "StorageFaults" (rig <> ", with the storage workers held at the seam") StorageFaults.spec
  ]
  where
    rig = "real Lua owners over the production service (withRig)"

-- | The set in its place: every example on one capability, the started count put back after it.
spec ∷ Spec
spec = describe "Terrain" $ do
  started ← runIO getNumCapabilities
  around_ (\example → (setNumCapabilities 1 >> example) `finally` setNumCapabilities started) $
    forM_ entries entrySpec

-- | The label of the pass: a fixed text, so that an example's identity is the same at every capability count.
passLabel ∷ String
passLabel = "The multi-capability pass"

-- | The set once more, last, on the pass's count: before the first example the pass sets and prints its count; around each
-- example it sets the count, and fails when the runtime does not report it, before and after.
passSpec ∷ PassSetting → Spec
passSpec setting =
  describe passLabel
    $ beforeAll_ (enterPass setting >> passLine setting >>= putStrLn)
    $ around_ (inPass setting)
    $ describe "Terrain" (forM_ entries entrySpec)
