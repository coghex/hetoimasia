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
-- = A due chain holds the tick
--
-- While a logical root that is due (its tick reached) has not come to an outcome, the
-- owner asks to be held at the next tick: the scheduler does not apply a grant that would
-- begin the next tick, so the chain's tick is not complete and nothing advances past the
-- obligation. The hold is one need, taken and given back as the set of such roots becomes
-- non-empty and empty, and given back when the owner exits. A UI chain holds nothing: hooks
-- and stop requests simply go on while its source is awaited. A non-yielding module still
-- blocks its owner; nothing here preempts trusted Lua.
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
-- When the owner exits the inbox closes, the loader is stopped on the owner's thread
-- (its frames closed, its interests withdrawn), every outcome that was only admitted is
-- published as stopped, and the tick hold is given back.
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
import Control.Monad (forM_, when)
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
  , stopModuleLoader
  )
import Hetoimasia.Scripting.Lua.Provider.Types (Ticks (ticksHold, ticksNow, ticksOpen, ticksRelease))

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
  | -- | Pending or evaluating when the owner stopped.
    OutcomeStopped
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
  , lsDues ∷ !(TVar (Map.Map ExportIdentity RootDue))
    -- ^ The due of each admitted root that has not come to an outcome: what eligibility
    -- reads.
  , lsOutcomes ∷ !(TVar (Map.Map ExportIdentity LoaderOutcome))
  , lsRefusals ∷ !(TVar (Seq (ExportIdentity, RootRefusal)))
    -- ^ The last 'lsBound' roots the loader refused.
  , lsHeld ∷ !(TVar (Maybe Word64))
    -- ^ The tick the owner holds for a due chain.
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
    }
  where
    -- A root nobody gave a due is a dependency that was also asked for as a root, or one
    -- the coordinator admitted without: it waits for nothing.
    eligible identity = do
      due ← Map.lookup identity <$> readTVarIO (lsDues ls)
      case due of
        Just (DueTick tick) → (>= tick) <$> atomically (ticksNow (lsTicks ls))
        _ → pure True

-- ---------------------------------------------------------------------------------
-- From any thread

-- | Leave a root for the owner to admit. Never blocks.
submitRootIn ∷ LoadingState → RootRequest → RootDue → IO SubmitAnswer
submitRootIn ls request due = atomically $ do
  open ← readTVar (lsOpen ls)
  admitting ← ticksOpen (lsTicks ls)
  queue ← readTVar (lsSubmitted ls)
  lastDue ← readTVar (lsLastDue ls)
  let append = writeTVar (lsSubmitted ls) (queue |> Submission request due) >> pure SubmitAccepted
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

-- | What the owner published about a root, if anything.
outcomeIn ∷ LoadingState → ExportIdentity → IO (Maybe LoaderOutcome)
outcomeIn ls identity = Map.lookup identity <$> readTVarIO (lsOutcomes ls)

-- | What the owner published about a root once it has come to an outcome (ready, failed or
-- stopped), retrying until it has. For a caller to compose with its supervised wait, so that
-- the owner ending is an answer and not a hang.
awaitOutcomeIn ∷ LoadingState → ExportIdentity → STM LoaderOutcome
awaitOutcomeIn ls identity = do
  found ← Map.lookup identity <$> readTVar (lsOutcomes ls)
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
    -- ^ The tick held for a due chain.
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
      forM_ submitted $ \(Submission request due) → do
        admission ← admitRoot owned request
        atomically (recordAdmission ls request due admission)
      forM_ notified $ \(identity, answer) → deliverSource owned identity answer
      report ← advanceLoader owned
      writeIORef (lsSeen ls) (Just (tick, advanceBlocked report))
      atomically $ forM_ (advanceSettled report) $ \(identity, status) → do
        modifyTVar' (lsDues ls) (Map.delete identity)
        modifyTVar' (lsOutcomes ls) (Map.insert identity (OutcomeSettled status))
      settleHold ls
      pure (not nothingNew || not (null (advanceSettled report)))
  where
    recordAdmission state request due admission = case admission of
      RootQueued → admitted state request due
      RootJoined → admitted state request due
      RootSettled status → modifyTVar' (lsOutcomes state) (Map.insert (identityOf request) (OutcomeSettled status))
      RootRefused refusal →
        modifyTVar' (lsRefusals state) $ \held →
          let next = held |> (identityOf request, refusal)
           in if Seq.length next > lsBound state then Seq.drop 1 next else next
      RootClosed → modifyTVar' (lsOutcomes state) (Map.insert (identityOf request) OutcomeStopped)
    admitted state request due = do
      modifyTVar' (lsDues state) (Map.insert (identityOf request) due)
      modifyTVar' (lsOutcomes state) (Map.insertWith (\_ existing → existing) (identityOf request) OutcomeAdmitted)
    identityOf = rootIdentity

-- | Hold the next tick while a logical root that is due has no outcome, and give the hold
-- back when none is. One need, whatever the number of roots; taken in the transaction that
-- read the tick, for a tick that has not begun.
settleHold ∷ LoadingState → IO ()
settleHold ls = atomically $ do
  dues ← readTVar (lsDues ls)
  held ← readTVar (lsHeld ls)
  tick ← ticksNow (lsTicks ls)
  let due = not (null [() | DueTick at ← Map.elems dues, at <= tick])
      wanted = if due && tick < maxBound then Just (tick + 1) else Nothing
  when (wanted /= held) $ do
    forM_ held (ticksRelease (lsTicks ls))
    forM_ wanted (ticksHold (lsTicks ls))
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
  atomically $ do
    modifyTVar' (lsOutcomes ls) (Map.map (\outcome → if outcome == OutcomeAdmitted then OutcomeStopped else outcome))
    -- Every identity the stop found pending or evaluating reads as stopped, the dependencies
    -- of a chain among them.
    forM_ (either (const []) stopIdentities stopped) $ \identity →
      modifyTVar' (lsOutcomes ls) (Map.insert identity OutcomeStopped)
    writeTVar (lsDues ls) Map.empty
    writeTVar (lsSubmitted ls) Seq.empty
    writeTVar (lsNotified ls) Map.empty
    held ← readTVar (lsHeld ls)
    forM_ held (ticksRelease (lsTicks ls))
    writeTVar (lsHeld ls) Nothing
  pure stopped
