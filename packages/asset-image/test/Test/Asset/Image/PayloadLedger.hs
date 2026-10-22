-- | A byte bank for the bounded decoder's examples: the account the decoder
-- charges, and the caller's own charges beside it.
--
-- The ledger models a pipeline's payload bank. It grants a reservation only
-- while the live bytes plus the request fit its capacity, records every
-- grant, refusal and release in order, and tracks the live bytes and their
-- peak. The caller's own charges (the encoded input, a staging copy) go
-- through the same bank with 'chargeCaller' and 'releaseCaller', so the peak
-- is the whole pipeline's, not only the decoder's.
--
-- Fault injection wraps an account: a hook runs before the ledger sees a
-- reservation or a release, and may throw, so a call that faulted is not
-- counted, exactly as a bank that failed would not count it.
module Test.Asset.Image.PayloadLedger
  ( Ledger
  , Event (..)
  , newLedger
  , ledgerAccount
  , chargeCaller
  , releaseCaller
  , liveBytes
  , peakBytes
  , events
  , grantedEvents
  , beforeReserve
  , beforeRelease
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Hetoimasia.Asset.Image.PngDecode (PayloadAccount (..), PayloadStage)

-- | What the bank saw, in order.
data Event
  = Granted PayloadStage Int
  | Refused PayloadStage Int
  | Released PayloadStage Int
  | CallerCharged Int
  | CallerReleased Int
  deriving (Eq, Show)

data State = State
  { stateLive ∷ !Int
  , statePeak ∷ !Int
  , stateLog ∷ [Event]
  }

data Ledger = Ledger
  { ledgerCapacity ∷ !Int
  , ledgerState ∷ MVar State
  }

-- | An empty bank of this many bytes.
newLedger ∷ Int → IO Ledger
newLedger capacity = Ledger capacity <$> newMVar (State 0 0 [])

-- | The account the decoder is given.
ledgerAccount ∷ Ledger → PayloadAccount
ledgerAccount ledger =
  PayloadAccount
    { reservePayload = \stage bytes → modifyMVar (ledgerState ledger) $ \state →
        if stateLive state + bytes > ledgerCapacity ledger
          then pure (state {stateLog = Refused stage bytes : stateLog state}, False)
          else pure (grow state bytes (Granted stage bytes), True)
    , releasePayload = \stage bytes →
        modifyMVar_ (ledgerState ledger) $ \state →
          pure state {stateLive = stateLive state - bytes, stateLog = Released stage bytes : stateLog state}
    }

grow ∷ State → Int → Event → State
grow state bytes event =
  let live = stateLive state + bytes
   in State {stateLive = live, statePeak = max live (statePeak state), stateLog = event : stateLog state}

-- | The caller charges its own bytes: whether the bank had room.
chargeCaller ∷ Ledger → Int → IO Bool
chargeCaller ledger bytes = modifyMVar (ledgerState ledger) $ \state →
  if stateLive state + bytes > ledgerCapacity ledger
    then pure (state, False)
    else pure (grow state bytes (CallerCharged bytes), True)

releaseCaller ∷ Ledger → Int → IO ()
releaseCaller ledger bytes =
  modifyMVar_ (ledgerState ledger) $ \state →
    pure state {stateLive = stateLive state - bytes, stateLog = CallerReleased bytes : stateLog state}

liveBytes, peakBytes ∷ Ledger → IO Int
liveBytes = fmap stateLive . readMVar . ledgerState
peakBytes = fmap statePeak . readMVar . ledgerState

-- | Every event so far, oldest first.
events ∷ Ledger → IO [Event]
events = fmap (reverse . stateLog) . readMVar . ledgerState

-- | The decoder's grants alone, oldest first, as (stage, bytes).
grantedEvents ∷ Ledger → IO [(PayloadStage, Int)]
grantedEvents ledger = do
  seen ← events ledger
  pure [(stage, bytes) | Granted stage bytes ← seen]

-- | Run an action before each reservation reaches the account; an exception
-- from it is the bank failing, and nothing is counted.
beforeReserve ∷ (PayloadStage → Int → IO ()) → PayloadAccount → PayloadAccount
beforeReserve hook account = account {reservePayload = \stage bytes → hook stage bytes >> reservePayload account stage bytes}

-- | Run an action before each release reaches the account; an exception from
-- it is the release failing, and the bytes stay counted.
beforeRelease ∷ (PayloadStage → Int → IO ()) → PayloadAccount → PayloadAccount
beforeRelease hook account = account {releasePayload = \stage bytes → hook stage bytes >> releasePayload account stage bytes}
