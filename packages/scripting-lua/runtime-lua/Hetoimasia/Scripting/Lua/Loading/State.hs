-- | What a scheduled owner keeps to host the module loader: the bounded inbox that any
-- thread may submit roots and arrived sources to, the owner's thread that drains it into
-- the loader, and the hold on the logical tick a due chain keeps while it is unfinished.
--
-- = Who does what
--
-- The loader itself ("Hetoimasia.Scripting.Lua.Owner") is the VM owner's alone: it compiles,
-- evaluates, resumes and publishes on the owner's thread under its gate, and refuses every
-- other thread. A provider thread, or a coordinator, cannot call it. What it can do, from
-- any thread and without blocking, is leave a message in this module's inbox:
-- 'submitRootIn' a root to evaluate and 'notifySourceIn' a source it found. The owner's
-- thread wakes for the inbox beside the scheduler's own work, drains it at each boundary
-- into 'Hetoimasia.Scripting.Lua.Owner.admitRoot' and
-- 'Hetoimasia.Scripting.Lua.Owner.deliverSource', and advances the loader, so every
-- compile, evaluation, resume, cache publication and Lua-reference release happens on the
-- owner's thread, and a hook or a stop request is served between two advances while a
-- chain waits for its source.
--
-- = The inbox is bounded by admitted work
--
-- Not more than 'planBound' roots wait to be admitted, and not more than that many arrived
-- sources wait to be delivered, and a notification for an identity already waiting is a
-- duplicate and changes nothing. A full inbox refuses, so a producer waits (by whatever
-- means it has) and tries again: no unbounded source-prefetch queue exists. The loader's
-- own bounds (the identities it holds, the chain's length, a module's source) are the
-- owner's configuration and are not repeated here.
--
-- = Ordering and eligibility
--
-- Roots are admitted to the loader in the order they were submitted. A coordinator submits
-- logical roots ('DueTick') in non-decreasing tick order and UI roots ('DueUi') in
-- request-admission order, and this refuses a logical root whose tick is below one already
-- submitted ('SubmitOutOfOrder'), so the loader's queue order is the logical order. A UI
-- root is eligible at once; a logical root once the owner's logical tick has reached its
-- tick. Neither adds a priority, a phase or a second scheduler: source arrival never starts
-- a root, only the loader's head-of-queue rule and this eligibility do.
--
-- = A due chain keeps its tick open
--
-- A logical root owes its tick: tick @t@ is not complete until the root has come to an
-- outcome. The obligation is recorded in the transaction that accepts the submission, from
-- any thread, and the owner asks the scheduler ('ticksOwe') to keep the tick open in that
-- same transaction, before the owner has looked at anything. The grant that reaches the
-- tick is applied and what it woke runs, and the grant is not finished: it stays
-- outstanding, so nothing reports the tick complete, and no later grant is applied,
-- however many were queued meanwhile, until the root has an outcome. The need is one, for
-- the earliest tick owed by an unfinished root (or the current tick, once that has passed
-- and its grant is still open), taken and given back as that set changes, and given back
-- when the owner exits. A root that is submitted again keeps the earliest of its
-- obligations and of the ticks it may begin at; a later submission never postpones
-- either. A root submitted after its tick is complete has nothing left to keep. A UI chain
-- owes nothing: hooks and stop requests simply go on while its source is awaited. A
-- non-yielding module still blocks its owner; nothing here preempts trusted Lua.
--
-- = What is published
--
-- The outcomes of the owner's roots are written, on the owner's thread, to a map that any
-- thread may read ('outcomeIn'): the identity, whether it is admitted, ready (with the
-- very export handle, a value that names a slot of the VM and is checked on every use),
-- failed with its sticky fault, or stopped. The loader settles no request ticket: a later
-- coordinator reads these and delivers at its own positions.
--
-- = Exit
--
-- Once a stop has been asked of the owner, or it has begun to exit, the inbox is closed to
-- producers and the owner admits, delivers and advances nothing more: what is queued is left
-- for the exit. When the owner exits the loader is stopped on the owner's thread (its
-- frames closed, its interests withdrawn), every outcome that was only admitted is
-- published as stopped, and the need is given back.
module Hetoimasia.Scripting.Lua.Loading.State
  ( -- * Configuring
    LoaderPlan (..)
  , loaderPlan
  , defaultLoaderBound
  , RootDue (..)
    -- * Refusing a plan
  , LoaderPlanRefused (..)
  , LoaderViolation (..)
  , validatePlan
    -- * The state
  , LoadingState
  , LoaderEndpoint (..)
  , newLoadingState
  , loadingConfig
    -- * From any thread
  , SubmitAnswer (..)
  , submitRootIn
  , NotifyAnswer (..)
  , notifySourceIn
  , LoaderOutcome (..)
  , outcomeIn
  , awaitOutcomeIn
  , refusalsIn
  , LoadingDiagnostics (..)
  , diagnosticsIn
    -- * The owner's thread
  , loadingWork
  , serviceLoading
  , closeLoading
  , retireLoading
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVarIO
  , readTVar
  , modifyTVar'
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (Exception, ExceptionWithContext, SomeException, tryWithContext)
import Control.Monad (forM, forM_, when)
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Owner
  ( AddressResolver
  , AdvanceReport (advanceBlocked, advanceSettled)
  , Blocked (BlockedIneligible)
  , ExportIdentity
  , LoaderConfig (..)
  , ModulePhase
  , ModuleStatus (..)
  , OwnedVm
  , RootAdmission (..)
  , RootRefusal
  , RootRequest (..)
  , SourceAnswer (..)
  , SourceSupplier
  , StopReport (stopIdentities)
  , admitRoot
  , advanceLoader
  , loaderConfig
  , deliverSource
  , lookupModule
  , stopModuleLoader
  )
import Hetoimasia.Scripting.Lua.Provider.Types (Ticks (ticksNow, ticksOpen, ticksOwe, ticksOweRelease))

-- | What a scheduled owner's module loader is made from.
data LoaderPlan = LoaderPlan
  { planSupplier ∷ !SourceSupplier
    -- ^ Where verified source comes from; see 'SourceSupplier'.
  , planResolver ∷ !AddressResolver
    -- ^ How an import's path and root become an identity; see 'AddressResolver'.
  , planBound ∷ !Int
    -- ^ How many submitted roots, and how many arrived sources, the inbox holds before it
    -- refuses. At least one.
  , planPhase ∷ !(Maybe ModulePhase)
    -- ^ Set while a module's top level runs, for the application's own preconditions.
  }

-- | A plan over a supplier and a resolver, with room for 'defaultLoaderBound' of each.
loaderPlan ∷ SourceSupplier → AddressResolver → LoaderPlan
loaderPlan supplier resolver = LoaderPlan supplier resolver defaultLoaderBound Nothing

defaultLoaderBound ∷ Int
defaultLoaderBound = 64

-- | When a submitted root may begin.
data RootDue
  = -- | At once, in the order it was submitted: a root a UI asked for.
    DueUi
  | -- | When the owner's logical tick has reached this one, in the order submitted.
    DueTick !Word64
  deriving (Eq, Show)

-- | What a producer is told of a submission.
data SubmitAnswer
  = SubmitAccepted
  | -- | The inbox holds as many roots as it may: nothing changed.
    SubmitFull
  | -- | The owner has stopped taking roots: nothing changed.
    SubmitClosed
  | -- | A logical root below the last logical tick submitted: that tick. Nothing changed.
    SubmitOutOfOrder !Word64
  deriving (Eq, Show)

-- | What a producer is told of a notification.
data NotifyAnswer
  = NotifyAccepted
  | -- | A notification for the identity is already waiting: nothing changed.
    NotifyDuplicate
  | -- | The inbox holds as many arrived sources as it may: nothing changed.
    NotifyFull
  | NotifyClosed
  | -- | The answer was 'SourcePending', which tells the owner nothing.
    NotifyNothing
  deriving (Eq, Show)

-- | What the owner published about a root.
data LoaderOutcome
  = -- | Admitted, and not yet ready or failed.
    OutcomeAdmitted
  | -- | Ready or failed: the status, with the very export handle or the sticky fault.
    OutcomeSettled !ModuleStatus
  | -- | Pending or evaluating when the owner stopped, or submitted and never admitted.
    OutcomeStopped
  | -- | The loader refused the root before anything was recorded for it.
    OutcomeRefused !RootRefusal
  deriving (Eq, Show)

-- | Where roots and sources are left for one owner's loader, from any thread.
newtype LoaderEndpoint = LoaderEndpoint LoadingState

-- | Why a plan is refused when the owner is created, before anything starts.
data LoaderViolation
  = -- | The inbox bound is below one: the bound.
    LoaderBoundBelowOne !Int
  | -- | The owner's VM configuration already names a loader. The plan is the owner's
    -- loader; two would disagree about the one identity cache.
    LoaderAlreadyConfigured
  deriving (Eq, Show)

-- | Every reason a plan was refused.
newtype LoaderPlanRefused = LoaderPlanRefused [LoaderViolation]
  deriving (Eq, Show)

instance Exception LoaderPlanRefused

-- | The reasons a plan cannot be used with this configuration of the owner's VM.
validatePlan ∷ Bool → LoaderPlan → [LoaderViolation]
validatePlan configured plan =
  [LoaderBoundBelowOne (planBound plan) | planBound plan < 1] <> [LoaderAlreadyConfigured | configured]

-- | What a root is owed and may begin at, from everything it was submitted as.
data Standing = Standing
  { standingFrom ∷ !Word64
    -- ^ The logical tick it may begin at; zero when a UI asked for it.
  , standingOwed ∷ !(Maybe Word64)
    -- ^ The tick that is not complete until it has an outcome, if a logical root owes one.
  }
  deriving (Eq, Show)

standingOf ∷ RootDue → Standing
standingOf DueUi = Standing 0 Nothing
standingOf (DueTick tick) = Standing tick (Just tick)

-- | The earliest of each: a root submitted again is never made later or less owed.
mergeStanding ∷ Standing → Standing → Standing
mergeStanding (Standing from owed) (Standing from' owed') =
  Standing (min from from') (case (owed, owed') of
    (Just a, Just b) → Just (min a b)
    (a, Nothing) → a
    (Nothing, b) → b)

