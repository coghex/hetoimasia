-- | An explicit retry's WRITE PROBE (requirement 9: "reservation/write probe as applicable"): the
-- pages whose write failed are written again, through the ordinary write path, by a probe-only store
-- transaction ('writeProbePlanner'), read back while that transaction still holds them, compared with
-- what was written, and the transaction is then ABORTED: nothing is published and the pages stay free.
--
-- * A page the committed roots no longer hold free was claimed and committed since: a write of it
--   succeeded after the failure, so it is certified without a probe (the planner leaves it out).
-- * A page that fails again, or reads back anything but the pattern, means the cause persists.
-- * The probe's own failure (temporary pressure, a defect, a closure, a failure of another cause) is
--   classified exactly as any transaction's.
--
-- State, owner, thread, lifetime: the terrain owner's, on its one thread, in the session's slot (it
-- is a transaction: its worst-case credits are reserved at its grant and it is serialized with every
-- mutation), from the grant until it is over. Every step is called masked.
module Hetoimasia.Terrain.Runtime.Backed.WriteProbe
  ( WriteRun
  , startWriteProbe
  , advanceWriteProbe
  , cancelWriteProbe
  , writeProbeTicket
  , writeProbeTxnId
  , writeProbeDraining
  , writeProbePhaseName
  , WriteStep (..)
  , WriteResult (..)
  ) where

import Control.Concurrent.STM (STM, atomically)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Gather (lostTicket)
import Hetoimasia.Terrain.Runtime.Backed.Txn (Done (..), Io (..), Progress (..), Run)
import qualified Hetoimasia.Terrain.Runtime.Backed.Txn as Txn
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
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..), Store, TxnId, storeConfig)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan (..), writeProbePattern)
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (writeProbePlanner)

-- | How a write probe ended.
data WriteResult
  = -- | Every page took the write and read it back (or was committed since): the write cause is gone.
    WriteCertified
  | -- | A page failed again, or read back otherwise: the write cause persists.
    WritePersists
  | -- | The probe's own failure, classified as any transaction's: the retry is not answered on it.
    WriteRefused !Handling
  deriving stock (Eq, Show)

data WriteStep
  = WMore
  | WBlocked !(STM ())
  | WOver !WriteResult

data Phase
  = -- | Planning and writing, through the transaction runner.
    WTxn !Run
  | -- | Every page is written and the transaction still holds them: each is read back in turn (the
    -- pages still to read, and the read in flight).
    WReading !Run ![(PageNo, ByteString)] !(Maybe Ticket)
  | -- | A read in flight is being withdrawn before the transaction is abandoned.
    WWithdrawing !Run !Ticket !WriteResult
  | -- | The transaction is being abandoned (it is never published), with the result to report.
    WAborting !Run !WriteResult
  | WEnded !WriteResult

-- | The continuation of one write probe.
data WriteRun = WriteRun ![PageNo] !Phase

startWriteProbe ∷ Store → [PageNo] → WriteRun
startWriteProbe store pages = WriteRun pages (WTxn (Txn.start store (writeProbePlanner store pages)))

-- | The job of the storage service the probe holds, if any.
writeProbeTicket ∷ WriteRun → Maybe Ticket
writeProbeTicket (WriteRun _ phase) = case phase of
  WTxn run → Txn.runTicket run
  WReading run _ fetch → maybe (Txn.runTicket run) Just fetch
  WWithdrawing _ ticket _ → Just ticket
  WAborting run _ → Txn.runTicket run
  WEnded _ → Nothing

-- | The store transaction the probe holds, if one was admitted.
writeProbeTxnId ∷ WriteRun → Maybe TxnId
writeProbeTxnId (WriteRun _ phase) = case phase of
  WTxn run → Txn.runTxnId run
  WReading run _ _ → Txn.runTxnId run
  WWithdrawing run _ _ → Txn.runTxnId run
  WAborting run _ → Txn.runTxnId run
  WEnded _ → Nothing

-- | Whether the probe is being abandoned and waits for a job to drain.
writeProbeDraining ∷ WriteRun → Bool
writeProbeDraining (WriteRun _ phase) = case phase of
  WWithdrawing {} → True
  WAborting {} → True
  WEnded _ → True
  WTxn run → Txn.runDraining run
  WReading {} → False

writeProbePhaseName ∷ WriteRun → Text
writeProbePhaseName (WriteRun _ phase) = case phase of
  WTxn run → Txn.runPhaseName run
  WReading {} → "reading back"
  WWithdrawing {} → "withdrawing"
  WAborting {} → "aborting"
  WEnded _ → "over"

