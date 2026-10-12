-- | Read-only views of a running graphics owner, for the main thread, the
-- application, and the examples.
--
-- Nothing here writes owner state. Each view is a transaction over the cells
-- of "Hetoimasia.Runtime.GLFW.Internal.Owner.State" or the handoff, so any
-- thread may take one, and 'awaitOwnerRound' is coordination that retries
-- until the owner's own progress satisfies it.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Observation
  ( ownerHandoff
  , graphicsOwnerWorker
  , readOwnerStatusNow
  , readOwnerTerminalNow
  , readTargetTerminalsNow
  , readOwnerGeometry
  , readOwnerTargets
  , readOwnerAcknowledged
  , readTargetStanding
  , readOwnerFailure
  , readOwnerFailures
  , ownerTargetAcknowledgement
  , awaitOwnerRound
  , readOwnerDemandTaken
  , publishGraphicsWindowScene
  , readGraphicsSceneRevisions
  , pruneWindowScenes
  ) where

import Control.Concurrent.STM (STM, check, readTVar)
import Control.Exception (ExceptionWithContext, SomeException)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Worker (Worker)
import Hetoimasia.GLFW.Internal.Attachment (Acknowledgement, AttachmentId)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (custodyAcknowledgementOf)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( OwnerHandoff
  , OwnerStatus (statusRounds)
  , OwnerTerminal (ownerRunEnded)
  , TargetGeometry
  , SceneMode (..)
  , TerminalRecord
  , WindowScenePublication
  , handoffSceneMode
  , ownerTerminal
  , publishOwnerWindowScene
  , pruneOwnerWindowScenes
  , readOwnerDemandAt
  , readOwnerSceneAt
  , readOwnerWindowSceneAt
  , readOwnerStatus
  , targetTerminals
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( GraphicsOwner (..)
  , Latched (latchedFailure)
  , TargetStanding
  , TargetState (targetConstruction)
  , standingOf
  )
import Numeric.Natural (Natural)

-- | The handoff state, for a caller that publishes into it or reads from it.
ownerHandoff ∷ GraphicsOwner scene → OwnerHandoff scene
ownerHandoff = ownerHandoff'

-- | The foundation worker, for raw observation of its completion.
graphicsOwnerWorker ∷ GraphicsOwner scene → Worker ()
graphicsOwnerWorker = ownerWorkerHandle

readOwnerStatusNow ∷ GraphicsOwner scene → STM OwnerStatus
readOwnerStatusNow = readOwnerStatus . ownerHandoff'

readOwnerTerminalNow ∷ GraphicsOwner scene → STM OwnerTerminal
readOwnerTerminalNow = ownerTerminal . ownerHandoff'

readTargetTerminalsNow ∷ GraphicsOwner scene → STM (Map AttachmentId TerminalRecord)
readTargetTerminalsNow = targetTerminals . ownerHandoff'

-- | The last coherent framebuffer observation and reported bounds the owner
-- holds per target, which is the state D-30's seam chooses from.
readOwnerGeometry ∷ GraphicsOwner scene → STM (Map AttachmentId TargetGeometry)
readOwnerGeometry = readTVar . ownerGeometryCells

-- | The targets the owner still holds, whose retirement is therefore
-- unfinished. An entry leaves this table only against a terminal record.
readOwnerTargets ∷ GraphicsOwner scene → STM [AttachmentId]
readOwnerTargets owner = Map.keys <$> readTVar (ownerTargets owner)

-- | The attachments the owner still holds an acknowledgement for, which is
-- bounded by the windows the host may hold live and not by how many
-- incarnations they have had.
readOwnerAcknowledged ∷ GraphicsOwner scene → STM [AttachmentId]
readOwnerAcknowledged owner = Map.keys <$> readTVar (ownerCustody owner)

-- | What the owner's own construction of one target settled as, or 'Nothing'
-- once the owner no longer holds it.
readTargetStanding ∷ GraphicsOwner scene → AttachmentId → STM (Maybe TargetStanding)
readTargetStanding owner target =
  fmap (standingOf . targetConstruction) . Map.lookup target <$> readTVar (ownerTargets owner)

-- | The terminal owner failure, latched as soon as it was known. It is the
-- notification, not the evidence: 'readOwnerFailures' is the evidence.
readOwnerFailure ∷ GraphicsOwner scene → STM (Maybe (ExceptionWithContext SomeException))
readOwnerFailure owner = fmap latchedFailure <$> readTVar (ownerLatch owner)

-- | Every failure the owner retained, oldest first.
readOwnerFailures ∷ GraphicsOwner scene → STM [ExceptionWithContext SomeException]
readOwnerFailures = readTVar . ownerRetained

-- | The acknowledgement the host gave one attachment's protocol, which is what
-- the owner publishes that attachment's certified facts under.
--
-- It is kept after the target's own state is gone, because a fact may still be
-- owed once the target has been retired, and it is readable so that a
-- composition which must supply /independent/ evidence for an attachment the
-- owner could not account for has the authority to publish it. It is
-- completion authority for that one incarnation and nothing else: it names no
-- window, no session, and no resource.
ownerTargetAcknowledgement ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
ownerTargetAcknowledgement = custodyAcknowledgementOf

-- | Wait until the owner has completed a round beyond the one given, or has
-- ended.
--
-- It is coordination for a caller that must observe the owner's progress
-- without reading a clock; the owner never waits for anybody to call it.
awaitOwnerRound ∷ GraphicsOwner scene → Natural → STM OwnerStatus
awaitOwnerRound owner seen = do
  status ← readOwnerStatus (ownerHandoff' owner)
  finished ← ownerRunEnded <$> ownerTerminal (ownerHandoff' owner)
  check (statusRounds status > seen || finished)
  pure status

-- | Whether the owner has taken the latest published render demand into a
-- step.
--
-- A publisher that accumulates demand until it has been taken reads this to
-- know when it may stop republishing what it already published: the demand is
-- a latest-value snapshot, so a newer publication replaces an older one the
-- owner never read, and only a publisher that keeps what was not yet taken in
-- every later publication loses nothing. Coordination only; the owner never
-- waits for anybody to read it.
readOwnerDemandTaken ∷ GraphicsOwner scene → STM Bool
readOwnerDemandTaken owner = do
  (_, published) ← readOwnerDemandAt (ownerHandoff' owner)
  (seen, _) ← readTVar (ownerSeenInputs owner)
  pure (seen >= published)

-- | Publish one window's scene, from any application thread, in a handoff that
-- carries one for each window.
--
-- The windows the host holds are read in the same transaction as the
-- publication, so a window that ends is never accepted a scene after the
-- transaction that saw it end. A window the host does not hold is answered
-- 'Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff.WindowSceneUnknown', naming
-- it, and nothing changes. See
-- 'Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff.publishOwnerWindowScene'.
publishGraphicsWindowScene ∷ GraphicsOwner scene → WindowId → Prepared scene → STM WindowScenePublication
publishGraphicsWindowScene owner window scene = do
  held ← ownerWindows owner
  publishOwnerWindowScene (ownerHandoff' owner) held window scene

-- | The latest published scene revision of every window the host holds, in one
-- transaction: a window's own, or zero for one that has had no publication.
-- In a shared handoff the shared scene's revision plays the part of every
-- window's.
readGraphicsSceneRevisions ∷ GraphicsOwner scene → STM (Map WindowId Natural)
readGraphicsSceneRevisions owner = do
  held ← ownerWindows owner
  let handoff = ownerHandoff' owner
  revisions ← case handoffSceneMode handoff of
    SharedScene → (\(_, revision) → map (\window → (window, revision)) held) <$> readOwnerSceneAt handoff
    PerWindowScenes → traverse (\window → (\(_, revision) → (window, revision)) <$> readOwnerWindowSceneAt handoff window) held
  pure (Map.fromList revisions)

-- | Forget the publication of every window the host no longer holds. The
-- owner's round does it; nothing else writes the table.
pruneWindowScenes ∷ GraphicsOwner scene → STM ()
pruneWindowScenes owner = do
  held ← ownerWindows owner
  pruneOwnerWindowScenes (ownerHandoff' owner) held
