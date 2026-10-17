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
-- client; a binding that wants the collection asks 'lentToCallback' when its
-- action runs. It is valid for that callback, on that callback's thread:
--
-- * once the callback has returned, every operation through it is refused with
--   'LoanEnded', including in a later callback of the same VM;
-- * a thread the callback started, another VM's callback, and any other thread
--   are refused with 'LoanElsewhere', while the callback it was lent to is still
--   running and goes on using it. Whether a thread is this VM's callback is
--   decided by the record the VM keeps of its callbacks, which is the one that
--   refuses an operation re-entered from a callback, and never by what a thread
--   says of itself;
-- * a thread that is not running a callback of an owner that lends finds nothing
--   to ask for, and 'lentToCallback' refuses it with 'NoLoan'.
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
    LentCollection
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
  ( LendingRefused (..)
  , LentCollection
  , loanOfThisThread
  , presenting
  )
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)

-- | What the callback the calling thread is running was lent: the collection of
-- the scheduled owner whose VM is running it.
--
-- Refused with 'NoLoan' from a thread that is not running such a callback, a
-- thread a callback started included.
lentToCallback ∷ HasCallStack ⇒ IO LentCollection
lentToCallback =
  loanOfThisThread >>= maybe (throwFailure runtimeComponent (operation "lent-collection") [] NoLoan) pure

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
