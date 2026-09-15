{-# LANGUAGE DeriveGeneric #-}

-- | Bounded, ordered input feeds with an acknowledged reset, one per window.
--
-- A window's 'InputFeed' carries its ordered input — key transitions, Unicode
-- characters, button transitions, scroll offsets, and focus transitions — to one
-- logical consumer through a bounded foundation channel. When that channel is
-- full, or the application temporarily suspends input, the feed does not block,
-- drop silently, or fail the window: it discards the ambiguous backlog, clears
-- its held-state interpretation, and requires the consumer to acknowledge a
-- reset before a fresh input epoch can deliver anything.
--
-- = Ownership
--
-- The feed belongs to its window's owner. The owner creates it with
-- 'newInputFeed', produces into it, attempts the overflow warning, resumes it,
-- and closes it; in "Hetoimasia.Runtime.GLFW" the window host creates one per
-- window and closes it with the window. The consumer receives two opaque
-- capabilities:
--
-- * an 'InputReader', which reads or waits ('readInput', 'awaitInput'),
--   acknowledges a reset ('acknowledgeReset'), and reads 'inputStatistics';
-- * an 'InputControl', which enables and temporarily suspends the application's
--   input admission ('enableInput', 'suspendInput').
--
-- Neither exposes the channel, its endpoints, the feed's state, or a producer.
-- Each feed has one logical consumer. Copying a reader copies a reference to the
-- same feed: every copy observes the same reset and the same acknowledgement, so
-- no copy is a second, independently acknowledged consumer. Concurrent handlers
-- over one feed need the application's own coordination.
--
-- = Events and epochs
--
-- Every delivered 'InputEvent' carries its window's identity, the 'InputEpoch'
-- it was admitted in, and an 'InputPayload'. Epochs start at one, advance by one
-- for each reset, and are 'Natural', so they never wrap. Scroll offsets, key
-- transitions (with key code and scancode), and Unicode characters are distinct
-- payloads, and a key transition is not a text decoder. A button transition
-- carries the cursor position and modifiers captured when it was produced:
-- 'produceButton' copies the producer's latest cursor sample at that moment,
-- so later cursor motion does not change an event already produced. Scroll,
-- text, button and key transitions, and focus transitions are never coalesced.
--
-- The producer prepares each event to normal form in 'IO' before admission.
-- Every transaction here only reads and writes state: none evaluates a payload,
-- makes a native call, logs, or runs a handler.
--
-- = Phases and gates
--
-- The feed's 'InputPhase' is separate from the application's admission and from
-- the window's focus:
--
-- @
-- InputRunning           → InputResetPending       ordinary admission is full,
--                                                  or input is suspended
-- InputResetPending      → InputResetAcknowledged  the consumer acknowledges
-- InputResetAcknowledged → InputRunning            the owner resumes a fresh epoch
-- any                    → InputFeedClosed         the feed, window, or host closes
-- @
--
-- 'ApplicationAdmission' starts at 'AwaitingReadiness'. 'enableInput' opens it,
-- and after that 'suspendInput' closes it again, through the reset below; input
-- produced before readiness is gated, and disabling input before readiness needs
-- no reset. The focus gate is the latest focus transition the producer reported.
-- Ordinary input is admitted only while the phase is running, admission is
-- enabled, and the window is focused; otherwise it is counted as gated and
-- dropped. A focus transition is admitted while the phase is running and
-- admission is enabled whatever the focus gate says, so the focus loss that
-- closes the gate is itself delivered. While the phase is not running, a focus
-- transition still updates the gate, and is counted as suppressed.
--
-- = Held-state interpretation
--
-- The producer keeps a held-state baseline for keys in @0 .. 'keyDomainLast'@
-- and buttons in @0 .. 'buttonDomainLast'@, the bounded native domains; nothing
-- is indexed by scancode. Only an admitted press establishes held state. A
-- repeat or release of a key or button that is not held — including one outside
-- the domain, such as GLFW's unknown key — is suppressed and counted as unpaired,
-- so a release never invents a matching press and a repeat never becomes a
-- press. An admitted focus loss clears the baseline, as does every reset and
-- closure. Each epoch therefore begins with nothing held: a key still physically
-- down from before a reset produces nothing until it is pressed again.
--
-- The consumer clears its own held keys, buttons, and derived gesture state when
-- it reads a focus loss, before it acknowledges a reset, and on closure.
--
-- = The reset
--
-- On the first overflow of a running generation, one transaction aborts the
-- channel, records the backlog it discarded from the channel's depth counter
-- apart from the one overflowing event that was never admitted, reserves the next
-- epoch, clears the held-state baseline, drops the aborted channel from the
-- feed's state, and installs the reset, reason 'InputOverflowed', whose opaque
-- 'ResetToken' names this feed and the reserved epoch. The channel's own
-- statistics keep their meanings; the feed counts separately.
--
-- 'suspendInput' after readiness makes the same transition with reason
-- 'AdmissionSuspended', and a zero unadmitted count.
--
-- While the reset is pending or acknowledged, produced input is suppressed and
-- counted, in the feed's cumulative counters and the episode's. Nothing is kept
-- per event. Production allocates no channel, advances no epoch, replaces no
-- token, and owes no further warning. 'enableInput' and 'suspendInput' change
-- only the application gate: they neither replace the token nor advance the
-- epoch, and never erase the overflow warning an episode owes.
--
-- The consumer's next read or wait answers 'InputResetRequired' before anything
-- else, and keeps answering it until the token is acknowledged; reading it
-- consumes and acknowledges nothing, so a consumer that stalls or is cancelled
-- before acknowledging leaves the feed paused and closable. Events dequeued
-- before the reset's transaction are already in flight: the consumer finishes or
-- abandons their handlers and clears its derived state before acknowledging. The
-- feed undoes no effect an event already had, and replays nothing.
--
-- 'acknowledgeReset' is a non-retrying transaction, independent of any command
-- capacity, that allocates nothing and runs nothing. In order:
--
-- 1. a token another feed issued is 'ForeignResetToken' misuse;
-- 2. a closed feed answers 'AcknowledgementClosed', even for the pending token;
-- 3. a token for an older reset answers 'StaleAcknowledgement';
-- 4. the pending token answers 'Acknowledged' and moves the phase to
--    'InputResetAcknowledged';
-- 5. the token of a reset already acknowledged or resumed answers
--    'AlreadyAcknowledged' and changes nothing.
--
-- After acknowledgement, reads answer 'InputPaused' and waits keep waiting until
-- the owner resumes; neither demands the same reset again. There is no timeout
-- that resumes on its own.
--
-- = The overflow warning
--
-- An overflow episode owes one structured 'Hetoimasia.Foundation.Log.Warning'.
-- 'attemptOverflowWarning' claims it at a safe owner boundary — outside
-- callbacks, transactions, and release — and writes it once through the
-- injected logger under the @glfw.input@ component. The obligation lives in the
-- episode, beside the queue rather than in it, so neither an early
-- acknowledgement nor further production loses it. A sink failure propagates to
-- the caller, as every logging failure does, and a cancellation propagates as
-- itself; either is recorded in the episode as 'WarningFailed' or
-- 'WarningInterrupted', and the sink is never tried again. A closed feed claims
-- nothing, so an obligation shutdown prevented stays 'WarningOwed'. An attempt
-- already in progress when the feed closes still records how it ended. A
-- suspension owes no warning.
--
-- = Resumption
--
-- 'resumeInput' allocates one fresh channel in 'IO', then installs it in one
-- transaction only if the same reset is still acknowledged, no warning is owed
-- or being attempted, the feed has not closed, admission is enabled, and the
-- window is focused. The window and host close the feed as they end, so an open
-- feed is a live one. That transaction marks the reserved epoch running. If any
-- condition fails the candidate is never published, and a closure committed at
-- any point before the install wins.
--
-- = Closure
--
-- 'closeInputFeed' is idempotent, finite, and never retries, so a quiescence
-- action or release may use it. It aborts any running channel, counting what it
-- discarded apart from reset discards, clears the held-state baseline, and makes
-- every later read and wait answer 'InputClosed' immediately — without first
-- delivering a pending reset, and without waiting for any acknowledgement. The
-- phase, epoch, counters, and last reset are frozen from then on, apart from an
-- in-progress warning attempt recording its end.
--
-- = State
--
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | State              | Owner       | Readers and writers                  | Thread             | Lifetime          | Reset or disposal             |
-- +====================+=============+======================================+====================+===================+===============================+
-- | Current channel    | The feed    | Production sends; reads receive;     | Produce, reset,    | One generation    | Aborted and dropped by a reset|
-- |                    |             | a reset or closure aborts and drops  | resume, close:     |                   | or closure; replaced only by  |
-- |                    |             | it; resumption installs a new one    | owner; read: any   |                   | resumption                    |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | Phase, epoch, and  | The feed    | Production, suspension, reset,       | Owner and consumer | The feed          | Frozen at closure             |
-- | episode            |             | acknowledgement, warning, resumption,| through the        |                   |                               |
-- |                    |             | and closure write; everyone reads    | capabilities       |                   |                               |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | Application        | The feed    | 'enableInput' and 'suspendInput'     | Any holder of the  | The feed          | Starts awaiting readiness;    |
-- | admission          |             | write; production and resumption     | control            |                   | frozen at closure             |
-- |                    |             | read                                 |                    |                   |                               |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | Focus gate and     | The feed    | Production writes; resumption reads; | Owner              | The feed          | Baseline cleared by focus     |
-- | held baseline      |             | reset and closure clear the baseline |                    |                   | loss, reset, and closure      |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | Latest cursor      | The feed    | 'recordCursor' writes;               | Owner              | The feed          | Replaced by the next sample   |
-- | sample             |             | 'produceButton' copies it            |                    |                   |                               |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
-- | Counters           | The feed    | Every transition adds; statistics    | Any                | The feed          | Cumulative; never reset, never|
-- |                    |             | read                                 |                    |                   | wrap                          |
-- +--------------------+-------------+--------------------------------------+--------------------+-------------------+-------------------------------+
--
-- Everything is bounded: one channel of the configured capacity, one episode —
-- the latest, kept as the last-reset summary — held sets bounded by the native
-- domains, and a fixed set of counters. No history of events, epochs, or
-- channels is kept.
module Hetoimasia.GLFW.Internal.Input
  ( -- * Events
    InputEvent
  , inputWindow
  , inputEpoch
  , inputPayload
  , InputEpoch
  , epochNumber
  , InputPayload (..)
  , KeyEvent (..)
  , KeyAction (..)
  , ButtonEvent (..)
  , ButtonAction (..)
  , ScrollEvent (..)
  , CursorPosition (..)
  , Modifiers (..)
  , noModifiers
  , keyDomainLast
  , buttonDomainLast

    -- * Reading
  , InputReader
  , inputReaderWindow
  , InputRead (..)
  , readInput
  , awaitInput

    -- * Resets
  , ResetToken
  , resetWindow
  , resetEpoch
  , resetReason
  , ResetReason (..)
  , Acknowledgement (..)
  , InputMisuse (..)
  , acknowledgeReset

    -- * Application admission
  , InputControl
  , inputControlWindow
  , ApplicationAdmission (..)
  , AdmissionChange (..)
  , enableInput
  , suspendInput

    -- * Statistics
  , InputStatistics (..)
  , InputPhase (..)
  , ResetSummary (..)
  , WarningState (..)
  , inputStatistics

    -- * Owner operations
  , InputFeed
  , newInputFeed
  , feedReader
  , feedControl
  , feedStatistics
  , Production (..)
  , produceInput
  , recordCursor
  , produceButton
  , resetFromStagingOverflow
  , WarningAttempt (..)
  , attemptOverflowWarning
  , Resumption (..)
  , resumeInput
  , resumeInputWith
  , closeInputFeed
  , inputComponent
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , rethrowIO
  , tryWithContext
  )
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Unique (Unique, newUnique)
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Log (Component, Logger, logWarning, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel
  ( ChannelControl
  , Receipt (..)
  , SendResult (..)
  , abortChannel
  , channelReceiver
  , channelSender
  , channelStatistics
  , newChannel
  , receive
  , send
  , statisticsDepth
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import Hetoimasia.GLFW.Internal.Attribute (CursorPosition (..))
import {-# SOURCE #-} Hetoimasia.GLFW.Internal.Window (WindowId, windowLocalIdentity)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Events

-- | An input epoch: one for a feed's first generation, and one more for each
-- reset. It never wraps.
newtype InputEpoch = InputEpoch Natural
  deriving (Eq, Ord, Show)

instance NFData InputEpoch where
  rnf (InputEpoch number) = rnf number

epochNumber ∷ InputEpoch → Natural
epochNumber (InputEpoch number) = number

-- | Which modifier keys were held for an event.
data Modifiers = Modifiers
  { modifierShift ∷ !Bool
  , modifierControl ∷ !Bool
  , modifierAlt ∷ !Bool
  , modifierSuper ∷ !Bool
  , modifierCapsLock ∷ !Bool
  , modifierNumLock ∷ !Bool
  }
  deriving (Eq, Show, Generic)

instance NFData Modifiers

noModifiers ∷ Modifiers
noModifiers = Modifiers False False False False False False

data KeyAction = KeyPressed | KeyRepeated | KeyReleased
  deriving (Eq, Show, Generic)

instance NFData KeyAction

-- | A physical key transition. The key code is GLFW's layout-independent key,
-- with @-1@ for a key it does not name; the scancode is the platform's, kept for
-- the application to interpret.
data KeyEvent = KeyEvent
  { keyCode ∷ !Int
  , keyScancode ∷ !Int
  , keyAction ∷ !KeyAction
  , keyModifiers ∷ !Modifiers
  }
  deriving (Eq, Show, Generic)

instance NFData KeyEvent

data ButtonAction = ButtonPressed | ButtonReleased
  deriving (Eq, Show, Generic)

instance NFData ButtonAction

-- | A mouse button transition, with the cursor position and modifiers captured
-- for this event. The position is 'Nothing' when the producer had no cursor
-- sample yet.
data ButtonEvent = ButtonEvent
  { buttonNumber ∷ !Int
  , buttonAction ∷ !ButtonAction
  , buttonCursor ∷ !(Maybe CursorPosition)
  , buttonModifiers ∷ !Modifiers
  }
  deriving (Eq, Show, Generic)

instance NFData ButtonEvent

-- | Scroll offsets on both axes.
data ScrollEvent = ScrollEvent
  { scrollX ∷ !Double
  , scrollY ∷ !Double
  }
  deriving (Eq, Show, Generic)

instance NFData ScrollEvent

-- | What one input event reports. Each kind is distinct.
data InputPayload
  = KeyInput !KeyEvent
  | TextInput !Char
    -- ^ One Unicode character.
  | ButtonInput !ButtonEvent
  | ScrollInput !ScrollEvent
  | FocusInput !Bool
    -- ^ The window gained ('True') or lost ('False') input focus.
  deriving (Eq, Show, Generic)

instance NFData InputPayload

-- | The last key code in the held-state domain: @GLFW_KEY_LAST@.
keyDomainLast ∷ Int
keyDomainLast = 348

-- | The last button number in the held-state domain: @GLFW_MOUSE_BUTTON_LAST@.
buttonDomainLast ∷ Int
buttonDomainLast = 7

-- | One delivered input event. Its representation is private.
data InputEvent = InputEvent !WindowId !InputEpoch !InputPayload
  deriving (Eq, Show)

instance NFData InputEvent where
  rnf (InputEvent window epoch payload) = rnf window `seq` rnf epoch `seq` rnf payload

inputWindow ∷ InputEvent → WindowId
inputWindow (InputEvent window _ _) = window

inputEpoch ∷ InputEvent → InputEpoch
inputEpoch (InputEvent _ epoch _) = epoch

inputPayload ∷ InputEvent → InputPayload
inputPayload (InputEvent _ _ payload) = payload

-- ---------------------------------------------------------------------------
-- Resets

-- | Why a reset began.
data ResetReason
  = InputOverflowed
    -- ^ Ordered admission was full.
  | AdmissionSuspended
    -- ^ The application suspended input after enabling it.
  deriving (Eq, Show)

-- | The opaque token of one reset: the feed that issued it and the epoch it
-- reserved. It has no constructor, field, or coercion outside this package.
data ResetToken = ResetToken !Unique !WindowId !Natural !ResetReason
  deriving (Eq)

instance Show ResetToken where
  showsPrec precedence (ResetToken _ window epoch reason) =
    showParen (precedence > 10) $
      showString "ResetToken "
        . showsPrec 11 window
        . showString " "
        . showsPrec 11 (InputEpoch epoch)
        . showString " "
        . showsPrec 11 reason

-- | The window whose feed issued the token.
resetWindow ∷ ResetToken → WindowId
resetWindow (ResetToken _ window _ _) = window

-- | The epoch the reset reserved: the epoch input resumes in.
resetEpoch ∷ ResetToken → InputEpoch
resetEpoch (ResetToken _ _ epoch _) = InputEpoch epoch

resetReason ∷ ResetToken → ResetReason
resetReason (ResetToken _ _ _ reason) = reason

-- | How an acknowledgement was answered.
data Acknowledgement
  = Acknowledged
    -- ^ The pending reset is now acknowledged.
  | AlreadyAcknowledged
    -- ^ This reset was already acknowledged, or has resumed. Nothing changed.
  | StaleAcknowledgement
    -- ^ A newer reset has begun since this token. Nothing changed.
  | AcknowledgementClosed
    -- ^ The feed has closed. Nothing changed.
  deriving (Eq, Show)

-- | Misuse of an input capability.
data InputMisuse
  = ForeignResetToken
      { misuseTokenWindow ∷ !WindowId
      , misuseFeedWindow ∷ !WindowId
      }
    -- ^ The token was issued by another feed.
  deriving (Eq, Show)

instance Exception InputMisuse

-- ---------------------------------------------------------------------------
-- Feeds

-- | A window's input feed: the owner's handle. Its representation is private.
data InputFeed = InputFeed
  { feedKey ∷ !Unique
  , feedWindow ∷ !WindowId
  , feedCapacity ∷ !Integer
  , feedState ∷ !(TVar FeedState)
  , feedCursor ∷ !(IORef (Maybe CursorPosition))
  }

-- | The consumer's read and acknowledgement capability.
newtype InputReader = InputReader InputFeed

-- | The application's admission capability.
newtype InputControl = InputControl InputFeed

data FeedState = FeedState
  { statePhase ∷ !InputPhase
  , stateEpoch ∷ !Natural
    -- ^ The epoch of the running generation, or of the last one that ran.
  , stateChannel ∷ !(Maybe (ChannelControl InputEvent))
  , stateAdmission ∷ !ApplicationAdmission
  , stateFocused ∷ !Bool
  , stateHeldKeys ∷ !IntSet
  , stateHeldButtons ∷ !IntSet
  , stateEpisode ∷ !(Maybe ResetSummary)
    -- ^ The latest reset.
  , stateCounters ∷ !Counters
  }

data Counters = Counters
  { countAdmitted ∷ !Natural
  , countDelivered ∷ !Natural
  , countGated ∷ !Natural
  , countUnpaired ∷ !Natural
  , countSuppressed ∷ !Natural
  , countOverflowed ∷ !Natural
  , countDiscardedByReset ∷ !Natural
  , countDiscardedAtClose ∷ !Natural
  , countResets ∷ !Natural
  , countGenerations ∷ !Natural
  }

-- | Where a feed is.
data InputPhase
  = InputRunning
  | InputResetPending
  | InputResetAcknowledged
  | InputFeedClosed
  deriving (Eq, Show)

-- | The application's input admission.
data ApplicationAdmission
  = AwaitingReadiness
    -- ^ Not yet enabled.
  | InputEnabled
  | InputSuspended
    -- ^ Enabled earlier, and suspended since.
  deriving (Eq, Show)

-- | What happened to an episode's overflow warning.
data WarningState
  = NoWarningOwed
    -- ^ The reset was a suspension.
  | WarningOwed
  | WarningAttempting
  | WarningWritten
  | WarningFailed
    -- ^ The sink failed; it is not tried again.
  | WarningInterrupted
    -- ^ The attempt was cancelled; it is not tried again.
  deriving (Eq, Show)

-- | The latest reset.
data ResetSummary = ResetSummary
  { summaryEpoch ∷ !InputEpoch
    -- ^ The epoch it reserved.
  , summaryReason ∷ !ResetReason
  , summaryDiscarded ∷ !Natural
    -- ^ Accepted events the abort discarded.
  , summaryUnadmitted ∷ !Natural
    -- ^ The overflowing event that was never admitted: one for an overflow,
    -- zero for a suspension.
  , summarySuppressed ∷ !Natural
    -- ^ Events produced while this reset was pending or acknowledged.
  , summaryWarning ∷ !WarningState
  }
  deriving (Eq, Show)

-- | One coherent observation of a feed. The counts are cumulative over the
-- feed's life and never wrap.
data InputStatistics = InputStatistics
  { statisticsFeedWindow ∷ !WindowId
  , statisticsPhase ∷ !InputPhase
  , statisticsEpoch ∷ !InputEpoch
    -- ^ The epoch of the running generation, or of the last one that ran.
  , statisticsAdmission ∷ !ApplicationAdmission
  , statisticsFocused ∷ !Bool
  , statisticsCapacity ∷ !Natural
  , statisticsQueued ∷ !Natural
    -- ^ Events waiting in the current channel; zero without one.
  , statisticsHeld ∷ !Natural
    -- ^ Keys and buttons in the producer's held-state baseline.
  , statisticsAdmitted ∷ !Natural
  , statisticsDelivered ∷ !Natural
  , statisticsGated ∷ !Natural
    -- ^ Dropped by the application or focus gate while running.
  , statisticsUnpaired ∷ !Natural
    -- ^ Repeats and releases with no held press.
  , statisticsSuppressed ∷ !Natural
    -- ^ Produced while a reset was pending or acknowledged.
  , statisticsOverflowed ∷ !Natural
    -- ^ Overflowing events that were never admitted.
  , statisticsDiscardedByReset ∷ !Natural
  , statisticsDiscardedAtClose ∷ !Natural
  , statisticsResets ∷ !Natural
  , statisticsGenerations ∷ !Natural
    -- ^ Channels installed: the first, and one per resumption.
  , statisticsLastReset ∷ !(Maybe ResetSummary)
  }
  deriving (Eq, Show)

-- | The component the overflow warning is written under.
inputComponent ∷ Component
inputComponent = unsafeComponent "glfw.input"

-- | Create a running feed for a window: epoch one, admission awaiting
-- readiness, and the given focus. A capacity 'Hetoimasia.Foundation.Messaging.Channel.newChannel'
-- refuses raises its failure, and nothing is created.
newInputFeed ∷ HasCallStack ⇒ WindowId → Integer → Bool → IO InputFeed
newInputFeed window capacity focused = do
  channel ← newChannel capacity
  key ← newUnique
  state ←
    newTVarIO
      FeedState
        { statePhase = InputRunning
        , stateEpoch = 1
        , stateChannel = Just channel
        , stateAdmission = AwaitingReadiness
        , stateFocused = focused
        , stateHeldKeys = IntSet.empty
        , stateHeldButtons = IntSet.empty
        , stateEpisode = Nothing
        , stateCounters = Counters 0 0 0 0 0 0 0 0 0 1
        }
  InputFeed key window capacity state <$> newIORef Nothing

feedReader ∷ InputFeed → InputReader
feedReader = InputReader

feedControl ∷ InputFeed → InputControl
feedControl = InputControl

inputReaderWindow ∷ InputReader → WindowId
inputReaderWindow (InputReader feed) = feedWindow feed

inputControlWindow ∷ InputControl → WindowId
inputControlWindow (InputControl feed) = feedWindow feed

modifyCounters ∷ (Counters → Counters) → FeedState → FeedState
modifyCounters change state = state {stateCounters = change (stateCounters state)}

tokenOf ∷ InputFeed → ResetSummary → ResetToken
tokenOf feed summary =
  ResetToken (feedKey feed) (feedWindow feed) (epochNumber (summaryEpoch summary)) (summaryReason summary)

-- ---------------------------------------------------------------------------
-- Reading

-- | What a read found.
data InputRead
  = InputDelivered !InputEvent
  | InputResetRequired !ResetToken
    -- ^ A reset is pending. It stays pending until acknowledged.
  | InputPaused
    -- ^ The reset was acknowledged; the owner has not resumed yet.
  | InputEmpty
    -- ^ Running, with nothing queued.
  | InputClosed
  deriving (Eq, Show)

-- | Read without waiting.
readInput ∷ InputReader → STM InputRead
readInput (InputReader feed) = do
  state ← readTVar (feedState feed)
  case statePhase state of
    InputFeedClosed → pure InputClosed
    InputResetAcknowledged → pure InputPaused
    InputResetPending → pure (maybe InputPaused (InputResetRequired . tokenOf feed) (stateEpisode state))
    InputRunning → case stateChannel state of
      Nothing → pure InputEmpty
      Just channel →
        receive (channelReceiver channel) >>= \case
          Received payload → do
            writeTVar (feedState feed) (modifyCounters (\counts → counts {countDelivered = countDelivered counts + 1}) state)
            pure (InputDelivered (preparedValue payload))
          Empty → pure InputEmpty
          -- A running generation's channel is only aborted by the transaction
          -- that also leaves the running phase.
          Terminated _ → pure InputEmpty

-- | Read, waiting while the feed is running with nothing queued or paused after
-- an acknowledgement. Returns a delivered event, a pending reset, or closure.
awaitInput ∷ InputReader → STM InputRead
awaitInput reader =
  readInput reader >>= \case
    InputEmpty → retry
    InputPaused → retry
    found → pure found

-- | Acknowledge a reset, under the module's acknowledgement rules. Never
-- retries.
acknowledgeReset ∷ InputReader → ResetToken → STM (Either InputMisuse Acknowledgement)
acknowledgeReset (InputReader feed) token@(ResetToken key window epoch _)
  | key /= feedKey feed = pure (Left (ForeignResetToken window (feedWindow feed)))
  | otherwise = do
      state ← readTVar (feedState feed)
      Right <$> case (statePhase state, stateEpisode state) of
        (InputFeedClosed, _) → pure AcknowledgementClosed
        (_, Nothing) → pure StaleAcknowledgement
        (phase, Just summary)
          | epoch /= epochNumber (summaryEpoch summary) → pure StaleAcknowledgement
          | tokenOf feed summary /= token → pure StaleAcknowledgement
          | phase == InputResetPending → do
              writeTVar (feedState feed) state {statePhase = InputResetAcknowledged}
              pure Acknowledged
          | otherwise → pure AlreadyAcknowledged

-- ---------------------------------------------------------------------------
-- Application admission

-- | What an admission change did.
data AdmissionChange
  = AdmissionOpened
    -- ^ The application gate is now enabled. During a reset this opens only
    -- the gate: acknowledgement, resumption, and focus still apply.
  | AdmissionReset !ResetToken
    -- ^ Suspension began a reset.
  | AdmissionClosedDuringReset
    -- ^ The gate is now suspended; the existing reset is unchanged.
  | AdmissionUnchanged
  | AdmissionFeedClosed
  deriving (Eq, Show)

-- | Enable the application's input admission. Never retries.
enableInput ∷ InputControl → STM AdmissionChange
enableInput (InputControl feed) = do
  state ← readTVar (feedState feed)
  case (statePhase state, stateAdmission state) of
    (InputFeedClosed, _) → pure AdmissionFeedClosed
    (_, InputEnabled) → pure AdmissionUnchanged
    _ → do
      writeTVar (feedState feed) state {stateAdmission = InputEnabled}
      pure AdmissionOpened

-- | Suspend the application's input admission after it was enabled, beginning a
-- reset if input was running. Before readiness this changes nothing. Never
-- retries.
suspendInput ∷ InputControl → STM AdmissionChange
suspendInput (InputControl feed) = do
  state ← readTVar (feedState feed)
  case (statePhase state, stateAdmission state) of
    (InputFeedClosed, _) → pure AdmissionFeedClosed
    (_, AwaitingReadiness) → pure AdmissionUnchanged
    (_, InputSuspended) → pure AdmissionUnchanged
    (InputRunning, InputEnabled) → do
      summary ← beginReset feed AdmissionSuspended 0 state {stateAdmission = InputSuspended}
      pure (AdmissionReset (tokenOf feed summary))
    (_, InputEnabled) → do
      writeTVar (feedState feed) state {stateAdmission = InputSuspended}
      pure AdmissionClosedDuringReset

-- | The reset transition from a running state: abort and drop the channel,
-- reserve the next epoch, clear the held baseline, and install the episode.
beginReset ∷ InputFeed → ResetReason → Natural → FeedState → STM ResetSummary
beginReset feed reason unadmitted state = do
  discarded ← maybe (pure 0) abortChannel (stateChannel state)
  let summary =
        ResetSummary
          { summaryEpoch = InputEpoch (stateEpoch state + 1)
          , summaryReason = reason
          , summaryDiscarded = discarded
          , summaryUnadmitted = unadmitted
          , summarySuppressed = 0
          , summaryWarning = case reason of
              InputOverflowed → WarningOwed
              AdmissionSuspended → NoWarningOwed
          }
  writeTVar (feedState feed) $
    modifyCounters
      ( \counts →
          counts
            { countDiscardedByReset = countDiscardedByReset counts + discarded
            , countOverflowed = countOverflowed counts + unadmitted
            , countResets = countResets counts + 1
            }
      )
      state
        { statePhase = InputResetPending
        , stateChannel = Nothing
        , stateHeldKeys = IntSet.empty
        , stateHeldButtons = IntSet.empty
        , stateEpisode = Just summary
        }
  pure summary

-- ---------------------------------------------------------------------------
-- Statistics

inputStatistics ∷ InputReader → STM InputStatistics
inputStatistics (InputReader feed) = feedStatistics feed

feedStatistics ∷ InputFeed → STM InputStatistics
feedStatistics feed = do
  state ← readTVar (feedState feed)
  queued ← maybe (pure 0) (fmap statisticsDepth . channelStatistics) (stateChannel state)
  let counts = stateCounters state
  pure
    InputStatistics
      { statisticsFeedWindow = feedWindow feed
      , statisticsPhase = statePhase state
      , statisticsEpoch = InputEpoch (stateEpoch state)
      , statisticsAdmission = stateAdmission state
      , statisticsFocused = stateFocused state
      , statisticsCapacity = fromInteger (feedCapacity feed)
      , statisticsQueued = queued
      , statisticsHeld = fromIntegral (IntSet.size (stateHeldKeys state) + IntSet.size (stateHeldButtons state))
      , statisticsAdmitted = countAdmitted counts
      , statisticsDelivered = countDelivered counts
      , statisticsGated = countGated counts
      , statisticsUnpaired = countUnpaired counts
      , statisticsSuppressed = countSuppressed counts
      , statisticsOverflowed = countOverflowed counts
      , statisticsDiscardedByReset = countDiscardedByReset counts
      , statisticsDiscardedAtClose = countDiscardedAtClose counts
      , statisticsResets = countResets counts
      , statisticsGenerations = countGenerations counts
      , statisticsLastReset = stateEpisode state
      }

-- ---------------------------------------------------------------------------
-- Production

-- | What producing one event did.
data Production
  = ProductionAdmitted
  | ProductionGated
    -- ^ Dropped by the application or focus gate while running.
  | ProductionUnpaired
    -- ^ A repeat or release with no held press.
  | ProductionSuppressed
    -- ^ A reset is pending or acknowledged.
  | ProductionOverflowed !ResetToken
    -- ^ The channel was full, and this event began a reset.
  | ProductionClosed
  deriving (Eq, Show)

-- | Produce one event, on the owner. The event is tagged with the running epoch
-- and prepared in 'IO'; if the epoch changes before admission commits, it is
-- prepared again for the newer state.
produceInput ∷ InputFeed → InputPayload → IO Production
produceInput feed payload = do
  epoch ← stateEpoch <$> readTVarIO (feedState feed)
  prepared ← prepare (InputEvent (feedWindow feed) (InputEpoch epoch) payload)
  atomically (admitInput feed epoch payload prepared) >>= maybe (produceInput feed payload) pure

-- | Record the producer's latest cursor sample. Samples coalesce: only the latest
-- is kept, and none is an event.
recordCursor ∷ InputFeed → CursorPosition → IO ()
recordCursor feed = atomicWriteIORef (feedCursor feed) . Just

-- | Produce a button transition carrying the latest cursor sample and the given
-- modifiers, copied now.
produceButton ∷ InputFeed → Int → ButtonAction → Modifiers → IO Production
produceButton feed button action modifiers = do
  position ← readIORef (feedCursor feed)
  produceInput feed (ButtonInput (ButtonEvent button action position modifiers))

-- | Begin the overflow reset because native staging overflowed, without
-- presenting an event to the channel. The protocol is the same as a full send:
-- the running backlog is discarded, held state is cleared, and the consumer
-- sees one 'InputOverflowed' token. Already resetting or closed feeds do not
-- begin another episode.
resetFromStagingOverflow ∷ InputFeed → IO Production
resetFromStagingOverflow feed = atomically $ do
  state ← readTVar (feedState feed)
  case statePhase state of
    InputFeedClosed → pure ProductionClosed
    InputRunning → ProductionOverflowed . tokenOf feed <$> beginReset feed InputOverflowed 1 state
    _ → do
      writeTVar (feedState feed) $
        modifyCounters (\counts → counts {countSuppressed = countSuppressed counts + 1}) $
          state {stateEpisode = (\summary → summary {summarySuppressed = summarySuppressed summary + 1}) <$> stateEpisode state}
      pure ProductionSuppressed

-- | The admission transaction. 'Nothing' when the running epoch is no longer the
-- one the event was prepared for.
admitInput ∷ InputFeed → Natural → InputPayload → Prepared InputEvent → STM (Maybe Production)
admitInput feed epoch payload prepared = do
  state ← readTVar (feedState feed)
  case statePhase state of
    InputFeedClosed → pure (Just ProductionClosed)
    InputRunning
      | stateEpoch state /= epoch → pure Nothing
      | otherwise → Just <$> running (focusChanged state)
    _ → do
      let suppressed = focusChanged state
      writeTVar (feedState feed) $
        modifyCounters (\counts → counts {countSuppressed = countSuppressed counts + 1}) $
          suppressed {stateEpisode = (\summary → summary {summarySuppressed = summarySuppressed summary + 1}) <$> stateEpisode suppressed}
      pure (Just ProductionSuppressed)
  where
    -- A focus transition updates the gate, and a loss clears the baseline,
    -- whatever else happens to the event.
    focusChanged state = case payload of
      FocusInput focused
        | focused → state {stateFocused = True}
        | otherwise → state {stateFocused = False, stateHeldKeys = IntSet.empty, stateHeldButtons = IntSet.empty}
      _ → state

    running state
      | stateAdmission state /= InputEnabled = gated state
      | otherwise = case payload of
          FocusInput _ → sendWith state
          _ | not (stateFocused state) → gated state
          KeyInput key → case keyAction key of
            KeyPressed → sendWith (holdKey (keyCode key) state)
            _ | not (inKeyDomain (keyCode key)) || not (IntSet.member (keyCode key) (stateHeldKeys state)) → unpaired state
            KeyRepeated → sendWith state
            KeyReleased → sendWith state {stateHeldKeys = IntSet.delete (keyCode key) (stateHeldKeys state)}
          ButtonInput button → case buttonAction button of
            ButtonPressed → sendWith (holdButton (buttonNumber button) state)
            ButtonReleased
              | inButtonDomain (buttonNumber button) && IntSet.member (buttonNumber button) (stateHeldButtons state) →
                  sendWith state {stateHeldButtons = IntSet.delete (buttonNumber button) (stateHeldButtons state)}
              | otherwise → unpaired state
          TextInput _ → sendWith state
          ScrollInput _ → sendWith state

    gated state = do
      writeTVar (feedState feed) (modifyCounters (\counts → counts {countGated = countGated counts + 1}) state)
      pure ProductionGated

    unpaired state = do
      writeTVar (feedState feed) (modifyCounters (\counts → counts {countUnpaired = countUnpaired counts + 1}) state)
      pure ProductionUnpaired

    -- Send, committing the updated held baseline only if the event is admitted.
    sendWith updated = case stateChannel updated of
      Nothing → pure ProductionClosed
      Just channel →
        send (channelSender channel) prepared >>= \case
          Accepted → do
            writeTVar (feedState feed) (modifyCounters (\counts → counts {countAdmitted = countAdmitted counts + 1}) updated)
            pure ProductionAdmitted
          Full → ProductionOverflowed . tokenOf feed <$> beginReset feed InputOverflowed 1 updated
          Closed → pure ProductionClosed

    holdKey code state
      | inKeyDomain code = state {stateHeldKeys = IntSet.insert code (stateHeldKeys state)}
      | otherwise = state
    holdButton number state
      | inButtonDomain number = state {stateHeldButtons = IntSet.insert number (stateHeldButtons state)}
      | otherwise = state
    inKeyDomain code = code >= 0 && code <= keyDomainLast
    inButtonDomain number = number >= 0 && number <= buttonDomainLast

-- ---------------------------------------------------------------------------
-- The overflow warning

-- | What a warning attempt did.
data WarningAttempt
  = NoWarningDue
    -- ^ No warning was owed, or the feed has closed.
  | WarningLogged
  deriving (Eq, Show)

-- | Claim and write the latest episode's overflow warning, if one is owed and the
-- feed is open, at an owner boundary outside callbacks, transactions, and
-- release. A sink failure or cancellation is recorded and propagates as itself.
attemptOverflowWarning ∷ HasCallStack ⇒ Logger → InputFeed → IO WarningAttempt
attemptOverflowWarning logger feed = mask $ \restore →
  atomically claim >>= \case
    Nothing → pure NoWarningDue
    Just summary →
      tryWithContext (restore (logWarning logger inputComponent "Input overflowed; the feed was reset" (fields summary))) >>= \case
        Right () → WarningLogged <$ atomically (settle summary WarningWritten)
        Left caught@(ExceptionWithContext _ failure) → do
          let outcome
                | isJust (fromException failure ∷ Maybe SomeAsyncException) = WarningInterrupted
                | otherwise = WarningFailed
          atomically (settle summary outcome)
          rethrowIO (caught ∷ ExceptionWithContext SomeException)
  where
    claim = do
      state ← readTVar (feedState feed)
      case stateEpisode state of
        Just summary
          | statePhase state /= InputFeedClosed
          , summaryWarning summary == WarningOwed → do
              writeTVar (feedState feed) state {stateEpisode = Just summary {summaryWarning = WarningAttempting}}
              pure (Just summary)
        _ → pure Nothing

    settle claimed outcome = do
      state ← readTVar (feedState feed)
      case stateEpisode state of
        Just summary
          | summaryEpoch summary == summaryEpoch claimed →
              writeTVar (feedState feed) state {stateEpisode = Just summary {summaryWarning = outcome}}
        _ → pure ()

    fields summary =
      [ ("window", Text.pack (show (windowLocalIdentity (feedWindow feed))))
      , ("epoch", shown (epochNumber (summaryEpoch summary)))
      , ("discarded", shown (summaryDiscarded summary))
      , ("unadmitted", shown (summaryUnadmitted summary))
      ]

    shown ∷ Natural → Text
    shown = Text.pack . show

-- ---------------------------------------------------------------------------
-- Resumption

-- | What a resumption attempt did.
data Resumption
  = Resumed !InputEpoch
  | ResumeNotNeeded
    -- ^ The feed is running.
  | ResumeAwaitingAcknowledgement
  | ResumeAwaitingWarning
    -- ^ The episode's overflow warning is owed or being attempted.
  | ResumeAdmissionClosed
  | ResumeUnfocused
  | ResumeClosed
  deriving (Eq, Show)

-- | Resume an acknowledged feed into its reserved epoch, under the module's
-- resumption rules.
resumeInput ∷ HasCallStack ⇒ InputFeed → IO Resumption
resumeInput = resumeInputWith (pure ())

-- | 'resumeInput', running @interruption@ after the candidate channel is
-- allocated and before the transaction that would install it. Production passes
-- @pure ()@; the examples use it to race closure against the install.
resumeInputWith ∷ HasCallStack ⇒ IO () → InputFeed → IO Resumption
resumeInputWith interruption feed =
  readiness <$> readTVarIO (feedState feed) >>= \case
    Left refused → pure refused
    Right epoch → do
      candidate ← newChannel (feedCapacity feed)
      interruption
      atomically $ do
        state ← readTVar (feedState feed)
        case readiness state of
          Right current
            | current == epoch → do
                writeTVar (feedState feed) $
                  modifyCounters
                    (\counts → counts {countGenerations = countGenerations counts + 1})
                    state {statePhase = InputRunning, stateEpoch = current, stateChannel = Just candidate}
                pure (Resumed (InputEpoch current))
            -- Another reset cannot begin without a resumption between, so this
            -- is only defensive: leave the candidate unpublished.
            | otherwise → pure ResumeAwaitingAcknowledgement
          Left refused → pure refused
  where
    readiness state = case (statePhase state, stateEpisode state) of
      (InputFeedClosed, _) → Left ResumeClosed
      (InputRunning, _) → Left ResumeNotNeeded
      (InputResetPending, _) → Left ResumeAwaitingAcknowledgement
      (InputResetAcknowledged, Nothing) → Left ResumeAwaitingAcknowledgement
      (InputResetAcknowledged, Just summary)
        | summaryWarning summary `elem` [WarningOwed, WarningAttempting] → Left ResumeAwaitingWarning
        | stateAdmission state /= InputEnabled → Left ResumeAdmissionClosed
        | not (stateFocused state) → Left ResumeUnfocused
        | otherwise → Right (epochNumber (summaryEpoch summary))

-- ---------------------------------------------------------------------------
-- Closure

-- | Close the feed: abort any running channel, clear the held baseline, and end
-- every read. Idempotent, finite, and never retries.
closeInputFeed ∷ InputFeed → STM ()
closeInputFeed feed = do
  state ← readTVar (feedState feed)
  case statePhase state of
    InputFeedClosed → pure ()
    _ → do
      discarded ← maybe (pure 0) abortChannel (stateChannel state)
      writeTVar (feedState feed) $
        modifyCounters
          (\counts → counts {countDiscardedAtClose = countDiscardedAtClose counts + discarded})
          state
            { statePhase = InputFeedClosed
            , stateChannel = Nothing
            , stateHeldKeys = IntSet.empty
            , stateHeldButtons = IntSet.empty
            }
