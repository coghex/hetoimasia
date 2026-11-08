-- | The one shared CPU render/staging allowance the texture pipeline charges retained coverage
-- to (TRA-15), as a narrow injected account.
--
-- = Owner, writers, readers, thread, lifetime
--
-- A 'RenderAccount' is made once per session by the composition root
-- ('Hetoimasia.Run.Session' in production; a test composition makes its own), sized at
-- 'm1RenderAccountBytes', and passed narrowly to the texture pipeline and, later, to any other
-- consumer of the same allowance. It is one allowance, not a bank per image, per consumer or per
-- arena: the pipeline constructs no default or fallback account of its own, and nothing here
-- raises the limit or caches anything. It belongs to the session and is never reset.
--
-- Every operation is an 'STM' action on one variable, so a credit composed into the host's one
-- admission transaction either takes its bytes with the rest of the admission or takes nothing.
-- Writers: the admission ('reserveHold'), the decode stage ('shrinkHold', 'takeOwnership'), the
-- last release of a version's CPU interests ('returnOwned') and the host's credit release
-- ('returnHold'); any other consumer through 'accountReserve' and 'accountRelease'. Readers:
-- anyone, through 'accountCharged'. There is no thread of its own and no waiting: a charge that
-- does not fit answers 'False', and a defective return raises 'AccountDefect'.
--
-- = What it charges
--
-- The retained coverage plane and its fixed metadata of each immutable loaded asset version
-- ('Hetoimasia.Asset.Image.DataMap.coverageRetainedBytes'), from the admission of the request that
-- loads it until the last CPU reader or owner of that version has let go. That includes the
-- temporary overlap of an old and a new version of the same path, which are two versions and two
-- charges. It is distinct from the decoder's per-lane workspace account, which bounds the decode
-- itself, and from the texture's nominal bytes, which follow the GPU registration's retirement;
-- none of the three stands in for another.
--
-- = A request's hold, exactly once
--
-- A 'Reservation' is one request's hold, a four-state machine each transition of which is one
-- transaction:
--
-- @
-- Unreserved --reserveHold--> Held n --shrinkHold--> Held m (m <= n)
--                              |  \\
--                   returnHold |   \\ takeOwnership
--                              v    v
--                            Done  Owned m --returnOwned--> Done
-- @
--
-- While /Held/ the request owns the bytes and its credit release returns them if the request ends
-- without a version (a refusal, a cancellation, a failure). 'takeOwnership' passes them to the
-- version the decode built, in the transaction that records the version, and from then on only the
-- version's last interest returns them; the credit release of that request is then a no-op. Every
-- state past /Done/ is final, so however many paths reach a return, the bytes go back once.
module Hetoimasia.LuaEngine.Texture.Account
  ( -- * The account
    RenderAccount
  , newRenderAccount
  , m1RenderAccountBytes
  , accountLimit
  , accountCharged
  , accountReserve
  , accountRelease
  , AccountDefect (..)

    -- * One request's hold
  , Reservation
  , newReservation
  , reserveHold
  , shrinkHold
  , takeOwnership
  , returnHold
  , returnOwned
  , ReservationReading (..)
  , reservationReading
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, throwSTM, writeTVar)
import Control.Exception (Exception)
import Control.Monad (when)
import Data.Text (Text)
import Data.Word (Word64)

-- | The shared allowance: a limit and what is charged to it.
data RenderAccount = RenderAccount
  { accountBytes ∷ !Word64
  , accountHeld ∷ !(TVar Word64)
  }
  deriving (Eq)

-- | An account with this much room.
newRenderAccount ∷ Word64 → IO RenderAccount
newRenderAccount limit = RenderAccount limit <$> newTVarIO 0

-- | The approved size of the session's CPU render/staging allowance: 128 MiB.
m1RenderAccountBytes ∷ Word64
m1RenderAccountBytes = 128 * 1024 * 1024

-- | The most the account may hold.
accountLimit ∷ RenderAccount → Word64
accountLimit = accountBytes

-- | What it holds now.
accountCharged ∷ RenderAccount → STM Word64
accountCharged = readTVar . accountHeld

