-- | The explicit handoffs between the process main thread and the supervised
-- graphics owner: what crosses in each direction, how it is bounded, and what
-- a publisher is told when it does not fit.
--
-- This module owns no thread, starts no worker, and makes no backend call. It
-- is the vocabulary and the state "Hetoimasia.Runtime.GLFW.Internal.Owner"
-- runs the owner over, kept apart so the handoff rules can be read, and
-- asserted, without the worker lifetime around them.
--
-- = Which way each thing goes
--
-- +--------------------------+-----------------+------------------------------+
-- | What                     | Direction       | Transport                    |
-- +==========================+=================+==============================+
-- | Attachment lifetime      | main → owner    | one bounded port             |
-- | ('TargetEvent')          |                 | ('offerTargetEvent')         |
-- +--------------------------+-----------------+------------------------------+
-- | Window observation and   | main → owner    | one latest-value snapshot    |
-- | render eligibility       |                 | per attached target          |
-- +--------------------------+-----------------+------------------------------+
-- | Render demand            | main → owner    | one latest-value snapshot    |
-- +--------------------------+-----------------+------------------------------+
-- | Scene                    | any application | one latest-value snapshot    |
-- |                          | thread → owner  |                              |
-- +--------------------------+-----------------+------------------------------+
-- | Progress and the next    | owner → main    | one coalescing status cell   |
-- | deadline                 |                 | ('OwnerStatus')              |
-- +--------------------------+-----------------+------------------------------+
-- | Retirement facts         | owner → main    | the host's existing          |
-- |                          |                 | completion publisher, with   |
-- |                          |                 | 'TerminalRecord' retaining   |
-- |                          |                 | what a refusal could not     |
-- |                          |                 | carry                        |
-- +--------------------------+-----------------+------------------------------+
--
-- = What bounds each of them
--
-- The lifetime port is the only /ordinary/ port here, and it is bounded. A
-- refusal is answered to its publisher as 'EventRefusedFull' and is never
-- dropped silently: the main thread learns that the event did not cross and
-- keeps the attachment it was about. Nothing else rides that port, so a full
-- one cannot keep the owner from being stopped, from publishing terminal
-- evidence, or from making progress on what it already holds — those travel on
-- the stop token, on the terminal cells, and on the snapshots, none of which
-- the port can occupy.
--
-- Every snapshot holds exactly one value, so a publisher never waits and a
-- slow reader never grows anything. A target's observations carry their own
-- 'targetRevision', which is checked to be strictly increasing before the
-- value is published: a delayed publication is answered 'ObservationStale' and
-- changes nothing. A publication naming an attachment the owner no longer
-- holds — an incarnation the window's slot has moved past, in particular — is
-- answered 'ObservationUnknownTarget', because the slot is keyed by the exact
-- 'AttachmentId' and a later incarnation is never the same key.
--
-- = State
--
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
-- | State                | Owner            | Readers and writers             | Thread | Lifetime             | Reset or disposal           |
-- +======================+==================+=================================+========+======================+=============================+
-- | The lifetime port    | The owner        | Main thread sends; the graphics | Any    | The owner's lifetime | Closed by the exit, drained |
-- |                      | handoff state    | owner receives                  |        |                      | by the owner                |
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
-- | A target's           | The owner        | Main thread publishes; the      | Any    | From the target's    | Removed when the owner      |
-- | observation snapshot | handoff state    | graphics owner reads            |        | attachment to its    | releases the target         |
-- |                      |                  |                                 |        | release              |                             |
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
-- | The demand and scene | The owner        | Main thread, and any            | Any    | The owner's lifetime | Closed by the exit          |
-- | snapshots            | handoff state    | application thread, publish     |        |                      |                             |
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
-- | The status cell      | The owner        | The graphics owner writes; any  | Any    | The owner's lifetime | Never reopened once the     |
-- |                      | handoff state    | thread reads                    |        |                      | owner has finished          |
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
-- | The terminal cells   | The owner        | The graphics owner writes; the  | Any    | The owner's lifetime | Retained until the main     |
-- |                      | handoff state    | main thread validates and reads |        |                      | thread has validated them   |
-- +----------------------+------------------+---------------------------------+--------+----------------------+-----------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( -- * The handoff state
    OwnerHandoff
  , newOwnerHandoff
  , handoffLimit
  , handoffEventCapacity

    -- * Main thread to owner: attachment lifetime
  , TargetEvent (..)
  , EventAdmission (..)
  , offerTargetEvent
  , takeTargetEvents
  , closeTargetEvents
  , targetEventsOpen
  , pendingTargetEvents
  , closeOwnerPublications

    -- * Main thread to owner: observations
  , TargetObservation (..)
  , ObservationPublication (..)
  , openTargetSlot
  , closeTargetSlot
  , publishTargetObservation
  , readTargetObservations
  , observedTargets

    -- * Main thread to owner: render demand
  , OwnerDemand (..)
  , noOwnerDemand
  , publishOwnerDemand
  , readOwnerDemand
  , readOwnerDemandAt

    -- * Any application thread to owner: the scene
  , ScenePublication (..)
  , publishOwnerScene
  , readOwnerScene
  , readOwnerSceneAt

    -- * Owner to main thread: replaceable status
  , OwnerStatus (..)
  , OwnerPhase (..)
  , initialOwnerStatus
  , readOwnerStatus
  , writeOwnerPhase
  , writeOwnerProgress

    -- * Owner to main thread: terminal evidence
  , TerminalRecord (..)
  , targetTerminals
  , targetTerminal
  , recordTargetTerminal
  , recordPublishedFact
  , forgetTargetTerminal
  , OwnerTerminal (..)
  , noOwnerTerminal
  , ownerTerminal
  , recordOwnerRetired
  , recordOwnerDestroyed
  , recordOwnerEnded
  , ownerDestructionVerified

    -- * The extent seam
  , TargetGeometry (..)
  , noTargetGeometry
  , ExtentBounds (..)
  , observationFramebuffer
  , observeGeometry
  , boundGeometry
  , SuppliedExtent (..)
  , ChosenExtent (..)
  , ExtentRefusal (..)
  , chooseTargetExtent
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Control.DeepSeq (NFData (rnf))
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Foundation.Messaging.Channel
  ( ChannelControl
  , ChannelStatistics (statisticsCapacity, statisticsDepth)
  , Receipt (..)
  , SendResult (..)
  , Sender
  , channelReceiver
  , channelSender
  , channelStatistics
  , closeChannel
  , newChannel
  , receive
  , send
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( Publication (..)
  , SnapshotPublisher
  , closeSnapshot
  , cursorRevision
  , newSnapshot
  , observedCursor
  , observedValue
  , publish
  , readSnapshot
  , snapshotReader
  )
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GLFW.Internal.Attachment (Acknowledgement, AttachmentId, RetirementFact)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , Extent (..)
  , WindowObservation
  , observedFramebufferExtent
  )
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility (..))
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Main thread to owner: attachment lifetime

