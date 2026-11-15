-- | A read-only query of #661's knowledge (a cell's known solid and void, an obligation's state)
-- against one pinned committed version of the store, through the storage backend, as a resumable
-- state machine.
--
-- The query runs #661's pure function over a provider of the pinned version's records. A record
-- the window does not hold is a page to read ('readerMissing' names it), never an absence: the
-- step submits ONE read job and names the wait; when the page is in the window the query runs
-- again. A page that contradicts its place is the store's integrity failure (the arena pauses,
-- never fog, air or the source). The window holds at most the pages one reader may pin; a query
-- that needs more fails closed as a defect of the bound.
--
-- State, owner, thread, lifetime: as "Hetoimasia.Terrain.Runtime.Backed.Gather": the terrain
-- owner's, on its one thread, its pin released by 'endQuery' on every exit.
module Hetoimasia.Terrain.Runtime.Backed.Query
  ( Query
  , startQuery
  , queryOnPin
  , queryWindow
  , queryFetching
  , stepQuery
  , cancelQuery
  , endQuery
  , queryVersion
  , queryDraining
  , QProgress (..)
  ) where

import Control.Concurrent.STM (STM, atomically)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Observed (..), Provider, Unresolved (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Backed.Gather (GatherRefusal (..), gatherPinLimit, lostTicket, supplied)
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( ReadMode (..)
  , Ticket
  , awaitTicket
  , cancelTicket
  , discardTicket
  , pollTicket
  , submitRead
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( Condition (..)
  , ReaderToken
  , Store
  , acquireReader
  , readerMissing
  , readerProviderFor
  , readerVersion
  , readerWindow
  , releaseReader
  , storeConfig
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Window, windowSize)

-- | A pinned query's continuation.
data Query a = Query
  { qToken ∷ !ReaderToken
  , qWindow ∷ !Window
  , qVersion ∷ !Word64
  , qRun ∷ Provider → Observed a
  , qFetch ∷ !(Maybe (PageNo, Ticket))
  , qDraining ∷ !Bool
  , qFresh ∷ !Bool
  -- ^ The window holds only what this query read: one that fills it then needs more than a reader may
  -- pin. A query begun on a window an earlier read on the same pin filled starts again on an empty
  -- window once, instead.
  , qRefused ∷ !(Map PageNo Condition)
  -- ^ Pages a regional build already failed to read, with their cause: a query that needs one fails
  -- with 'HandlePausedFor' that cause and never reads it again. Empty for every other query.
  }

data QProgress a
  = QMore
  | QBlocked !(STM ())
  | QDone !a
  | QFailed !Handling
  | QDrained

-- | Pin the committed version and begin the query.
startQuery ∷ Store → (Provider → Observed a) → Either GatherRefusal (Store, Query a)
startQuery store run = case acquireReader store of
  Left refusal → Left (NoPin refusal)
  Right (token, pinned) → case (readerWindow pinned token, readerVersion pinned token) of
    (Right window, Right version) → Right (pinned, Query token window version run Nothing False True Map.empty)
    _ → Left PinRefused

-- | A query on a pin its caller already holds and keeps (a regional build's one committed version),
-- through the window an earlier read on that pin left: the caller takes it back with 'queryWindow',
-- and releases the pin itself ('endQuery' is not called on this query).
queryOnPin ∷ ReaderToken → Word64 → Window → Map PageNo Condition → (Provider → Observed a) → Query a
queryOnPin token version window refused run = Query token window version run Nothing False False refused

-- | The window the query reads through, for the next read on the same pin.
queryWindow ∷ Query a → Window
queryWindow = qWindow

-- | The page whose read the query has submitted and not yet taken, if any.
queryFetching ∷ Query a → Maybe PageNo
queryFetching = fmap fst . qFetch

queryDraining ∷ Query a → Bool
queryDraining = qDraining

queryVersion ∷ Query a → Word64
queryVersion = qVersion

endQuery ∷ Store → Query a → Store
endQuery store q = snd (releaseReader (qToken q) store)

-- | One step: take a finished read's outcome, or run the query once (which may ask for one page).
stepQuery ∷ Io → Closing → Store → Query a → IO (Query a, QProgress a)
stepQuery io closing store q = case qFetch q of
  Just (page, ticket) → do
    finished ← atomically (pollTicket (ioService io) ticket)
    if not finished
      then pure (q, QBlocked (awaitTicket (ioService io) ticket))
      else
        if qDraining q
          then discardTicket (ioService io) ticket >> pure (q {qFetch = Nothing}, QDrained)
          else
            withOutcome (ioService io) ticket (\outcome → pure $! supplied closing (storeConfig store) page (qWindow q) outcome) >>= \case
              Nothing → (\handling → (q {qFetch = Nothing}, QFailed handling)) <$> lostTicket closing io
              Just (Left handling) → pure (q {qFetch = Nothing}, QFailed handling)
              Just (Right window) → pure (q {qWindow = window, qFetch = Nothing}, QMore)
  Nothing
    | qDraining q → pure (q, QDrained)
    | otherwise → case readerProviderFor store (qToken q) (qWindow q) of
        Left why → pure (q, QFailed (HandleDefect (Text.pack ("a query's own pin was refused: " <> show why))))
        Right provider → case observedValue (qRun q provider) of
          Right answer → pure (q, QDone answer)
          Left (Inconsistent why) → pure (q, QFailed (HandlePause CondIntegrity (FaultIntegrity (FromRecords why))))
          Left (ReadLimit n) → pure (q, QFailed (HandleDefect (Text.pack ("a query passed its read limit: " <> show n))))
          Left (QueryCapacity c) → pure (q, QFailed (HandleDefect (Text.pack ("a query passed its capacity: " <> show c))))
          Left (MissingRecord key) → case readerMissing store (qToken q) (qWindow q) key of
            Left why → pure (q, QFailed (HandleDefect (Text.pack ("a query's own pin was refused: " <> show why))))
            Right (Left why) → pure (q, QFailed (HandlePause CondIntegrity (FaultIntegrity (FromStore why))))
            Right (Right Nothing) → pure (q, QFailed (HandleDefect "a record was missing with no page to read"))
            Right (Right (Just page))
              | Just cause ← Map.lookup page (qRefused q) → pure (q, QFailed (HandlePausedFor cause))
              | windowSize (qWindow q) >= gatherPinLimit, not (qFresh q) →
                  pure $ case readerWindow store (qToken q) of
                    Right fresh → (q {qWindow = fresh, qFresh = True}, QMore)
                    Left why → (q, QFailed (HandleDefect (Text.pack ("a query's own pin was refused: " <> show why))))
              | windowSize (qWindow q) >= gatherPinLimit → pure (q, QFailed (HandleDefect "a query needed more pages than a reader may pin"))
              | otherwise →
                  submitRead (ioService io) (ioBacking io) (ioClass io) (storeConfig store) page 1 ReadValidated >>= \case
                    Left failure → pure (q, QFailed (classifyFailure closing JkRead failure))
                    Right ticket → pure (q {qFetch = Just (page, ticket)}, QBlocked (awaitTicket (ioService io) ticket))

-- | The owner no longer wants the query: a read in flight is withdrawn or drained. Called masked.
cancelQuery ∷ Io → Query a → IO (Query a, QProgress a)
cancelQuery io q
  | qDraining q = case qFetch q of
      Nothing → pure (q, QDrained)
      Just (_, ticket) → do
        finished ← atomically (pollTicket (ioService io) ticket)
        if finished
          then discardTicket (ioService io) ticket >> pure (q {qFetch = Nothing}, QDrained)
          else pure (q, QBlocked (awaitTicket (ioService io) ticket))
  | otherwise = case qFetch q of
  Nothing → pure (q {qDraining = True}, QDrained)
  Just (_, ticket) →
    cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
      CancelWithdrawn → discardTicket (ioService io) ticket >> pure (q {qFetch = Nothing, qDraining = True}, QDrained)
      CancelOutcomeStands → discardTicket (ioService io) ticket >> pure (q {qFetch = Nothing, qDraining = True}, QDrained)
      CancelWaitsForDrain → pure (q {qDraining = True}, QBlocked (awaitTicket (ioService io) ticket))
      CancelDefect why → pure (q {qFetch = Nothing, qDraining = True}, QFailed (HandleDefect why))
