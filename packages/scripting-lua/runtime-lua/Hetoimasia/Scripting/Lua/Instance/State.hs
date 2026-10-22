-- | The transactions on an owner's instance state: what the application's threads
-- do (admit, deliver, ask, observe, inspect), and the small steps of the owner's
-- thread that settle an instance and its receipts.
--
-- Each is one STM transaction that never blocks. The owner's thread does the rest,
-- in "Hetoimasia.Scripting.Lua.Instance.Run".
module Hetoimasia.Scripting.Lua.Instance.State
  ( Gate (..)
  , admitInstance
  , admitBehavior
  , deliverEvent
  , requestInstanceControl
  , requestInstanceControlAt
  , admitControl
  , takeDueControls
  , takeAllLogical
  , overtakeLogical
  , observeInstance
  , forgetInstance
  , observeReceipt
  , forgetReceipt
  , settleReceipt
  , snapshotOf
  , inspectInstance
  , inspectInstances
  , lookupLive
  , connectSource
  , isInstanceTask
  , takeDelta
  , beginEnding
  , settleInstance
  , takeJobs
  , awaitJobs
  ) where

import Control.Concurrent.STM (STM, modifyTVar', newTVar, readTVar, retry, writeTVar)
import Control.Monad (forM, unless, when)
import Data.Foldable (toList)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Instance.Types
import Hetoimasia.Scripting.Lua.Owner (ModuleRef)
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId)
import Hetoimasia.Scripting.Lua.Scheduler (ControlResult (ControlNoLongerApplicable))
import Hetoimasia.Scripting.Lua.Value (Value)

-- | What the scheduler answers the instance layer's transactions: whether
-- producers are admitted, the logical tick, and what an invocation's task is doing.
data Gate = Gate
  { gateOpen ∷ STM Bool
  , gateTick ∷ STM Word64
  , gateExecution ∷ TaskId → STM Execution
  , gateWatch ∷ Word64 → STM ()
    -- ^ Ask the owner to be held at a tick: a grant that reaches it is not finished, and no
    -- later one is applied, until the owner has applied what was assigned to it.
  }

-- | Admit an instance. Never blocks.
--
-- It takes a live place and a result reservation, and the owner is told to make
-- it. The owner's thread makes the instance's @self@ and runs its @init@; until it
-- has, the instance is 'Initializing' and events can be accepted for it.
admitInstance ∷ Instances → Gate → OwnerId → InstanceRequest → STM InstanceAdmission
admitInstance instances gate owner = admitCell instances gate owner Nothing

-- | Admit an M1 behavior instance: the same live place and result reservation as any
-- other, with no event grants, and the behavior left for the owner's thread to find,
-- validate and capture when it starts the instance. The module it is named by is the
-- given reference, which only names it in a snapshot and a failure.
admitBehavior ∷ Instances → Gate → OwnerId → ModuleRef → BehaviorRequest → STM InstanceAdmission
admitBehavior instances gate owner source behavior =
  admitCell
    instances
    gate
    owner
    (Just behavior)
    InstanceRequest
      { instanceModule = source
      , instanceKind = EventOnly
      , instanceName = behaviorName behavior
      , instanceClass = behaviorClass behavior
      , instanceGrants = []
      }

admitCell ∷ Instances → Gate → OwnerId → Maybe BehaviorRequest → InstanceRequest → STM InstanceAdmission
admitCell instances gate owner behavior request = do
  open ← gateOpen gate
  live ← readTVar (insLive instances)
  retained ← readTVar (insRetained instances)
  let bounds = insBounds instances
      -- A periodic instance's interval is resolved here, exactly or not at all, and
      -- before a place is taken for it.
      resolved = case instanceKind request of
        Periodic interval → Just <$> resolveInterval (insTickDuration instances) interval
        _ → Right Nothing
  if not open
    then pure InstanceAdmissionClosed
    else case resolved of
      Left refusal → pure (InstanceIntervalRefused refusal)
      Right cadence →
        if live >= boundLiveInstances bounds || retained >= boundRetainedInstances bounds
        then pure InstanceFull
        else do
          number ← readTVar (insNext instances)
          writeTVar (insNext instances) (number + 1)
          state ← newTVar initialState
          result ← newTVar Nothing
          forgotten ← newTVar False
          released ← newTVar False
          held ← forM behavior $ \wanted → BehaviorCell wanted <$> newTVar Nothing
          let cell =
                ICell
                  { icId = number
                  , icModule = instanceModule request
                  , icKind = instanceKind request
                  , icCadence = cadence
                  , icName = instanceName request
                  , icClass = instanceClass request
                  , icGrants = Set.fromList (instanceGrants request)
                  , icState = state
                  , icResult = result
                  , icForgotten = forgotten
                  , icReleased = released
                  , icBehavior = held
                  }
          modifyTVar' (insCells instances) (Map.insert number cell)
          writeTVar (insLive instances) (live + 1)
          writeTVar (insRetained instances) (retained + 1)
          modifyTVar' (insInbox instances) (|> JobStart number)
          let identity = InstanceId owner number
          pure (InstanceAccepted identity (InstanceTicket instances cell identity))

