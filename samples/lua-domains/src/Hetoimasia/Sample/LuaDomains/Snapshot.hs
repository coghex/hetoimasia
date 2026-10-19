{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The value gameplay publishes once per completed tick (requirement 5).
--
-- It carries the session's identity, the completed tick, the whole committed world, the
-- dispositions of the intentions the tick settled and the session's status. It is published with
-- the foundation's latest-value snapshot, one revision per commit, in the transaction that commits
-- the tick, so a reader sees a world with its own tick, dispositions and status and never a mixture
-- of two ticks.
--
-- The UI reads it through the capture its owner takes at the start of each segment
-- ("Hetoimasia.Sample.LuaDomains.Shared.captureView"); nothing else reads it in production.
module Hetoimasia.Sample.LuaDomains.Snapshot
  ( GameSnapshot (..)
  , SessionStatus (..)
  , initialSnapshot
  ) where

import Control.DeepSeq (NFData)
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Generics (Generic)
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions, noDispositions)
import Hetoimasia.Sample.LuaDomains.World (World (worldSession))

-- | How the session is. The type admits a failed session, which a later slice sets; in this slice
-- only 'Running' is reachable.
data SessionStatus
  = Running
  | -- | The session failed, and why. Nothing sets it yet.
    Failed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | One committed tick.
data GameSnapshot = GameSnapshot
  { snapSession ∷ !Word64
  , snapTick ∷ !Word64
    -- ^ The completed tick; zero before the first.
  , snapWorld ∷ !World
  , snapDispositions ∷ !Dispositions
    -- ^ What the tick settled: the applied places and the stale rejections.
  , snapStatus ∷ !SessionStatus
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The snapshot before the first tick, which the snapshot holds as its initial value.
initialSnapshot ∷ World → GameSnapshot
initialSnapshot world =
  GameSnapshot
    { snapSession = worldSession world
    , snapTick = 0
    , snapWorld = world
    , snapDispositions = noDispositions
    , snapStatus = Running
    }
