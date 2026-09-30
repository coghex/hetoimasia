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
-- no device exists yet, or when the queue already holds its capacity.
-- Admitted, an action is queued, and its ticket is the caller's only handle on
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
  , Actions
  , newActions
  , admitAction
  , actionsWaiting
  , actionsCount
  , Started (..)
  , startAction
  , refuseRemaining
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException)
import Data.Foldable (for_)
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import qualified Data.Sequence as Seq
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering (Construction)
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
    -- ^ The queue already holds its capacity. Nothing waited for room.
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

-- | One queued action, with its ticket's standing.
data Entry = ∀ r. Entry !(TVar (Standing r)) !(VulkanAction r)

-- | The session's queue of admitted actions.
data Actions = Actions
  { actionsQueue ∷ !(TVar (Seq Entry))
  , actionsCapacity ∷ !Natural
  , actionsGate ∷ STM (Maybe ActionRefusal)
    -- ^ Whether an action may be admitted or started now: 'Nothing', or the
    -- refusal — a failed session, a closed owner.
  }

-- | An empty queue holding at most this many actions, gated by this.
newActions ∷ Natural → STM (Maybe ActionRefusal) → IO Actions
newActions capacity gate = (\queue → Actions queue capacity gate) <$> newTVarIO Seq.empty

-- | Admit one action, given whether the session's device exists, or refuse it
-- at once. It never waits.
admitAction ∷ Actions → Bool → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
admitAction actions device action =
  actionsGate actions >>= \case
    Just refusal → pure (Left refusal)
    Nothing
      | not device → pure (Left ActionDeviceNotReady)
      | otherwise → do
          queue ← readTVar (actionsQueue actions)
          if fromIntegral (Seq.length queue) >= actionsCapacity actions
            then pure (Left ActionQueueFull)
            else do
              standing ← newTVar Queued
              writeTVar (actionsQueue actions) (queue |> Entry standing action)
              pure (Right (ActionTicket standing (actionsGate actions)))

-- | Whether the queue holds anything for the owner to take: a round's worth
-- of work, which is what wakes an idle owner.
actionsWaiting ∷ Actions → STM Bool
actionsWaiting actions = not . Seq.null <$> readTVar (actionsQueue actions)

-- | How many entries the queue holds now, for a step to bound the actions it
-- takes to those waiting when it began.
actionsCount ∷ Actions → STM Int
actionsCount actions = Seq.length <$> readTVar (actionsQueue actions)

-- | An action the owner has started, with what settles it.
data Started = ∀ r. Started !(VulkanAction r) !(ActionOutcome r → STM ())

-- | Take the next action the owner may start, marking it running, in one
-- transaction. An entry its reader already settled is dropped. While the gate
-- refuses, every queued one is settled as refused and dropped, and nothing is
-- started.
startAction ∷ Actions → STM (Maybe Started)
startAction actions =
  viewl <$> readTVar (actionsQueue actions) >>= \case
    EmptyL → pure Nothing
    Entry standing action :< rest → do
      writeTVar (actionsQueue actions) rest
      readTVar standing >>= \case
        Queued →
          actionsGate actions >>= \case
            Just refusal → writeTVar standing (Settled (ActionRefused refusal)) >> startAction actions
            Nothing → do
              writeTVar standing Running
              pure (Just (Started action (writeTVar standing . Settled)))
        _ → startAction actions

-- | Settle every action still queued as refused, with the gate's answer or
-- this, and empty the queue: the owner's retirement, after which nothing
-- starts.
refuseRemaining ∷ Actions → ActionRefusal → STM ()
refuseRemaining actions fallback = do
  refusal ← maybe fallback id <$> actionsGate actions
  queue ← readTVar (actionsQueue actions)
  writeTVar (actionsQueue actions) Seq.empty
  for_ queue $ \(Entry standing _) →
    readTVar standing >>= \case
      Queued → writeTVar standing (Settled (ActionRefused refusal))
      _ → pure ()