-- | One attachment lifetime event, the only thing the ordinary bounded port
-- carries.
--
-- 'TargetAttached' hands the owner the acknowledgement the attachment's own
-- protocol was given, which is the authority the owner publishes that
-- attachment's certified facts under. It is an authority over the attachment's
-- retirement evidence and over nothing else: it names no window handle, no
-- session, and no native resource.
data TargetEvent
  = TargetAttached !AttachmentId !Acknowledgement
  | TargetReleased !AttachmentId
    -- ^ The main thread has begun this target's individual retirement. The
    -- owner retires it through its injected operations and publishes its
    -- terminal evidence; nothing here releases anything.
  deriving (Eq, Show)

instance NFData TargetEvent where
  rnf = \case
    TargetAttached target acknowledgement → target `seq` acknowledgement `seq` ()
    TargetReleased target → target `seq` ()

-- | What one offered event did. A refusal is answered, never swallowed.
data EventAdmission
  = EventAdmitted
  | EventRefusedFull
    -- ^ The port is open and holds its whole capacity. Nothing was queued and
    -- the publisher still owns the event. It is backpressure, reported here so
    -- the main thread can keep the attachment and offer it again rather than
    -- believe the owner was told.
  | EventPortClosed
    -- ^ Admission has ended: the owner is exiting. Nothing was queued.
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Main thread to owner: observations

