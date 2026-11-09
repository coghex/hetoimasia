-- | The work the texture backend's pump and the fake owner do, counted by site, so that an example can bound it
-- by what was examined and never by how long it took (#679).
--
-- A /unit/ is one record examined or one list cell traversed at the site named: a candidate the pump evaluated, an
-- upload or release request the owner's loop read, an image or upload a scan walked. A site that finds its record
-- directly (a map lookup, a cons) counts one, and a site that walks a collection counts one for the operation and one
-- for each record it walks, so that a scan of an empty collection is still the operation it was. Each site counts where it
-- traverses, and the counts a bound compares (see "Test.LuaEngine.Graphics.Facade") are compared with the operations the
-- scenario performs, which the fake's own log records independently of these counters.
--
-- Owner, writers, readers, thread, lifetime: a 'Work' is made by 'Test.LuaEngine.Graphics.Fake.newFake' and lives
-- as long as its fake. Every thread that traverses a site writes it ('tally'); the example that bounds the work reads
-- it ('readWork') after the scenario's scope ended, when no thread writes any more. It is never reset.
--
-- A counter is written from inside an STM transaction, and a transaction that retries, or that the runtime
-- restarts because a variable it read changed, runs again. 'tally' is a side effect that is not rolled back, so a
-- count is the work /attempted/: every evaluation of the transaction, including those that did not commit. This is
-- deliberate. A complete unsuccessful search, which the pump retries on, is exactly the work a quadratic pump
-- does and a committed-only count would lose; and how many times the scheduler restarts a transaction is bounded by
-- the writes that happen, so it grows with the scenario's operations and not with the records the site traverses.
-- The bounds the examples assert leave room for that variation (a linear total over four times the size is four;
-- they allow six) and are a long way below what a quadratic total gives (sixteen).
module Test.LuaEngine.Graphics.Work
  ( Site (..)
  , Work
  , newWork
  , tally
  , readWork
  , tallyExamined
  ) where

import Control.Concurrent.STM (STM)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import GHC.Conc (unsafeIOToSTM)
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (Examined (..))

-- | Where work is counted.
data Site
  = -- | The pump evaluated a job.
    PumpJobs
  | -- | The pump evaluated a texture that has a step or waits on something.
    PumpTextures
  | -- | The pump evaluated the table's bootstrap.
    PumpBoot
  | -- | The close's drain read a texture.
    PumpDrain
  | -- | The fake owner's loop read an open upload.
    OwnerUploads
  | -- | The fake owner's loop read a queued release request.
    OwnerReleases
  | -- | The fake's admission of an upload walked an upload.
    Admission
  | -- | The fake's allocation looked at an image to count those alive.
    Allocation
  | -- | The fake's release looked at an image to find the one holding a slot.
    ReleaseLookup
  | -- | The fake's event log walked a cell to append an event.
    EventAppend
  | -- | The fake's list of free slots walked a cell to return a slot.
    SlotAppend
  deriving (Eq, Ord, Show, Enum, Bounded)

newtype Work = Work (Map Site (IORef Int))

newWork ∷ IO Work
newWork = Work . Map.fromList <$> traverse (\site → (,) site <$> newIORef 0) [minBound .. maxBound]

-- | Add units to a site, from inside a transaction (see the module's note on retries).
tally ∷ Work → Site → Int → STM ()
tally (Work counters) site units = case Map.lookup site counters of
  Just ref → unsafeIOToSTM (atomicModifyIORef' ref (\now → (now + units, ())))
  Nothing → pure ()

-- | Every site's count.
readWork ∷ Work → IO (Map Site Int)
readWork (Work counters) = traverse readIORef counters

-- | The observer 'Hetoimasia.LuaEngine.Graphics.Texture.Backend.withBackendObserved' is given.
tallyExamined ∷ Work → Examined → STM ()
tallyExamined work = \case
  ExaminedJob → tally work PumpJobs 1
  ExaminedTexture → tally work PumpTextures 1
  ExaminedBoot → tally work PumpBoot 1
  ExaminedDrain → tally work PumpDrain 1
