-- | An embedded Lua interpreter, from outside the bridge.
--
-- This is the whole of what a client outside this package may say about Lua:
-- construct a VM over an explicitly chosen set of standard libraries, load and
-- run a chunk, call a global that VM already defines, and close it. Nothing
-- here is a Lua state, a stack index, a registry reference, a coroutine, a
-- closure, or a native address, and no type below has a reachable
-- representation that becomes one.
--
-- What is deliberately absent is as much of the contract as what is present.
-- There is no way to open "all the libraries": 'newVm' takes the list, and the
-- empty list is a VM with no standard library at all. There is no way to
-- register a Haskell function, because module identity, capability namespaces,
-- and per-domain policy are LUA-3's and installing callbacks without them is
-- how a bridge acquires an unreviewable surface. There is no protected owner
-- that closes the VM for you, because that lifetime facility is LUA-2's; here
-- 'closeVm' is called explicitly and is terminal.
--
-- Failures arrive as ordinary Haskell exceptions. A Lua error is a 'LuaFault'
-- with a bounded diagnostic; it did not unwind Haskell to get here. A Haskell
-- exception raised inside a callback the VM invoked is re-raised as itself,
-- with its own type and context, even if Lua caught the bridge's stand-in error
-- and finished successfully; so is a cancellation delivered while a call was
-- outstanding. Neither becomes something a script can swallow.
module Hetoimasia.Scripting.Lua.Bridge
  ( -- * The VM
    Vm
  , newVm
  , closeVm

    -- * Standard libraries
  , Library (..)

    -- * Running Lua
  , ChunkName
  , chunkName
  , chunkNameText
  , evalChunk
  , callGlobal

    -- * Failures
  , LuaFault (..)
  , FaultKind (..)
  , ErrorValue (..)
  , VmClosed (..)
  , CloseFault (..)
  ) where

import Hetoimasia.Scripting.Lua.Internal.Call
  ( ChunkName
  , callGlobal
  , chunkName
  , chunkNameText
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFault (..)
  , ErrorValue (..)
  , FaultKind (..)
  , LuaFault (..)
  , VmClosed (..)
  )
import Hetoimasia.Scripting.Lua.Internal.Library (Library (..))
import Hetoimasia.Scripting.Lua.Internal.Vm (Vm, closeVm, newVm)