-- | What the main thread last observed about one attached target.
--
-- The revision is the attachment's own and is monotonic within it: the main
-- thread increments it for every publication it offers, and a publication that
-- does not advance it is refused. It is not the snapshot's revision, which
-- counts publications the snapshot accepted; keeping the two apart is what
-- lets a delayed publication be recognized as delayed.
data TargetObservation = TargetObservation
  { targetRevision ∷ !Natural
  , targetWindow ∷ !WindowObservation
  , targetEligibility ∷ !RenderEligibility
    -- ^ The main thread's own classification of that observation, handed over
    -- rather than recomputed, so the owner and the main thread never disagree
    -- about which observation a decision was made from.
  , targetBounds ∷ !(Maybe ExtentBounds)
    -- ^ The bounds the platform reported for the target, when it reported any.
  }
  deriving (Eq, Show)

instance NFData TargetObservation where
  rnf observation =
    rnf (targetRevision observation)
      `seq` rnf (targetWindow observation)
      `seq` targetEligibility observation
      `seq` rnf (targetBounds observation)

-- | What one offered observation did.
data ObservationPublication
  = ObservationAccepted !Natural
    -- ^ Accepted, at this revision.
  | ObservationStale !Natural
    -- ^ The revision did not advance past the one the slot already holds,
    -- named here. Nothing changed: a delayed publication never replaces a
    -- newer one.
  | ObservationUnknownTarget
    -- ^ The owner holds no slot for this exact attachment. A publication for
    -- an incarnation the window's slot has moved past lands here, because the
    -- slot is keyed by the exact attachment and a later incarnation is a
    -- different key.
  | ObservationSlotClosed
    -- ^ The slot exists but its snapshot has been closed by the exit.
  deriving (Eq, Show)

-- | One target's slot: its latest-value snapshot and the revision it holds.
-- | One target's slot: its latest-value snapshot and the observation revision
-- it holds. The snapshot holds 'Nothing' until the main thread has published
-- an observation for it, so a target that was just handed over is never
-- mistaken for one whose extent is known.
data TargetSlot = TargetSlot
  { slotSnapshot ∷ !(SnapshotPublisher (Maybe TargetObservation))
  , slotRevision ∷ !(TVar Natural)
  }

-- ---------------------------------------------------------------------------
-- Main thread to owner: render demand

-- | The render demand the main thread hands the owner, composed on the owner
-- turn from the application's simulation demand and each window's observed
-- eligibility.
--
-- It is coordination, not authority: the owner schedules its own waits from
-- its own deadlines and this together, and a main thread that publishes
-- nothing at all does not stop the owner from meeting a deadline of its own.
data OwnerDemand = OwnerDemand
  { ownerDemandImmediate ∷ !Bool
  , ownerDemandDeadline ∷ !(Maybe Instant)
  }
  deriving (Eq, Show)

instance NFData OwnerDemand where
  rnf demand = rnf (ownerDemandImmediate demand) `seq` ownerDemandDeadline demand `seq` ()

-- | No demand at all, which is what an owner with no attached target is handed.
noOwnerDemand ∷ OwnerDemand
noOwnerDemand = OwnerDemand False Nothing

-- ---------------------------------------------------------------------------
-- Owner to main thread

-- | Where the owner is in its own lifetime. Replaceable status, never evidence.
data OwnerPhase
  = OwnerStarting
    -- ^ Its injected startup has not answered yet.
  | OwnerRunning
  | OwnerRetiring
    -- ^ It is retiring its targets and itself through its injected operations.
  | OwnerDestroying
  | OwnerFinished
    -- ^ Its run action has ended. This says nothing about evidence: what was
    -- established is in 'OwnerTerminal' and in the retirement facts the host's
    -- model holds, and neither is implied by reaching this phase.
  deriving (Eq, Ord, Show)