-- | Take these bytes if they fit, or none: 'False' is a full allowance, which may empty. Checked
-- arithmetic: the request is compared with the room left, so nothing is added that could wrap.
accountReserve ∷ RenderAccount → Word64 → STM Bool
accountReserve account wanted = do
  held ← readTVar (accountHeld account)
  if wanted > accountBytes account - held
    then pure False
    else True <$ writeTVar (accountHeld account) (held + wanted)

-- | Give these bytes back. Returning more than the account holds is a defect.
accountRelease ∷ RenderAccount → Word64 → STM ()
accountRelease account amount = do
  held ← readTVar (accountHeld account)
  when (amount > held) $ throwSTM (AccountDefect "bytes were returned that the account did not hold")
  writeTVar (accountHeld account) (held - amount)

-- | An accounting failure: a return past what was held, or a hold used out of order.
newtype AccountDefect = AccountDefect Text
  deriving (Eq, Show)

instance Exception AccountDefect

-- Reservations --------------------------------------------------------------------------------------------

data HoldState
  = Unreserved
  | Held !Word64
  | Owned !Word64
  | Done

-- | One request's hold on the account.
data Reservation = Reservation
  { holdAccount ∷ !RenderAccount
  , holdState ∷ !(TVar HoldState)
  }

instance Eq Reservation where
  a == b = holdState a == holdState b

-- | A hold that holds nothing yet.
newReservation ∷ RenderAccount → STM Reservation
newReservation account = Reservation account <$> newTVar Unreserved

-- | Take the request's bytes, if they fit: the credit the admission composes. 'False' is busy and
-- wrote nothing. Reserving a hold twice is a defect.
reserveHold ∷ Reservation → Word64 → STM Bool
reserveHold hold wanted =
  readTVar (holdState hold) >>= \case
    Unreserved → do
      fits ← accountReserve (holdAccount hold) wanted
      when fits $ writeTVar (holdState hold) (Held wanted)
      pure fits
    _ → throwSTM (AccountDefect "a request's bytes were reserved twice")

-- | Reduce a held reservation to the exact bytes, giving the difference back. Growing it is a
-- defect: the admission reserved the worst case.
shrinkHold ∷ Reservation → Word64 → STM ()
shrinkHold hold actual =
  readTVar (holdState hold) >>= \case
    Held held
      | actual > held → throwSTM (AccountDefect "a request's reservation was asked to grow")
      | actual == held → pure ()
      | otherwise → do
          accountRelease (holdAccount hold) (held - actual)
          writeTVar (holdState hold) (Held actual)
    _ → throwSTM (AccountDefect "a request's reservation was shrunk while it was not held")

-- | Pass a held reservation to the version it will be retained for, and answer its bytes. From now
-- on the credit release returns nothing and only 'returnOwned' does.
takeOwnership ∷ Reservation → STM Word64
takeOwnership hold =
  readTVar (holdState hold) >>= \case
    Held held → held <$ writeTVar (holdState hold) (Owned held)
    _ → throwSTM (AccountDefect "a request's reservation was taken that it did not hold")

-- | Give a still-held reservation back: the request ended without a version. A no-op in any other
-- state, which is what makes the host's credit release safe whatever happened.
returnHold ∷ Reservation → STM ()
returnHold hold =
  readTVar (holdState hold) >>= \case
    Held held → accountRelease (holdAccount hold) held >> writeTVar (holdState hold) Done
    _ → pure ()

-- | Give an owned reservation back: the last CPU interest of its version ended. A no-op in any
-- other state.
returnOwned ∷ Reservation → STM ()
returnOwned hold =
  readTVar (holdState hold) >>= \case
    Owned held → accountRelease (holdAccount hold) held >> writeTVar (holdState hold) Done
    _ → pure ()

-- | What a hold is, for observation.
data ReservationReading
  = ReservationUnreserved
  | ReservationHeld !Word64
  | ReservationOwned !Word64
  | ReservationDone
  deriving (Eq, Show)

-- | A hold, in one transaction.
reservationReading ∷ Reservation → STM ReservationReading
reservationReading hold =
  readTVar (holdState hold) <&> \case
    Unreserved → ReservationUnreserved
    Held n → ReservationHeld n
    Owned n → ReservationOwned n
    Done → ReservationDone
  where
    (<&>) = flip fmap
