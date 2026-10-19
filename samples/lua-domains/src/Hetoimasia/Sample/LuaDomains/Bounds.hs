-- | Every bound the sample documents, in one record, so that the Lua facade, the
-- admission seam, the staging batch and the snapshot's disposition lists all read the
-- same numbers.
--
-- Nothing here is a game design: the world is a handful of entities with integer
-- positions, and these are the limits that keep each queue, batch and list finite.
module Hetoimasia.Sample.LuaDomains.Bounds
  ( Bounds (..)
  , defaultBounds
  , BoundsProblem (..)
  , validateBounds
  , deltaWithin
  , maxEntities
  , maxDeltaLimit
  , positionLimit
  , randomLimit
  ) where

import Data.Int (Int64)

-- | The most entities a world may have (requirement 4).
maxEntities ∷ Int
maxEntities = 64

-- | The largest delta bound a configuration may choose.
maxDeltaLimit ∷ Int
maxDeltaLimit = 1000

-- | A position is clamped to the range from the negative of this to this, so that no
-- sequence of moves can overflow a 64-bit integer.
positionLimit ∷ Int64
positionLimit = 1000000000

-- | The largest bound a random draw accepts: @rand.below(n)@ answers a value in
-- @[0, n)@ for @n@ from 1 to this.
randomLimit ∷ Int64
randomLimit = 2147483648

-- | The sample's limits.
data Bounds = Bounds
  { boundEntities ∷ !Int
    -- ^ How many entities the world has: from 1 to 'maxEntities'.
  , boundDelta ∷ !Int
    -- ^ The largest absolute value of either component of a move.
  , boundQueue ∷ !Int
    -- ^ The most intentions accepted and not yet settled by a commit, across every tick
    -- that holds any: the open tick's, and the tick in flight's until its commit.
  , boundPlaces ∷ !Int
    -- ^ The most intentions one tick holds, one per place.
  , boundStaleListed ∷ !Int
    -- ^ The most stale rejections one snapshot lists; the rest are counted.
  , boundStaging ∷ !Int
    -- ^ The most moves one tick's staging batch holds.
  }
  deriving (Eq, Show)

-- | Eight entities, moves of at most eight in each direction, twelve intentions waiting
-- at most, eight to a tick, four stale rejections listed and four staged moves.
defaultBounds ∷ Bounds
defaultBounds =
  Bounds
    { boundEntities = 8
    , boundDelta = 8
    , boundQueue = 12
    , boundPlaces = 8
    , boundStaleListed = 4
    , boundStaging = 4
    }

-- | Whether one component of a move is within the bound on deltas. Two direct comparisons, so that
-- no value can slip past: the absolute value of the minimum integer is itself negative, and a check
-- written with it accepts the one value it most needs to refuse.
deltaWithin ∷ Bounds → Int64 → Bool
deltaWithin bounds delta = delta >= negate limit && delta <= limit
  where
    limit = fromIntegral (boundDelta bounds)

-- | What is wrong with a configuration.
data BoundsProblem
  = -- | The named bound is below one.
    BoundBelowOne !String !Int
  | -- | More entities than 'maxEntities'.
    TooManyEntities !Int
  | -- | A delta bound over 'maxDeltaLimit'.
    DeltaTooLarge !Int
  deriving (Eq, Show)

-- | Every problem with a configuration, so that a refusal names all of them.
validateBounds ∷ Bounds → [BoundsProblem]
validateBounds bounds =
  [ BoundBelowOne name value
  | (name, value) ←
      [ ("entities", boundEntities bounds)
      , ("delta", boundDelta bounds)
      , ("queue", boundQueue bounds)
      , ("places", boundPlaces bounds)
      , ("stale-listed", boundStaleListed bounds)
      , ("staging", boundStaging bounds)
      ]
  , value < 1
  ]
    <> [TooManyEntities (boundEntities bounds) | boundEntities bounds > maxEntities]
    <> [DeltaTooLarge (boundDelta bounds) | boundDelta bounds > maxDeltaLimit]