-- | The replaceable progress the owner publishes.
--
-- Every field is coalescing: a reader sees the latest, never a backlog, and
-- the owner never waits for one to be read. Nothing here is evidence, and
-- nothing here is permission: the exit validates terminal facts and never this.
data OwnerStatus = OwnerStatus
  { statusPhase ∷ !OwnerPhase
  , statusRounds ∷ !Natural
    -- ^ Bounded rounds the owner has completed, so a test and a diagnostic can
    -- see it progressing without reading a clock.
  , statusAdvanced ∷ !Natural
    -- ^ Of those, the ones whose step reported work done.
  , statusImmediate ∷ !Bool
    -- ^ Whether the owner's own last step said further work is owed at once.
  , statusNextDeadline ∷ !(Maybe Instant)
    -- ^ The earliest absolute instant the owner's injected operations named, in
    -- the host clock's domain. The main loop may fold it into its own idle
    -- bound; the owner does not need it to be read.
  }
  deriving (Eq, Show)

-- | Nothing run, nothing owed, nowhere yet.
initialOwnerStatus ∷ OwnerStatus
initialOwnerStatus = OwnerStatus OwnerStarting 0 0 False Nothing

-- | The terminal evidence one target's retirement established.
--
-- A record exists only because an injected operation returned one. The owner
-- never writes a record it inferred from a step's failure, a cancellation, or
-- its own completion, so a target with no record here is a target whose
-- retirement is unverified.
data TerminalRecord = TerminalRecord
  { terminalEvidence ∷ !Text
    -- ^ What the backend's own retirement operation returned.
  , terminalOwed ∷ ![RetirementFact]
    -- ^ The certified facts this record establishes and the owner has not yet
    -- had admitted by the host's completion publisher. A refusal leaves them
    -- here, so a full inbox delays publication and never loses it.
  , terminalPublished ∷ ![RetirementFact]
    -- ^ The facts the publisher has admitted, oldest first.
  }
  deriving (Eq, Show)

-- | What the owner's whole-owner retirement and destruction established.
--
-- The two are separate because D-33 separates them: retirement ends the
-- owner's use of its shared state, destruction releases it, and only the
-- second is permission for anything. Both are absent until the injected
-- operation that establishes each has returned one.
data OwnerTerminal = OwnerTerminal
  { ownerRetiredEvidence ∷ !(Maybe Text)
  , ownerDestroyedEvidence ∷ !(Maybe Text)
  , ownerRunEnded ∷ !Bool
    -- ^ Whether the owner's run action has ended, however it ended. It is
    -- never evidence: an owner that ended without 'ownerDestroyedEvidence' has
    -- destroyed nothing that the main thread may act on.
  }
  deriving (Eq, Show)

noOwnerTerminal ∷ OwnerTerminal
noOwnerTerminal = OwnerTerminal Nothing Nothing False

-- ---------------------------------------------------------------------------
-- The whole handoff state

-- | Everything that crosses between the main thread and one graphics owner.
data OwnerHandoff scene = OwnerHandoff
  { handoffEvents ∷ !(ChannelControl TargetEvent)
  , handoffEventSender ∷ !(Sender TargetEvent)
  , handoffSlots ∷ !(TVar (Map AttachmentId TargetSlot))
  , handoffLimit' ∷ !Int
  , handoffDemand ∷ !(SnapshotPublisher OwnerDemand)
  , handoffScene ∷ !(SnapshotPublisher scene)
  , handoffStatus ∷ !(TVar OwnerStatus)
  , handoffTargetTerminals ∷ !(TVar (Map AttachmentId TerminalRecord))
  , handoffOwnerTerminal ∷ !(TVar OwnerTerminal)
  , handoffAdmitting ∷ !(TVar Bool)
    -- ^ Whether the lifetime port still admits. The channel's own phase is not
    -- readable without taking from it, and a reader that had to take would be
    -- a reader that could lose an event.
  }

-- | Build the handoff state for one owner over a host's window limit.
--
-- The limit bounds the number of observation slots and the capacity bounds the
-- lifetime port, so the whole handoff is bounded by configuration and by
-- nothing that grows with how long the owner runs or with how many targets it
-- has ever held.
newOwnerHandoff ∷ Int → Int → Prepared scene → IO (OwnerHandoff scene)
newOwnerHandoff limit capacity scene = do
  events ← newChannel (fromIntegral (max 1 capacity))
  demand ← prepare noOwnerDemand >>= newSnapshot
  OwnerHandoff events (channelSender events)
    <$> newTVarIO Map.empty
    <*> pure (max 1 limit)
    <*> pure demand
    <*> newSnapshot scene
    <*> newTVarIO initialOwnerStatus
    <*> newTVarIO Map.empty
    <*> newTVarIO noOwnerTerminal
    <*> newTVarIO True

