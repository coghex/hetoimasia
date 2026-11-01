{-# LANGUAGE RankNTypes #-}

-- | Owner-thread actions (GRS-15): bounded work a consumer hands the graphics
-- owner, run on the owner's thread with the session's 'Construction', and
-- whose result the caller takes back.
--
-- This module owns the queue and every ticket's standing, and nothing native.
-- The controller ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller") admits
-- actions from any thread, runs them in the owner's step and settles what is
-- left at the owner's retirement.
--
-- = Admission, start and settlement
--
-- Admission is one transaction that never waits: it refuses at once, with the
-- reason, when the session has failed or the owner's admission has closed, when
-- no device exists yet, or when the queue already holds its capacity for the
-- admission's class: an action is counted against the action capacity alone,
-- and a release request against the release capacity alone (see below). Those
-- refusals come in that order, so a failed session, a closed owner or a missing
-- device is reported before a full queue. Admitted, an action is queued, and its ticket is the caller's only handle on
-- it; waiting for the outcome is the caller's explicit choice.
--
-- An action starts when the owner takes it, in one transaction that asks the
-- same gate admission asks: a session that failed or an owner whose exit has
-- begun refuses it there instead, and it never runs. A caller reading its
-- ticket asks that gate too, in its own transaction, and a queued action the
-- gate now refuses is settled as refused there and then. The two transactions
-- decide one standing, so each queued action either starts or is refused,
-- never both; and a worker waiting on one is answered as soon as exit or
-- failure begins, without waiting for the owner to reach it. An action that
-- has started finishes, and its outcome is its own: what it returned, or what
-- it raised.
--
-- = Release requests
--
-- A release request is an action that also waits for a 'Barrier': the scene
-- revisions the scene targets it names — windows, and the offscreen targets
-- registered with the host — must have been adopted by the owner before it
-- runs (D-28). It is admitted exactly as an action is — one transaction that
-- never waits, refused at once for a failed session, a closed owner, a missing
-- device or a full queue, and settled as refused if it is still queued when the
-- owner's exit begins — and it shares the queue, though not its capacity: the
-- release requests the queue holds are bounded by a capacity of their own, and
-- one admitted when that bound is full is refused at once with
-- 'ReleaseQueueFull'. Each capacity bounds the queued entries of its own class,
-- so release requests never cause an action to be refused ('ActionQueueFull')
-- and actions never cause a release request to be. A release request is
-- counted from its admission, whether or not its barrier is empty or already
-- met, until the owner takes it; one the owner is running no longer occupies a
-- slot, and a capacity of zero refuses its class at once. What differs is when
-- it starts: the queue is in the order requests were made, and a
-- release request starts only when its barrier is met and no earlier release
-- request is still queued, so release requests run in the order they were
-- made. An action with no barrier is never held back by one that has, and a
-- release request whose barrier is already met starts in the owner's next
-- step. A queue holding nothing but blocked release requests is not work: it
-- does not wake an idle owner.
--
-- = State
--
-- +------------------+--------------+------------------------------------+--------+--------------------------+------------------------------+
-- | State            | Owner        | Readers and writers                | Thread | Lifetime                 | Reset or disposal            |
-- +==================+==============+====================================+========+==========================+==============================+
-- | The queue        | This module  | Any thread admits; the owner takes | Any,   | The session              | Each entry is removed when   |
-- |                  |              | and removes                        | in STM |                          | the owner takes it           |
-- +------------------+--------------+------------------------------------+--------+--------------------------+------------------------------+
-- | A ticket's       | This module  | The owner starts and settles it; a | Any,   | Admission until its      | Only advances: queued,       |
-- | standing         |              | reader settles a refused one       | in STM | reader drops the ticket  | running, settled             |
-- +------------------+--------------+------------------------------------+--------+--------------------------+------------------------------+
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions
  ( -- * Actions
    VulkanAction (..)
  , ActionRefusal (..)
  , ActionOutcome (..)
  , ActionTicket
  , readActionTicket
  , awaitActionTicket

    -- * The queue
  , Barrier
  , Actions
  , newActions
  , admitAction
  , admitRelease
  , pendingBarriers
  , actionsWaiting
  , actionsCount
  , Started (..)
  , startAction
  , refuseRemaining
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException)
import Data.Foldable (for_, toList)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import qualified Data.Sequence as Seq
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering (Construction)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Target (SceneTargetKey)
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause)

-- | Bounded work for the graphics owner's thread, given the session's managed
-- 'Construction' there.
--
-- It is a cooperative, finite callback: it runs on the owner's thread between
-- the owner's other work, never beside a frame's rendering, and the owner does
-- nothing else until it returns. It must never wait for work that needs the
-- same owner — another action's outcome, a frame, a handover — which could
-- only come after it returns. It runs at most once: nothing replays it.
--
-- What it constructs through the 'Construction' is a managed resource of the
-- session, whatever becomes of the action, and is released as the renderer's
-- are; the construction refuses a call from any other thread.
newtype VulkanAction r = VulkanAction
  { runVulkanAction ∷ ∀ q inst msgr phys dev cmd. Construction q inst msgr phys dev cmd → IO r
  }

