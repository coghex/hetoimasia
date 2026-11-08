-- | The texture banks of the M1 profile that are charged per texture rather than per lane: the nominal bytes
-- of one UI instance and the nominal bytes of the session. Memory is the only bound; there is no count of
-- textures (owner decision 2026-11-08, "Hetoimasia.LuaEngine.Profile.Limits.textureMinimumChargeBytes").
-- Every texture is charged at least the minimum charge in both banks, from admission until its proven
-- retirement, so a bank of @n@ bytes holds at most @n `div` 4096@ textures and the structural capacities
-- sized from that (the native table, the facade's lease scope) never answer before the banks do.
--
-- = Owner, writers, lifetime
--
-- A 'SessionBytes' belongs to one pipeline and is never reset. A 'TextureOwner' belongs to one UI
-- instance, made for it by the pipeline's 'Hetoimasia.LuaEngine.Texture.Pipeline.newTextureOwner' and
-- held by that instance's bindings (there is no registry of owners). A 'TextureCharge' belongs to
-- one accepted texture request. Every write is a transaction:
--
-- * admission reserves a charge's nominal bytes inside the host's one admission transaction
--   ('reserveNominal'), so a texture's request, lease capacity and bytes are all taken or none is;
-- * the decode stage shrinks the nominal bytes to the validated size ('shrinkNominal'), never below the
--   minimum charge;
-- * the charge is returned, once, by whoever owns the texture's end: the lease after the backend
--   proved the texture retired, the pipeline's own housekeeping for a texture no lease will ever own,
--   or the host's credit release for a request that never produced a texture.
--
-- Nothing here is a cache: a charge is a promise about one texture, and it ('returnNominal') can be
-- returned once however many paths reach it. The number of textures an owner holds is kept only as a
-- read-only observation ('ownerTexturesCharged'): nothing compares it with anything.
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
  , ownerByteLimit
  , ownerTexturesCharged
  , ownerBytesCharged
  , ownerIsOpen
  , closeOwner

    -- * One texture
  , TextureCharge
  , newCharge
  , chargeOwner
  , reserveNominal
  , shrinkNominal
  , returnNominal
  , chargeNominal
  , BankDefect (..)
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, throwSTM, writeTVar)
import Control.Exception (Exception)
import Control.Monad (unless, when)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile (textureChargeBytes)

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
  , ownerTextures ∷ !(TVar Int)
    -- ^ The textures the owner holds (a charge holding bytes is a texture): an observation, never enforced.
  , ownerByteLimit ∷ !Word64
  , ownerBytes ∷ !(TVar Word64)
  , ownerOpen ∷ !(TVar Bool)
  }

instance Eq TextureOwner where
  a == b = ownerTextures a == ownerTextures b

-- | An owner with these limits, numbered by its pipeline. The numbers are issued in order and never
-- again.
newOwner ∷ Word64 → SessionBytes → Word64 → TextureRole → STM TextureOwner
newOwner number session byteLimit role =
  TextureOwner number role session <$> newTVar 0 <*> pure byteLimit <*> newTVar 0 <*> newTVar True

-- | The textures the owner holds (pending, live and retiring), as a read-only observation: the bytes are
-- the bound, and no decision reads this.
ownerTexturesCharged ∷ TextureOwner → STM Int
ownerTexturesCharged = readTVar . ownerTextures

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
  , chargeBytes ∷ !(TVar Word64)
  }

-- | A charge that holds nothing yet, for this owner.
newCharge ∷ TextureOwner → STM TextureCharge
newCharge owner = TextureCharge owner <$> newTVar 0

-- | The nominal bytes the charge holds now.
chargeNominal ∷ TextureCharge → STM Word64
chargeNominal = readTVar . chargeBytes

-- | Take this many nominal bytes (at least the minimum charge) from both the owner's bank and the
-- session's, or neither. Checked arithmetic: each request is compared with the room left, so nothing is
-- added that could wrap. The charge then holds at least 'textureMinimumChargeBytes', which is what makes it
-- a texture to the owner's observation.
reserveNominal ∷ TextureCharge → Word64 → STM Bool
reserveNominal charge requested = do
  held ← readTVar (chargeBytes charge)
  when (held /= 0) $ throwSTM (BankDefect "nominal bytes were reserved twice for one request")
  let wanted = textureChargeBytes requested
      owner = chargeOwner charge
      session = ownerSession owner
  instanceUsed ← readTVar (ownerBytes owner)
  sessionUsed ← readTVar (sessionCharged session)
  if wanted > ownerByteLimit owner - instanceUsed || wanted > sessionLimit session - sessionUsed
    then pure False
    else do
      writeTVar (ownerBytes owner) (instanceUsed + wanted)
      writeTVar (sessionCharged session) (sessionUsed + wanted)
      writeTVar (chargeBytes charge) wanted
      readTVar (ownerTextures owner) >>= writeTVar (ownerTextures owner) . (+ 1)
      pure True

-- | Reduce the charge to this many bytes, or to the minimum charge if that is more, giving the difference
-- back to both banks in the same transaction. Growing a charge is a defect: the conservative reservation
-- was made for the largest possible output (and is never below the minimum).
shrinkNominal ∷ TextureCharge → Word64 → STM ()
shrinkNominal charge decoded = do
  held ← readTVar (chargeBytes charge)
  let actual = textureChargeBytes decoded
  when (actual > held) $ throwSTM (BankDefect "a nominal charge was asked to grow")
  unless (actual == held) $ do
    giveBack (chargeOwner charge) (held - actual)
    writeTVar (chargeBytes charge) actual

-- | Return the nominal bytes the charge holds now, once, and with them the texture the owner observes.
-- Further calls do nothing.
returnNominal ∷ TextureCharge → STM ()
returnNominal charge = do
  held ← readTVar (chargeBytes charge)
  unless (held == 0) $ do
    giveBack (chargeOwner charge) held
    writeTVar (chargeBytes charge) 0
    let textures = ownerTextures (chargeOwner charge)
    count ← readTVar textures
    when (count <= 0) $ throwSTM (BankDefect "a texture was returned that the owner did not hold")
    writeTVar textures (count - 1)

giveBack ∷ TextureOwner → Word64 → STM ()
giveBack owner amount = do
  instanceUsed ← readTVar (ownerBytes owner)
  sessionUsed ← readTVar (sessionCharged (ownerSession owner))
  when (amount > instanceUsed || amount > sessionUsed) $ throwSTM (BankDefect "nominal bytes were returned that a bank did not hold")
  writeTVar (ownerBytes owner) (instanceUsed - amount)
  writeTVar (sessionCharged (ownerSession owner)) (sessionUsed - amount)