-- | The most observation slots the handoff holds at once.
handoffLimit ∷ OwnerHandoff scene → Int
handoffLimit = handoffLimit'

-- | The most lifetime events the port holds at once.
handoffEventCapacity ∷ OwnerHandoff scene → STM Natural
handoffEventCapacity handoff = statisticsCapacity <$> channelStatistics (handoffEvents handoff)

-- ---------------------------------------------------------------------------
-- The lifetime port

-- | Offer one lifetime event, without waiting, from any thread.
offerTargetEvent ∷ OwnerHandoff scene → Prepared TargetEvent → STM EventAdmission
offerTargetEvent handoff event =
  send (handoffEventSender handoff) event >>= \case
    Accepted → pure EventAdmitted
    Full → pure EventRefusedFull
    Closed → pure EventPortClosed

-- | Take every queued event, oldest first, without waiting.
takeTargetEvents ∷ OwnerHandoff scene → STM [TargetEvent]
takeTargetEvents handoff = go []
  where
    receiver = channelReceiver (handoffEvents handoff)
    go taken =
      receive receiver >>= \case
        Received payload → go (preparedValue payload : taken)
        _ → pure (reverse taken)

-- | End the port's admission. Queued events stay for the owner to drain.
closeTargetEvents ∷ OwnerHandoff scene → STM ()
closeTargetEvents handoff = do
  closeChannel (handoffEvents handoff)
  writeTVar (handoffAdmitting handoff) False

-- | Whether the lifetime port still admits an event, readable from any thread
-- and taking nothing.
targetEventsOpen ∷ OwnerHandoff scene → STM Bool
targetEventsOpen = readTVar . handoffAdmitting

-- | End every publication into the handoff: the lifetime port, the demand
-- snapshot, the scene snapshot, and each target's observation slot.
--
-- The owner's quiescence closes all of them together, for the reason the
-- host's own quiescence closes its ports: after it, a publisher holding an
-- escaped endpoint is told its publication was refused rather than being left
-- to believe an owner that has ended received it. Each is idempotent, and none
-- is ever reopened.
closeOwnerPublications ∷ OwnerHandoff scene → STM ()
closeOwnerPublications handoff = do
  closeTargetEvents handoff
  closeSnapshot (handoffDemand handoff)
  closeSnapshot (handoffScene handoff)
  slots ← readTVar (handoffSlots handoff)
  mapM_ (closeSnapshot . slotSnapshot) (Map.elems slots)

-- | How many events are queued, for an example that must prove the port is
-- full rather than assume it. It takes nothing and changes nothing.
pendingTargetEvents ∷ OwnerHandoff scene → STM Natural
pendingTargetEvents handoff = statisticsDepth <$> channelStatistics (handoffEvents handoff)

-- ---------------------------------------------------------------------------
-- Observation slots

-- | Open one target's observation slot, from the main thread.
--
-- It answers 'False' for an attachment that already holds one and for a
-- handoff already holding its whole limit, having changed nothing. An
-- attachment identity is never reissued, so the first case is a repeat rather
-- than a replacement, and the slot the target already has is left exactly as
-- it is.
openTargetSlot ∷ OwnerHandoff scene → AttachmentId → IO Bool
openTargetSlot handoff target = do
  snapshot ← prepare Nothing >>= newSnapshot
  revision ← newTVarIO 0
  atomically $ do
    slots ← readTVar (handoffSlots handoff)
    if Map.member target slots || Map.size slots >= handoffLimit' handoff
      then pure False
      else True <$ writeTVar (handoffSlots handoff) (Map.insert target (TargetSlot snapshot revision) slots)

-- | Close and forget one target's slot, which the owner does once it has
-- released the target. A later publication for it answers
-- 'ObservationUnknownTarget'.
closeTargetSlot ∷ OwnerHandoff scene → AttachmentId → STM ()
closeTargetSlot handoff target = modifyTVar' (handoffSlots handoff) (Map.delete target)

-- | Publish one target's latest observation, from the main thread.
publishTargetObservation
  ∷ OwnerHandoff scene → AttachmentId → Prepared (Maybe TargetObservation) → STM ObservationPublication
