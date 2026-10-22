-- | The admission gate of a content root.
--
-- Operations on one root run on any number of threads at once; the root's
-- descriptor may be closed only after every one of them has retired. The
-- foundation's capability-owned collection serializes its users and rejects a
-- second concurrent borrow, which is the wrong shape for readers that later
-- workers run in parallel, so the root keeps this small gate of its own.
--
-- State: a counter of admitted operations and a phase, in one 'TVar'.
--
-- +-------------+------------------------------------------------------------+
-- | Phase       | Meaning                                                    |
-- +=============+============================================================+
-- | Admitting n | Operations may be admitted; @n@ are inside.                |
-- | Draining n  | Admission is closed; @n@ admitted operations are finishing.|
-- | Shut        | Admission is closed and no operation is inside.            |
-- +-------------+------------------------------------------------------------+
--
-- Owner: the root's scope. Writers: 'withAdmitted' (admit and retire, on the
-- operation's thread) and 'closeAdmission' / 'awaitDrained' (the scope's exit).
-- Lifetime: the scope. Disposal: the gate ends 'Shut' and is never reopened.
module Hetoimasia.Content.Internal.Gate
  ( Gate
  , newGate
  , withAdmitted
  , borrowCount
  , closeAdmission
  , awaitDrained
  ) where

import Control.Concurrent.STM
  ( TVar
  , atomically
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (SomeException, mask, rethrowIO, throwIO, tryWithContext)
import Hetoimasia.Content.Internal.Types (ContentDefect (..), Defect (RootNotAdmitting))

data Phase = Admitting !Int | Draining !Int | Shut

newtype Gate = Gate (TVar Phase)

newGate ∷ IO Gate
newGate = Gate <$> newTVarIO (Admitting 0)

-- | Run an operation inside the gate.
--
-- Admission and retirement are non-blocking transactions, and the retirement is
-- installed in the same masked step as the admission, so an asynchronous
-- exception can never land between the count and the handler that gives it back.
-- The operation runs with the caller's masking state restored; it is retired on
-- every exit, including cancellation, and its own exception is rethrown with its
-- context. A gate that is not admitting refuses with a 'ContentDefect'.
withAdmitted ∷ Gate → IO r → IO r
withAdmitted (Gate phase) operation = mask $ \restore → do
  admitted ← atomically $ do
    current ← readTVar phase
    case current of
      Admitting n → writeTVar phase (Admitting (n + 1)) >> pure True
      _ → pure False
  if admitted
    then do
      outcome ← tryWithContext @SomeException (restore operation)
      atomically $ do
        current ← readTVar phase
        case current of
          Admitting n → writeTVar phase (Admitting (n - 1))
          Draining n → writeTVar phase (Draining (n - 1))
          Shut → pure ()
      either rethrowIO pure outcome
    else throwIO (ContentDefect RootNotAdmitting)

-- | How many operations are inside right now.
borrowCount ∷ Gate → IO Int
borrowCount (Gate phase) =
  readTVarIO phase >>= \case
    Admitting n → pure n
    Draining n → pure n
    Shut → pure 0

-- | Stop admitting. Idempotent.
closeAdmission ∷ Gate → IO ()
closeAdmission (Gate phase) = atomically $ do
  current ← readTVar phase
  case current of
    Admitting n → writeTVar phase (Draining n)
    _ → pure ()

-- | Wait until every admitted operation has retired, then shut the gate.
-- It blocks for as long as an operation is inside, and nothing shortens that
-- wait: the caller runs it uninterruptibly, so a root is never closed under a
-- borrow, and an operation that never returns holds its root's exit.
awaitDrained ∷ Gate → IO ()
awaitDrained (Gate phase) = atomically $ do
  current ← readTVar phase
  case current of
    Admitting _ → pure ()
    Draining 0 → writeTVar phase Shut
    Draining _ → retry
    Shut → pure ()
