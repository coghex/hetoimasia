-- | The texture banks of the M1 profile that are charged per texture rather than per lane: the
-- texture slots and the nominal RGBA8 bytes of one UI instance, and the nominal bytes of the session.
--
-- = Owner, writers, lifetime
--
-- A 'SessionBytes' belongs to one pipeline and is never reset. A 'TextureOwner' belongs to one UI
-- instance, made for it by the pipeline's 'Hetoimasia.LuaEngine.Texture.Pipeline.newTextureOwner' and
-- held by that instance's bindings (there is no registry of owners). A 'TextureCharge' belongs to
-- one accepted texture request. Every write is a transaction:
--
-- * admission reserves a charge's slot and nominal bytes inside the host's one admission
--   transaction ('reserveSlot', 'reserveNominal'), so a texture's request, lease capacity, slot and
--   bytes are all taken or none is;
-- * the decode stage shrinks the nominal bytes to the validated size ('shrinkNominal');
-- * the charge is returned, once, by whoever owns the texture's end: the lease after the backend
--   proved the texture retired, the pipeline's own housekeeping for a texture no lease will ever own,
--   or the host's credit release for a request that never produced a texture.
--
-- Nothing here is a cache: a charge is a promise about one texture, and each part of it ('returnSlot',
-- 'returnNominal') can be returned once however many paths reach it.
module Hetoimasia.LuaEngine.Texture.Banks
  ( -- * The session
    SessionBytes
  , newSessionBytes
  , sessionBytesLimit
  , sessionBytesCharged

    -- * One UI instance
  , TextureOwner
  , newOwner
  , TextureRole (..)
  , ownerRole
  , ownerNumber
  , ownerSession
  , ownerSlotLimit
  , ownerByteLimit
  , ownerSlotsCharged
  , ownerBytesCharged
  , ownerIsOpen
  , closeOwner

    -- * One texture
  , TextureCharge
  , newCharge
  , chargeOwner
  , reserveSlot
  , reserveNominal
  , shrinkNominal
  , returnSlot
  , returnNominal
  , chargeNominal
  , chargeSlotHeld
  , BankDefect (..)
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, throwSTM, writeTVar)
import Control.Exception (Exception)
import Control.Monad (unless, when)
import Data.Text (Text)
import Data.Word (Word64)

-- | The nominal bytes the session's textures hold.
data SessionBytes = SessionBytes
  { sessionLimit ∷ !Word64
  , sessionCharged ∷ !(TVar Word64)
  }
  deriving (Eq)

-- | A session bank with this much room.
newSessionBytes ∷ Word64 → IO SessionBytes
newSessionBytes limit = SessionBytes limit <$> newTVarIO 0

-- | The most the session's textures may hold.
sessionBytesLimit ∷ SessionBytes → Word64
sessionBytesLimit = sessionLimit

-- | What they hold now.
sessionBytesCharged ∷ SessionBytes → STM Word64
sessionBytesCharged = readTVar . sessionCharged

-- | One UI instance's texture banks.
-- | The role of the instance an owner stands for, declared by the facade boundary from the instance's
-- immutable metadata, never read from Lua. Texture acquisition is presentation-instance hook work: an
-- owner for a logical instance is refused before any reservation.
data TextureRole = PresentationRole | LogicalRole
  deriving (Eq, Show)

data TextureOwner = TextureOwner
  { ownerNumber ∷ !Word64
  , ownerRole ∷ !TextureRole
  , ownerSession ∷ !SessionBytes
  , ownerSlotLimit ∷ !Int
  , ownerSlots ∷ !(TVar Int)
  , ownerByteLimit ∷ !Word64
  , ownerBytes ∷ !(TVar Word64)
  , ownerOpen ∷ !(TVar Bool)
  }

instance Eq TextureOwner where
  a == b = ownerSlots a == ownerSlots b

-- | An owner with these limits, numbered by its pipeline. The numbers are issued in order and never
-- again.
newOwner ∷ Word64 → SessionBytes → Int → Word64 → TextureRole → STM TextureOwner
newOwner number session slotLimit byteLimit role =
  TextureOwner number role session slotLimit <$> newTVar 0 <*> pure byteLimit <*> newTVar 0 <*> newTVar True

-- | The texture slots the owner holds (pending, live and retiring).
ownerSlotsCharged ∷ TextureOwner → STM Int
ownerSlotsCharged = readTVar . ownerSlots

-- | The nominal bytes the owner holds.
ownerBytesCharged ∷ TextureOwner → STM Word64
ownerBytesCharged = readTVar . ownerBytes

-- | Whether the owner still takes requests. A closed owner is refused before any action; closing it
-- releases nothing, which is the lease's and the pipeline's, as each texture ends.
ownerIsOpen ∷ TextureOwner → STM Bool
ownerIsOpen = readTVar . ownerOpen

