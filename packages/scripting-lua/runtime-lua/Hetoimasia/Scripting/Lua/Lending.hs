-- | A resource collection lent to a scheduled owner's synchronous Lua callbacks.
--
-- This is LUA-25. A binding's action runs on a thread of its own for each call,
-- created for it and ending with it, while the owner's thread is blocked inside
-- the Lua call that made it. "Hetoimasia.Foundation.Resource.Collection" accepts
-- calls only from the thread that created it, so a binding cannot use a
-- collection its owner allocated. A scheduled owner
-- ("Hetoimasia.Scripting.Lua.Scheduled") therefore holds a
-- "Hetoimasia.Foundation.Resource.OwnedCollection" on its own thread, owned by a
-- capability and not by a thread, and lends it to its VM's callbacks. A binding's
-- action asks for what its callback was lent with 'lentToCallback', and acquires,
-- borrows and retires members through it on the owner's behalf. Members acquired
-- in one callback are there for a later one, because the collection is the
-- owner's and outlives every callback.
--
-- = The handle
--
-- The application makes a 'Lending' with 'newLending', closes the bindings that
-- use the collection over it, and gives it to the owner it creates
-- ('Hetoimasia.Scripting.Lua.Scheduled.scheduledLending'). A handle serves one
-- owner: giving it to a second is refused with 'LendingInUse'. That is the whole
-- of how a binding reaches the collection. There is no registry of owners and no
-- lookup by thread, so a binding can use only the owner whose handle it was given,
-- and an owner with no handle lends nothing.
--
-- = What is lent, and for how long
--
-- Each callback of the owner's VM is lent the collection for exactly its
-- duration: from before its action starts until after it has ended, however it
-- ends, a failing action included. That covers every callback the VM runs: those
-- of the initial chunks and of the modules while they load, of a task's segments,
-- of a coroutine's closing handlers and of a finalizer-eligible binding reached
-- while the VM closes. The collection stays open until the owner's retirement has
-- closed the VM, so the last of those still find it.
--
-- A loan is a 'LentCollection'. It is never a Lua value and cannot be made by a
-- client; a binding that wants the collection asks 'lentToCallback' with its
-- handle when its action runs. It is valid for that callback, on that callback's
-- thread:
--
-- * once the callback has returned, every operation through it is refused with
--   'LoanEnded', including in a later callback of the same VM;
-- * a thread the callback started, another VM's callback, and any other thread
--   are refused with 'LoanElsewhere', while the callback it was lent to is still
--   running and goes on using it. Whether a thread is this VM's callback is
--   decided by the record the VM keeps of its callbacks, which is the one that
--   refuses an operation re-entered from a callback, and never by what a thread
--   says of itself. Asking for the loan is not what is checked: a thread that can
--   ask, because it holds the handle, still cannot use what it is given;
-- * while the owner's VM is running no callback there is nothing lent, and
--   'lentToCallback' refuses with 'NoLoan'.
--
-- A refusal is raised before the operation has any effect, and does not
-- invalidate the loan: the callback it was lent to goes on using it. The
-- refusals are ordinary Haskell exceptions, so a binding's action that lets one
-- escape ends the owner as any host failure does, and one it catches changes
-- nothing.
--
-- = What the operations are
--
-- They are those of "Hetoimasia.Foundation.Resource.OwnedCollection", with
-- every one of its guarantees and its rejections ('OwnedCollectionError'): a
-- bounded live set, no reentry while busy, staged acquisition with masked
-- registration and the handoff, retirement exactly once, poisoning and latched
-- evidence. A rejection is raised as it is, with its own type, from the
-- operation that was refused.
--
-- = The collection's lifetime
--
-- It lives on the owner's thread, around the VM's lifetime: allocated before the
-- VM, closed after the VM has closed, as part of the owner's retirement and on
-- the owner's thread. Retirement releases what remains, newest first, and
-- keeps what a release raised as cleanup evidence, beside the VM's own, on the
-- owner's outcome, where it is fatal under every policy. The same retirement runs
-- when the owner fails or is cancelled.
module Hetoimasia.Scripting.Lua.Lending
  ( -- * The collection a callback was lent
    Lending
  , newLending
  , LentCollection
  , lentToCallback

    -- * Members
  , acquireLent
  , acquireLentThen
  , withLentMember
  , retireLent
  , liveLentCount

    -- * Refusals
  , LendingRefused (..)
  , OwnedCollectionError (..)
  ) where

import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Resource (Assembly)
import Hetoimasia.Foundation.Resource.OwnedCollection
  ( Member
  , OwnedCollectionError (..)
  , Retirement
  , acquireOwnedMember
  , acquireOwnedMemberThen
  , liveOwnedMemberCount
  , retireOwnedMember
  , withOwnedMember
  )
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Lending.Loan
  ( Lending
  , LendingRefused (..)
  , LentCollection
  , currentLoan
  , newLending
  , presenting
  )
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)

-- | What the callback the handle's owner is running was lent: the owner's
-- collection.
--
-- Refused with 'NoLoan' while the owner's VM is running no callback.
lentToCallback ∷ HasCallStack ⇒ Lending → IO LentCollection
lentToCallback lending =
  currentLoan lending >>= maybe (throwFailure runtimeComponent (operation "lent-collection") [] NoLoan) pure

-- | 'Hetoimasia.Foundation.Resource.OwnedCollection.acquireOwnedMember' on the
-- lent collection.
acquireLent ∷ HasCallStack ⇒ LentCollection → Assembly a → IO (Member a)
acquireLent lent assembly =
  presenting "acquire-lent-member" lent $ \collection capability →
    acquireOwnedMember collection capability assembly

-- | 'Hetoimasia.Foundation.Resource.OwnedCollection.acquireOwnedMemberThen' on
-- the lent collection.
acquireLentThen ∷ HasCallStack ⇒ LentCollection → Assembly a → (Member a → IO b) → IO b
acquireLentThen lent assembly handoff =
  presenting "acquire-lent-member" lent $ \collection capability →
    acquireOwnedMemberThen collection capability assembly handoff

-- | 'Hetoimasia.Foundation.Resource.OwnedCollection.withOwnedMember' on the lent
-- collection.
withLentMember ∷ HasCallStack ⇒ LentCollection → Member a → (a → IO r) → IO r
withLentMember lent member use =
  presenting "borrow-lent-member" lent $ \collection capability →
    withOwnedMember collection capability member use

-- | 'Hetoimasia.Foundation.Resource.OwnedCollection.retireOwnedMember' on the
-- lent collection.
retireLent ∷ HasCallStack ⇒ LentCollection → Member a → IO Retirement
retireLent lent member =
  presenting "retire-lent-member" lent $ \collection capability →
    retireOwnedMember collection capability member

-- | 'Hetoimasia.Foundation.Resource.OwnedCollection.liveOwnedMemberCount' on the
-- lent collection.
liveLentCount ∷ HasCallStack ⇒ LentCollection → IO Int
liveLentCount lent =
  presenting "count-lent-members" lent liveOwnedMemberCount
