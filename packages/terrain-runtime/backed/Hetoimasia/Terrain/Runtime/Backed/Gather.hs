-- | Reading the removed runs of some columns from a pinned committed version of the store,
-- through the storage backend, as a resumable state machine.
--
-- Every read of terrain a client can ask for (a cell, a column's runs, a surface) and every
-- load of resident detail is answered from the immutable source plus the removals that are
-- authoritative in the store. This is how those removals are fetched: a reader pins one
-- committed version ('startGather'), the runs of each column are read in key order through a
-- window that holds at most the pages one reader may pin ('readerPinnedCacheBytes', 32), and the
-- caller builds the answer with the pure query functions over the runs it was given. A page
-- the read needs and the window lacks is a read job to the backend, never an empty answer, never
-- air and never the pristine source: a missing or contradicting page is a typed outcome.
--
-- == One wait, no polling
--
-- 'stepGather' takes every step that needs no waiting and, when it needs a page, submits ONE
-- read job and names the wait ('GBlocked'); the owner composes that wait with its other sources
-- and calls it again. The pin is released by 'endGather' on EVERY exit: success, a typed
-- failure, a cancellation, an exception.
--
-- == State, owner, thread, lifetime
--
-- A 'Gather' and the 'Store' it pins are the terrain owner's, on its one thread. The pin is a
-- record in the store (accounted as a reader record) and lives from 'startGather' to 'endGather'.
-- The window's pages are copies the window made (the service's result buffer is retired inside the
-- outcome's borrow), at most 32 of them.
module Hetoimasia.Terrain.Runtime.Backed.Gather
  ( Gather
  , GatherRefusal (..)
  , startGather
  , startGatherWith
  , stepGather
  , cancelGather
  , endGather
  , gatherInFlight
  , gatherVersion
  , GProgress (..)
  , gatherWindowPages
  , gatherPeakWindow
  , gatherPinLimit
  ) where

import Control.Concurrent.STM (STM, atomically)
import Data.Int (Int64)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( BackingView (..)
  , Outcome
  , ReadMode (..)
  , Ticket
  , awaitTicket
  , backingView
  , cancelTicket
  , discardTicket
  , pollTicket
  , submitRead
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (StorageFailure (BackingClosed))
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (readerPinnedCacheBytes)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo, TreeId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( Condition (..)
  , ReadOutcome (..)
  , ReaderRefusal
  , ReaderToken
  , Store
  , acquireReader
  , maxRangeRecords
  , readerRange
  , readerVersion
  , readerWindow
  , releaseReader
  , storeConfig
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (IntegrityWhy, RangeStart (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.State (StoreConfig, cfgTotalPages, windowPageBytes)
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (Supply (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Window, windowInsert, windowSize)

-- | The pages one reader may pin: its window never holds more.
gatherPinLimit ∷ Int
gatherPinLimit = fromIntegral (readerPinnedCacheBytes `div` fromIntegral windowPageBytes)

-- | A reader's pinned continuation.
data Gather = Gather
  { gToken ∷ !ReaderToken
  , gWindow ∷ !Window
  , gColumns ∷ ![Column]
  -- ^ Columns still to read (the one in progress first).
  , gStart ∷ !(Maybe RangeStart)
  -- ^ Where the column in progress resumes; 'Nothing' before its first call.
  , gPin ∷ !Int
  -- ^ The pages this reader may pin.
  , gLimit ∷ !Int
  -- ^ Records the next ranged read asks for; halved when a fresh window of 'gatherPinLimit' pages is not enough.
  , gStrikes ∷ !Int
  -- ^ Times in a row the window filled before the call could finish.
  , gPeak ∷ !Int
  -- ^ The most pages the window held when a ranged read answered.
  , gRuns ∷ ![(Column, Int64, Int64)]
  -- ^ Runs found, newest first.
  , gFetch ∷ !(Maybe (PageNo, Ticket))
  , gVersion ∷ !Word64
  -- ^ The committed version the pin holds.
  , gDraining ∷ !Bool
  -- ^ The owner cancelled the gather: a read in flight is drained, never taken.
  }

-- | The window the gather holds, in pages (for the bound's example and the evidence).
gatherWindowPages ∷ Gather → Int
gatherWindowPages = windowSize . gWindow

-- | The most pages the window held when a ranged read answered (the evidence of the window's bound).
gatherPeakWindow ∷ Gather → Int
gatherPeakWindow = gPeak

-- | Where a step left the gather.
data GProgress
  = -- | A step was taken and nothing is owed: step again (after serving whatever else the owner has to do).
    GMore
  | -- | Wait for this (one read job), then 'stepGather' again.
    GBlocked !(STM ())
  | -- | Every run of every column, ascending by column and level. The pin is still held: 'endGather'.
    GDone ![(Column, Int64, Int64)]
  | -- | The read ended with the decision for its cause. The pin is still held: 'endGather'.
    GFailed !Handling
  | -- | The gather was cancelled and its read job has drained: nothing of the backend is held for it. The
    -- pin is still held: 'endGather'.
    GDrained

-- | Why a gather could not begin.
data GatherRefusal
  = -- | The store has as many readers as it may pin: wait for one to be released.
    NoPin !ReaderRefusal
  | -- | The pin the store had just handed out was refused by its own window: a defect.
    PinRefused
  deriving stock (Eq, Show)

-- | Pin the committed version and begin reading the runs of the columns.
startGather ∷ Store → [Column] → Either GatherRefusal (Store, Gather)
startGather = startGatherWith gatherPinLimit

-- | 'startGather' with a smaller number of pinned pages, so a suite can reach the window's limit with a
-- small store. The production bound is 'gatherPinLimit'.
startGatherWith ∷ Int → Store → [Column] → Either GatherRefusal (Store, Gather)
startGatherWith pin store columns = case acquireReader store of
  Left refusal → Left (NoPin refusal)
  Right (token, pinned) → case (readerWindow pinned token, readerVersion pinned token) of
    (Right window, Right version) → Right (pinned, Gather token window columns Nothing pin maxRangeRecords 0 0 [] Nothing version False)
    _ → Left PinRefused

-- | End a gather: the pin is released (releasing twice changes nothing). Called on every exit, and only
-- once no read of it is in flight ('GDone', 'GFailed' or 'GDrained').
endGather ∷ Store → Gather → Store
endGather store g = snd (releaseReader (gToken g) store)

-- | Whether a read job of the gather is in flight (submitted and not yet taken).
gatherInFlight ∷ Gather → Bool
gatherInFlight = maybe False (const True) . gFetch

-- | The version the gather pinned.
gatherVersion ∷ Gather → Word64
gatherVersion = gVersion

-- | Take ONE step: take a finished read's outcome, or make one ranged read of the store (which may ask for
-- one page). The owner calls it masked. A step is bounded by one ranged read: at most 'maxRangeRecords'
-- records through a window of at most the gather's pinned pages.
stepGather ∷ Io → Closing → Store → Gather → IO (Gather, GProgress)
stepGather io closing store g = case gFetch g of
  Just (page, ticket) → do
    finished ← atomically (pollTicket (ioService io) ticket)
    if not finished
      then pure (g, GBlocked (awaitTicket (ioService io) ticket))
      else
        if gDraining g
          then discardTicket (ioService io) ticket >> pure (g {gFetch = Nothing}, GDrained)
          else
            withOutcome (ioService io) ticket (\outcome → pure $! supplied closing (storeConfig store) page (gWindow g) outcome) >>= \case
              -- a finished job whose outcome cannot be taken: the closure, or a lost ticket (never a spin)
              Nothing → (\handling → (g {gFetch = Nothing}, GFailed handling)) <$> lostTicket closing io
              Just (Left handling) → pure (g {gFetch = Nothing}, GFailed handling)
              Just (Right window) → pure (g {gWindow = window, gFetch = Nothing}, GMore)
  Nothing
    | gDraining g → pure (g, GDrained)
    | otherwise → case gColumns g of
        [] → pure (g, GDone (reverse (gRuns g)))
        column : rest →
          let start = maybe (RangeFrom (KeyRun column minBound)) id (gStart g)
           in case readerRange store (gToken g) (gWindow g) TreeRuns start (gLimit g) of
                Read records →
                  let mine = [(col, lo, hi) | (KeyRun col lo, RecRun hi) ← records, col == column]
                      -- the column ends at the first record of another column, or when the tree ends
                      ended = length mine < length records || length records < gLimit g
                      next = case reverse records of
                        (key, _) : _ → Just (RangeAfter key)
                        [] → Nothing
                      g' = g {gRuns = reverse mine <> gRuns g, gStrikes = 0, gPeak = max (gPeak g) (windowSize (gWindow g))}
                   in pure $
                        if ended
                          then (g' {gColumns = rest, gStart = Nothing, gLimit = maxRangeRecords}, GMore)
                          else (g' {gStart = next}, GMore)
                ReadNeeds page
                  | windowSize (gWindow g) >= gPin g →
                      -- the pin holds no more pages. A fresh window first; if the same call fills a fresh
                      -- window too, it asks for fewer records
                      pure $
                        if gStrikes g == 0
                          then ((restart g) {gStrikes = 1}, GMore)
                          else
                            if gLimit g > 1
                              then ((restart g) {gLimit = gLimit g `div` 2, gStrikes = 0}, GMore)
                              else (g, GFailed (HandleDefect "one record did not fit the pages a reader may pin"))
                  | otherwise →
                      submitRead (ioService io) (ioBacking io) (ioClass io) (storeConfig store) page 1 ReadValidated >>= \case
                        Left failure → pure (g, GFailed (classifyFailure closing JkRead failure))
                        Right ticket → pure (g {gFetch = Just (page, ticket)}, GBlocked (awaitTicket (ioService io) ticket))
                ReadCorrupt why → pure (g, GFailed (corrupt why))
                ReadStale → pure (g, GFailed (HandleDefect "a reader's own pin was stale"))
                ReadWrongWindow why → pure (g, GFailed (HandleDefect (Text.pack ("a reader's window was refused: " <> show why))))
  where
    restart x = either (const x) (\w → x {gWindow = w}) (readerWindow store (gToken x))
    corrupt ∷ IntegrityWhy → Handling
    corrupt why = HandlePause CondIntegrity (FaultIntegrity (FromStore why))

-- | The owner no longer wants this gather (its request ended, its arena closed). A read in flight is
-- withdrawn if queued and stopped at its next safe point if running; nothing is released until it has
-- returned. The owner calls it masked, then steps the gather until 'GDrained'.
cancelGather ∷ Io → Gather → IO (Gather, GProgress)
cancelGather io g = case gFetch g of
  Nothing → pure (g {gDraining = True}, GDrained)
  Just (_, ticket) →
    cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
      CancelWithdrawn → discardTicket (ioService io) ticket >> pure (g {gFetch = Nothing, gDraining = True}, GDrained)
      CancelOutcomeStands → discardTicket (ioService io) ticket >> pure (g {gFetch = Nothing, gDraining = True}, GDrained)
      CancelWaitsForDrain → pure (g {gDraining = True}, GBlocked (awaitTicket (ioService io) ticket))
      CancelDefect why → pure (g {gFetch = Nothing, gDraining = True}, GFailed (HandleDefect why))

-- | A finished job whose outcome cannot be taken: the backing is closing or gone (the decision for a closed
-- backing), or the ticket is lost (a defect).
lostTicket ∷ Closing → Io → IO Handling
lostTicket closing io = do
  view ← atomically (backingView (ioService io) (ioBacking io))
  pure $ case view of
    Nothing → classifyFailure closing JkRead BackingClosed
    Just v
      | bvClosing v → classifyFailure closing JkRead BackingClosed
      | otherwise → HandleDefect "a finished read named a ticket the service does not hold"

-- | The page a read job returned, put in the window inside the outcome's borrow: the window keeps its
-- OWN copy, so the service's result is retired when the body returns and nothing retains a view of it.
supplied ∷ Closing → StoreConfig → PageNo → Window → Outcome → Either Handling Window
supplied closing cfg page window outcome = case reactTo closing JkRead outcome of
  GotPages [(p, bytes)]
    | p == page → either (\err → Left (classifySupply (PageRefusedByWindow page err))) Right (windowInsert (cfgTotalPages cfg) page bytes window)
  GotPages other → Left (HandleDefect (Text.pack ("a read of one page answered " <> show (map fst other))))
  GotFailure handling _ → Left handling
  GotCancelled _ → Left (classifyUnaskedCancel closing)
  GotBacking {} → mismatch
  GotWritten _ → mismatch
  GotGrowthPrepared {} → mismatch
  GotGrowthNoChange → mismatch
  GotReleased → mismatch
  GotMismatch why → Left (HandleDefect why)
  where
    mismatch = Left (HandleDefect "a read job answered with another kind of outcome")