-- | Stop taking requests for this owner. Idempotent.
closeOwner ∷ TextureOwner → STM ()
closeOwner owner = writeTVar (ownerOpen owner) False

-- | An engine accounting failure: a charge that was returned past what it held, or a shrink that
-- would grow.
newtype BankDefect = BankDefect Text
  deriving (Eq, Show)

instance Exception BankDefect

-- | What one accepted texture request holds.
data TextureCharge = TextureCharge
  { chargeOwner ∷ !TextureOwner
  , chargeSlot ∷ !(TVar Bool)
  , chargeBytes ∷ !(TVar Word64)
  }

-- | A charge that holds nothing yet, for this owner.
newCharge ∷ TextureOwner → STM TextureCharge
newCharge owner = TextureCharge owner <$> newTVar False <*> newTVar 0

-- | Whether the slot is held.
chargeSlotHeld ∷ TextureCharge → STM Bool
chargeSlotHeld = readTVar . chargeSlot

-- | The nominal bytes the charge holds now.
chargeNominal ∷ TextureCharge → STM Word64
chargeNominal = readTVar . chargeBytes

-- | Take one of the owner's texture slots, if it has one. Checked: the count is compared with the
-- limit, never incremented past it.
reserveSlot ∷ TextureCharge → STM Bool
reserveSlot charge = do
  held ← readTVar (chargeSlot charge)
  when held $ throwSTM (BankDefect "a texture slot was reserved twice for one request")
  used ← readTVar (ownerSlots (chargeOwner charge))
  if used >= ownerSlotLimit (chargeOwner charge)
    then pure False
    else do
      writeTVar (ownerSlots (chargeOwner charge)) (used + 1)
      writeTVar (chargeSlot charge) True
      pure True

-- | Take this many nominal bytes from both the owner's bank and the session's, or neither. Checked
-- arithmetic: each request is compared with the room left, so nothing is added that could wrap.
reserveNominal ∷ TextureCharge → Word64 → STM Bool
reserveNominal charge wanted = do
  held ← readTVar (chargeBytes charge)
  when (held /= 0) $ throwSTM (BankDefect "nominal bytes were reserved twice for one request")
  let owner = chargeOwner charge
      session = ownerSession owner
  instanceUsed ← readTVar (ownerBytes owner)
  sessionUsed ← readTVar (sessionCharged session)
  if wanted > ownerByteLimit owner - instanceUsed || wanted > sessionLimit session - sessionUsed
    then pure False
    else do
      writeTVar (ownerBytes owner) (instanceUsed + wanted)
      writeTVar (sessionCharged session) (sessionUsed + wanted)
      writeTVar (chargeBytes charge) wanted
      pure True

-- | Reduce the charge to this many bytes, giving the difference back to both banks in the same
-- transaction. Growing a charge is a defect: the conservative reservation was made for the largest
-- possible output.
shrinkNominal ∷ TextureCharge → Word64 → STM ()
shrinkNominal charge actual = do
  held ← readTVar (chargeBytes charge)
  when (actual > held) $ throwSTM (BankDefect "a nominal charge was asked to grow")
  unless (actual == held) $ do
    giveBack (chargeOwner charge) (held - actual)
    writeTVar (chargeBytes charge) actual

-- | Return the slot, once. Further calls do nothing.
returnSlot ∷ TextureCharge → STM ()
returnSlot charge = do
  held ← readTVar (chargeSlot charge)
  when held $ do
    used ← readTVar (ownerSlots (chargeOwner charge))
    when (used <= 0) $ throwSTM (BankDefect "a texture slot was returned that the owner did not hold")
    writeTVar (ownerSlots (chargeOwner charge)) (used - 1)
    writeTVar (chargeSlot charge) False

-- | Return the nominal bytes the charge holds now, once. Further calls do nothing.
returnNominal ∷ TextureCharge → STM ()
returnNominal charge = do
  held ← readTVar (chargeBytes charge)
  unless (held == 0) $ do
    giveBack (chargeOwner charge) held
    writeTVar (chargeBytes charge) 0

giveBack ∷ TextureOwner → Word64 → STM ()
giveBack owner amount = do
  instanceUsed ← readTVar (ownerBytes owner)
  sessionUsed ← readTVar (sessionCharged (ownerSession owner))
  when (amount > instanceUsed || amount > sessionUsed) $ throwSTM (BankDefect "nominal bytes were returned that a bank did not hold")
  writeTVar (ownerBytes owner) (instanceUsed - amount)
  writeTVar (sessionCharged (ownerSession owner)) (sessionUsed - amount)
