-- | The representations behind "Hetoimasia.Scripting.Lua.Lending": the handle an
-- application gives a scheduled owner to lend through, what a callback is lent,
-- and the scope the owner runs around each of its VM's callbacks to lend and take
-- back.
--
-- This is a hidden module of the adapter. The public module re-exports the
-- handle and the operations over 'LentCollection' without its constructor and the
-- refusal type with its own, and the scheduled owner's run action alone builds a
-- 'lendingScope'. A client cannot make a 'LentCollection', so it can only be
-- given one by the callback it was lent to.
--
-- = The handle
--
-- A 'Lending' belongs to one owner. The application makes it, closes the
-- bindings that use the collection over it, and gives it to the owner it creates;
-- there is no registry of owners and no ambient lookup. The handle holds the loan
-- of the callback the owner's VM is running right now, if it is running one: an
-- owner's VM runs one callback at a time, because a callback cannot ask its own
-- VM for anything and the owner's thread is inside Lua until it returns. The
-- scope sets it when a callback starts and puts back what was there when it ends,
-- however it ends.
--
-- = Who may present a loan
--
-- Asking the handle for the loan says nothing about whether the asker may use it:
-- a thread a callback started can ask, and so can another VM's callback holding
-- the same handle by mistake. Presenting a loan asks three questions before
-- anything else happens, and an operation that fails any of them has no effect.
-- Has the callback it was lent to returned? Is the presenting thread one of the
-- VM's recorded callback threads, by the same record the VM uses to refuse an
-- operation re-entered from a callback? And is it the thread this loan was lent
-- to? A thread the callback started fails the second, another VM's callback fails
-- it too, and a later callback of this VM fails the first because its
-- predecessor's loan ended. The identity is never the callback's own claim: the
-- scope runs inside the VM's record of the thread.
--
-- The foundation capability behind a loan is itself lent for the callback's
-- duration, and so is revoked on every exit from it: a loan that somehow reached
-- the foundation's operations after the callback would meet
-- 'Hetoimasia.Foundation.Resource.OwnedCollection.CapabilityStale' there.
module Hetoimasia.Scripting.Lua.Lending.Loan
  ( Lending
  , newLending
  , bindLending
  , sameLending
  , currentLoan
  , LentCollection (..)
  , LendingRefused (..)
  , lendingScope
  , presenting
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Exception (Exception, finally)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
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
  = -- | The handle's owner is running no callback, so nothing is lent.
    NoLoan
  | -- | The callback the collection was lent to has returned.
    LoanEnded
  | -- | The collection was lent to a different thread: not the callback it was
    -- lent to, whether a thread that callback started, another VM's callback, or
    -- any other thread.
    LoanElsewhere
  | -- | The handle already belongs to an owner. A handle serves one owner.
    LendingInUse
  deriving (Eq, Show)

instance Exception LendingRefused

-- | What an application gives one scheduled owner to lend through, and its
-- bindings use to find what their callback was lent.
data Lending = Lending
  { lendingCurrent ∷ !(IORef (Maybe LentCollection))
    -- ^ The loan of the callback the owner's VM is running, if it is running one.
  , lendingBound ∷ !(IORef Bool)
    -- ^ Whether an owner has taken the handle.
  }

-- | A handle that no owner has taken yet and that holds no loan.
newLending ∷ IO Lending
newLending = Lending <$> newIORef Nothing <*> newIORef False

-- | Take the handle for an owner. A handle serves one owner, so a second is
-- refused with 'LendingInUse' before it does anything.
bindLending ∷ HasCallStack ⇒ Lending → IO ()
bindLending lending = do
  taken ← atomicModifyIORef' (lendingBound lending) (\held → (True, held))
  if taken then refuse "bind-lending" LendingInUse else pure ()

-- | Whether two handles are the same one.
sameLending ∷ Lending → Lending → Bool
sameLending a b = lendingBound a == lendingBound b

-- | What the handle's owner is lending right now, if its VM is running a callback.
currentLoan ∷ Lending → IO (Maybe LentCollection)
currentLoan = readIORef . lendingCurrent

-- | The scope an owner runs around each of its VM's callbacks to lend its
-- collection: the loan exists exactly while the callback runs, on the callback's
-- thread, and is ended however the callback ends.
--
-- The owner holds the capability on its own thread, and each callback is lent a
-- capability derived from it, so revoking one callback's loan touches no other.
lendingScope ∷ Lending → OwnedCollection → OwnerCapability → CallbackScope
lendingScope lending collection capability = CallbackScope $ \site action → do
  self ← myThreadId
  lendCapability capability $ \lent → do
    active ← newIORef True
    let loan = LentCollection collection lent self active (siteIsCallback site)
    earlier ← atomicModifyIORef' (lendingCurrent lending) (\held → (Just loan, held))
    action `finally` do
      writeIORef active False
      writeIORef (lendingCurrent lending) earlier

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