publishTargetObservation handoff target payload = do
  slots ← readTVar (handoffSlots handoff)
  case Map.lookup target slots of
    Nothing → pure ObservationUnknownTarget
    Just slot → do
      held ← readTVar (slotRevision slot)
      let offered = maybe 0 targetRevision (preparedValue payload)
      if offered <= held
        then pure (ObservationStale held)
        else
          publish (slotSnapshot slot) payload >>= \case
            PublicationClosed → pure ObservationSlotClosed
            Published → ObservationAccepted offered <$ writeTVar (slotRevision slot) offered

-- | Every target's latest observation, in attachment order, in one
-- transaction. A target the main thread has published nothing for yet answers
-- 'Nothing'.
readTargetObservations ∷ OwnerHandoff scene → STM [(AttachmentId, Maybe TargetObservation)]
readTargetObservations handoff = do
  slots ← readTVar (handoffSlots handoff)
  traverse
    (\(target, slot) → (,) target . preparedValue . observedValue <$> readSnapshot (snapshotReader (slotSnapshot slot)))
    (Map.toAscList slots)

-- | The targets the handoff holds a slot for.
observedTargets ∷ OwnerHandoff scene → STM [AttachmentId]
observedTargets handoff = Map.keys <$> readTVar (handoffSlots handoff)

-- ---------------------------------------------------------------------------
-- Demand and scene

publishOwnerDemand ∷ OwnerHandoff scene → Prepared OwnerDemand → STM Publication
publishOwnerDemand handoff = publish (handoffDemand handoff)

readOwnerDemand ∷ OwnerHandoff scene → STM OwnerDemand
readOwnerDemand = fmap fst . readOwnerDemandAt

-- | The demand beside the snapshot revision it came from, so a reader can wait
-- for one newer than the one it folded.
readOwnerDemandAt ∷ OwnerHandoff scene → STM (OwnerDemand, Natural)
readOwnerDemandAt handoff = do
  observed ← readSnapshot (snapshotReader (handoffDemand handoff))
  pure (preparedValue (observedValue observed), cursorRevision (observedCursor observed))

-- | What one scene publication did.
newtype ScenePublication = ScenePublication Publication
  deriving (Eq, Show)

-- | Publish the scene the owner renders, from any application thread.
--
-- It is a latest-value snapshot deliberately: a thread that produces scenes
-- faster than the owner consumes them replaces its own last one and never
-- waits, and a main thread stalled in a platform modal loop publishes nothing
-- without keeping the owner from rendering the last coherent scene it holds.
publishOwnerScene ∷ OwnerHandoff scene → Prepared scene → STM ScenePublication
publishOwnerScene handoff = fmap ScenePublication . publish (handoffScene handoff)

readOwnerScene ∷ OwnerHandoff scene → STM scene
readOwnerScene = fmap fst . readOwnerSceneAt

-- | The scene beside the snapshot revision it came from.
readOwnerSceneAt ∷ OwnerHandoff scene → STM (scene, Natural)
readOwnerSceneAt handoff = do
  observed ← readSnapshot (snapshotReader (handoffScene handoff))
  pure (preparedValue (observedValue observed), cursorRevision (observedCursor observed))

-- ---------------------------------------------------------------------------
-- Status

readOwnerStatus ∷ OwnerHandoff scene → STM OwnerStatus
readOwnerStatus = readTVar . handoffStatus

writeOwnerPhase ∷ OwnerHandoff scene → OwnerPhase → STM ()
writeOwnerPhase handoff phase =
  modifyTVar' (handoffStatus handoff) (\status → status {statusPhase = phase})

-- | Record one completed round: whether its step reported work, whether more
-- is owed at once, and the earliest deadline the owner's operations named.
writeOwnerProgress ∷ OwnerHandoff scene → Bool → Bool → Maybe Instant → STM ()
writeOwnerProgress handoff advanced immediate deadline =
  modifyTVar' (handoffStatus handoff) $ \status →
    status
      { statusRounds = statusRounds status + 1
      , statusAdvanced = statusAdvanced status + (if advanced then 1 else 0)
      , statusImmediate = immediate
      , statusNextDeadline = deadline
      }

