-- | One mutating store transaction, driven through the storage backend by the terrain
-- owner as a resumable state machine.
--
-- A 'Run' is the owner's continuation of one transaction: planning (the caller protocol
-- of "Hetoimasia.Terrain.Runtime.Store.Internal.Protocol"), the page reads the plan asks
-- for, the admission of the plan, the write of its pages and the outcome of that write.
--
-- == One step at a time, and one wait
--
-- 'advance' takes ONE step (at most one planner run, or one submission, or taking one outcome)
-- and says what is owed: 'More' (nothing to wait for: the owner serves its cancellation, closure
-- and other arenas, then calls 'advance' again) or 'Blocked' (wait for this job). The owner
-- composes that wait with its other sources (commands, cancellation, closure, host eligibility) in
-- ONE blocking transaction, never a loop that polls or sleeps. Nothing here blocks.
--
-- == What a 'Run' never does
--
-- It never publishes. A transaction that has written every page is 'ReadyToPublish':
-- an I/O completion is not publication. The owner's one arbitration decides it and calls
-- 'Hetoimasia.Terrain.Runtime.Store.Internal.Model.publish'; if it decides otherwise the
-- owner calls 'cancel', which aborts without a write (the committed roots were never changed).
--
-- == The model's answers are checked
--
-- Every event applied to the store answers 'Applied', 'Duplicate' or 'Unknown'. A dispatch and a
-- completion the run itself caused must be 'Applied' (a cancellation request may be 'Duplicate': it
-- is idempotent); anything else is a defect the run reports, never silently ignored.
--
-- == Ownership and exceptions
--
-- A 'Run' and the 'Store' it steps are values the owner alone holds, on its one thread. 'advance' and
-- 'cancel' perform their effects (submitting a job, taking an outcome) and return the new state, forced,
-- in the same step, so they are called MASKED: the effect and the record of it have no instruction
-- between them an asynchronous exception could reach, and any error a fold would have hidden in a
-- thunk happens inside the masked step. A page read's bytes are copied into the window inside the
-- outcome's borrow, so the service's result is retired on return.
--
-- == A job the run cannot take
--
-- When a finished job's outcome cannot be taken, the backing is asked: a backing that is closing or gone
-- is the closure (the decision for a closed backing), and any other is a lost ticket, a defect. Neither
-- spins: the run ends, and a transaction that was admitted is retired (its pages were handed to the job,
-- so each is a page not written, and the abort needs no write).
module Hetoimasia.Terrain.Runtime.Backed.Txn
  ( -- * Where the transaction does its work
    Io (..)

    -- * The transaction
  , Run
  , start
  , runTxnId
  , runPlan
  , runPhaseName
  , runDraining
  , Progress (..)
  , Done (..)
  , advance
  , cancel
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (evaluate)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( Backing
  , BackingView (..)
  , Outcome
  , ReadMode (..)
  , StorageService
  , Ticket
  , awaitTicket
  , backingView
  , cancelTicket
  , discardTicket
  , pollTicket
  , stageWrite
  , stagedPages
  , submitRead
  , submitWrite
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (StorageFailure (BackingClosed), WorkClass)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( Eligibility (..)
  , EventResult (..)
  , Store
  , TxnId
  , WriteOutcome (..)
  , abortTransaction
  , admit
  , completeWrite
  , dispatchWrite
  , eligibility
  , requestCancel
  , storeConfig
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan, plPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (Driver, Planner, newDriver, supplyPage, supplyProbe)
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Protocol as Protocol

-- | The backend a transaction works through: the service, the arena's backing and the
-- class of work it is (explicit work precedes camera prefetch).
data Io = Io
  { ioService ∷ !StorageService
  , ioBacking ∷ !Backing
  , ioClass ∷ !WorkClass
  }

-- | The continuation of one transaction.
newtype Run = Run Phase

data Phase
  = -- | Running the planner.
    Planning !Driver
  | -- | The planner asked for these pages (each read once): the one in flight, if any.
    Fetching !Driver !Probing ![PageNo] !(Maybe Ticket)
  | -- | Admitted and handed to the backend: every page is in flight in the model.
    Writing !TxnId !Plan !Ticket
  | -- | Every page written; the owner's arbitration decides.
    Written !TxnId !Plan
  | -- | A job that must end before the transaction can be retired: what the transaction
    -- is (admitted or not), the ticket of the job still running, and the cause to report once
    -- it has drained ('Nothing': the owner's own cancellation, which ends as 'Drained').
    Draining !(Maybe (TxnId, Plan)) !Ticket !(Maybe Handling)
  | -- | Nothing more to do.
    Over

-- | Whether the pages being fetched are plan pages or ownership probes.
type Probing = Bool

-- | Begin a transaction: plan through the protocol driver. 'start' only builds the
-- continuation; the first 'advance' runs the planner.
start ∷ Store → Planner → Run
start store planner = Run (Planning (newDriver store planner))

-- | The identity of the admitted transaction, when there is one.
runTxnId ∷ Run → Maybe TxnId
runTxnId (Run phase) = case phase of
  Writing tid _ _ → Just tid
  Written tid _ → Just tid
  Draining (Just (tid, _)) _ _ → Just tid
  Planning _ → Nothing
  Fetching {} → Nothing
  Draining Nothing _ _ → Nothing
  Over → Nothing

-- | The plan, once it is admitted.
runPlan ∷ Run → Maybe Plan
runPlan (Run phase) = case phase of
  Writing _ plan _ → Just plan
  Written _ plan → Just plan
  Draining (Just (_, plan)) _ _ → Just plan
  Planning _ → Nothing
  Fetching {} → Nothing
  Draining Nothing _ _ → Nothing
  Over → Nothing

-- | Whether the run has been cancelled and waits for its job to drain.
runDraining ∷ Run → Bool
runDraining (Run phase) = case phase of
  Draining {} → True
  Over → True
  Planning _ → False
  Fetching {} → False
  Writing {} → False
  Written {} → False

-- | A phase's name, for diagnostics and for the suite.
runPhaseName ∷ Run → Text
runPhaseName (Run phase) = case phase of
  Planning _ → "planning"
  Fetching {} → "fetching"
  Writing {} → "writing"
  Written {} → "written"
  Draining {} → "draining"
  Over → "over"

-- | Where a step left the transaction.
data Progress
  = -- | A step was taken and there is nothing to wait for: call 'advance' again, after serving
    -- whatever else the owner has to do.
    More
  | -- | Wait for this (a job's completion), then 'advance' again.
    Blocked !(STM ())
  | -- | Every page is written and none is in flight. This is not publication.
    ReadyToPublish !TxnId !Plan
  | -- | The transaction is over, and how.
    Finished !Done

-- | How a transaction ended without publishing.
data Done
  = -- | The candidate changes no page and no header: no history is appended.
    NothingToDo
  | -- | The oldest retirement entry is held by a reader (its version, the oldest pin).
    ReaderBlocks !Word64 !Word64
  | -- | The loose list is over its cap at the smallest unit: run maintenance, plan again.
    MaintenanceFirst
  | -- | The candidate was made against another version: make it again.
    Remake
  | -- | Aborted, with the decision for the cause (a pause, a retry, a defect, a closure).
    Aborted !Handling
  | -- | Cancelled by the owner, and drained: no job, claim or buffer remains.
    Drained
  deriving stock (Eq, Show)

-- | The store, forced, with the run's new state.
yield ∷ Store → Phase → Progress → IO (Store, Run, Progress)
yield store phase progress = do
  s ← evaluate store
  pure (s, Run phase, progress)

done ∷ Store → Done → IO (Store, Run, Progress)
done store d = yield store Over (Finished d)

defect ∷ String → Handling
defect = HandleDefect . Text.pack

-- | Apply an event the run itself caused: the model must answer 'Applied'.
applied ∷ String → (EventResult, Store) → Either Handling Store
applied what (result, store) = case result of
  Applied → Right store
  Duplicate → Left (defect (what <> " answered Duplicate"))
  Unknown → Left (defect (what <> " answered Unknown"))

-- | A strict fold in the model's answers: the first answer that is not the expected one ends it.
applyAll ∷ String → (a → Store → (EventResult, Store)) → [a] → Store → Either Handling Store
applyAll what f items store0 = go store0 items
  where
    go !s [] = Right s
    go !s (x : rest) = applied what (f x s) >>= \s' → go s' rest

-- | Take one step. The owner calls it masked.
advance ∷ Io → Closing → Store → Run → IO (Store, Run, Progress)
advance io closing store (Run phase) = case phase of
  Over → done store Drained
  Planning driver → case Protocol.advance driver of
    (d, Protocol.Continue) → yield store (Planning d) More
    (d, Protocol.NeedPages pages) → yield store (Fetching d False pages Nothing) More
    (d, Protocol.NeedProbes pages) → yield store (Fetching d True pages Nothing) More
    (_, Protocol.Ready plan) → admitPlan io closing store plan
    (_, Protocol.NothingToDo) → done store NothingToDo
    (_, Protocol.WaitsForReader version oldest) → done store (ReaderBlocks version oldest)
    (_, Protocol.NeedMaintenance) → done store MaintenanceFirst
    (_, Protocol.Replan) → done store Remake
    (_, Protocol.Refuse refusal _) → done store (Aborted (classifyPlanRefusal refusal))
    (_, Protocol.Stuck why) → done store (Aborted (defect ("the planner protocol stalled: " <> show why)))
  -- a read in flight with no page left to ask for cannot be built
  Fetching _ _ [] (Just _) → done store (Aborted (defect "a read was in flight with no page left to fetch"))
  -- every page asked for is in the window: plan again
  Fetching driver _ [] Nothing → yield store (Planning driver) More
  Fetching driver probing (page : rest) Nothing →
    submitRead (ioService io) (ioBacking io) (ioClass io) (storeConfig store) page 1 (if probing then ReadProbe else ReadValidated) >>= \case
      Left failure → done store (Aborted (classifyFailure closing JkRead failure))
      Right ticket → yield store (Fetching driver probing (page : rest) (Just ticket)) (Blocked (awaitTicket (ioService io) ticket))
  Fetching driver probing (page : rest) (Just ticket) →
    atomically (pollTicket (ioService io) ticket) >>= \case
      False → yield store phase (Blocked (awaitTicket (ioService io) ticket))
      True →
        withOutcome (ioService io) ticket (fetched closing probing page driver) >>= \case
          Nothing → lostJob closing io >>= \handling → done store (Aborted handling)
          Just (Left handling) → done store (Aborted handling)
          Just (Right driver') → yield store (Fetching driver' probing rest Nothing) More
  Writing tid plan ticket →
    atomically (pollTicket (ioService io) ticket) >>= \case
      False → yield store phase (Blocked (awaitTicket (ioService io) ticket))
      True →
        withOutcome (ioService io) ticket (\outcome → evaluate $! reportOf closing outcome) >>= \case
          Nothing → lostJob closing io >>= \handling → afterWrite closing tid plan store (NoReport (Just handling))
          Just report → afterWrite closing tid plan store report
  Written tid plan → yield store phase (ReadyToPublish tid plan)
  Draining admitted ticket cause →
    atomically (pollTicket (ioService io) ticket) >>= \case
      False → yield store phase (Blocked (awaitTicket (ioService io) ticket))
      True →
        -- the drained job's outcome is taken whatever it is: a write's report completes the pages in the model, the
        -- rest owns nothing. The owner asked for this, so a cancelled job is what it asked for
        withOutcome (ioService io) ticket (\outcome → evaluate $! reportOf closing outcome) >>= \case
          Nothing → retire admitted cause store (NoReport Nothing)
          Just report → retire admitted cause store report

-- | A finished job whose outcome cannot be taken: the backing is closing or gone (the decision for a closed
-- backing: the closure while the owner closes, a defect while it runs), or the ticket is lost (a defect).
lostJob ∷ Closing → Io → IO Handling
lostJob closing io = do
  view ← atomically (backingView (ioService io) (ioBacking io))
  pure $ case view of
    Nothing → closed
    Just v
      | bvClosing v → closed
      | otherwise → defect "a finished job named a ticket the service does not hold"
  where
    closed = classifyFailure closing JkRead BackingClosed

-- | The fetched page, supplied to the driver inside the outcome's borrow: the window keeps its
-- OWN copy, so the service's result is retired the moment the body returns. The result is forced.
fetched ∷ Closing → Probing → PageNo → Driver → Outcome → IO (Either Handling Driver)
fetched closing probing page driver outcome = evaluate $! case reactTo closing JkRead outcome of
  GotPages pages
    | [(p, bytes)] ← pages, p == page →
        either (Left . classifySupply) Right ((if probing then supplyProbe else supplyPage) page bytes driver)
    | otherwise → Left (defect ("a read of one page answered " <> show (map fst pages)))
  GotFailure handling _ → Left handling
  GotCancelled _ → Left (classifyUnaskedCancel closing)
  GotBacking {} → mismatch
  GotWritten _ → mismatch
  GotGrowthPrepared {} → mismatch
  GotGrowthNoChange → mismatch
  GotReleased → mismatch
  GotMismatch why → Left (HandleDefect why)
  where
    mismatch = Left (defect "a read job answered with another kind of outcome")

-- | What a write job came to, with every piece the owner needs held as plain values.
data Reported
  = Reported ![(PageNo, WriteOutcome)] !Bool !(Maybe Handling)
  | -- | The job ended without a report of its own (failed as a whole, or cancelled): every staged
    -- page is a page not written. The decision for the cause, if the job failed.
    NoReport !(Maybe Handling)

reportOf ∷ Closing → Outcome → Reported
reportOf closing outcome = case reactTo closing JkWrite outcome of
  GotWritten report → Reported (wrOutcomes report) (wrAllWritten report) (snd <$> wrFirstFailure report)
  GotFailure handling _ → NoReport (Just handling)
  GotCancelled _ → NoReport Nothing
  GotPages _ → NoReport (Just mismatch)
  GotBacking {} → NoReport (Just mismatch)
  GotGrowthPrepared {} → NoReport (Just mismatch)
  GotGrowthNoChange → NoReport (Just mismatch)
  GotReleased → NoReport (Just mismatch)
  GotMismatch why → NoReport (Just (HandleDefect why))
  where
    mismatch = defect "a write job answered with another kind of outcome"

-- | Admit a complete plan, claim its pages, and hand them to the backend.
admitPlan ∷ Io → Closing → Store → Plan → IO (Store, Run, Progress)
admitPlan io closing store plan = case admit plan store of
  Left refusal → done store (Aborted (classifyAdmitRefusal refusal))
  Right (tid, admitted) → case stageWrite admitted tid of
    Left refusal → abortNow tid admitted (defect ("an admitted plan could not be staged: " <> show refusal))
    Right staged →
      submitWrite (ioService io) (ioBacking io) staged >>= \case
        -- nothing was handed to a worker: the pages are staged, not in flight, so the claim
        -- retires at once (an abort needs no write)
        Left failure → abortNow tid admitted (classifyFailure closing JkWrite failure)
        Right ticket → case applyAll "dispatching a staged page" (dispatchWrite tid) (stagedPages staged) admitted of
          Right inFlight → yield inFlight (Writing tid plan ticket) (Blocked (awaitTicket (ioService io) ticket))
          -- the job is running and the model cannot account for it: it is stopped and drained like any other, and the
          -- defect is what the run reports when it has returned
          Left handling → do
            _ ← cancelTicket (ioService io) ticket
            yield admitted (Draining (Just (tid, plan)) ticket (Just handling)) (Blocked (awaitTicket (ioService io) ticket))
  where
    abortNow tid s handling = case abortTransaction tid s of
      Right s' → done s' (Aborted handling)
      Left refusal → done s (Aborted (defect ("a transaction with nothing in flight could not abort: " <> show refusal)))

-- | The write job has ended: report each page to the model, then either the transaction is
-- eligible for the owner's arbitration, or it is aborted (an abort needs no write). A job that stopped
-- at a page nobody asked it to stop at is the closure while the owner closes and a defect while it runs.
afterWrite ∷ Closing → TxnId → Plan → Store → Reported → IO (Store, Run, Progress)
afterWrite closing tid plan store reported = case reported of
  Reported outcomes True _ → case applyAll "completing a written page" (\(page, outcome) → completeWrite tid page outcome) outcomes store of
    Left handling → abort store handling
    Right s → case eligibility tid s of
      Eligible → yield s (Written tid plan) (ReadyToPublish tid plan)
      other → abort s (defect ("every page was written and the transaction is not eligible: " <> show other))
  Reported outcomes False cause → case applyAll "completing a page" (\(page, outcome) → completeWrite tid page outcome) outcomes store of
    Left handling → abort store handling
    Right s → abort s (maybe (classifyUnaskedCancel closing) id cause)
  NoReport cause → case applyAll "completing a page the job never reported" (\page → completeWrite tid page WriteFailed) (map fst (plPages plan)) store of
    Left handling → abort store handling
    Right s → abort s (maybe (classifyUnaskedCancel closing) id cause)
  where
    abort s handling = case abortTransaction tid s of
      Right s' → done s' (Aborted handling)
      Left refusal → done s (Aborted (defect ("a drained transaction could not abort: " <> show refusal)))

-- | Retire a transaction whose job has drained: the owner asked for it, or the cause is what it reports.
retire ∷ Maybe (TxnId, Plan) → Maybe Handling → Store → Reported → IO (Store, Run, Progress)
retire admitted cause store reported = case admitted of
  Nothing → done store (finish cause)
  Just (tid, plan) →
    let completion = case reported of
          Reported outcomes _ _ → applyAll "completing a page" (\(page, outcome) → completeWrite tid page outcome) outcomes store
          NoReport _ → applyAll "completing a page the job never reported" (\page → completeWrite tid page WriteFailed) (map fst (plPages plan)) store
     in case completion of
          Left handling → done store (Aborted handling)
          Right completed → case abortTransaction tid completed of
            Right s' → done s' (finish cause)
            Left refusal → done completed (Aborted (defect ("a drained transaction could not abort: " <> show refusal)))
  where
    finish = maybe Drained Aborted

-- | The owner decided against this transaction (a cancellation, a closure, a request that lost
-- its place): retire it. Nothing is released until the job in flight has actually returned, and
-- an abort needs no write, so the old committed roots, knowledge and frontier are as they were.
-- Called masked.
cancel ∷ Io → Store → Run → IO (Store, Run, Progress)
cancel io store (Run phase) = case phase of
  Over → done store Drained
  Planning _ → done store Drained
  Fetching _ _ _ Nothing → done store Drained
  Fetching _ _ _ (Just ticket) → withdrawRead ticket
  -- every page is written and none in flight: the model has nothing to complete
  Written tid plan → retire (Just (tid, plan)) Nothing store (Reported [] False Nothing)
  Writing tid plan ticket → case requested tid of
    Left handling → done store (Aborted handling)
    Right store' →
      -- the backend withdraws a queued job or stops a running one at its next safe point, and the pages stay
      -- claimed until it has returned
      cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
        CancelWithdrawn → yield store' (Draining (Just (tid, plan)) ticket Nothing) More
        CancelOutcomeStands → yield store' (Draining (Just (tid, plan)) ticket Nothing) More
        CancelWaitsForDrain → yield store' (Draining (Just (tid, plan)) ticket Nothing) (Blocked (awaitTicket (ioService io) ticket))
        CancelDefect why → done store' (Aborted (HandleDefect why))
    where
      requested tid' = case requestCancel tid' store of
        (Applied, s) → Right s
        (Duplicate, s) → Right s
        (Unknown, _) → Left (defect "requesting the cancellation of a transaction the store does not hold answered Unknown")
  -- already cancelled: the job is waited for and its outcome taken, as 'advance' does
  Draining {} → advance io OwnerClosing store (Run phase)
  where
    -- a read nobody will use: withdrawn if queued, stopped at its next safe point if running
    withdrawRead ticket =
      cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
        CancelWithdrawn → discardTicket (ioService io) ticket >> done store Drained
        CancelOutcomeStands → discardTicket (ioService io) ticket >> done store Drained
        CancelWaitsForDrain → yield store (Draining Nothing ticket Nothing) (Blocked (awaitTicket (ioService io) ticket))
        CancelDefect why → done store (Aborted (HandleDefect why))
