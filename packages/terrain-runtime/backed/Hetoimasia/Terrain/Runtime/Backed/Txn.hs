-- | One mutating store transaction, driven through the storage backend by the terrain
-- owner as a resumable state machine.
--
-- A 'Run' is the owner's continuation of one transaction: planning (the caller protocol
-- of "Hetoimasia.Terrain.Runtime.Store.Internal.Protocol"), the page reads the plan asks
-- for, the admission of the plan, the write of its pages and the outcome of that write.
-- 'advance' takes a step that needs no waiting and says what to wait for next; the owner
-- composes that wait with its other sources (commands, cancellation, closure, host
-- eligibility) in ONE blocking transaction, never a loop that polls or sleeps, and then
-- calls 'advance' again. Nothing here blocks.
--
-- == What a 'Run' never does
--
-- It never publishes. A transaction that has written every page is 'ReadyToPublish':
-- an I/O completion is not publication. The owner's one arbitration decides it
-- ("Hetoimasia.Terrain.Runtime.Backed.Publish" in the service) and calls
-- 'Hetoimasia.Terrain.Runtime.Store.Internal.Model.publish'; if it decides otherwise the
-- owner calls 'cancel', which aborts without a write (the committed roots were never
-- changed).
--
-- == Ownership and exceptions
--
-- A 'Run' and the 'Store' it steps are values the owner alone holds, on its one thread.
-- 'advance' and 'cancel' perform their effects (submitting a job, taking an outcome) and
-- return the new state in the same step, so they are called MASKED: the effect and the
-- record of it have no instruction between them an asynchronous exception could reach.
-- A page read's bytes are copied into the window inside the outcome's borrow, so the
-- service's result is retired on return and nothing here retains a view of it.
module Hetoimasia.Terrain.Runtime.Backed.Txn
  ( -- * Where the transaction does its work
    Io (..)

    -- * The transaction
  , Run
  , start
  , runTxnId
  , runPlan
  , runPhaseName
  , Progress (..)
  , Done (..)
  , advance
  , cancel
  ) where