-- | Why an action was refused. A refused action never ran.
data ActionRefusal
  = ActionQueueFull
    -- ^ The queue already holds as many actions as its action capacity allows.
    -- Nothing waited for room, and release requests never count toward it.
  | ReleaseQueueFull
    -- ^ The queue already holds as many release requests as its release
    -- capacity allows. Nothing waited for room, and actions never count toward
    -- it. Only a release request is refused with this.
  | ActionDeviceNotReady
    -- ^ The session has no device yet: its owner has not started, or — with
    -- the device made at the first window's admission — no window has been
    -- admitted. Nothing was created for it.
  | ActionSessionFailed !TerminalCause
    -- ^ The session has failed, with this primary failure.
  | ActionOwnerClosed
    -- ^ The owner's admission has closed: its exit has begun, or its run has
    -- ended.
  deriving (Eq, Show)

-- | What became of an admitted action.
data ActionOutcome r
  = ActionReturned r
    -- ^ It ran on the owner's thread and returned this.
  | ActionRaised !(ExceptionWithContext SomeException)
    -- ^ It ran and raised this. What it constructed before it raised stays the
    -- session's. A failure the owner's own run must end with — a construction
    -- whose effect escaped it, a failure the session latched, a cancellation
    -- of the owner — also ends the owner's run.
  | ActionRefused !ActionRefusal
    -- ^ It was admitted and never started: the owner's exit or the session's
    -- failure began first.

-- | Where one admitted action stands. It only advances.
data Standing r
  = Queued
  | Running
  | Settled !(ActionOutcome r)

-- | One admitted action's ticket, from which its outcome is read.
data ActionTicket r = ActionTicket
  { ticketStanding ∷ !(TVar (Standing r))
  , ticketGate ∷ STM (Maybe ActionRefusal)
  }

-- | The outcome, once there is one. A queued action whose start the gate now
-- refuses — the owner's exit or the session's failure has begun — is settled
-- as refused here, in this transaction, so the owner never starts it.
readActionTicket ∷ ActionTicket r → STM (Maybe (ActionOutcome r))
readActionTicket ticket =
  readTVar (ticketStanding ticket) >>= \case
    Settled outcome → pure (Just outcome)
    Running → pure Nothing
    Queued →
      ticketGate ticket >>= \case
        Nothing → pure Nothing
        Just refusal → do
          writeTVar (ticketStanding ticket) (Settled (ActionRefused refusal))
          pure (Just (ActionRefused refusal))

-- | Wait for the outcome. The wait is the caller's: nothing about admission
-- waits.
awaitActionTicket ∷ ActionTicket r → STM (ActionOutcome r)
awaitActionTicket ticket = readActionTicket ticket >>= maybe retry pure

-- ---------------------------------------------------------------------------
-- The queue

-- | The scene revisions a release request waits for: each scene target it
-- names, a window or a registered offscreen target, must have adopted that
-- revision or a later one, unless the host no longer holds it.
type Barrier = Map SceneTargetKey Natural

-- | One queued action, with its ticket's standing and, for a release request,
-- the barrier it waits for.
data Entry = ∀ r. Entry !(TVar (Standing r)) !(VulkanAction r) !(Maybe Barrier)

-- | The session's queue of admitted actions.
data Actions = Actions
  { actionsQueue ∷ !(TVar (Seq Entry))
  , actionsCapacity ∷ !Natural
    -- ^ How many actions with no barrier the queue may hold.
  , actionsReleaseCapacity ∷ !Natural
    -- ^ How many release requests the queue may hold, whatever their barriers.
  , actionsGate ∷ STM (Maybe ActionRefusal)
    -- ^ Whether an action may be admitted or started now: 'Nothing', or the
    -- refusal — a failed session, a closed owner.
  , actionsMet ∷ Barrier → STM Bool
    -- ^ Whether a release request's barrier is met now.
  }

-- | An empty queue holding at most the first many actions and the second many
-- release requests, gated by this, whose release requests wait on barriers that
-- are met when this says so.
newActions ∷ Natural → Natural → STM (Maybe ActionRefusal) → (Barrier → STM Bool) → IO Actions
newActions capacity releaseCapacity gate met = (\queue → Actions queue capacity releaseCapacity gate met) <$> newTVarIO Seq.empty

-- | Admit one action, given whether the session's device exists, or refuse it
-- at once. It never waits.
admitAction ∷ Actions → Bool → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
admitAction actions device = admitWith actions device Nothing