-- ---------------------------------------------------------------------------
-- Terminal evidence

targetTerminals ∷ OwnerHandoff scene → STM (Map AttachmentId TerminalRecord)
targetTerminals = readTVar . handoffTargetTerminals

targetTerminal ∷ OwnerHandoff scene → AttachmentId → STM (Maybe TerminalRecord)
targetTerminal handoff target = Map.lookup target <$> targetTerminals handoff

-- | Record what one target's injected retirement returned, with the facts it
-- establishes still owed publication.
--
-- The record is never replaced: retirement evidence is established once, and a
-- second call for the same target leaves the first record exactly as it is.
recordTargetTerminal ∷ OwnerHandoff scene → AttachmentId → Text → [RetirementFact] → STM ()
recordTargetTerminal handoff target evidence facts =
  modifyTVar' (handoffTargetTerminals handoff) $
    Map.insertWith (\_ existing → existing) target (TerminalRecord evidence facts [])

-- | Move one fact from owed to published, once the host's completion publisher
-- has admitted it. A fact the publisher refused stays owed.
recordPublishedFact ∷ OwnerHandoff scene → AttachmentId → RetirementFact → STM ()
recordPublishedFact handoff target fact =
  modifyTVar' (handoffTargetTerminals handoff) (Map.adjust move target)
  where
    move record =
      record
        { terminalOwed = filter (/= fact) (terminalOwed record)
        , terminalPublished = terminalPublished record <> [fact]
        }

-- | Drop one target's terminal record, once the attachment it belongs to has
-- validated the facts it established and left the host's pending set.
--
-- Nothing here is dropped on the owner's say-so: the caller establishes that
-- the exact attachment is gone from the host's own model first, which is what
-- keeps these cells bounded by the live windows rather than by how many
-- incarnations a window has ever had.
forgetTargetTerminal ∷ OwnerHandoff scene → AttachmentId → STM ()
forgetTargetTerminal handoff target =
  modifyTVar' (handoffTargetTerminals handoff) (Map.delete target)

ownerTerminal ∷ OwnerHandoff scene → STM OwnerTerminal
ownerTerminal = readTVar . handoffOwnerTerminal

-- | Whether the owner's whole-owner destruction evidence has been established,
-- by the owner itself or by an independent publisher.
ownerDestructionVerified ∷ OwnerHandoff scene → STM Bool
ownerDestructionVerified handoff = isJust . ownerDestroyedEvidence <$> ownerTerminal handoff

recordOwnerRetired ∷ OwnerHandoff scene → Text → STM ()
recordOwnerRetired handoff evidence =
  modifyTVar' (handoffOwnerTerminal handoff) $ \terminal →
    terminal {ownerRetiredEvidence = maybe (Just evidence) Just (ownerRetiredEvidence terminal)}

recordOwnerDestroyed ∷ OwnerHandoff scene → Text → STM ()
recordOwnerDestroyed handoff evidence =
  modifyTVar' (handoffOwnerTerminal handoff) $ \terminal →
    terminal {ownerDestroyedEvidence = maybe (Just evidence) Just (ownerDestroyedEvidence terminal)}

-- | Record that the owner's run action has ended. It establishes nothing.
recordOwnerEnded ∷ OwnerHandoff scene → STM ()
recordOwnerEnded handoff =
  modifyTVar' (handoffOwnerTerminal handoff) (\terminal → terminal {ownerRunEnded = True})

-- ---------------------------------------------------------------------------
-- The extent seam

-- | The bounds a platform reported for one target's drawable area.
data ExtentBounds = ExtentBounds
  { boundsMinimum ∷ !Extent
  , boundsMaximum ∷ !Extent
  }
  deriving (Eq, Show)

instance NFData ExtentBounds where
  rnf bounds = rnf (boundsMinimum bounds) `seq` rnf (boundsMaximum bounds)

-- | The last coherent framebuffer observation and reported bounds the owner
-- holds for one target.
--
-- It is held by the owner, on the owner's thread, precisely so a main thread
-- stalled in a platform modal loop leaves the owner with the last observation
-- it did publish rather than with nothing.
data TargetGeometry = TargetGeometry
  { geometryFramebuffer ∷ !(Maybe Extent)
  , geometryBounds ∷ !(Maybe ExtentBounds)
  }
  deriving (Eq, Show)