-- | Take one step. Called masked.
advanceWriteProbe ∷ Io → Closing → Store → WriteRun → IO (Store, WriteRun, WriteStep)
advanceWriteProbe io closing store (WriteRun pages phase) = case phase of
  WEnded result → pure (store, WriteRun pages phase, WOver result)
  WTxn run → do
    (store', run', progress) ← Txn.advance io closing store run
    case progress of
      More → pure (store', WriteRun pages (WTxn run'), WMore)
      Blocked wait → pure (store', WriteRun pages (WTxn run'), WBlocked wait)
      -- written, never published: read each page back while the transaction still holds it
      ReadyToPublish _ plan → pure (store', WriteRun pages (WReading run' (plPages plan) Nothing), WMore)
      Finished done → pure (store', WriteRun pages (WEnded (resultOf done)), WOver (resultOf done))
  WReading run pending (Just ticket) → do
    finished ← atomically (pollTicket (ioService io) ticket)
    if not finished
      then pure (store, WriteRun pages phase, WBlocked (awaitTicket (ioService io) ticket))
      else do
        reaction ← withOutcome (ioService io) ticket (\outcome → pure $! reactTo closing JkRead outcome)
        verdict ← case reaction of
          Nothing → Left . WriteRefused <$> lostTicket closing io
          Just (GotPages [(_, bytes)]) | Just (page, written) ← headOf pending → pure $
            if bytes == written && written == writeProbePattern page then Right (drop 1 pending) else Left WritePersists
          Just (GotFailure handling _) → pure (Left (failed handling))
          Just (GotCancelled _) → pure (Left (WriteRefused (classifyUnaskedCancel closing)))
          Just (GotMismatch why) → pure (Left (WriteRefused (HandleDefect why)))
          Just _ → pure (Left (WriteRefused (HandleDefect "a write probe's read-back answered with another kind of outcome")))
        pure $ case verdict of
          Right rest → (store, WriteRun pages (WReading run rest Nothing), WMore)
          Left result → (store, WriteRun pages (WAborting run result), WMore)
  WReading run [] Nothing → pure (store, WriteRun pages (WAborting run WriteCertified), WMore)
  WReading run pending@((page, _) : _) Nothing →
    submitRead (ioService io) (ioBacking io) (ioClass io) (storeConfig store) page 1 ReadProbe >>= \case
      Left failure → pure (store, WriteRun pages (WAborting run (failed (classifyFailure closing JkRead failure))), WMore)
      Right ticket → pure (store, WriteRun pages (WReading run pending (Just ticket)), WBlocked (awaitTicket (ioService io) ticket))
  WWithdrawing run ticket result → do
    finished ← atomically (pollTicket (ioService io) ticket)
    if finished
      then discardTicket (ioService io) ticket >> pure (store, WriteRun pages (WAborting run result), WMore)
      else pure (store, WriteRun pages phase, WBlocked (awaitTicket (ioService io) ticket))
  WAborting run result → do
    (store', run', progress) ← Txn.cancel io store run
    case progress of
      Finished _ → pure (store', WriteRun pages (WEnded result), WOver result)
      Blocked wait → pure (store', WriteRun pages (WAborting run' result), WBlocked wait)
      _ → pure (store', WriteRun pages (WAborting run' result), WMore)
  where
    headOf = \case
      x : _ → Just x
      [] → Nothing
    -- the write (or its read-back) failed again for the cause the probe re-tests: it persists
    failed = \case
      HandlePause CondIo _ → WritePersists
      HandlePausedFor CondIo → WritePersists
      handling → WriteRefused handling
    resultOf = \case
      -- no page asked about is free any more: each was claimed and committed since
      NothingToDo → WriteCertified
      Aborted handling → failed handling
      Drained → WriteRefused HandleClosing
      other → WriteRefused (HandleDefect (Text.pack ("a write probe's transaction ended " <> show other)))

-- | The owner no longer wants the probe: a read in flight is withdrawn, then the transaction is
-- abandoned (a write in flight is drained first, by the transaction runner). Called masked.
cancelWriteProbe ∷ Io → Store → WriteRun → IO (Store, WriteRun, WriteStep)
cancelWriteProbe io store (WriteRun pages phase) = case phase of
  WEnded result → pure (store, WriteRun pages phase, WOver result)
  WReading run _ (Just ticket) → do
    _ ← cancelTicket (ioService io) ticket
    pure (store, WriteRun pages (WWithdrawing run ticket (WriteRefused HandleClosing)), WMore)
  WReading run _ Nothing → pure (store, WriteRun pages (WAborting run (WriteRefused HandleClosing)), WMore)
  WTxn run → pure (store, WriteRun pages (WAborting run (WriteRefused HandleClosing)), WMore)
  _ → advanceWriteProbe io OwnerClosing store (WriteRun pages phase)