-- | Admit one release request, given whether the session's device exists, as
-- 'admitAction' admits an action, against the release capacity instead of the
-- action capacity ('ReleaseQueueFull'). The barrier is read in the same transaction
-- that queues the request, after the gate and the capacity have been
-- consulted, so what it names is exactly what was published and which windows
-- were held when the request took its place in the queue.
admitRelease ∷ Actions → Bool → STM Barrier → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
admitRelease actions device barrier = admitWith actions device (Just barrier)

admitWith ∷ Actions → Bool → Maybe (STM Barrier) → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
admitWith actions device barrier action =
  actionsGate actions >>= \case
    Just refusal → pure (Left refusal)
    Nothing
      | not device → pure (Left ActionDeviceNotReady)
      | otherwise → do
          queue ← readTVar (actionsQueue actions)
          let (capacity, refusal) = case barrier of
                Nothing → (actionsCapacity actions, ActionQueueFull)
                Just _ → (actionsReleaseCapacity actions, ReleaseQueueFull)
              sameClass (Entry _ _ held) = isJust held == isJust barrier
          if fromIntegral (length (filter sameClass (toList queue))) >= capacity
            then pure (Left refusal)
            else do
              held ← traverse id barrier
              standing ← newTVar Queued
              writeTVar (actionsQueue actions) (queue |> Entry standing action held)
              pure (Right (ActionTicket standing (actionsGate actions)))

-- | The barriers of the release requests still queued, in the order they were
-- made.
pendingBarriers ∷ Actions → STM [Barrier]
pendingBarriers actions = do
  queue ← readTVar (actionsQueue actions)
  fmap concat . traverse pending $ toList queue
  where
    pending (Entry standing _ barrier) =
      readTVar standing <&> \case
        Queued → maybe [] pure barrier
        _ → []
    (<&>) = flip fmap

-- | Whether the queue holds anything the owner may take: a round's worth of
-- work, which is what wakes an idle owner. A release request whose barrier is
-- not met is not, and neither is one behind an earlier release request.
actionsWaiting ∷ Actions → STM Bool
actionsWaiting actions = (> 0) <$> actionsCount actions

-- | How many entries the queue holds that the owner may start in sequence now,
-- for a step to bound the actions it takes to those waiting when it began.
-- Entries their readers already settled are counted: the owner drops them.
actionsCount ∷ Actions → STM Int
actionsCount actions = readTVar (actionsQueue actions) >>= go 0 False . toList
  where
    go count _ [] = pure count
    go count blocked (Entry standing _ barrier : rest) =
      readTVar standing >>= \case
        Queued → case barrier of
          Nothing → go (count + 1) blocked rest
          Just wanted
            | blocked → go count blocked rest
            | otherwise →
                actionsMet actions wanted >>= \case
                  True → go (count + 1) blocked rest
                  False → go count True rest
        _ → go (count + 1) blocked rest

-- | An action the owner has started, with what settles it.
data Started = ∀ r. Started !(VulkanAction r) !(ActionOutcome r → STM ())

-- | Take the next action the owner may start, marking it running, in one
-- transaction. An entry its reader already settled is dropped. While the gate
-- refuses, every queued one is settled as refused and dropped, and nothing is
-- started. A release request is taken only when its barrier is met and no
-- earlier release request remains queued.
startAction ∷ Actions → STM (Maybe Started)
startAction actions = readTVar (actionsQueue actions) >>= scan Seq.empty False
  where
    scan kept blocked remaining = case viewl remaining of
      EmptyL → Nothing <$ writeTVar (actionsQueue actions) kept
      entry@(Entry standing action barrier) :< rest →
        readTVar standing >>= \case
          Queued →
            actionsGate actions >>= \case
              Just refusal → writeTVar standing (Settled (ActionRefused refusal)) >> scan kept blocked rest
              Nothing → case barrier of
                Nothing → start standing action kept rest
                Just wanted
                  | blocked → scan (kept |> entry) blocked rest
                  | otherwise →
                      actionsMet actions wanted >>= \case
                        True → start standing action kept rest
                        False → scan (kept |> entry) True rest
          _ → scan kept blocked rest
    start ∷ TVar (Standing r) → VulkanAction r → Seq Entry → Seq Entry → STM (Maybe Started)
    start standing action kept rest = do
      writeTVar (actionsQueue actions) (kept <> rest)
      writeTVar standing Running
      pure (Just (Started action (writeTVar standing . Settled)))

-- | Settle every action still queued as refused, with the gate's answer or
-- this, and empty the queue: the owner's retirement, after which nothing
-- starts.
refuseRemaining ∷ Actions → ActionRefusal → STM ()
refuseRemaining actions fallback = do
  refusal ← maybe fallback id <$> actionsGate actions
  queue ← readTVar (actionsQueue actions)
  writeTVar (actionsQueue actions) Seq.empty
  for_ queue $ \(Entry standing _ _) →
    readTVar standing >>= \case
      Queued → writeTVar standing (Settled (ActionRefused refusal))
      _ → pure ()
