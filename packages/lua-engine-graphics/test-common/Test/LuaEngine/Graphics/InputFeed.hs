{-# LANGUAGE OverloadedStrings #-}

-- | A controlled model of one window's input feed, for the Lua input adapter's examples (TRA-6).
--
-- This is /an injected feed/, never device evidence. No public API outside the GLFW package can produce a GLFW input event
-- or a reset token, so the adapter ("Hetoimasia.LuaEngine.Graphics.Input") is written over a 'Source', and this module is a
-- source an example drives by hand: it follows the documented semantics of the real feed (the admission gate, the focus
-- gate, the held-state interpretation, the overflow and suspension resets, the acknowledgement order and the owner's resume
-- rule) closely enough that the adapter's behavior over it is the behavior the contract describes, and no closer. What
-- the real feed does is the GLFW package's own suite's evidence (@glfw-tests@), and what a real window delivers is the
-- native suite's; neither is claimed here.
--
-- The model never blocks, sleeps or runs a thread: every operation is one transaction, so an example orders a producer and a
-- consumer exactly as it chooses.
module Test.LuaEngine.Graphics.InputFeed
  ( -- * The model
    Feed
  , Phase (..)
  , Admission (..)
  , newFeed
  , feedSource
    -- * The producer's and the owner's side
  , produce
  , closeFeed
  , resumeFeed
  , setObservation
  , plainObservation
    -- * What it holds
  , feedPhase
  , feedAdmission
  , feedEpoch
  , feedQueued
  , feedLog
  , feedSuppressed
  , feedGated
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import qualified Data.IntSet as IntSet
import Data.IntSet (IntSet)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Hetoimasia.GLFW.Input as Glfw
import Hetoimasia.GLFW.Window (Attribute (..))
import Hetoimasia.LuaEngine.Graphics.Input (Source (..), SourceObservation (..), SourceRead (..))
import Numeric.Natural (Natural)

data Phase = Running | ResetPending | ResetAcknowledged | Closed
  deriving (Eq, Show)

data Admission = Awaiting | Enabled | Suspended
  deriving (Eq, Show)

data St = St
  { stPhase ∷ !Phase
  , stEpoch ∷ !Natural
  , stQueue ∷ ![(Natural, Glfw.InputPayload)]
  , stAdmission ∷ !Admission
  , stFocused ∷ !Bool
  , stKeys ∷ !IntSet
  , stButtons ∷ !IntSet
  , stEpisode ∷ !(Maybe (Natural, Glfw.ResetReason))
  , stGated ∷ !Int
  , stSuppressed ∷ !Int
  , stCapacity ∷ !Int
  , stObservation ∷ !SourceObservation
  }

data Feed = Feed
  { feedState ∷ !(TVar St)
  , feedLogVar ∷ !(TVar [Text])
  }

-- | A running feed at epoch one, awaiting readiness, with this much room for ordered events, focused.
newFeed ∷ Int → IO Feed
newFeed capacity = do
  st ← newTVarIO (St Running 1 [] Awaiting True IntSet.empty IntSet.empty Nothing 0 0 capacity plainObservation)
  Feed st <$> newTVarIO []

-- | An observation that says nothing is known: revision zero, every attribute unavailable.
plainObservation ∷ SourceObservation
plainObservation = SourceObservation 0 Unavailable Nothing Nothing Unavailable Unavailable Unavailable

note ∷ Feed → Text → STM ()
note feed entry = modifyTVar' (feedLogVar feed) (<> [entry])

modify ∷ Feed → (St → St) → STM ()
modify feed change = readTVar (feedState feed) >>= writeTVar (feedState feed) . change

-- | Offer one payload, as the window's owner does: the application gate, the focus gate and the held-state rules decide
-- whether it is admitted, and a full queue is the overflow reset.
produce ∷ Feed → Glfw.InputPayload → STM ()
produce feed payload = do
  st ← readTVar (feedState feed)
  let running = stPhase st == Running
      open = stAdmission st == Enabled
      focus = case payload of
        Glfw.FocusInput gained → Just gained
        _ → Nothing
      st' = maybe st (\gained → st {stFocused = gained}) focus
      count change = writeTVar (feedState feed) (change st')
  case () of
    _
      | stPhase st == Closed → pure ()
      -- A focus transition is admitted whatever the focus gate says; while the phase is not running it only moves the gate.
      | Just gained ← focus, running && open →
          admit st' (if gained then st' else st' {stKeys = IntSet.empty, stButtons = IntSet.empty})
      | Just _ ← focus →
          count (\now → if running then now {stGated = stGated now + 1} else now {stSuppressed = stSuppressed now + 1})
      | not running → count (\now → now {stSuppressed = stSuppressed now + 1})
      | not open || not (stFocused st) → count (\now → now {stGated = stGated now + 1})
      | otherwise → case payload of
          Glfw.KeyInput key → case Glfw.keyAction key of
            Glfw.KeyPressed → admit st (st {stKeys = IntSet.insert (Glfw.keyCode key) (stKeys st)})
            _
              | IntSet.member (Glfw.keyCode key) (stKeys st) → admit st (if Glfw.keyAction key == Glfw.KeyReleased then st {stKeys = IntSet.delete (Glfw.keyCode key) (stKeys st)} else st)
              | otherwise → pure ()
          Glfw.ButtonInput button → case Glfw.buttonAction button of
            Glfw.ButtonPressed → admit st (st {stButtons = IntSet.insert (Glfw.buttonNumber button) (stButtons st)})
            Glfw.ButtonReleased
              | IntSet.member (Glfw.buttonNumber button) (stButtons st) → admit st (st {stButtons = IntSet.delete (Glfw.buttonNumber button) (stButtons st)})
              | otherwise → pure ()
          _ → admit st st
  where
    admit before after
      | length (stQueue before) >= stCapacity before = overflow after
      | otherwise = writeTVar (feedState feed) after {stQueue = stQueue after <> [(stEpoch after, payload)]}
    overflow st = writeTVar (feedState feed) (beginReset Glfw.InputOverflowed st)

beginReset ∷ Glfw.ResetReason → St → St
beginReset reason st =
  st
    { stPhase = ResetPending
    , stQueue = []
    , stKeys = IntSet.empty
    , stButtons = IntSet.empty
    , stEpisode = Just (stEpoch st + 1, reason)
    }

-- | The owner closes the feed: every read answers closed at once.
closeFeed ∷ Feed → STM ()
closeFeed feed = modify feed (\st → st {stPhase = Closed, stQueue = [], stKeys = IntSet.empty, stButtons = IntSet.empty})

-- | The owner's resume rule: an acknowledged reset resumes in its reserved epoch once admission is enabled and the window is
-- focused. Nothing else resumes it.
resumeFeed ∷ Feed → STM Bool
resumeFeed feed = do
  st ← readTVar (feedState feed)
  case (stPhase st, stEpisode st) of
    (ResetAcknowledged, Just (epoch, _)) | stAdmission st == Enabled && stFocused st → do
      writeTVar (feedState feed) st {stPhase = Running, stEpoch = epoch}
      pure True
    _ → pure False

setObservation ∷ Feed → SourceObservation → STM ()
setObservation feed observation = modify feed (\st → st {stObservation = observation})

feedPhase ∷ Feed → STM Phase
feedPhase feed = stPhase <$> readTVar (feedState feed)

feedAdmission ∷ Feed → STM Admission
feedAdmission feed = stAdmission <$> readTVar (feedState feed)

feedEpoch ∷ Feed → STM Natural
feedEpoch feed = stEpoch <$> readTVar (feedState feed)

feedQueued ∷ Feed → STM Int
feedQueued feed = length . stQueue <$> readTVar (feedState feed)

feedGated, feedSuppressed ∷ Feed → STM Int
feedGated feed = stGated <$> readTVar (feedState feed)
feedSuppressed feed = stSuppressed <$> readTVar (feedState feed)

-- | What the adapter did to the feed through its source, in order: @enable@, @suspend@ and @ack N@ (the epoch a reset
-- reserved).
feedLog ∷ Feed → STM [Text]
feedLog feed = readTVar (feedLogVar feed)

-- | The feed as a 'Source': the event is its epoch and payload, a reset token is the epoch it reserved and why.
feedSource ∷ Feed → Source (Natural, Glfw.InputPayload) (Natural, Glfw.ResetReason)
feedSource feed =
  Source
    { sourceRead = do
        st ← readTVar (feedState feed)
        case stPhase st of
          Closed → pure ReadClosed
          ResetAcknowledged → pure ReadPaused
          ResetPending → pure (maybe ReadPaused ReadReset (stEpisode st))
          Running → case stQueue st of
            [] → pure ReadEmpty
            event : rest → ReadEvent event <$ writeTVar (feedState feed) st {stQueue = rest}
    , sourceEvent = id
    , sourceResetOf = id
    , sourceAcknowledge = \(epoch, reason) → do
        st ← readTVar (feedState feed)
        note feed ("ack " <> textOf epoch)
        Right <$> case (stPhase st, stEpisode st) of
          (Closed, _) → pure Glfw.AcknowledgementClosed
          (_, Nothing) → pure Glfw.StaleAcknowledgement
          (phase, Just (current, why))
            | epoch /= current || reason /= why → pure Glfw.StaleAcknowledgement
            | phase == ResetPending → Glfw.Acknowledged <$ writeTVar (feedState feed) st {stPhase = ResetAcknowledged}
            | otherwise → pure Glfw.AlreadyAcknowledged
    , sourceEpoch = stEpoch <$> readTVar (feedState feed)
    , sourceLastReset = stEpisode <$> readTVar (feedState feed)
    , sourceClosed = (== Closed) . stPhase <$> readTVar (feedState feed)
    , sourceObservation = stObservation <$> readTVar (feedState feed)
    , sourceEnable = do
        note feed "enable"
        modify feed (\st → if stPhase st == Closed then st else st {stAdmission = Enabled})
    , sourceSuspend = do
        note feed "suspend"
        modify feed $ \st -> case (stPhase st, stAdmission st) of
          (Closed, _) → st
          (_, Awaiting) → st
          (_, Suspended) → st
          (Running, Enabled) → (beginReset Glfw.AdmissionSuspended st) {stAdmission = Suspended}
          (_, Enabled) → st {stAdmission = Suspended}
    }
  where
    textOf = Text.pack . show
