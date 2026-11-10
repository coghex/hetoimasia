-- | The work the texture backend's pump and the fake owner do, counted by site, so that an example can bound it by what
-- was examined and never by how long it took (#679).
--
-- A /unit/ is one record examined or one list cell traversed at the site named: a candidate the pump evaluated, an
-- upload or release request the owner's loop read, an image or upload a scan walked. An operation that finds its record
-- directly (a map lookup, a cons) is one unit; one that walks a collection is one unit and one for each record it walks, so
-- that a scan of an empty collection is still the operation it was.
--
-- = Where a unit is charged: with the traversal, by construction
--
-- The fake owner keeps its history in the counted collections below ('CMap', 'CList', 'CSeq'), whose constructors are
-- private. Every operation on one takes the meter of its site and charges what that operation traverses: a lookup or a
-- cons one, a walk of the whole collection its size, an append at the tail the length of what it walks past. Code that
-- scans a collection, or appends at its tail, therefore charges its traversal whatever site it sits at and without any
-- other line changing; the only way past a charge is 'cmObserve' and its peers, which read a collection for an observer
-- and are used only where no operation of the scenario is running. A mutation that restores a scan is a change of the
-- operation at its call site (see the pull request's negative controls) and nothing else.
--
-- = What is asserted, and what is only reported
--
-- A transaction that retries, or that the runtime restarts because a variable it read changed, runs again, and a side
-- effect of its attempt is not rolled back. How often that happens depends on the scheduler, so a total taken over attempts
-- is a diagnostic and never an assertion ('rAttempted', shown when an example fails). An example asserts two measures that
-- the scheduler does not move:
--
-- * 'rPeak': the most units a single operation or pump evaluation charged at the site. A maximum is the same whether an
--   attempt ran once or five times, so it also covers the complete unsuccessful search a pump retries on, which a count
--   of committed work would lose. A site that looks at everything retained has a peak that grows with the size.
-- * 'rCommitted': the units of operations that committed, a total over the scenario. A committed operation is a logical
--   one: a fake operation charges inside its own transaction, into a variable that a retry rolls back ('charge'); the
--   owner's loop returns its charges from the transaction and commits them after it ('commitIO'); the pump's evaluation
--   keeps what it saw since 'ExaminedEvaluation' and commits it when the backend reports the evaluation committed.
--
-- Owner, writers, readers, thread, lifetime: a 'Work' is made by 'Test.LuaEngine.Graphics.Fake.newFake' and lives as long
-- as its fake. Every thread that traverses a site writes it; the example that bounds the work reads it ('readWork') after
-- the scenario's scope ended, when no thread writes any more. It is never reset.
module Test.LuaEngine.Graphics.Work
  ( Site (..)
  , Work
  , Reading (..)
  , Meter
  , newWork
  , readWork
  , charge
  , observe
  , commitIO
  , pumpObserver
  , -- * Counted collections
    CMap
  , cmEmpty
  , cmSize
  , cmLookup
  , cmInsert
  , cmDelete
  , cmAdjust
  , cmToList
  , cmObserve
  , CList
  , clEmpty
  , clCons
  , clSnoc
  , clObserve
  , CSeq
  , csFromListInitial
  , csToList
  , csFromList
  , csPopFront
  , csPush
  , csAppendList
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, ViewL (EmptyL, (:<)), (><), (|>))
import qualified Data.Sequence as Seq
import GHC.Conc (unsafeIOToSTM)
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (Examined (..))

-- | Where work is charged.
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
  | -- | The fake's admission of an upload read the open uploads.
    Admission
  | -- | The fake looked up or recorded an upload in the history of every upload it admitted.
    UploadHistory
  | -- | The fake looked up or recorded an image's state.
    ImageMap
  | -- | The fake looked up or recorded the image a slot holds.
    SlotOwners
  | -- | The fake's event log added an event.
    EventLog
  | -- | The fake's queue of free slots took a slot or gave one back.
    FreeSlots
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a site has been charged: the same three counts for each, read after the scenario.
data Reading = Reading
  { rCommitted ∷ !(Map Site Int)
    -- ^ The units of operations that committed.
  , rPeak ∷ !(Map Site Int)
    -- ^ The most one operation (or one pump evaluation) charged, over every attempt.
  , rAttempted ∷ !(Map Site Int)
    -- ^ The units of every attempt, restarted and retried ones included: a diagnostic, never asserted.
  }
  deriving (Eq, Show)

data Work = Work
  { wCommitted ∷ !(Map Site (TVar Int))
  , wPeak ∷ !(Map Site (IORef Int))
  , wAttempted ∷ !(Map Site (IORef Int))
  , wPending ∷ !(Map Site (IORef Int))
    -- ^ What the pump's current evaluation has examined at each of its sites; reset as an evaluation begins.
  }

-- | A function that charges a number of units, at one site, for the operation that calls it.
type Meter = Int → STM ()

newWork ∷ IO Work
newWork =
  Work
    <$> each (newTVarIO 0)
    <*> each (newIORef 0)
    <*> each (newIORef 0)
    <*> each (newIORef 0)
  where
    each make = Map.fromList <$> traverse (\site → (,) site <$> make) [minBound .. maxBound]

-- | Every site's counts.
readWork ∷ Work → IO Reading
readWork work =
  Reading
    <$> traverse readTVarIO (wCommitted work)
    <*> traverse readIORef (wPeak work)
    <*> traverse readIORef (wAttempted work)

-- | Note an attempt's units, from inside a transaction that may be retried or restarted: the attempted total and the peak, which
-- no restart moves. It is a side effect that is not rolled back.
observe ∷ Work → Site → Int → STM ()
observe work site units = unsafeIOToSTM $ do
  forRef (wAttempted work) site (\now → now + units)
  forRef (wPeak work) site (max units)

-- | Note units and count them as committed, from a transaction that never waits. The committed count is a variable of the
-- transaction, so a retried or restarted attempt does not keep it, and a transaction that waited would be woken by every other
-- charge: the owner's loop and the pump therefore never use this ('commitIO' and the pump's own flush).
charge ∷ Work → Site → Int → STM ()
charge work site units = do
  observe work site units
  maybe (pure ()) (\var → modifyTVar' var (+ units)) (Map.lookup site (wCommitted work))

-- | Count units as committed, after the transaction that observed them committed.
commitIO ∷ Work → Site → Int → IO ()
commitIO work site units = case Map.lookup site (wCommitted work) of
  Just var | units /= 0 → atomically (modifyTVar' var (+ units))
  _ → pure ()

forRef ∷ Map Site (IORef Int) → Site → (Int → Int) → IO ()
forRef refs site change = case Map.lookup site refs of
  Just ref → atomicModifyIORef' ref (\now → (change now, ()))
  Nothing → pure ()

-- | The observers 'Hetoimasia.LuaEngine.Graphics.Texture.Backend.withBackendObserved' is given: what the pump looks at.
--
-- An evaluation begins at 'ExaminedEvaluation' (a restarted one begins again, so what it examined before is forgotten), counts
-- the candidates it examines of each kind, and charges them as committed when the backend reports it committed. Its peak is the
-- most any one evaluation examined. The close's drain is observed only: it waits in a transaction of its own.
pumpObserver ∷ Work → (Examined → STM (), IO ())
pumpObserver work = (examined, committed)
  where
    sites = [PumpJobs, PumpTextures, PumpBoot]
    examined = \case
      ExaminedEvaluation → unsafeIOToSTM (mapM_ (\site → forRef (wPending work) site (const 0)) sites)
      ExaminedJob → candidate PumpJobs
      ExaminedTexture → candidate PumpTextures
      ExaminedBoot → candidate PumpBoot
      ExaminedDrain → observe work PumpDrain 1
    candidate site = unsafeIOToSTM $ do
      forRef (wAttempted work) site (+ 1)
      case Map.lookup site (wPending work) of
        Just pending → do
          seen ← atomicModifyIORef' pending (\now → (now + 1, now + 1))
          forRef (wPeak work) site (max seen)
        Nothing → pure ()
    committed = mapM_ flush sites
    flush site = case Map.lookup site (wPending work) of
      Just pending → do
        seen ← readIORef pending
        writeIORef pending 0
        commitIO work site seen
      Nothing → pure ()

-- Counted collections ----------------------------------------------------------------------------------

-- | A map whose operations charge what they traverse.
newtype CMap k v = CMap (Map k v)

cmEmpty ∷ CMap k v
cmEmpty = CMap Map.empty

-- | Its size, which the map keeps: not a traversal.
cmSize ∷ CMap k v → Int
cmSize (CMap m) = Map.size m

cmLookup ∷ Ord k ⇒ Meter → k → CMap k v → STM (Maybe v)
cmLookup meter key (CMap m) = meter 1 >> pure (Map.lookup key m)

cmInsert ∷ Ord k ⇒ Meter → k → v → CMap k v → STM (CMap k v)
cmInsert meter key value (CMap m) = meter 1 >> pure (CMap (Map.insert key value m))

cmDelete ∷ Ord k ⇒ Meter → k → CMap k v → STM (CMap k v)
cmDelete meter key (CMap m) = meter 1 >> pure (CMap (Map.delete key m))

cmAdjust ∷ Ord k ⇒ Meter → (v → v) → k → CMap k v → STM (CMap k v)
cmAdjust meter change key (CMap m) = meter 1 >> pure (CMap (Map.adjust change key m))

-- | Every entry, in key order: a walk of the whole map.
cmToList ∷ Meter → CMap k v → STM [(k, v)]
cmToList meter (CMap m) = meter (1 + Map.size m) >> pure (Map.toList m)

-- | The map for an observer that runs when no operation does (an example reading what the fake did after its scope).
cmObserve ∷ CMap k v → Map k v
cmObserve (CMap m) = m

-- | A list that is added to at its head, newest first.
newtype CList a = CList [a]

clEmpty ∷ CList a
clEmpty = CList []

-- | Add at the head: one cell.
clCons ∷ Meter → a → CList a → STM (CList a)
clCons meter x (CList xs) = meter 1 >> pure (CList (x : xs))

-- | Add at the tail: a walk past every cell there is.
clSnoc ∷ Meter → CList a → a → STM (CList a)
clSnoc meter (CList xs) x = meter (1 + length xs) >> pure (CList (xs <> [x]))

clObserve ∷ CList a → [a]
clObserve (CList xs) = xs

-- | A queue of values, taken from the front and added at the back.
newtype CSeq a = CSeq (Seq a)

-- | The queue as the fake is made with it, before any operation of a scenario runs.
csFromListInitial ∷ [a] → CSeq a
csFromListInitial = CSeq . Seq.fromList

-- | The front, if any: one cell.
csPopFront ∷ Meter → CSeq a → STM (Maybe (a, CSeq a))
csPopFront meter (CSeq s) = meter 1 >> pure (case Seq.viewl s of
  EmptyL → Nothing
  x :< rest → Just (x, CSeq rest))

-- | Add at the back: one cell.
csPush ∷ Meter → CSeq a → a → STM (CSeq a)
csPush meter (CSeq s) x = meter 1 >> pure (CSeq (s |> x))

-- | Add several at the back: a cell for each.
csAppendList ∷ Meter → CSeq a → [a] → STM (CSeq a)
csAppendList meter (CSeq s) xs = meter (1 + length xs) >> pure (CSeq (s >< Seq.fromList xs))

-- | Every value, front first: a walk of the whole queue.
csToList ∷ Meter → CSeq a → STM [a]
csToList meter (CSeq s) = meter (1 + Seq.length s) >> pure (foldr (:) [] s)

-- | A queue made of these values, back to front: a cell for each.
csFromList ∷ Meter → [a] → STM (CSeq a)
csFromList meter xs = meter (1 + length xs) >> pure (CSeq (Seq.fromList xs))
