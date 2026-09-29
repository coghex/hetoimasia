-- | Starting a graphics owner: allocating the one owner handle and starting
-- its worker into the component's own worker group.
--
-- It runs on the main thread, inside the protected host's scope, and is the
-- only place any cell of "Hetoimasia.Runtime.GLFW.Internal.Owner.State" is
-- allocated. From the host it takes only the narrow readers the owner keeps —
-- the pending and retiring attachment sets — its completion publisher, its
-- wake notifier, its clock and its window limit; never the host itself.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Start
  ( startGraphicsOwner
  , OwnerHostUnprotected (..)
  , OwnerHandleMissing (..)
  ) where

import Control.Concurrent.STM (STM, newTVarIO)
import Control.Exception (Exception, throwIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Worker (WorkerGroup, awaitStartup, startWorkerWith, workerDefinition)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentPhase (AttachmentRetiring), viewPhase)
import Hetoimasia.Runtime.GLFW.Internal
  ( AttachmentId
  , HostConfig (..)
  , WindowHost
  , hostAttachmentView
  , hostConfiguration
  , hostGraphicsPublisher
  , hostPendingAttachments
  , hostWakeNotifier
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (newOwnerHandoff)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..), retainedFailureBound)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Worker (runOwnerAction)

-- | A graphics owner was asked for over a host that owns no retirement state,
-- so no attachment could ever name it and no fact could be published to it.
data OwnerHostUnprotected = OwnerHostUnprotected
  deriving (Eq, Show)

instance Exception OwnerHostUnprotected

-- | The owner's run action found no handle naming it.
--
-- Unreachable: the starter's preparation step fills that cell before the
-- child runs any of its definition. It is a typed failure rather than a silent
-- success, so a future change to the start handoff cannot turn an owner that
-- never ran into one that appears to have finished.
data OwnerHandleMissing = OwnerHandleMissing
  deriving (Eq, Show)

instance Exception OwnerHandleMissing

-- | Build the handoff, start the worker, and answer the handle.
startGraphicsOwner
  ∷ WorkerGroup
  → WindowHost
  → IO ()
  → GraphicsOwnerConfig scene
  → (GraphicsOwner scene → IO ())
  → IO (GraphicsOwner scene)
startGraphicsOwner group host settled config publish = do
  publisher ← maybe (throwIO OwnerHostUnprotected) pure (hostGraphicsPublisher host)
  handoff ←
    newOwnerHandoff
      (hostWindowLimit (hostConfiguration host))
      (max 1 (ownerEventCapacity config))
      (ownerScene config)
  latch ← newTVarIO Nothing
  delivered ← newTVarIO False
  retained ← newTVarIO []
  targets ← newTVarIO Map.empty
  custody ← newTVarIO Map.empty
  geometry ← newTVarIO Map.empty
  seenInputs ← newTVarIO (0, 0)
  started ← newTVarIO False
  reservations ← newTVarIO 0
  let partial worker =
        GraphicsOwner
          handoff
          worker
          group
          latch
          delivered
          retained
          targets
          custody
          geometry
          seenInputs
          (hostPendingAttachments host)
          (retiringAttachments host)
          started
          (retainedFailureBound (hostWindowLimit (hostConfiguration host)))
          reservations
          (hostWakeNotifier host)
          publisher
          (hostClock (hostConfiguration host))
          settled
          config
  -- The worker is registered and forked before a handle naming it exists, so
  -- the run action takes it from this cell. The starter's own preparation step
  -- fills it, which runs under the start's mask after the fork and before the
  -- gate that lets the child run any of its definition — so the run action
  -- never finds it empty.
  built ← newIORef Nothing
  let definition =
        workerDefinition
          (ownerLabel config)
          -- Nothing driver-shaped is allocated here and nothing is released
          -- here: every acquisition and every release the backend owns happens
          -- inside the run action's own protected retirement, which D-33
          -- requires and a 'Scoped' startup release could not provide.
          (\_ → pure ())
          (\token () → readIORef built >>= maybe (throwIO OwnerHandleMissing) (`runOwnerAction` token))
  -- The preparation step runs under the start's own mask, after the fork and
  -- before the gate that lets the child run any of its definition. Publishing
  -- the handle there — to the run action's own cell and to whatever composed
  -- this owner — is what leaves no instant at which a live owner exists that
  -- the protected exit cannot see.
  let publishHandle worker = do
        let owner = partial worker
        writeIORef built (Just owner)
        publish owner
  outcome ← startWorkerWith group definition publishHandle awaitStartup
  case outcome of
    Left _ → throwIO OwnerHostUnprotected
    Right (worker, _) → pure (partial worker)

-- | The attachments this host's model says are retiring.
retiringAttachments ∷ WindowHost → STM [AttachmentId]
retiringAttachments host = do
  pending ← hostPendingAttachments host
  views ← traverse (hostAttachmentView host) pending
  pure [target | (target, Just view) ← zip pending views, viewPhase view == AttachmentRetiring]