noTargetGeometry ∷ TargetGeometry
noTargetGeometry = TargetGeometry Nothing Nothing

-- | The framebuffer extent one observation reports, if the platform reported
-- one at all.
observationFramebuffer ∷ TargetObservation → Maybe Extent
observationFramebuffer observation = case observedFramebufferExtent (targetWindow observation) of
  Observed extent → Just extent
  Unavailable → Nothing

-- | Fold one observation's framebuffer extent and reported bounds into the
-- geometry, keeping the last /coherent/ value of each: an attribute the
-- platform could not report leaves the one already held rather than erasing
-- it, which is what makes a stalled main thread leave the owner the last good
-- geometry rather than none.
observeGeometry ∷ Maybe Extent → Maybe ExtentBounds → TargetGeometry → TargetGeometry
observeGeometry framebuffer bounds geometry =
  TargetGeometry
    { geometryFramebuffer = maybe (geometryFramebuffer geometry) Just framebuffer
    , geometryBounds = maybe (geometryBounds geometry) Just bounds
    }

-- | Clamp an extent to the bounds the geometry holds, if it holds any.
boundGeometry ∷ TargetGeometry → Extent → Extent
boundGeometry geometry extent = case geometryBounds geometry of
  Nothing → extent
  Just bounds →
    Extent
      { extentWidth = clamp (extentWidth (boundsMinimum bounds)) (extentWidth (boundsMaximum bounds)) (extentWidth extent)
      , extentHeight = clamp (extentHeight (boundsMinimum bounds)) (extentHeight (boundsMaximum bounds)) (extentHeight extent)
      }
  where
    clamp low high value = max low (min high value)

-- | What a backend said about the current extent this round.
data SuppliedExtent
  = BackendSupplied !Extent
    -- ^ The backend reported a concrete current extent. D-30 takes it.
  | ApplicationChooses
    -- ^ The backend reported that the application chooses, which is the case
    -- D-30 falls back to the last published observation for.
  | ExtentUnreported
    -- ^ The backend reported nothing this round.
  deriving (Eq, Show)

-- | Why no extent was chosen.
data ExtentRefusal
  = ExtentNotEligible !RenderEligibility
    -- ^ The target's own eligibility excludes rendering. Checked first, so a
    -- clamp can never resume a suspended target.
  | ExtentZeroArea !Extent
    -- ^ The extent has no area. Checked before clamping, so clamping a zero
    -- framebuffer to a positive minimum never resumes it.
  | ExtentUnobserved
    -- ^ No coherent framebuffer observation has ever reached the owner for
    -- this target, so there is nothing to fall back to.
  deriving (Eq, Show)

-- | The extent the seam chose, and which source it came from.
data ChosenExtent
  = ExtentFromBackend !Extent
  | ExtentFromObservation !Extent
    -- ^ Chosen from the last coherent observation and clamped to the reported
    -- bounds, which is D-30's "application chooses" case.
  | ExtentWithheld !ExtentRefusal
  deriving (Eq, Show)

-- | D-30's seam: take the backend's concrete extent when it supplies one, else
-- the last coherent observation clamped to the reported bounds.
--
-- The order is the decision, and it is this module's, not a backend's: render
-- eligibility first, then zero area, then the clamp. VK-10 supplies the policy
-- that decides what a backend reports and what a suspended target does next;
-- nothing here rebuilds, suspends, or bounds a retry.
chooseTargetExtent ∷ RenderEligibility → TargetGeometry → SuppliedExtent → ChosenExtent
chooseTargetExtent eligibility geometry supplied
  | eligibility /= RenderEligible = ExtentWithheld (ExtentNotEligible eligibility)
  | BackendSupplied extent ← supplied =
      if blank extent then ExtentWithheld (ExtentZeroArea extent) else ExtentFromBackend extent
  | otherwise = case geometryFramebuffer geometry of
      Nothing → ExtentWithheld ExtentUnobserved
      Just observed
        | blank observed → ExtentWithheld (ExtentZeroArea observed)
        | otherwise → ExtentFromObservation (boundGeometry geometry observed)
  where
    blank extent = extentWidth extent <= 0 || extentHeight extent <= 0