-- | A root the owner has been asked for and has not admitted yet.
data Submission = Submission !RootRequest !RootDue

-- | What the loading side of a scheduled owner holds.
data LoadingState = LoadingState
  { lsBound ∷ !Int
  , lsTicks ∷ !Ticks
  , lsOpen ∷ !(TVar Bool)
  , lsSubmitted ∷ !(TVar (Seq Submission))
  , lsNotified ∷ !(TVar (Map.Map ExportIdentity SourceAnswer))
  , lsLastDue ∷ !(TVar (Maybe Word64))
    -- ^ The last logical tick submitted: later ones may not be lower.
  , lsDues ∷ !(TVar (Map.Map ExportIdentity Standing))
    -- ^ What each submitted root that has not come to an outcome is owed and may begin at:
    -- what eligibility and the hold read. Written in the transaction that accepts the
    -- submission, and taken out when the root has an outcome or the loader will not take it.
  , lsOutcomes ∷ !(TVar (Map.Map ExportIdentity LoaderOutcome))
  , lsRefusals ∷ !(TVar (Seq (ExportIdentity, RootRefusal)))
    -- ^ The last 'lsBound' roots the loader refused.
  , lsHeld ∷ !(TVar (Maybe Word64))
    -- ^ The tick the owner owes to a due chain: kept open until the chain has an outcome.
  , lsSeen ∷ !(IORef (Maybe (Word64, Blocked)))
    -- ^ The tick and blocking reason of the last advance, to leave the loader alone when
    -- nothing that could change them has.
  }

