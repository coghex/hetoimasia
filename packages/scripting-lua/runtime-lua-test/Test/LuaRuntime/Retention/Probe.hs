-- | A retirement reading that counts how often it runs, and holds the engine at a gate the
-- first time, so that an example can inject exactly one conflicting commit while the engine is
-- polling it.
--
-- The counting is the same whatever the engine does with the reading: it is test-only
-- instrumentation that increments an 'IORef' from inside the transaction, so it counts every
-- execution, including the attempts that are rolled back and never commit anything. (A counter
-- kept in a 'TVar' would count only the attempts that commit.)
module Test.LuaRuntime.Retention.Probe
  ( Probe
  , Trace
  , newTrace
  , newProbe
  , newGatedProbe
  , instrument
  , instrumentAnswering
  , Answer (..)
  , answeredWith
  , awaitAnswer
  , awaitEntry
  , commitThen
  , totalRuns
  , awaitRuns
  , runsAfterCommit
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (STM)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import GHC.Conc (unsafeIOToSTM)
import Hetoimasia.Scripting.Lua.Provider (RetirementState (..))

-- | The order readings ran in, newest first, shared by the probes of one example.
newtype Trace = Trace (IORef [Text])

newTrace ∷ IO Trace
newTrace = Trace <$> newIORef []

-- | One reading's instrumentation.
data Probe = Probe
  { prName ∷ !Text
  , prTrace ∷ !Trace
  , prGated ∷ !Bool
  , prFirst ∷ !(IORef Bool)
    -- ^ Whether the next execution is the first.
  , prEntered ∷ !(MVar [Text])
    -- ^ Opened by the first execution, once it holds the gate: the trace as it found it.
  , prProceed ∷ !(MVar ())
    -- ^ Opened by the example after its conflicting commit, to let the first execution go on.
  , prCommitted ∷ !(IORef Bool)
  , prTotal ∷ !(IORef Int)
  , prAfter ∷ !(IORef Int)
  , prAnswers ∷ !(IORef [Answer])
    -- ^ What each execution that got as far as an answer answered, newest first.
  }

-- | A probe that only counts.
newProbe ∷ Trace → Text → IO Probe
newProbe = make False

-- | A probe whose first execution holds at a gate until the example lets it go.
newGatedProbe ∷ Trace → Text → IO Probe
newGatedProbe = make True

make ∷ Bool → Trace → Text → IO Probe
make gated trace name =
  Probe name trace gated
    <$> newIORef True
    <*> newEmptyMVar
    <*> newEmptyMVar
    <*> newIORef False
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef []

-- | The reading, counted and recorded in the trace before it runs, and held at the gate if this
-- is the first execution of a gated probe. What the reading itself reads comes after.
instrument ∷ Probe → STM a → STM a
instrument probe reading = do
  unsafeIOToSTM $ do
    atomicModifyIORef' (prTotal probe) (\n → (n + 1, ()))
    let Trace ref = prTrace probe
    atomicModifyIORef' ref (\held → (prName probe : held, ()))
    committed ← readIORef (prCommitted probe)
    when committed (atomicModifyIORef' (prAfter probe) (\n → (n + 1, ())))
  when (prGated probe) $ do
    first ← unsafeIOToSTM (atomicModifyIORef' (prFirst probe) (\held → (False, held)))
    when first . unsafeIOToSTM $ do
      let Trace ref = prTrace probe
      seen ← readIORef ref
      putMVar (prEntered probe) seen
      readMVar (prProceed probe)
  reading

-- | What an execution answered.
data Answer = AnsweredPending | AnsweredComplete | AnsweredFailed
  deriving (Eq, Show)

-- | The reading as 'instrument' runs it, and what it answered recorded once it has answered.
-- An execution that is still running, or that retried, or that raised, has answered nothing: an
-- example that waits for an answer waits for an execution that got as far as returning one.
instrumentAnswering ∷ Probe → STM RetirementState → STM RetirementState
instrumentAnswering probe reading = instrument probe $ do
  state ← reading
  unsafeIOToSTM $ atomicModifyIORef' (prAnswers probe) $ \held → (answer state : held, ())
  pure state
  where
    answer = \case
      ProviderPending → AnsweredPending
      ProviderComplete → AnsweredComplete
      ProviderFailed _ → AnsweredFailed

-- | How many executions answered this.
answeredWith ∷ Probe → Answer → IO Int
answeredWith probe wanted = length . filter (== wanted) <$> readIORef (prAnswers probe)

-- | Wait, without sleeping, until an execution has answered this.
awaitAnswer ∷ Probe → Answer → IO ()
awaitAnswer probe wanted = do
  found ← answeredWith probe wanted
  if found >= 1 then pure () else yield >> awaitAnswer probe wanted

-- | Wait until the gated probe's first execution holds the gate, and answer the trace it found:
-- its own entry first, then the readings that ran before it.
awaitEntry ∷ Probe → IO [Text]
awaitEntry = readMVar . prEntered

-- | Inject the one conflicting commit while the first execution holds the gate, and let it go
-- on. Everything the probe counts as running "after the commit" starts after this returns.
commitThen ∷ Probe → IO () → IO ()
commitThen probe commit = do
  commit
  writeIORef (prCommitted probe) True
  putMVar (prProceed probe) ()

-- | How many times the reading ran in all, including attempts that were rolled back.
totalRuns ∷ Probe → IO Int
totalRuns = readIORef . prTotal

-- | Wait, without sleeping, until the reading has run at least this many times.
awaitRuns ∷ Probe → Int → IO ()
awaitRuns probe wanted = do
  ran ← totalRuns probe
  if ran >= wanted then pure () else yield >> awaitRuns probe wanted

-- | How many times the reading started after the conflicting commit.
runsAfterCommit ∷ Probe → IO Int
runsAfterCommit = readIORef . prAfter
