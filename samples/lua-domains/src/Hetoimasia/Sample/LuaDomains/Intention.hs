{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | What the UI asks of gameplay, what it is answered, and what becomes of it (requirements 6
-- and 8).
--
-- An intention is a bounded action — move an entity by a delta — carrying the session it acts in,
-- the committed tick of the view it acted on, the entity, and the entity's version in that view.
-- The version is what lets gameplay tell, at the intention's own tick, whether the world the UI
-- looked at is still the world there is (P-2).
--
-- = The answers
--
-- An intention is answered once, at once, and never by waiting for gameplay:
--
-- * 'Accepted' only once the gameplay queue has taken it for a tick that has not started, with
--   the 'Placement' it holds;
-- * 'Full' when the queue's bound or the tick's places are all taken;
-- * 'Closed' when no tick that has not started is left to take it (the finite session's last tick
--   has begun);
-- * 'Refused' for a value outside the application's bounds, naming which.
--
-- The reasons a script sees are the fixed words of 'answerReason', never text the script wrote.
module Hetoimasia.Sample.LuaDomains.Intention
  ( -- * What crosses
    Submitted (..)
  , Intention (..)
  , Refusal (..)
  , validate
  , refusalReason
    -- * Answers
  , Answer (..)
  , answerReason
  , malformedReason
  , fullReason
  , closedReason
    -- * Places and dispositions
  , Placement (..)
  , StaleReason (..)
  , Stale (..)
  , Dispositions (..)
  , noDispositions
  ) where

import Control.DeepSeq (NFData)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundEntities), deltaWithin)

-- | The six integers the UI's binding is handed, before any bound is applied.
data Submitted = Submitted
  { submittedSession ∷ !Int64
  , submittedTick ∷ !Int64
  , submittedEntity ∷ !Int64
  , submittedVersion ∷ !Int64
  , submittedDx ∷ !Int64
  , submittedDy ∷ !Int64
  }
  deriving (Eq, Show)

-- | An intention within the application's bounds.
data Intention = Intention
  { intentSession ∷ !Word64
  , intentTick ∷ !Word64
    -- ^ The committed tick of the view it acted on. Informational: staleness is decided by the
    -- session and the entity's version alone.
  , intentEntity ∷ !Int
  , intentVersion ∷ !Word64
  , intentDx ∷ !Int64
  , intentDy ∷ !Int64
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Which bound a submitted value broke.
data Refusal
  = RefusedSession
  | RefusedTick
  | RefusedEntity
  | RefusedVersion
  | RefusedDelta
  deriving (Eq, Show, Enum, Bounded)

-- | Apply the bounds: the session, tick and version are not negative, the entity is one the world
-- has, and each component of the delta is within the bound.
validate ∷ Bounds → Submitted → Either Refusal Intention
validate bounds submitted
  | submittedSession submitted < 0 = Left RefusedSession
  | submittedTick submitted < 0 = Left RefusedTick
  | submittedEntity submitted < 0 || submittedEntity submitted >= fromIntegral (boundEntities bounds) = Left RefusedEntity
  | submittedVersion submitted < 0 = Left RefusedVersion
  | not (deltaWithin bounds (submittedDx submitted) && deltaWithin bounds (submittedDy submitted)) = Left RefusedDelta
  | otherwise =
      Right
        Intention
          { intentSession = fromIntegral (submittedSession submitted)
          , intentTick = fromIntegral (submittedTick submitted)
          , intentEntity = fromIntegral (submittedEntity submitted)
          , intentVersion = fromIntegral (submittedVersion submitted)
          , intentDx = submittedDx submitted
          , intentDy = submittedDy submitted
          }

-- | The reason a refusal answers with: a fixed word.
refusalReason ∷ Refusal → Text
refusalReason = \case
  RefusedSession → "session"
  RefusedTick → "tick"
  RefusedEntity → "entity"
  RefusedVersion → "version"
  RefusedDelta → "delta"

-- | Where an accepted intention is: the tick it was accepted for, and its place among that tick's
-- intentions. The tick's intentions are applied in the order of their places.
data Placement = Placement
  { placeTick ∷ !Word64
  , placeOrder ∷ !Word32
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | What the UI is answered.
data Answer
  = Accepted !Placement
  | Full
  | Closed
  | Refused !Refusal
  deriving (Eq, Show)

-- | The reason a script is told for a refusal to accept, and nothing for an acceptance.
answerReason ∷ Answer → Maybe Text
answerReason = \case
  Accepted _ → Nothing
  Full → Just fullReason
  Closed → Just closedReason
  Refused refusal → Just (refusalReason refusal)

-- | What the facade answers for a call whose arity or types are wrong.
malformedReason ∷ Text
malformedReason = "malformed"

fullReason ∷ Text
fullReason = "full"

closedReason ∷ Text
closedReason = "closed"

-- | Why an accepted intention was rejected at its tick.
data StaleReason
  = -- | The world's session is not the one the intention acted in.
    StaleSession
  | -- | The entity's version at the tick is not the one the intention carried.
    StaleVersion
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One stale rejection, as a snapshot lists it.
data Stale = Stale
  { stalePlace ∷ !Placement
  , staleIntention ∷ !Intention
  , staleReason ∷ !StaleReason
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The terminal dispositions of one tick's intentions, as its snapshot carries them. Every
-- accepted intention of the tick is exactly one of: in 'dispApplied', listed in 'dispStale', or
-- counted in 'dispStaleOmitted' because the list was full.
data Dispositions = Dispositions
  { dispApplied ∷ ![Placement]
    -- ^ The places applied, in order. The tick holds at most the bound on places, so this is
    -- bounded by it.
  , dispStale ∷ ![Stale]
    -- ^ The stale rejections, in order, at most the bound on listed ones.
  , dispStaleOmitted ∷ !Int
    -- ^ How many stale rejections did not fit in the list.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | A tick with nothing to settle.
noDispositions ∷ Dispositions
noDispositions = Dispositions [] [] 0
