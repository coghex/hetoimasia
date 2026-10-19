{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The sample's authoritative world: a fixed number of entities, each with an integer
-- position and a version that changes whenever its position does, the committed tick,
-- the session's identity and the state of the session's random stream.
--
-- = Ownership
--
-- The world is a pure value. Its one owner is the driver ("Hetoimasia.Sample.LuaDomains.Domains"),
-- which keeps the committed world in a transactional variable and replaces it once per completed
-- tick, in the transaction that publishes the tick's snapshot. Gameplay's scripts never hold a
-- world: they read the tick's candidate ("Hetoimasia.Sample.LuaDomains.Candidate") through
-- bindings and stage effects into it. The UI never reads this variable: it reads published
-- snapshots only.
--
-- = The random stream
--
-- Gameplay's randomness is the stream this module defines, because the algorithm must not depend
-- on a library whose output can change between versions. It is SplitMix64 (Steele, Lea and Flood,
-- "Fast splittable pseudorandom number generators", 2014), fixed here and never delegated:
--
-- @
-- next s = (z3, s')   where  s' = s + 0x9E3779B97F4A7C15
--                            z1 = (s' xor (s' >> 30)) * 0xBF58476D1CE4E5B9
--                            z2 = (z1 xor (z1 >> 27)) * 0x94D049BB133111EB
--                            z3 = z2 xor (z2 >> 31)
-- @
--
-- all in unsigned 64-bit arithmetic. The stream's whole state is the one 64-bit word @s@, which is
-- part of the committed world, and the session's seed is its first state. A draw from @[0, n)@ is
-- @z3 mod n@ for @n@ from 1 to 2^31; the bias of the remainder is below 2^-33 for every such
-- bound and is accepted.
module Hetoimasia.Sample.LuaDomains.World
  ( Entity (..)
  , World (..)
  , initialWorld
  , entityAt
  , moveEntity
  , nextRandom
  , drawBelow
  ) where

import Control.DeepSeq (NFData)
import Data.Bits (shiftR, xor)
import Data.Int (Int64)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import GHC.Generics (Generic)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundEntities), positionLimit, randomLimit)

-- | One entity: where it is, and a version that changes whenever its position does.
data Entity = Entity
  { entityX ∷ !Int64
  , entityY ∷ !Int64
  , entityVersion ∷ !Word64
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The authoritative state.
data World = World
  { worldSession ∷ !Word64
    -- ^ The session's identity.
  , worldTick ∷ !Word64
    -- ^ The last committed tick; zero before the first.
  , worldEntities ∷ !(Seq Entity)
    -- ^ The entities, by index from zero.
  , worldRandom ∷ !Word64
    -- ^ The random stream's state.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The world before the first tick: the configured number of entities at fixed places and
-- version zero, the stream at the seed.
initialWorld ∷ Bounds → Word64 → Word64 → World
initialWorld bounds session seed =
  World
    { worldSession = session
    , worldTick = 0
    , worldEntities = Seq.fromList [Entity (4 * fromIntegral index) (fromIntegral index) 0 | index ← [0 .. boundEntities bounds - 1]]
    , worldRandom = seed
    }

-- | The entity at this index, if there is one.
entityAt ∷ World → Int → Maybe Entity
entityAt world index = Seq.lookup index (worldEntities world)

-- | Move an entity by a delta, keeping it inside the position limit. Its version advances if and
-- only if its position changed. An index with no entity changes nothing.
moveEntity ∷ Int → Int64 → Int64 → World → World
moveEntity index dx dy world = case entityAt world index of
  Nothing → world
  Just entity ->
    let x = clamp (entityX entity + dx)
        y = clamp (entityY entity + dy)
        moved = x /= entityX entity || y /= entityY entity
        entity' = Entity x y (if moved then entityVersion entity + 1 else entityVersion entity)
     in world {worldEntities = Seq.update index entity' (worldEntities world)}
  where
    clamp = max (negate positionLimit) . min positionLimit

-- | The stream's step: the output and the next state.
nextRandom ∷ Word64 → (Word64, Word64)
nextRandom state = (z3, state')
  where
    state' = state + 0x9E3779B97F4A7C15
    z1 = (state' `xor` (state' `shiftR` 30)) * 0xBF58476D1CE4E5B9
    z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
    z3 = z2 `xor` (z2 `shiftR` 31)

-- | A draw from @[0, n)@ and the next state, for @n@ from 1 to 'randomLimit'; 'Nothing' for any
-- other bound, which draws nothing and leaves the state where it was.
drawBelow ∷ Int64 → Word64 → Maybe (Int64, Word64)
drawBelow bound state
  | bound < 1 || bound > randomLimit = Nothing
  | otherwise = Just (fromIntegral (output `mod` fromIntegral bound), state')
  where
    (output, state') = nextRandom state
