-- | The representations behind "Hetoimasia.Scripting.Lua.Lending": what a
-- callback is lent, the record of which thread was lent what, and the scope a
-- scheduled owner runs around each of its VM's callbacks to lend and take back.
--
-- This is a hidden module of the adapter. The public module re-exports the
-- operations over 'LentCollection' without its constructor and the refusal type
-- with its own, and the scheduled owner's run action alone builds a
-- 'lendingScope'. A client cannot make a 'LentCollection', so it can only be
-- given one by the callback it was lent to.
--
-- = The record
--
-- A scheduled owner's VM runs each callback on a thread of its own. The scope
-- enters that thread in one process-wide table, keyed by the thread, for exactly
-- the callback's duration, and removes it when the callback ends however it
-- ends. A binding's action finds what its own callback was lent by asking for its
-- own thread: a thread that is not running a lending callback finds nothing, and
-- a thread cannot find another thread's loan. The table holds a loan per
-- callback, not per VM, so a later callback of the same VM is lent a loan of its
-- own, and a loan kept from an earlier one is a different value that has ended.
--
-- = Who may present a loan
--
-- Presenting a loan asks three questions before anything else happens, and an
-- operation that fails any of them has no effect. Has the callback it was lent to
-- returned? Is the presenting thread one of the VM's recorded callback threads,
-- by the same record the VM uses to refuse an operation re-entered from a
-- callback? And is it the thread this loan was lent to? A thread the callback
-- started fails the second, another VM's callback fails it too, and a later
-- callback of this VM fails the first because its predecessor's loan ended. The
-- identity is never the callback's own claim: the loan keeps no thread the VM
-- did not record, because the scope runs inside the VM's record of the thread.
--
-- The foundation capability behind a loan is itself lent for the callback's
-- duration, and so is revoked on every exit from it: a loan that somehow reached
-- the foundation's operations after the callback would meet
-- 'Hetoimasia.Foundation.Resource.OwnedCollection.CapabilityStale' there.
module Hetoimasia.Scripting.Lua.Lending.Loan
  ( LentCollection (..)
  , LendingRefused (..)
  , lendingScope
  , loanOfThisThread
  , presenting
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Exception (Exception, finally)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Resource.OwnedCollection
  ( OwnedCollection
  , OwnerCapability
  , lendCapability
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (CallbackScope (CallbackScope), CallbackSite (siteIsCallback))
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import System.IO.Unsafe (unsafePerformIO)

-- | A scheduled owner's collection, lent to one callback of its VM.
--
-- It is valid for that callback, on its thread, from the moment the callback
-- starts until it returns. It is never a Lua value.
data LentCollection = LentCollection
  { lentOwned ∷ !OwnedCollection
  , lentCapability ∷ !OwnerCapability
    -- ^ The foundation capability lent for this callback and revoked with it.
  , lentThread ∷ !ThreadId
    -- ^ The thread the callback runs on.
  , lentActive ∷ !(IORef Bool)
    -- ^ Whether the callback is still running.
  , lentRecorded ∷ !(IO Bool)
    -- ^ Whether the calling thread is one of the VM's recorded callbacks.
  }

-- | Why a collection was not lent to the thread that used it.
data LendingRefused
  = -- | The thread is not running a callback of an owner that lends a
    -- collection, so there is nothing to find.
    NoLoan
  | -- | The callback the collection was lent to has returned.
    LoanEnded
  | -- | The collection was lent to a different thread: not the callback it was
    -- lent to, whether a thread that callback started, another VM's callback, or
    -- any other thread.
    LoanElsewhere
  deriving (Eq, Show)

instance Exception LendingRefused

-- | Every loan being lent right now, by the thread of the callback it was lent
-- to.
loans ∷ IORef (Map ThreadId LentCollection)
loans = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE loans #-}

-- | The scope an owner runs around each of its VM's callbacks to lend its
-- collection: the loan exists exactly while the callback runs, on the callback's
-- thread, and is ended however the callback ends.
--
-- The owner holds the capability on its own thread, and each callback is lent a
-- capability derived from it, so revoking one callback's loan touches no other.
lendingScope ∷ OwnedCollection → OwnerCapability → CallbackScope
lendingScope collection capability = CallbackScope $ \site action → do
  self ← myThreadId
  lendCapability capability $ \lent → do
    active ← newIORef True
    let loan = LentCollection collection lent self active (siteIsCallback site)
    earlier ← atomicModifyIORef' loans (\held → (Map.insert self loan held, Map.lookup self held))
    action `finally` do
      writeIORef active False
      atomicModifyIORef' loans $ \held →
        (maybe (Map.delete self held) (\kept → Map.insert self kept held) earlier, ())

-- | What the calling thread's callback was lent, if it is running one that was.
loanOfThisThread ∷ IO (Maybe LentCollection)
loanOfThisThread = do
  self ← myThreadId
  Map.lookup self <$> readIORef loans

-- | Run an operation on the loan's collection, presenting its capability, after
-- the loan has been checked. A refusal is raised before the operation has any
-- effect.
presenting
  ∷ HasCallStack
  ⇒ Text
  → LentCollection
  → (OwnedCollection → OwnerCapability → IO a)
  → IO a
presenting name loan use = do
  active ← readIORef (lentActive loan)
  unless active (refuse name LoanEnded)
  self ← myThreadId
  recorded ← lentRecorded loan
  unless (recorded && self == lentThread loan) (refuse name LoanElsewhere)
  use (lentOwned loan) (lentCapability loan)

refuse ∷ HasCallStack ⇒ Text → LendingRefused → IO a
refuse name = throwFailure runtimeComponent (operation name) []