-- | The live instance of this identity, if there is one: it is this owner's, its
-- cell is held, and it has not ended.
lookupLive ∷ Instances → OwnerId → InstanceId → STM (Maybe ICell)
lookupLive instances owner identity
  | instanceOwner identity /= owner = pure Nothing
  | otherwise = do
      cells ← readTVar (insCells instances)
      case Map.lookup (instanceLocal identity) cells of
        Nothing → pure Nothing
        Just cell → do
          state ← readTVar (icState cell)
          pure (if isTerminal (isPhase state) then Nothing else Just cell)

-- | Deliver an event to an instance's callback, by the source it connected to.
-- Never blocks.
--
-- The payload is already checked and copied, on the producer's thread. It is kept
-- unchanged, with the sequence admission gives it and the logical tick it is
-- admitted at, until its callback runs.
deliverEvent ∷ Instances → Gate → OwnerId → InstanceId → Text → Value → STM Delivery
deliverEvent instances gate owner identity source payload = do
  open ← gateOpen gate
  found ← lookupLive instances owner identity
  case found of
    Nothing → pure DeliveryUnknownTarget
    Just cell → do
      state ← readTVar (icState cell)
      if not open || isStopped state || isPhase state == Stopping
        then pure DeliveryClosed
        else
          if not (Set.member source (isConnections state))
            then pure DeliveryUnknownTarget
            else
              -- The invocation in flight, until it has run a segment, is an unstarted one
              -- and holds its place: taking it back never overfills the queue.
              if Seq.length (isQueue state) + pendingEvents state >= boundInvocationQueue (insBounds instances)
                then do
                  writeTVar (icState cell) state {isQueueFull = isQueueFull state + 1}
                  pure DeliveryQueueFull
                else do
                  tick ← gateTick gate
                  let sequenceNumber = isNextSequence state
                      queued = QueuedEvent source sequenceNumber tick payload Nothing
                  writeTVar (icState cell) $
                    state
                      { isQueue = isQueue state |> queued
                      , isNextSequence = sequenceNumber + 1
                      , isDelivered = isDelivered state + 1
                      , isDispatchQueued = True
                      }
                  unless (isDispatchQueued state) $
                    modifyTVar' (insInbox instances) (|> JobDispatch (icId cell))
                  pure (DeliveryAccepted sequenceNumber)

-- | Request that an instance pause, resume or stop. Never blocks.
--
-- Accepted, a request takes a reservation for its result and is applied by the
-- owner at its next safe boundary, in the order accepted.
requestInstanceControl ∷ Instances → Gate → OwnerId → InstanceId → InstanceControl → STM InstanceControlAnswer
requestInstanceControl instances gate owner identity request =
  admitControl instances gate owner identity request Nothing >>= either pure id

-- | Request that an instance pause, resume or stop at a place in a logically admitting
-- owner's input sequence. Never blocks.
--
-- Accepted, the request takes a reservation for its result and waits for the logical
-- boundary of its tick, where the owner applies it in the order of (tick, sequence)
-- ahead of that tick's other work. One assigned a tick the owner has begun is refused
-- as late, and one assigned a place another request holds as a duplicate; neither is
-- ever applied at another boundary or ordered by arrival. An owner that does not admit
-- logically refuses it.
requestInstanceControlAt ∷ Instances → Gate → OwnerId → InstanceId → InstanceControl → ControlSlot → STM InstanceControlAnswer
requestInstanceControlAt instances gate owner identity request slot =
  admitControl instances gate owner identity request (Just slot) >>= either pure id

