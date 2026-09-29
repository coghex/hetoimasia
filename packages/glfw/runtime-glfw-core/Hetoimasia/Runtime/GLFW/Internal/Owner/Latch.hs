-- | How the graphics owner records a failure: once in its latch, for
-- notification, and once in exactly one store, as evidence.
--
-- It runs on the owner thread, which is the only writer of the latch and the
-- retained failures in "Hetoimasia.Runtime.GLFW.Internal.Owner.State". The
-- supervision sentinel and the protected exit read them; see
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.Exit" for how the two stores and
-- the latch are reported exactly once between them.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Latch
  ( latchFailure
  , retainFailure
  , isAsynchronous
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, writeTVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , rethrowIO
  )
import Control.Monad (unless, when)
import Data.Maybe (isJust, isNothing)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (closeOwnerPublications)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( GraphicsOwner (..)
  , LatchSource (..)
  , Latched (..)
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Wake (wakeGraphicsHost)

-- | Latch a terminal owner failure as soon as it is known, and close the
-- admission it affects, without waiting for retirement to finish.
--
-- A cancellation is not a terminal failure and is never latched: it is what an
-- owner asked to stop is entitled to receive, the drain defers it, and the
-- worker's own outcome already carries it. Admission closes for it all the
-- same, because a cancelled owner is one no further target may be handed to.
latchFailure ∷ GraphicsOwner scene → Either (ExceptionWithContext SomeException) a → IO ()
latchFailure owner = \case
  Right _ → pure ()
  Left failure@(ExceptionWithContext _ exception) → atomically $ do
    unless (isAsynchronous exception) $ do
      held ← readTVar (ownerLatch owner)
      when (isNothing held) (writeTVar (ownerLatch owner) (Just (Latched LatchedByRunEnd failure)))
    -- Every publication into the handoff, not only the lifetime port: an
    -- owner that has ended reads none of them again, and a publisher told its
    -- demand or its scene was accepted by one would be told a falsehood.
    closeOwnerPublications (ownerHandoff' owner)

isAsynchronous ∷ SomeException → Bool
isAsynchronous failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

-- | Keep one failure the owner found while it kept running.
--
-- A cancellation is never kept here: it ends the run action and reaches the
-- drain as one, where it is deferred rather than recorded as the owner's
-- terminal failure.
--
-- Whether a synchronous one is /latched/ follows the established disposition,
-- because that is the question the disposition answers: a 'Required' graphics
-- owner's failure stops the run, and an 'Optional' one leaves the component
-- unavailable and the run going. Neither is ever permission to destroy
-- anything, and the target it happened to keeps its window either way.
retainFailure ∷ GraphicsOwner scene → ExceptionWithContext SomeException → IO ()
retainFailure owner failure@(ExceptionWithContext _ exception)
  | isAsynchronous exception = rethrowIO failure
  | otherwise = do
      atomically $ do
        -- Notification and evidence are separate. The latch keeps the first
        -- failure, because that is what a supervision sentinel can wait on;
        -- the retained list keeps every one of them with its own context,
        -- because a drain that failed three operations has three things to
        -- report and a latch would keep one.
        held ← readTVar (ownerLatch owner)
        when (isNothing held) (writeTVar (ownerLatch owner) (Just (Latched LatchedWhileRunning failure)))
        modifyTVar' (ownerRetained owner) (\kept → take (ownerRetainedLimit owner) (kept <> [failure]))
        -- Terminal for a required owner, so the admission it affects closes
        -- here rather than at the exit: no further target may be handed to an
        -- owner that is about to retire, and none may be constructed by the
        -- round this failure interrupted. The latch stays for supervision.
        closeOwnerPublications (ownerHandoff' owner)
      -- The main thread is told at once, so a checkpoint can raise while
      -- retirement is still to come.
      wakeGraphicsHost owner
