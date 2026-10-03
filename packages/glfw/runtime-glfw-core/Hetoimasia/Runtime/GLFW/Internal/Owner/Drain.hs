-- | The owner's own drain: retiring every target it still holds, then the
-- owner itself, then destroying it, whatever ended the run — and settling the
-- run's outcome against what that drain found.
--
-- Owner thread, inside the run action's mask in
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.Worker", after the handoff's
-- publications have closed. It writes the owner's phase and its whole-owner
-- evidence into the handoff. The drain raises nothing itself: it accumulates
-- every failure and defers every cancellation until each operation it owes has
-- been offered.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Drain
  ( OwnerDrain
  , ownerDrain
  , absorbOwnerFailure
  , settleOwnerOutcome
  , raiseRetainingOwner
  ) where

import Control.Concurrent.STM (atomically, check, readTVarIO)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (foldM)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , deadlineReached
  , durationFromNanoseconds
  , readInstant
  , remainingUntil
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..), OwnerTimer (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence (HasEvidence (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( OwnerPhase (..)
  , OwnerTerminal (ownerRetiredEvidence)
  , ownerTerminal
  , recordOwnerDestroyed
  , recordOwnerRetired
  , writeOwnerPhase
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Latch (isAsynchronous)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
  ( GraphicsOperations (..)
  , NextDeadline (..)
  , OwnerDestroy (OwnerDestroy)
  , OwnerRetire (OwnerRetire)
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..), TargetState (targetRetirementFailed))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Targets (takeLifetimeEvents)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Terminal (forgetValidatedTargets, publishOwed, retireOneTarget)

-- | What one owner drain accumulated.
data OwnerDrain = OwnerDrain
  { drainFailures ∷ ![ExceptionWithContext SomeException]
  , drainCancellation ∷ !(Maybe (ExceptionWithContext SomeException))
  }

noOwnerDrain ∷ OwnerDrain
noOwnerDrain = OwnerDrain [] Nothing

-- | Retire every target the owner still holds, then the owner itself, then
-- destroy it — whatever ended the run action.
--
-- It raises nothing. Every failure and every cancellation is accumulated and
-- handed back, so a cancellation delivered here cannot skip retirement still
-- owed and repeated cancellation cannot release a borrowed parent early: each
-- is absorbed and re-raised only after every operation this drain owes has
-- been offered, in dependency order — every target, then the owner, then its
-- destruction.
ownerDrain ∷ GraphicsOwner scene → (∀ a. IO a → IO a) → Bool → IO OwnerDrain
ownerDrain owner restore started = do
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerRetiring)
  -- The port is closed by now, so this takes its whole backlog and nothing can
  -- arrive after it. It matters: a target announced between the owner's last
  -- round and its stop is an attachment the main thread is already holding a
  -- window for, and an owner that never took the event would leave it with no
  -- evidence to validate and no path to one.
  takeLifetimeEvents owner
  afterTargets ← drainOwed =<< drainTargets noOwnerDrain
  unverified ← Map.keys <$> readTVarIO (ownerTargets owner)
  (retiredEvidence, afterRetire) ←
    absorbing afterTargets (graphicsRetireOwner operations (OwnerRetire started unverified) >>= evaluate)
  for_ retiredEvidence (atomically . recordOwnerRetired (ownerHandoff' owner) . evidenceDetail)
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerDestroying)
  terminal ← atomically (ownerTerminal (ownerHandoff' owner))
  (destroyedEvidence, afterDestroy) ←
    absorbing
      afterRetire
      (graphicsDestroyOwner operations (OwnerDestroy (isJust (ownerRetiredEvidence terminal))) >>= evaluate)
  for_ destroyedEvidence (atomically . recordOwnerDestroyed (ownerHandoff' owner) . evidenceDetail)
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerFinished)
  pure afterDestroy
  where
    operations = ownerOperations (ownerSettings owner)
    absorbing ∷ OwnerDrain → IO a → IO (Maybe a, OwnerDrain)
    absorbing accumulated action =
      tryWithContext (restore action) >>= \case
        Right value → pure (Just value, accumulated)
        Left failure → pure (Nothing, absorbOwnerFailure failure accumulated)
    -- Every remaining target is retired before the owner is, in the order the
    -- model registered them, and a failure of one does not stop the next. A
    -- target the backend never constructed is retired too, and is told so:
    -- what the owner owns for it may be nothing, but the attachment's own
    -- terminal evidence is owed either way.
    drainTargets accumulated = do
      states ← readTVarIO (ownerTargets owner)
      retired ←
        foldM
          ( \held (target, state) →
              either (`absorbOwnerFailure` held) (const held)
                <$> tryWithContext (restore (retireOneTarget owner target state))
          )
          accumulated
          (Map.toAscList states)
      published ←
        either (`absorbOwnerFailure` retired) (const retired)
          <$> tryWithContext (restore (publishOwed owner))
      either (`absorbOwnerFailure` published) (const published)
        <$> tryWithContext (forgetValidatedTargets owner)
    -- A target whose retirement the backend cannot perform yet — its
    -- obligations wait on evidence still to arrive — is asked again, between
    -- waits for the backend's own next deadline, until it has been
    -- retired or its retirement has failed. The waits are the backend's, so
    -- nothing spins, and no timeout ends them: a timeout is not evidence. A
    -- cancellation does end them, as it ends no retirement: what is still owed
    -- then stays with the owner, unverified, and whole-owner retirement is told
    -- so by name.
    drainOwed accumulated = do
      owed ← Map.keys . Map.filter (not . targetRetirementFailed) <$> readTVarIO (ownerTargets owner)
      if null owed || isJust (drainCancellation accumulated)
        then pure accumulated
        else do
          (_, waited) ← absorbing accumulated (awaitOwedRetirement owner)
          if isJust (drainCancellation waited)
            then pure waited
            else drainOwed =<< drainTargets waited

-- | Wait, in the exit drain, until the backend's own next deadline has come,
-- with no round in between: the drain is the owner's last work, and nothing
-- else it could do is owed. A backend that names no deadline is asked again
-- after 'owedRetirementFallback'. The backend's wake is not read here: it asks
-- for a round, and the drain takes none.
awaitOwedRetirement ∷ GraphicsOwner scene → IO ()
awaitOwedRetirement owner = do
  deadline ← graphicsNextDeadline operations >>= evaluate
  now ← readInstant (ownerClock owner)
  expired ← case deadline of
    OwnerDeadline due
      | deadlineReached now due → pure (pure True)
      | otherwise → arm (remainingUntil now due)
    NoOwnerDemand → arm owedRetirementFallback
  atomically (expired >>= check)
  where
    operations = ownerOperations (ownerSettings owner)
    OwnerTimer arm = ownerClockTimer (ownerSettings owner)

-- | How long the exit drain waits before asking again about a retirement the
-- backend could not perform yet and named no deadline for: P-15's idle bound.
owedRetirementFallback ∷ Duration
owedRetirementFallback = either (error . show) id (durationFromNanoseconds RequirePositive 100000000)

-- | Keep a synchronous failure; defer the first cancellation and absorb the
-- rest, so repeated cancellation cannot cut the drain short.
--
-- The run action folds its final wake's failure in through this too, after the
-- drain's own, so the wake follows the same policy as every drain operation.
absorbOwnerFailure ∷ ExceptionWithContext SomeException → OwnerDrain → OwnerDrain
absorbOwnerFailure caught@(ExceptionWithContext _ failure) accumulated
  | isAsynchronous failure =
      accumulated {drainCancellation = maybe (Just caught) Just (drainCancellation accumulated)}
  | otherwise = accumulated {drainFailures = drainFailures accumulated <> [caught]}

-- | Settle the run action's own outcome against what the drain found.
--
-- The body's failure stays primary; the drain's are retained beside it under
-- the owner's cleanup label, and the deferred cancellation is re-raised only
-- once every operation the drain owed has been offered.
settleOwnerOutcome ∷ Either (ExceptionWithContext SomeException) () → OwnerDrain → IO ()
settleOwnerOutcome body drained = case body of
  Left primary → raiseRetainingOwner primary afterwards
  Right () → case afterwards of
    [] → pure ()
    primary : retained → raiseRetainingOwner primary retained
  where
    afterwards = drainFailures drained <> maybe [] pure (drainCancellation drained)

raiseRetainingOwner
  ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException] → IO ()
raiseRetainingOwner primary = foldr retainOne (rethrowIO primary) . reverse
  where
    retainOne failure rest =
      withResourceLabelled ownerRetirementLabel (pure ()) (\() → rethrowIO failure) (\() → rest)

-- | The cleanup label the owner's retained failures carry.
ownerRetirementLabel ∷ Text
ownerRetirementLabel = "glfw graphics owner retirement"
