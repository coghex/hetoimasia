-- | A Lua VM owned through a protected IO lifetime, from outside the package.
--
-- 'withVmOwner' is the whole of it: it constructs one VM over an explicit set
-- of standard libraries, loads the initial chunks inside the lifetime, hands the
-- body that VM and only that VM, and closes it on every exit. Where the bridge's
-- own 'Hetoimasia.Scripting.Lua.Bridge.closeVm' leaves closing to the caller,
-- here nothing but the lifetime closes the VM, and a client cannot forget to.
--
-- = One owner per VM
--
-- The VM belongs to the thread that runs the lifetime, its execution owner.
-- Only that thread may run Lua on it, and the body's 'OwnedVm' offers no way to
-- close it, hand it to another owner or adopt it elsewhere: it is not the
-- bridge's @Vm@, so the bridge's operations do not accept it. A reference that
-- escapes the body, or reaches another thread, is refused rather than used: by
-- 'VmNotOwned' from any other thread while the VM is open, and by 'VmClosed'
-- from every thread once the lifetime has ended. A refused use runs no Lua and
-- changes nothing, and its rightful owner goes on using the VM.
--
-- = Any number of owners
--
-- Owners are independent. Any number may be live at once, created and closed in
-- any order, on any threads: none shares a VM, a Lua global state, a registry or
-- a callback table with another, and closing, failing or cancelling one leaves
-- every other one usable with its state and evidence untouched. There is no pool
-- and no scheduler across them; each is a thread running its own lifetime.
--
-- = How a lifetime ends
--
-- The outcome keeps the primary failure's type, value and context, and retains
-- every failure of the close as cleanup evidence that
-- 'Hetoimasia.Foundation.Resource.cleanupFailures' and
-- 'Hetoimasia.Foundation.Resource.cleanupFailuresInContext' read back, which is
-- what a supervisor reads: a cleanup failure stays cleanup, including when a
-- cancellation is the primary failure, and is never raised as a new script
-- error. A construction failure, partway through initialization, closes the VM
-- that was made through the same close before it is raised.
--
-- | Exit                         | Raised                                               |
-- |------------------------------|------------------------------------------------------|
-- | body returns, close succeeds | the body's result                                    |
-- | body fails                   | the body's failure, close failures retained          |
-- | construction fails           | that failure, close failures retained                |
-- | cancellation, any point      | the cancellation, after the VM is closed, close      |
-- |                              | failures retained                                    |
-- | body returns, close fails    | the first close failure, all retained                |
--
-- = Cancellation
--
-- A cancellation is never delivered inside a Lua call, so a thread inside Lua is
-- cancelled when the call returns. During initialization or the body it ends the
-- step and the VM is closed on the way out. During the close it waits: the close
-- cannot be interrupted, it never runs twice, and the dependencies Lua's
-- callbacks borrowed are released only once the state has closed. The owner
-- never detaches a VM it cannot finish closing; it waits for it as the thread
-- running a stuck finalizer does.
--
-- = Shutdown
--
-- Before the state closes the owner closes admission: every operation asked of
-- the VM is refused. A callback Lua's finalizers reach runs only if the owner's
-- finalizer allowlist names it, and the allowlist is empty: this module offers
-- no way to register a callback, which is LUA-3's. Any callback reached from a
-- finalizer is refused with 'FinalizerRefused', the refusal is retained as cleanup
-- evidence even if the finalizer's script caught the error, and what is retained
-- from finalizers is bounded.
module Hetoimasia.Scripting.Lua.Owner
  ( -- * The lifetime
    VmConfig (..)
  , vmConfig
  , withVmOwner
  , OwnedVm

    -- * Running Lua
  , evalOwned
  , callOwned

    -- * Standard libraries
  , Library (..)

    -- * Chunk names
  , ChunkName
  , chunkName
  , chunkNameText

    -- * Failures
  , LuaFault (..)
  , FaultKind (..)
  , ErrorValue (..)
  , VmClosed (..)
  , VmReentered (..)
  , VmNotOwned (..)
  , FinalizerRefused (..)
  , FinalizerEvidenceTruncated (..)
  , CloseFault (..)
  , CloseFailure (..)
  , CloseSource (..)
  , closeSourceLabel
  ) where

import Data.ByteString (ByteString)
import GHC.Stack (HasCallStack)
import Hetoimasia.Scripting.Lua.Internal.Call (ChunkName, chunkName, chunkNameText)
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFailure (..)
  , CloseFault (..)
  , CloseSource (..)
  , ErrorValue (..)
  , FaultKind (..)
  , FinalizerEvidenceTruncated (..)
  , FinalizerRefused (..)
  , LuaFault (..)
  , VmClosed (..)
  , VmNotOwned (..)
  , VmReentered (..)
  , closeSourceLabel
  )
import Hetoimasia.Scripting.Lua.Internal.Library (Library (..))
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnedVm
  , OwnerConfig (ownerChunks)
  , callOwned
  , defaultOwnerConfig
  , evalOwned
  , withOwnedVm
  )

-- | What a VM owner constructs.
data VmConfig = VmConfig
  { vmLibraries ∷ [Library]
    -- ^ Exactly the standard libraries the VM opens, in order. There is no way
    -- to open all of them at once, and the empty list opens none.
  , vmInitialChunks ∷ [(ChunkName, ByteString)]
    -- ^ The chunks loaded and run, in order, inside the lifetime and before the
    -- body: initialization. One that fails ends the lifetime with its failure,
    -- after closing the VM.
  }

-- | A configuration over these libraries with no initial chunk.
vmConfig ∷ [Library] → VmConfig
vmConfig libraries = VmConfig libraries []

-- | Run a body over a VM this owner constructs, and close the VM on every exit.
--
-- The VM is constructed, initialized and closed on the calling thread, which is
-- its execution owner for as long as the lifetime lasts. See the module header
-- for who may use it, how it ends and where a cancellation can land.
withVmOwner ∷ HasCallStack ⇒ VmConfig → (OwnedVm → IO r) → IO r
withVmOwner config =
  withOwnedVm ((defaultOwnerConfig (vmLibraries config)) {ownerChunks = vmInitialChunks config})