import Control.Concurrent.STM (STM, atomically)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( Backing
  , Outcome
  , StorageService
  , Ticket
  , awaitTicket
  , cancelTicket
  , discardTicket
  , pollTicket
  , stageWrite
  , stagedPages
  , submitRead
  , submitWrite
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (ReadMode (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (WorkClass)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( Store
  , TxnId
  , WriteOutcome (..)
  , abortTransaction
  , admit
  , completeWrite
  , dispatchWrite
  , eligibility
  , Eligibility (..)
  , requestCancel
  , storeConfig
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan, plPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol
  ( Driver
  , Planner
  , Stall
  , newDriver
  , supplyPage
  , supplyProbe
  )
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Protocol as Protocol
import Data.Text (Text)
import qualified Data.Text as Text

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
    -- is (admitted or not) and the ticket of the job still running.
    Draining !(Maybe (TxnId, Plan)) !Ticket
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
  Draining (Just (tid, _)) _ → Just tid
  Planning _ → Nothing
  Fetching {} → Nothing
  Draining Nothing _ → Nothing
  Over → Nothing

-- | The plan, once it is admitted.
runPlan ∷ Run → Maybe Plan
runPlan (Run phase) = case phase of
  Writing _ plan _ → Just plan
  Written _ plan → Just plan
  Draining (Just (_, plan)) _ → Just plan
  Planning _ → Nothing
  Fetching {} → Nothing
  Draining Nothing _ → Nothing
  Over → Nothing

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
  = -- | Wait for this (a job's completion), then 'advance' again.
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

done ∷ Store → Done → IO (Store, Run, Progress)
done store d = pure (store, Run Over, Finished d)

-- | Take every step that needs no waiting. The owner calls it masked.
advance ∷ Io → Closing → Store → Run → IO (Store, Run, Progress)
advance io closing store (Run phase) = case phase of
  Over → done store Drained
  Planning driver → case Protocol.advance driver of
    (d, Protocol.NeedPages pages) → advance io closing store (Run (Fetching d False pages Nothing))
    (d, Protocol.NeedProbes pages) → advance io closing store (Run (Fetching d True pages Nothing))
    (_, Protocol.Ready plan) → admitPlan io closing store plan
    (_, Protocol.NothingToDo) → done store NothingToDo
    (_, Protocol.WaitsForReader version oldest) → done store (ReaderBlocks version oldest)
    (_, Protocol.NeedMaintenance) → done store MaintenanceFirst
    (_, Protocol.Replan) → done store Remake
    (_, Protocol.Refuse refusal _) → done store (Aborted (classifyPlanRefusal refusal))
    (_, Protocol.Stuck why) → done store (Aborted (HandleDefect (stalled why)))
  -- a read in flight with no page left to ask for cannot be built
  Fetching _ _ [] (Just _) → done store (Aborted (HandleDefect "a read was in flight with no page left to fetch"))
  -- every page asked for is in the window: plan again
  Fetching driver _ [] Nothing → advance io closing store (Run (Planning driver))
  Fetching driver probing (page : rest) Nothing →
    submitRead (ioService io) (ioBacking io) (ioClass io) (storeConfig store) page 1 (if probing then ReadProbe else ReadValidated) >>= \case
      Left failure → done store (Aborted (classifyFailure closing JkRead failure))
      Right ticket → pure (store, Run (Fetching driver probing (page : rest) (Just ticket)), Blocked (awaitTicket (ioService io) ticket))
  Fetching driver probing (page : rest) (Just ticket) →
    finished io ticket >>= \case
      False → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
      True →
        taking io ticket (fetched closing probing page driver) >>= \case
          Nothing → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
          Just (Left handling) → done store (Aborted handling)
          Just (Right driver') → advance io closing store (Run (Fetching driver' probing rest Nothing))
  Writing tid plan ticket →
    finished io ticket >>= \case
      False → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
      True →
        taking io ticket (\outcome → pure $! reportOf closing outcome) >>= \case
          Nothing → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
          Just report → afterWrite tid plan store report
  Written tid plan → pure (store, Run phase, ReadyToPublish tid plan)
  Draining admitted ticket →
    finished io ticket >>= \case
      False → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
      True →
        -- the drained job's outcome is taken whatever it is: a write's report completes the
        -- pages in the model, the rest owns nothing
        taking io ticket (\outcome → pure $! reportOf closing outcome) >>= \case
          Nothing → pure (store, Run phase, Blocked (awaitTicket (ioService io) ticket))
          Just report → retire admitted store report

-- | The fetched page, supplied to the driver inside the outcome's borrow: the window keeps its
-- OWN copy, so the service's result is retired the moment the body returns.
fetched ∷ Closing → Probing → PageNo → Driver → Outcome → IO (Either Handling Driver)
fetched closing probing page driver outcome = pure $! case reactTo closing JkRead outcome of
  GotPages pages
    | [(p, bytes)] ← pages, p == page →
        either (Left . HandleDefect . stalled) Right ((if probing then supplyProbe else supplyPage) page bytes driver)
    | otherwise → Left (HandleDefect (Text.pack ("a read of one page answered " <> show (map fst pages))))
  GotFailure handling _ → Left handling
  GotCancelled _ → Left HandleClosing
  GotBacking {} → mismatch
  GotWritten _ → mismatch
  GotGrowthPrepared {} → mismatch
  GotGrowthNoChange → mismatch
  GotReleased → mismatch
  GotMismatch why → Left (HandleDefect why)
  where
    mismatch = Left (HandleDefect "a read job answered with another kind of outcome")

stalled ∷ Stall → Text
stalled why = Text.pack ("the planner protocol stalled: " <> show why)

-- | What a write job came to, with every piece the owner needs held as plain values: the
-- report's page outcomes, and the decision for the first failure.
data Reported
  = Reported ![(PageNo, WriteOutcome)] !Bool !(Maybe Handling)
  | -- | The job ended without a report of its own (failed as a whole, or cancelled): every staged
    -- page is a page not written.
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
    mismatch = HandleDefect "a write job answered with another kind of outcome"

-- | Admit a complete plan, claim its pages, and hand them to the backend.
admitPlan ∷ Io → Closing → Store → Plan → IO (Store, Run, Progress)
admitPlan io closing store plan = case admit plan store of
  Left refusal → done store (Aborted (classifyAdmitRefusal refusal))
  Right (tid, admitted) → case stageWrite admitted tid of
    Left refusal → abortNow tid admitted (HandleDefect (Text.pack ("an admitted plan could not be staged: " <> show refusal)))
    Right staged →
      submitWrite (ioService io) (ioBacking io) staged >>= \case
        -- nothing was handed to a worker: the pages are staged, not in flight, so the claim
        -- retires at once (an abort needs no write)
        Left failure → abortNow tid admitted (classifyFailure closing JkWrite failure)
        Right ticket → do
          let inFlight = foldl (\s page → snd (dispatchWrite tid page s)) admitted (stagedPages staged)
          pure (inFlight, Run (Writing tid plan ticket), Blocked (awaitTicket (ioService io) ticket))
  where
    abortNow tid s handling = case abortTransaction tid s of
      Right s' → done s' (Aborted handling)
      Left refusal → done s (Aborted (HandleDefect (Text.pack ("a transaction with nothing in flight could not abort: " <> show refusal))))

-- | The write job has ended: report each page to the model, then either the transaction is
-- eligible for the owner's arbitration, or it is aborted (an abort needs no write).
afterWrite ∷ TxnId → Plan → Store → Reported → IO (Store, Run, Progress)
afterWrite tid plan store reported = case reported of
  Reported outcomes True _ →
    let s = foldl (\acc (page, outcome) → snd (completeWrite tid page outcome acc)) store outcomes
     in case eligibility tid s of
          Eligible → pure (s, Run (Written tid plan), ReadyToPublish tid plan)
          other → abort s (HandleDefect (Text.pack ("every page was written and the transaction is not eligible: " <> show other)))
  Reported outcomes False cause →
    let s = foldl (\acc (page, outcome) → snd (completeWrite tid page outcome acc)) store outcomes
     in abort s (maybe HandleClosing id cause)
  NoReport cause →
    -- the job never reported a page: each is a page not written
    let s = foldl (\acc page → snd (completeWrite tid page WriteFailed acc)) store (planPageNumbers plan)
     in abort s (maybe HandleClosing id cause)
  where
    abort s handling = case abortTransaction tid s of
      Right s' → done s' (Aborted handling)
      Left refusal → done s (Aborted (HandleDefect (Text.pack ("a drained transaction could not abort: " <> show refusal))))

planPageNumbers ∷ Plan → [PageNo]
planPageNumbers = map fst . plPages

-- | Retire a transaction whose job has drained.
retire ∷ Maybe (TxnId, Plan) → Store → Reported → IO (Store, Run, Progress)
retire admitted store reported = case admitted of
  Nothing → done store Drained
  Just (tid, plan) → do
    let completed = case reported of
          Reported outcomes _ _ → foldl (\acc (page, outcome) → snd (completeWrite tid page outcome acc)) store outcomes
          NoReport _ → foldl (\acc page → snd (completeWrite tid page WriteFailed acc)) store (planPageNumbers plan)
    case abortTransaction tid completed of
      Right s' → done s' Drained
      Left refusal → done completed (Aborted (HandleDefect (Text.pack ("a drained transaction could not abort: " <> show refusal))))

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
  Written tid plan → retire (Just (tid, plan)) store (Reported [] False Nothing)
  Writing tid plan ticket →
    -- the model records the request; the backend withdraws a queued job or stops a running one at
    -- its next safe point, and the pages stay claimed until it has returned
    let store' = fst' (requestCancel tid store)
     in cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
          CancelWithdrawn → drainTicket (Just (tid, plan)) ticket store'
          CancelWaitsForDrain → pure (store', Run (Draining (Just (tid, plan)) ticket), Blocked (awaitTicket (ioService io) ticket))
          CancelOutcomeStands → drainTicket (Just (tid, plan)) ticket store'
          CancelDefect why → done store' (Aborted (HandleDefect why))
  Draining admitted ticket → pure (store, Run (Draining admitted ticket), Blocked (awaitTicket (ioService io) ticket))
  where
    fst' (_, s) = s
    -- a read nobody will use: withdrawn if queued, stopped at its next safe point if running
    withdrawRead ticket =
      cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
        CancelWithdrawn → discardTicket (ioService io) ticket >> done store Drained
        CancelOutcomeStands → discardTicket (ioService io) ticket >> done store Drained
        CancelWaitsForDrain → pure (store, Run (Draining Nothing ticket), Blocked (awaitTicket (ioService io) ticket))
        CancelDefect why → done store (Aborted (HandleDefect why))
    -- the job has ended or is withdrawn: its outcome is taken and the transaction retired
    drainTicket admitted ticket s =
      finished io ticket >>= \case
        False → pure (s, Run (Draining admitted ticket), Blocked (awaitTicket (ioService io) ticket))
        True →
          taking io ticket (\outcome → pure $! reportOf OwnerClosing outcome) >>= \case
            Nothing → pure (s, Run (Draining admitted ticket), Blocked (awaitTicket (ioService io) ticket))
            Just report → retire admitted s report

-- | Whether a job has finished, without waiting.
finished ∷ Io → Ticket → IO Bool
finished io ticket = atomically (pollTicket (ioService io) ticket)

-- | Take a finished job's outcome and run a pure body over it inside the borrow; the record is
-- retired on return. 'Nothing' when the ticket names nothing (already taken or discarded).
taking ∷ Io → Ticket → (Outcome → IO a) → IO (Maybe a)
taking io = withOutcome (ioService io)
