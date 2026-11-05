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

import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVar)
import Control.Exception (Exception, onException, throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Foundation.Worker (Startup (..), WorkerGroup, awaitStartup, pollCompletion, startWorkerWithIO, workerDefinition)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId, AttachmentPhase (AttachmentRetiring), viewPhase)
import Hetoimasia.Runtime.GLFW.Internal.Host.Attachments (hostGraphicsPublisher)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Seam (hostAttachmentView, hostPendingAttachments)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (OwnerBoundary (..), OwnerWorkerBoundary (..), WindowHost, hostConfiguration)
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows (hostWindowIdentities)
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake (hostWakeNotifier)
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
--
-- @boundary@ and @workerBoundary@ are the private examples' seams,
-- 'Host.State.ownerBoundary' (#612, #613) and 'Host.State.ownerWorkerBoundary';
-- production passes the no-ops of 'noHostHooks'. @boundary@ runs on the
-- starting thread at four places and nowhere else: with
-- 'OwnerBeforePublication' at the start of the preparation step, before the
-- handle is published to the run action's cell and to the composition that
-- owns the owner; with 'OwnerPublished' at its end, once the handle is
-- published; with 'OwnerAwaitingStartup' once the gate is open and before the
-- wait for the worker's startup begins; and with 'OwnerStarted' once the start
-- has returned its worker. @workerBoundary@ runs on the owner's worker thread,
-- in its startup and in the run closure that precedes the run action.
--
-- = A start that is abandoned (#613)
--
-- If the starting thread fails or is cancelled in the preparation step or in
-- the wait, the foundation's start has already asked the worker to cancel and
-- waited until it is terminal and its helper has finished, and then raises the
-- failure with the abandoned-start evidence. Before it reaches the caller this
-- function asks one question of the owner whose handle was published:
-- did the run action begin ('ownerEntered')? If it did, the action's own
-- protected retirement records the destruction evidence, and the protected
-- exit waits for it exactly as it does for any owner that ran. If it did not,
-- the worker is terminal and cannot ever record it, and it owns nothing the
-- backend must release (nothing driver-shaped is allocated before the action
-- runs), so the owner is /withdrawn/ from the protected exit by @withdraw@, in
-- the same transaction that observed the worker terminal: there is no instant
-- at which the owner is known never to run and is still published. The
-- failure then continues as itself. Nothing is published as evidence: a
-- withdrawn owner is one the exit no longer waits for, not one whose
-- destruction was established.
--
-- The same holds for a worker that ends before it acknowledges while the wait
-- itself returned normally ('NotAcknowledged').
--
-- @withdraw@ is the composition's: it must be safe to run on an owner the
-- composition never published, and it runs inside a transaction together with
-- the read of the worker's completion.
startGraphicsOwner
  ∷ WorkerGroup
  → WindowHost
  → IO ()
  → (OwnerBoundary → IO ())
  → (OwnerWorkerBoundary → IO ())
  → GraphicsOwnerConfig scene
  → (GraphicsOwner scene → IO ())
  → (GraphicsOwner scene → STM ())
  → IO (GraphicsOwner scene)
startGraphicsOwner group host settled boundary workerBoundary config publish withdraw = do
  publisher ← maybe (throwIO OwnerHostUnprotected) pure (hostGraphicsPublisher host)
  handoff ←
    newOwnerHandoff
      (hostWindowLimit (hostConfiguration host))
      (max 1 (ownerEventCapacity config))
      (ownerSceneMode config)
      (ownerScene config)
  latch ← newTVarIO Nothing
  delivered ← newTVarIO False
  retained ← newTVarIO []
  targets ← newTVarIO Map.empty
  custody ← newTVarIO Map.empty
  geometry ← newTVarIO Map.empty
  seenInputs ← newTVarIO (0, 0)
  withheld ← newTVarIO Map.empty
  withholdRequests ← newTVarIO 0
  presenting ← newTVarIO Set.empty
  started ← newTVarIO False
  entered ← newTVarIO False
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
          withheld
          withholdRequests
          presenting
          (hostPendingAttachments host)
          (retiringAttachments host)
          (hostWindowIdentities host)
          started
          entered
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
          (\_ → liftIO (workerBoundary OwnerWorkerStarting))
          ( \token () → do
              workerBoundary OwnerWorkerEntering
              readIORef built >>= maybe (throwIO OwnerHandleMissing) (`runOwnerAction` token)
          )
  -- The preparation step runs with the starter's own masking state, after the
  -- fork and before the gate that lets the child run any of its definition.
  -- Publishing the handle there — to the run action's own cell and to whatever
  -- composed this owner — is what leaves no instant at which a live owner
  -- exists that the protected exit cannot see. The cell is filled first, so a
  -- failure anywhere after it finds the handle to ask about, and a handle that
  -- was filled but not yet published is withdrawn from a place it never was.
  let publishHandle worker = do
        boundary OwnerBeforePublication
        let owner = partial worker
        writeIORef built (Just owner)
        publish owner
        boundary OwnerPublished
      awaitStarted worker = do
        boundary OwnerAwaitingStartup
        atomically (awaitStartup worker)
  outcome ←
    startWorkerWithIO group definition publishHandle awaitStarted
      -- Handler masked by 'onException', and the only thing it does is one
      -- transaction, which cannot be interrupted: the abandoned worker is
      -- already terminal when the failure reaches here, so no cancellation can
      -- fall between that and the withdrawal.
      `onException` withdrawIfNeverEntered withdraw built
  case outcome of
    Left _ → throwIO OwnerHostUnprotected
    Right (worker, startup) → do
      case startup of
        Acknowledged → pure ()
        -- Terminal before it acknowledged: its run action can never begin.
        NotAcknowledged _ → withdrawIfNeverEntered withdraw built
      boundary OwnerStarted
      pure (partial worker)

-- | Withdraw the owner whose handle the start filled in, if its worker is
-- terminal and its run action never began; do nothing otherwise.
--
-- One transaction reads the worker's completion and the owner's entered flag
-- and withdraws, so the decision and the withdrawal cannot come apart. A worker
-- with no completion yet is not terminal and is left alone, and so is an owner
-- that entered its run, whatever its worker's record says: those are the
-- owners whose own drain records the evidence the exit waits for.
withdrawIfNeverEntered
  ∷ (GraphicsOwner scene → STM ())
  → IORef (Maybe (GraphicsOwner scene))
  → IO ()
withdrawIfNeverEntered withdraw built =
  readIORef built >>= \filled → for_ filled $ \owner → atomically $ do
    settled ← pollCompletion (ownerWorkerHandle owner)
    entered ← readTVar (ownerEntered owner)
    for_ settled (\_ → if entered then pure () else withdraw owner)

-- | The attachments this host's model says are retiring.
retiringAttachments ∷ WindowHost → STM [AttachmentId]
retiringAttachments host = do
  pending ← hostPendingAttachments host
  views ← traverse (hostAttachmentView host) pending
  pure [target | (target, Just view) ← zip pending views, viewPhase view == AttachmentRetiring]