-- | What a request meets, decided in one transaction: either the refusal, with nothing
-- changed, or the step that takes the request, which the caller runs in the same
-- transaction. The split lets a caller whose own bound must also hold take nothing
-- unless both do, with the reason a refusal is found for in one order: the owner
-- closed, the target unknown, the slot not logical, late or taken, and the owner's
-- reservations all held.
admitControl ∷ Instances → Gate → OwnerId → InstanceId → InstanceControl → Maybe ControlSlot → STM (Either InstanceControlAnswer (STM InstanceControlAnswer))
admitControl instances gate owner identity request slot = do
  open ← gateOpen gate
  if not open
    then pure (Left InstanceControlClosed)
    else do
      found ← lookupLive instances owner identity
      case found of
        Nothing → pure (Left InstanceControlUnknown)
        Just cell → do
          reserved ← readTVar (insControls instances)
          tick ← gateTick gate
          queued ← readTVar (insLogical instances)
          pure $ case slot of
            Just place
              | insAdmission instances /= AdmitLogically → Left InstanceControlNotLogical
              | controlTick place <= tick → Left InstanceControlLate
              | Map.member place queued → Left InstanceControlDuplicate
            _
              -- A place stays taken until its tick begins, whatever became of the request that
              -- took it, so what is queued is bounded as the reservations are: the places of
              -- requests whose instances ended count until their ticks begin.
              | reserved >= boundInstanceControls (insBounds instances) → Left InstanceControlFull
              | isJust slot && Map.size queued >= boundInstanceControls (insBounds instances) → Left InstanceControlFull
              | otherwise → Right $ do
                  settlement ← newTVar Nothing
                  forgotten ← newTVar False
                  released ← newTVar False
                  let receipt = InstanceControlReceipt settlement forgotten released (insControls instances)
                  writeTVar (insControls instances) (reserved + 1)
                  case slot of
                    Just place → do
                      modifyTVar' (insLogical instances) (Map.insert place (LogicalControl (icId cell) request receipt))
                      -- Queued and the owner asked to be held at its tick in one step, so no grant
                      -- can reach the tick between the two.
                      gateWatch gate (controlTick place)
                    Nothing → modifyTVar' (insInbox instances) (|> JobControl (icId cell) request receipt)
                  pure (InstanceControlAccepted receipt)

-- | The accepted requests assigned a tick the owner has reached, in the order of their
-- places, taken: every one of them is applied at the boundary the owner is at, or is
-- settled by the owner's exit.
takeDueControls ∷ Instances → Word64 → STM [(ControlSlot, LogicalControl)]
takeDueControls instances tick = do
  queued ← readTVar (insLogical instances)
  let (due, later) = Map.partitionWithKey (\place _ → controlTick place <= tick) queued
  writeTVar (insLogical instances) later
  pure (Map.toAscList due)

-- | The requests waiting for their ticks that are made of an instance that has ended,
-- settled as no longer applicable, once: nothing is left to apply them to, so their callers
-- need not wait for a tick that may never come. They keep their places until their ticks
-- begin, so that a place that was taken is never given twice.
overtakeLogical ∷ Instances → Word64 → STM ()
overtakeLogical instances number = do
  queued ← readTVar (insLogical instances)
  mapM_ (\control → settleReceipt (logicalReceipt control) ControlNoLongerApplicable) (filter ((== number) . logicalInstance) (Map.elems queued))

-- | Every request still waiting for its tick, taken: what the owner's exit settles.
takeAllLogical ∷ Instances → STM [LogicalControl]
takeAllLogical instances = do
  queued ← readTVar (insLogical instances)
  writeTVar (insLogical instances) Map.empty
  pure (Map.elems queued)

-- | Give a receipt's reservation back, once.
releaseReceipt ∷ InstanceControlReceipt → STM ()
releaseReceipt receipt = do
  released ← readTVar (receiptReleased receipt)
  unless released $ do
    writeTVar (receiptReleased receipt) True
    modifyTVar' (receiptReserved receipt) (subtract 1)