-- | The state of an owner's loading, over what its scheduler offers. The plan's bound is
-- at least one: the owner's creation refuses a plan that says otherwise.
newLoadingState ∷ LoaderPlan → Ticks → IO LoadingState
newLoadingState plan ticks =
  LoadingState (planBound plan) ticks
    <$> newTVarIO True
    <*> newTVarIO Seq.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Seq.empty
    <*> newTVarIO Nothing
    <*> newIORef Nothing

-- | The loader the owner's VM is configured with: the plan's seams, and eligibility from
-- what has been submitted and where the owner's logical tick is.
loadingConfig ∷ LoadingState → LoaderPlan → LoaderConfig
loadingConfig ls plan =
  (loaderConfig (planSupplier plan) (planResolver plan))
    { loaderEligible = eligible
    , loaderPhase = planPhase plan
    , loaderMayRun = mayRun
    }
  where
    -- A root nobody gave a due is a dependency that was also asked for as a root, or one
    -- the coordinator admitted without: it waits for nothing.
    eligible identity = atomically $ do
      due ← Map.lookup identity <$> readTVar (lsDues ls)
      case due of
        Just (Standing from _) → (>= from) <$> ticksNow (lsTicks ls)
        Nothing → pure True
    -- Nothing is started or resumed once a stop is asked for, or the owner is exiting: whatever is
    -- queued or suspended stays where it is for the exit.
    mayRun = atomically ((&&) <$> readTVar (lsOpen ls) <*> ticksOpen (lsTicks ls))

