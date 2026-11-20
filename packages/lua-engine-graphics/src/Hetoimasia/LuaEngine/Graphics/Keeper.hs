-- | The graphics session's keeper of work a shorter scope hands over when it ends with something only the host can
-- still prove: a terrain view service's retirements, whose chunks wait on a release barrier, an adoption or a GPU batch
-- that the view scope must not wait for on its way out.
--
-- = Ownership
--
-- | State | Owner | Writers / thread | Readers | Lifetime and disposal |
-- | --- | --- | --- | --- | --- |
-- | The kept jobs | the keeper, made with the graphics session ('withKeeper') | 'keepWork' (the handing scope, in its own transaction); the keeper's thread | 'keeperHolding' | a job leaves when it is done, or when it can never move, after its end runs; at the keeper's end every job left runs its end |
-- | The keeper's thread | the session's scope ('withResource') | started at the keeper's acquisition, stopped and joined at its release | | joined before the session's dependencies unwind |
--
-- A job is handed over in one transaction with whatever marks its old owner done, so it always has exactly one owner.
-- The keeper's thread takes one step of one ready job at a time, never waiting on anything but the jobs' own ready,
-- done and stuck conditions and its own stop. Its release stops the thread, joins it, and runs every remaining job's end
-- in one transaction each: an end keeps what cannot be proved as its owner's evidence (charged) and waits for nothing,
-- so the session's exit never waits on GPU completion or an adoption.
module Hetoimasia.LuaEngine.Graphics.Keeper
  ( Keeper
  , KeptWork (..)
  , withKeeper
  , keepWork
  , keeperHolding
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM
import Control.Exception (finally, uninterruptibleMask_)
import Control.Monad (forM_, void)
import Hetoimasia.Foundation.Resource (withResource)

-- | One piece of handed-over work, as transactions over its own state: whether a step can move now, the step, whether
-- nothing is left, whether it can never move again (its host ended), and its end (what is left kept as evidence, what
-- it still charges returned or kept), which runs exactly once.
data KeptWork = KeptWork
  { keptReady ∷ STM Bool
  , keptStep ∷ STM ()
  , keptDone ∷ STM Bool
  , keptStuck ∷ STM Bool
  , keptEnd ∷ STM ()
  }

-- | The session's keeper.
data Keeper = Keeper
  { keeperJobs ∷ !(TVar [KeptWork])
  , keeperOpen ∷ !(TVar Bool)
  }

-- | Run the body with a keeper whose thread runs until the body's scope ends: its release stops and joins the thread,
-- then ends every job left, keeping what it cannot prove as its owner's evidence.
withKeeper ∷ (Keeper → IO a) → IO a
withKeeper body = do
  keeper ← Keeper <$> newTVarIO [] <*> newTVarIO True
  done ← newEmptyMVar
  withResource
    (void (forkIOWithUnmask (\unmask → unmask (run keeper) `finally` putMVar done ())))
    ( \() → uninterruptibleMask_ $ do
        atomically (writeTVar (keeperOpen keeper) False)
        readMVar done
        left ← atomically (readTVar (keeperJobs keeper) <* writeTVar (keeperJobs keeper) [])
        forM_ left (atomically . keptEnd)
    )
    (\() → body keeper)

-- | Hand a job to the keeper, in the caller's transaction: 'False', taking nothing, once the keeper has ended (the
-- caller keeps the job, and its evidence, itself).
keepWork ∷ Keeper → KeptWork → STM Bool
keepWork keeper job = do
  open ← readTVar (keeperOpen keeper)
  if open then True <$ modifyTVar' (keeperJobs keeper) (<> [job]) else pure False

-- | How many jobs the keeper holds. Read-only.
keeperHolding ∷ Keeper → STM Int
keeperHolding keeper = length <$> readTVar (keeperJobs keeper)

-- One job's next move, or the keeper's stop.
data Move = Stop | Ended | Stepped

run ∷ Keeper → IO ()
run keeper = loop
  where
    loop =
      atomically next >>= \case
        Stop → pure ()
        _ → loop
    next = (Stop <$ (readTVar (keeperOpen keeper) >>= check . not)) `orElse` (readTVar (keeperJobs keeper) >>= pick [])
    -- the first job that is done or stuck ends and leaves; otherwise the first that can move takes one step
    pick kept = \case
      [] → retry
      job : rest → do
        finished ← (||) <$> keptDone job <*> keptStuck job
        if finished
          then Ended <$ (keptEnd job >> writeTVar (keeperJobs keeper) (reverse kept <> rest))
          else do
            ready ← keptReady job
            if ready then Stepped <$ keptStep job else pick (job : kept) rest
