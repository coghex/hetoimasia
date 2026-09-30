-- | The owner's per-round target intake: taking lifetime events, noticing
-- retirements the host began, constructing what is owed, and folding the
-- latest observations.
--
-- Owner thread alone. It writes the owner's target table and geometry cells in
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.State", advances an incarnation's
-- custody to 'CustodyOwned' once it has taken the event, and reads the handoff
-- and the host's read-only retiring set.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Targets
  ( takeLifetimeEvents
  , foldHostRetirements
  , retirementsBegun
  , constructPending
  , foldObservations
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Exception (evaluate, mask, tryWithContext)
import Control.Monad (forM_, unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Hetoimasia.GLFW.Internal.Attachment (attachmentIncarnation, attachmentWindow)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (advanceCustody)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( TargetEvent (..)
  , TargetObservation (..)
  , noTargetGeometry
  , observationFramebuffer
  , observeGeometry
  , readTargetObservations
  , takeTargetEvents
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Latch (retainFailure)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
  ( GraphicsOperations (..)
  , TargetHandoff (..)
  , TargetStart (TargetStart)
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( Construction (..)
  , GraphicsOwner (..)
  , Stage (CustodyOwned)
  , TargetState (..)
  , initialEligibility
  )

-- | Fold every lifetime event the port holds, oldest first.
takeLifetimeEvents ∷ GraphicsOwner scene → IO ()
takeLifetimeEvents owner = atomically $ do
  events ← takeTargetEvents (ownerHandoff' owner)
  modifyTVar' (ownerTargets owner) (\states → foldl fold' states events)
  -- The ledger already said the owner owed each of these from the instant its
  -- announcement was admitted; this records that it has now taken it.
  forM_ [target | TargetAttached target _ ← events] (\target → advanceCustody owner target CustodyOwned)
  where
    fold' states = \case
      TargetAttached target acknowledgement →
        Map.insertWith
          (\_ existing → existing)
          target
          (TargetState acknowledgement ConstructionPending 0 initialEligibility False False 0)
          states
      TargetReleased target → Map.adjust (\state → state {targetReleasing = True}) target states

-- | Mark every target whose attachment the host has begun retiring.
--
-- 'releaseGraphicsTarget' sends a 'TargetReleased' event, but it is not the
-- only way an attachment starts retiring: a window's own close protocol
-- begins it, and so does the host's quiescence, and neither passes through
-- the lifetime port. An owner that waited for the event would leave such a
-- target unretired, its terminal evidence unproduced, and its window unable
-- to finish closing while the owner stayed live.
--
-- So the owner reads the host's model instead of waiting to be told. That is
-- idempotent — a target already releasing is unchanged — and it needs nothing
-- of the application.
foldHostRetirements ∷ GraphicsOwner scene → IO ()
foldHostRetirements owner = atomically $ do
  retiring ← ownerRetiring owner
  modifyTVar' (ownerTargets owner) $ \states →
    foldl (\held target → Map.adjust (\state → state {targetReleasing = True}) target held) states retiring

-- | Whether the host has begun retiring a target the owner holds and has not
-- yet marked.
retirementsBegun ∷ GraphicsOwner scene → STM Bool
retirementsBegun owner = do
  retiring ← ownerRetiring owner
  states ← readTVar (ownerTargets owner)
  pure (any (\target → maybe False (not . targetReleasing) (Map.lookup target states)) retiring)

-- | Construct every target the backend has not settled yet.
--
-- Ownership is retained until the backend accepts the target or verifies its
-- own rollback. A construction that raises, or is cancelled, settles as
-- neither: the target stays, marked unverified, and the owner keeps whatever
-- it left behind.
--
-- No settlement here releases anything. A target that cannot be used is
-- /reported/ through 'readTargetStanding', and the attachment it belongs to is
-- retired when the main thread releases it or when the whole host exits —
-- because the attachment and its window's exclusive slot are the main
-- thread's, and taking them from the owner's thread is the cross-thread
-- authority this design withholds.
constructPending ∷ GraphicsOwner scene → IO ()
constructPending owner = readTVarIO (ownerTargets owner) >>= go . unsettled
  where
    unsettled states = [target | (target, state) ← Map.toAscList states, pending (targetConstruction state)]
    pending = \case
      ConstructionPending → True
      _ → False
    go [] = pure ()
    go (target : rest) = do
      -- A terminal failure stops the round where it happened: the next target
      -- is not constructed into an owner that is already retiring.
      terminal ← isJust <$> readTVarIO (ownerLatch owner)
      unless terminal (construct target >> go rest)
    -- Interruptible across the injected call and masked from its return to
    -- the settlement it commits, so a cancellation can land /in/ the
    -- construction — where the owner must assume it owns whatever was built —
    -- but never between the answer and the record of it. Losing that record
    -- would leave the target pending, and the next round would construct it a
    -- second time.
    construct target = mask $ \restore →
      tryWithContext
        ( restore
            ( graphicsConstructTarget
                (ownerOperations (ownerSettings owner))
                (TargetStart target (attachmentWindow target) (attachmentIncarnation target))
                >>= evaluate
            )
        )
        >>= \case
          Left failure → do
            settle target ConstructionUnverified
            retainFailure owner failure
          Right (TargetConstructed evidence) → ownerSettled owner >> settle target (ConstructionAccepted evidence)
          Right (TargetPartial evidence) → settle target (ConstructionPartial evidence)
          Right (TargetRolledBack evidence) → settle target (ConstructionRolledBack evidence)
    settle target settlement =
      atomically
        ( modifyTVar'
            (ownerTargets owner)
            (Map.adjust (\state → state {targetConstruction = settlement}) target)
        )

-- | Fold every target's latest observation into the eligibility and geometry
-- the owner holds.
foldObservations ∷ GraphicsOwner scene → IO ()
foldObservations owner = atomically $ do
  observations ← readTargetObservations (ownerHandoff' owner)
  states ← readTVar (ownerTargets owner)
  let fresh =
        [ (target, observation)
        | (target, Just observation) ← observations
        , Just state ← [Map.lookup target states]
        , targetRevision observation > targetSeen state
        ]
  writeTVar (ownerTargets owner) (foldl foldState states fresh)
  modifyTVar' (ownerGeometryCells owner) (\geometry → foldl foldGeometry geometry fresh)
  where
    foldState held (target, observation) =
      Map.adjust
        (\state → state {targetSeen = targetRevision observation, targetEligible = targetEligibility observation})
        target
        held
    foldGeometry held (target, observation) =
      Map.insert
        target
        ( observeGeometry
            (observationFramebuffer observation)
            (targetBounds observation)
            (Map.findWithDefault noTargetGeometry target held)
        )
        held