-- ---------------------------------------------------------------------------------
-- From any thread

-- | Leave a root for the owner to admit. Never blocks.
submitRootIn ∷ LoadingState → RootRequest → RootDue → IO SubmitAnswer
submitRootIn ls request due = atomically $ do
  open ← readTVar (lsOpen ls)
  admitting ← ticksOpen (lsTicks ls)
  queue ← readTVar (lsSubmitted ls)
  lastDue ← readTVar (lsLastDue ls)
  let -- Accepted roots read as admitted from this transaction on, so that a root that is
      -- submitted and never drained (the owner exits first) is told from one nobody sent.
      append = do
        writeTVar (lsSubmitted ls) (queue |> Submission request due)
        modifyTVar' (lsOutcomes ls) (Map.insertWith (\_ existing → existing) (rootIdentity request) OutcomeAdmitted)
        -- What the root owes is recorded, and the tick held, before the owner looks at anything.
        modifyTVar' (lsDues ls) (Map.insertWith (flip mergeStanding) (rootIdentity request) (standingOf due))
        settleHoldSTM ls
        pure SubmitAccepted
  if not (open && admitting)
    then pure SubmitClosed
    else
      if Seq.length queue >= lsBound ls
        then pure SubmitFull
        else case due of
          DueUi → append
          DueTick tick → case lastDue of
            Just last' | tick < last' → pure (SubmitOutOfOrder last')
            _ → writeTVar (lsLastDue ls) (Just tick) >> append

-- | Leave the source a provider found for the owner to deliver. Never blocks.
notifySourceIn ∷ LoadingState → ExportIdentity → SourceAnswer → IO NotifyAnswer
notifySourceIn ls identity answer = atomically $ do
  open ← readTVar (lsOpen ls)
  admitting ← ticksOpen (lsTicks ls)
  waiting ← readTVar (lsNotified ls)
  case answer of
    _ | not (open && admitting) → pure NotifyClosed
    SourcePending → pure NotifyNothing
    _
      | Map.member identity waiting → pure NotifyDuplicate
      | Map.size waiting >= lsBound ls → pure NotifyFull
      | otherwise → writeTVar (lsNotified ls) (Map.insert identity answer waiting) >> pure NotifyAccepted

-- | What the owner published about a root, if anything: its outcome, or the refusal it was
-- last refused with.
outcomeIn ∷ LoadingState → ExportIdentity → IO (Maybe LoaderOutcome)
outcomeIn ls identity = atomically (outcomeSTM ls identity)

outcomeSTM ∷ LoadingState → ExportIdentity → STM (Maybe LoaderOutcome)
outcomeSTM ls identity = do
  found ← Map.lookup identity <$> readTVar (lsOutcomes ls)
  refused ← readTVar (lsRefusals ls)
  pure $ case found of
    Just outcome → Just outcome
    Nothing → OutcomeRefused . snd <$> lastMatch refused
  where
    lastMatch refused = case [r | r@(refusedIdentity, _) ← toList refused, refusedIdentity == identity] of
      [] → Nothing
      matches → Just (last matches)

-- | What the owner published about a root once it has come to an outcome (ready, failed,
-- stopped or refused), retrying until it has. For a caller to compose with its supervised
-- wait, so that the owner ending is an answer and not a hang.
awaitOutcomeIn ∷ LoadingState → ExportIdentity → STM LoaderOutcome
awaitOutcomeIn ls identity = do
  found ← outcomeSTM ls identity
  case found of
    Just OutcomeAdmitted → retry
    Just outcome → pure outcome
    Nothing → retry

-- | The last roots the loader refused, oldest first: nothing was recorded for them.
refusalsIn ∷ LoadingState → IO [(ExportIdentity, RootRefusal)]
refusalsIn ls = toList <$> readTVarIO (lsRefusals ls)

-- | What the loading side holds right now.
data LoadingDiagnostics = LoadingDiagnostics
  { loadingSubmitted ∷ !Int
  , loadingNotified ∷ !Int
  , loadingDue ∷ !Int
    -- ^ Roots admitted and without an outcome.
  , loadingHeld ∷ !(Maybe Word64)
    -- ^ The tick owed to a due chain.
  }
  deriving (Eq, Show)

diagnosticsIn ∷ LoadingState → IO LoadingDiagnostics
diagnosticsIn ls = atomically $
  LoadingDiagnostics
    <$> (Seq.length <$> readTVar (lsSubmitted ls))
    <*> (Map.size <$> readTVar (lsNotified ls))
    <*> (Map.size <$> readTVar (lsDues ls))
    <*> readTVar (lsHeld ls)

-- ---------------------------------------------------------------------------------
-- The owner's thread

-- | Something for the owner's thread to drain: a submitted root or an arrived source.
-- Retries otherwise, to be waited on beside the scheduler's own work.
loadingWork ∷ LoadingState → STM ()
loadingWork ls = do
  submitted ← readTVar (lsSubmitted ls)
  notified ← readTVar (lsNotified ls)
  when (Seq.null submitted && Map.null notified) retry

-- | Drain the inbox into the loader and advance it, on the owner's thread. Answers
-- whether anything happened, which is whether the owner should look again.
--
-- A root is admitted before any source is delivered, in the order it was submitted, and
-- the due of an admitted root is recorded before the loader asks whether it may begin.
-- The loader is left alone when nothing arrived and nothing that could change its answer
-- has: a chain waiting for a source is not asked again until one is delivered, and a root
-- that is not eligible is asked again when the logical tick moves.
serviceLoading ∷ LoadingState → OwnedVm → IO Bool
serviceLoading ls owned = do
  -- Asked to stop, or exiting: nothing is drained, delivered or advanced, so that no module
  -- runs after the request. What is queued stays for the exit.
  taking ← atomically ((&&) <$> readTVar (lsOpen ls) <*> ticksOpen (lsTicks ls))
  if taking then service else pure False
  where
    service = do
      (submitted, notified) ← atomically $ do
        roots ← readTVar (lsSubmitted ls)
        sources ← readTVar (lsNotified ls)
        writeTVar (lsSubmitted ls) Seq.empty
        writeTVar (lsNotified ls) Map.empty
        pure (toList roots, Map.toList sources)
      tick ← atomically (ticksNow (lsTicks ls))
      seen ← readIORef (lsSeen ls)
      let nothingNew = null submitted && null notified
          unchanged = case seen of
            Just (before, BlockedIneligible _) → before == tick
            _ → True
      settleHold ls
      if nothingNew && unchanged
        then pure False
        else do
          forM_ submitted $ \(Submission request _) → do
            admission ← admitRoot owned request
            atomically (recordAdmission request admission)
          forM_ notified $ \(identity, answer) → deliverSource owned identity answer
          report ← advanceLoader owned
          writeIORef (lsSeen ls) (Just (tick, advanceBlocked report))
          atomically $ forM_ (advanceSettled report) $ \(identity, status) → do
            modifyTVar' (lsDues ls) (Map.delete identity)
            modifyTVar' (lsOutcomes ls) (Map.insert identity (OutcomeSettled status))
          settleHold ls
          pure (not nothingNew || not (null (advanceSettled report)))
    -- What a root is owed was recorded when it was submitted; here it is kept for a root the
    -- loader holds and taken out for one it will not run.
    recordAdmission request admission = case admission of
      RootQueued → pure ()
      RootJoined → pure ()
      RootSettled status → do
        modifyTVar' (lsDues ls) (Map.delete identity)
        modifyTVar' (lsOutcomes ls) (Map.insert identity (OutcomeSettled status))
      RootRefused refusal → do
        modifyTVar' (lsDues ls) (Map.delete identity)
        modifyTVar' (lsRefusals ls) $ \held →
          let next = held |> (identity, refusal)
           in if Seq.length next > lsBound ls then Seq.drop 1 next else next
        -- Nothing was recorded for it: it no longer reads as admitted.
        modifyTVar' (lsOutcomes ls) (Map.update (\outcome → if outcome == OutcomeAdmitted then Nothing else Just outcome) identity)
      RootClosed → do
        modifyTVar' (lsDues ls) (Map.delete identity)
        modifyTVar' (lsOutcomes ls) (Map.insert identity OutcomeStopped)
      where
        identity = rootIdentity request

-- | Owe the earliest tick an unfinished logical root owes (or the current one, once that has
-- passed), and give the need back when none is owed. One need, whatever the number of
-- roots; taken in the transaction that read the tick. The scheduler keeps the grant that
-- reaches the tick open, and applies no later one, until the need is given back.
settleHold ∷ LoadingState → IO ()
settleHold = atomically . settleHoldSTM

settleHoldSTM ∷ LoadingState → STM ()
settleHoldSTM ls = do
  dues ← readTVar (lsDues ls)
  held ← readTVar (lsHeld ls)
  tick ← ticksNow (lsTicks ls)
  let owed = [at | Standing _ (Just at) ← Map.elems dues]
      wanted = case owed of
        [] → Nothing
        _ → Just (max (minimum owed) tick)
  when (wanted /= held) $ do
    forM_ held (ticksOweRelease (lsTicks ls))
    forM_ wanted (ticksOwe (lsTicks ls))
    writeTVar (lsHeld ls) wanted

-- | Stop taking roots and sources. Part of the owner beginning to exit.
closeLoading ∷ LoadingState → STM ()
closeLoading ls = writeTVar (lsOpen ls) False

-- | The owner is exiting, on its thread: nothing more is taken, the loader is stopped
-- (its frames closed, its interests withdrawn), every outcome that was only admitted is
-- published as stopped, and the tick hold is given back. Answers how the stop ended, for
-- the owner to keep as evidence; the rest is done whatever it was.
retireLoading ∷ LoadingState → OwnedVm → IO (Either (ExceptionWithContext SomeException) StopReport)
retireLoading ls owned = do
  atomically (closeLoading ls)
  stopped ← tryWithContext @SomeException (stopModuleLoader owned)
  -- What each root the owner admitted came to, read from the loader while its VM is still
  -- open: a root that was abandoned by a failure reads as failed, not as stopped.
  admitted ← atomically (Map.keys . Map.filter (== OutcomeAdmitted) <$> readTVar (lsOutcomes ls))
  read' ← forM admitted $ \identity → do
    status ← tryWithContext @SomeException (lookupModule owned identity)
    pure (identity, either (const OutcomeStopped) outcomeOfStatus status)
  atomically $ do
    forM_ read' $ \(identity, outcome) → modifyTVar' (lsOutcomes ls) (Map.insert identity outcome)
    -- Every identity the stop found pending or evaluating reads as stopped, the dependencies
    -- of a chain among them.
    forM_ (either (const []) stopIdentities stopped) $ \identity →
      modifyTVar' (lsOutcomes ls) (Map.insertWith (\_ existing → existing) identity OutcomeStopped)
    writeTVar (lsDues ls) Map.empty
    writeTVar (lsSubmitted ls) Seq.empty
    writeTVar (lsNotified ls) Map.empty
    held ← readTVar (lsHeld ls)
    forM_ held (ticksOweRelease (lsTicks ls))
    writeTVar (lsHeld ls) Nothing
  pure stopped
  where
    outcomeOfStatus status = case status of
      ModuleReady _ → OutcomeSettled status
      ModuleFailed _ → OutcomeSettled status
      _ → OutcomeStopped
