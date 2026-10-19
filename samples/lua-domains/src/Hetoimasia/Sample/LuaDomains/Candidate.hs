-- | The tick-local candidate state (requirements 4, 5, 8 and 12): everything one tick may change
-- before it is committed, as a pure value.
--
-- = What a tick does
--
-- 1. 'beginCandidate' takes the committed world and the tick's sealed intentions, in the order of
--    their places, and revalidates each against the /evolving/ candidate: an intention is stale
--    when its session is not the world's or when the entity's version in the candidate, which the
--    tick's earlier applied intentions have already moved, is not the version it carried. Two
--    intentions for one entity with the same version therefore apply the first and reject the
--    second. An applied intention moves its entity in the candidate at once, so gameplay reads
--    the world with the tick's intentions in it.
-- 2. Gameplay reads the candidate through bindings. The random stream advances in the candidate
--    only ('draw'); the committed stream does not move.
-- 3. Gameplay stages moves into a bounded batch ('stage'). The batch changes nothing: it is not
--    visible to gameplay's own reads, and it is applied by the commit.
-- 4. Gameplay marks its work finished ('finish').
-- 5. 'commit' applies the staged moves in the order they were staged, advances the tick and
--    answers the world and the tick's dispositions, which the driver publishes together.
--
-- A candidate that is never committed — a tick that is held, or whose work did not finish —
-- changes nothing: the committed world, its stream and the dispositions are exactly what the last
-- completed tick left. The candidate is owned by the driver, which makes it and discards it, and is
-- written, between the two, by the gameplay owner's bindings only.
module Hetoimasia.Sample.LuaDomains.Candidate
  ( Candidate (..)
  , Move (..)
  , beginCandidate
  , StagingRefusal (..)
  , stage
  , draw
  , finish
  , commit
  ) where

import Data.Int (Int64)
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundEntities, boundStaging, boundStaleListed), deltaWithin)
import Hetoimasia.Sample.LuaDomains.Intention
  ( Dispositions (..)
  , Intention (..)
  , Placement
  , Stale (..)
  , StaleReason (..)
  , noDispositions
  )
import Hetoimasia.Sample.LuaDomains.World (World (..), drawBelow, entityAt, entityVersion, moveEntity)

-- | One staged effect: move an entity by a delta.
data Move = Move
  { moveEntityIndex ∷ !Int
  , moveDx ∷ !Int64
  , moveDy ∷ !Int64
  }
  deriving (Eq, Show)

-- | One tick's working state.
data Candidate = Candidate
  { candidateTick ∷ !Word64
    -- ^ The tick being computed: the committed tick plus one.
  , candidateWorld ∷ !World
    -- ^ The committed world with the tick's applied intentions in it. Its tick and stream are
    -- still the committed ones.
  , candidateRandom ∷ !Word64
    -- ^ The stream's state as the tick's draws have left it.
  , candidateStaged ∷ ![Move]
    -- ^ The staging batch, newest first.
  , candidateFinished ∷ !Bool
    -- ^ Whether gameplay said its work for the tick is done.
  , candidateDispositions ∷ !Dispositions
  }
  deriving (Eq, Show)

-- | Begin a tick: revalidate its intentions, in order, against the evolving candidate and apply
-- the ones that still hold.
beginCandidate ∷ Bounds → World → Word64 → [(Placement, Intention)] → Candidate
beginCandidate bounds committed tick sealed =
  Candidate
    { candidateTick = tick
    , candidateWorld = world
    , candidateRandom = worldRandom committed
    , candidateStaged = []
    , candidateFinished = False
    , candidateDispositions =
        noDispositions
          { dispApplied = reverse appliedNewestFirst
          , dispStale = take (boundStaleListed bounds) staleInOrder
          , dispStaleOmitted = max 0 (length staleInOrder - boundStaleListed bounds)
          }
    }
  where
    (world, appliedNewestFirst, staleNewestFirst) = foldl step (committed, [], []) sealed
    -- The list keeps the earliest places; the rest are only counted.
    staleInOrder = reverse staleNewestFirst
    step (current, ok, bad) (place, intention) = case reason current intention of
      Just why → (current, ok, Stale place intention why : bad)
      Nothing → (moveEntity (intentEntity intention) (intentDx intention) (intentDy intention) current, place : ok, bad)
    reason current intention
      | intentSession intention /= worldSession current = Just StaleSession
      | otherwise = case entityAt current (intentEntity intention) of
          Just entity | entityVersion entity == intentVersion intention → Nothing
          _ → Just StaleVersion

-- | Why a move was not staged. Each is a recoverable answer to the script.
data StagingRefusal
  = -- | The batch holds its bound.
    StagingFull
  | -- | The entity is not one the world has.
    StagingNoEntity
  | -- | A component of the delta is over the bound.
    StagingDelta
  deriving (Eq, Show)

-- | Stage a move. Nothing changes the world: the batch is applied only by 'commit'.
stage ∷ Bounds → Move → Candidate → Either StagingRefusal Candidate
stage bounds move candidate
  | moveEntityIndex move < 0 || moveEntityIndex move >= boundEntities bounds = Left StagingNoEntity
  | not (deltaWithin bounds (moveDx move) && deltaWithin bounds (moveDy move)) = Left StagingDelta
  | length (candidateStaged candidate) >= boundStaging bounds = Left StagingFull
  | otherwise = Right candidate {candidateStaged = move : candidateStaged candidate}

-- | A draw from @[0, n)@, advancing the candidate's stream; 'Nothing' for a bound the stream does
-- not accept, which draws nothing.
draw ∷ Int64 → Candidate → Maybe (Int64, Candidate)
draw bound candidate = case drawBelow bound (candidateRandom candidate) of
  Nothing → Nothing
  Just (value, state) → Just (value, candidate {candidateRandom = state})

-- | Gameplay's work for the tick is done.
finish ∷ Candidate → Candidate
finish candidate = candidate {candidateFinished = True}

-- | The world the tick commits and the dispositions it publishes with it: the staged moves applied
-- in the order they were staged, the tick and the stream advanced.
commit ∷ Candidate → (World, Dispositions)
commit candidate =
  ( applied {worldTick = candidateTick candidate, worldRandom = candidateRandom candidate}
  , candidateDispositions candidate
  )
  where
    applied =
      foldl
        (\world (Move index dx dy) → moveEntity index dx dy world)
        (candidateWorld candidate)
        (reverse (candidateStaged candidate))