-- | A receipt's settlement if it has one, without waiting. Observes it.
observeReceipt ∷ InstanceControlReceipt → STM (Maybe ControlResult)
observeReceipt receipt =
  readTVar (receiptSettlement receipt) >>= \case
    Nothing → pure Nothing
    Just result → Just result <$ releaseReceipt receipt

-- | Withdraw interest in a receipt's settlement. A settled one gives its
-- reservation back now, an unsettled one when it settles.
forgetReceipt ∷ InstanceControlReceipt → STM ()
forgetReceipt receipt = do
  writeTVar (receiptForgotten receipt) True
  readTVar (receiptSettlement receipt) >>= \case
    Just _ → releaseReceipt receipt
    Nothing → pure ()

-- | Write a receipt's settlement, once. One its caller has abandoned gives its
-- reservation back as it settles.
settleReceipt ∷ InstanceControlReceipt → ControlResult → STM ()
settleReceipt receipt result =
  readTVar (receiptSettlement receipt) >>= \case
    Just _ → pure ()
    Nothing → do
      writeTVar (receiptSettlement receipt) (Just result)
      forgotten ← readTVar (receiptForgotten receipt)
      when forgotten (releaseReceipt receipt)

-- | Give an instance's result reservation back, once, and drop its cell.
releaseResult ∷ Instances → ICell → STM ()
releaseResult instances cell = do
  released ← readTVar (icReleased cell)
  unless released $ do
    writeTVar (icReleased cell) True
    modifyTVar' (insRetained instances) (subtract 1)
    modifyTVar' (insCells instances) (Map.delete (icId cell))

-- | An instance's settlement if it has one, without waiting. Reading it is
-- observing it: the first read that finds one gives the reservation back, and
-- every later read answers the same settlement and gives nothing back.
observeInstance ∷ InstanceTicket → STM (Maybe InstanceSettlement)
observeInstance (InstanceTicket instances cell _) =
  readTVar (icResult cell) >>= \case
    Nothing → pure Nothing
    Just settled → Just settled <$ releaseResult instances cell

-- | Withdraw interest in an instance's result. An ended instance gives its
-- reservation back now, a live one when it ends.
forgetInstance ∷ InstanceTicket → STM ()
forgetInstance (InstanceTicket instances cell _) = do
  writeTVar (icForgotten cell) True
  readTVar (icResult cell) >>= \case
    Just _ → releaseResult instances cell
    Nothing → pure ()

-- | Settle an instance, once: its terminal phase and its result are written
-- together, and its live place is given back. A second settlement changes nothing.
-- The result of an instance its holder has already abandoned is given back as it
-- settles.
settleInstance ∷ Instances → ICell → InstanceSettlement → STM Bool
settleInstance instances cell settlement =
  readTVar (icResult cell) >>= \case
    Just _ → pure False
    Nothing → do
      writeTVar (icResult cell) (Just settlement)
      modifyTVar' (icState cell) (\state → state {isPhase = resultPhase settlement, isStopped = True, isActive = Nothing, isConnections = Set.empty, isQueue = Seq.empty, isPending = Nothing, isUpdate = UpdateNone})
      modifyTVar' (insLive instances) (subtract 1)
      forgotten ← readTVar (icForgotten cell)
      when forgotten (releaseResult instances cell)
      pure True

-- | A coherent reading of one instance.
snapshotOf ∷ Instances → Gate → OwnerId → Text → ICell → STM InstanceSnapshot
snapshotOf instances gate owner label cell = do
  state ← readTVar (icState cell)
  kind ← cellKind cell
  execution ← case isActive state of
    Nothing → pure ExecIdle
    Just task → gateExecution gate task
  pure
    InstanceSnapshot
      { snapshotInstance = InstanceId owner (icId cell)
      , snapshotOwner = label
      , snapshotName = icName cell
      , snapshotModule = icModule cell
      , snapshotKind = kind
      , snapshotPhase = isPhase state
      , snapshotExecution = execution
      , snapshotQueued = Seq.length (isQueue state) + pendingEvents state
      , snapshotQueueBound = boundInvocationQueue (insBounds instances)
      , snapshotQueueFull = isQueueFull state
      , snapshotDelivered = isDelivered state
      , snapshotConnections = Set.size (isConnections state)
      , snapshotUpdateOwed = updateOwed state
      }

-- | One instance, live or ended and not yet observed. 'Nothing' for another
-- owner's identity and for one never issued or whose result was observed.
inspectInstance ∷ Instances → Gate → OwnerId → Text → InstanceId → STM (Maybe InstanceSnapshot)
inspectInstance instances gate owner label identity
  | instanceOwner identity /= owner = pure Nothing
  | otherwise = do
      cells ← readTVar (insCells instances)
      traverse (snapshotOf instances gate owner label) (Map.lookup (instanceLocal identity) cells)

-- | Every instance of the owner, live or ended and not yet observed, by identity.
inspectInstances ∷ Instances → Gate → OwnerId → Text → STM [InstanceSnapshot]
inspectInstances instances gate owner label = do
  cells ← readTVar (insCells instances)
  traverse (snapshotOf instances gate owner label) (Map.elems cells)

-- | Take what the owner has been asked to do, in order.
takeJobs ∷ Instances → STM (Seq Job)
takeJobs instances = do
  jobs ← readTVar (insInbox instances)
  writeTVar (insInbox instances) Seq.empty
  pure jobs

-- | Retry until there is something the owner has been asked to do.
awaitJobs ∷ Instances → STM ()
awaitJobs instances = do
  jobs ← readTVar (insInbox instances)
  when (null (toList jobs)) retry

-- | Record that an instance's function is connected to a source: the owner's side
-- of @api.connect@, run by the binding the instance's code calls, while it runs.
--
-- Refused, answering 'False', for an instance that is ending or ended, a source
-- the instance was not granted or the owner does not offer, and a source it is
-- already connected to. A connection made while @init@ runs is recorded now, so
-- that events can be accepted for it; they run only once @init@ has succeeded.
connectSource ∷ Instances → Word64 → Text → STM Bool
connectSource instances number source = do
  cells ← readTVar (insCells instances)
  case Map.lookup number cells of
    Nothing → pure False
    Just cell → do
      state ← readTVar (icState cell)
      running ← readTVar (insRunning instances)
      -- Only the instance whose code is running can connect itself: a script that
      -- names another instance's number is refused.
      let allowed =
            running == Just number
              && not (isTerminal (isPhase state))
              && not (isStopped state)
              && Set.member source (icGrants cell)
              && Map.member source (insSources instances)
              && not (Set.member source (isConnections state))
      when allowed $
        writeTVar (icState cell) state {isConnections = Set.insert source (isConnections state)}
      pure allowed

-- | The @dt@ of the update that is about to begin for this instance, in seconds, taken
-- once; a negative number when none is, which is how the driver tells a one-shot's
-- @run@ from an update. Only the instance whose code is running is answered.
takeDelta ∷ Instances → Word64 → STM Double
takeDelta instances number = do
  running ← readTVar (insRunning instances)
  pending ← readTVar (insDelta instances)
  case pending of
    Just (owner, seconds) | owner == number && running == Just number → seconds <$ writeTVar (insDelta instances) Nothing
    _ → pure (-1)

-- | Begin ending an instance, once: admission and delivery close, the connections
-- are revoked and what had not begun is discarded. Answers what that revoked and
-- discarded, and whether the instance was already ending, in which case nothing
-- changed.
beginEnding ∷ ICell → STM (Int, Int, Bool)
beginEnding cell = do
  state ← readTVar (icState cell)
  if isStopped state
    then pure (0, 0, True)
    else do
      writeTVar (icState cell) $
        state
          { isPhase = if isTerminal (isPhase state) then isPhase state else Stopping
          , isStopped = True
          , isConnections = Set.empty
          , isQueue = Seq.empty
          , isPending = Nothing
          , isUpdate = UpdateNone
          , isDispatchQueued = False
          }
      pure (Set.size (isConnections state), unstartedCount (icKind cell) state, False)

-- | Whether a scheduler task is an instance's invocation, which only the instance
-- layer controls.
isInstanceTask ∷ Instances → TaskId → STM Bool
isInstanceTask instances task = Set.member task <$> readTVar (insTasks instances)
