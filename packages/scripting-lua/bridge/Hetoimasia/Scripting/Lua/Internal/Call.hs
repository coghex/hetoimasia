-- | Loading a chunk, calling into Lua, and reporting what came back.
--
-- Every call into Lua is protected. Lua signals errors with @longjmp@, which
-- cannot cross a Haskell frame, so an unprotected call that errors ends the
-- process; @lua_pcall@ contains it and returns a status instead. The status is
-- classified, the error value is rendered under a bound, and the result is an
-- ordinary Haskell exception.
--
-- The reporting path is held to the same rule as the call it reports on, which
-- is the less obvious half. Once @lua_pcall@ has returned there is no protected
-- frame left, so anything the diagnostic does that could raise a Lua error has
-- nowhere for that error to go but Lua's panic function, which ends the
-- process. That rules out more than it looks like: @luaL_ref@ can raise on a
-- memory error, and @lua_tolstring@ allocates when it converts a number. So the
-- bridge takes no registry reference at all, and reads a value only with
-- accessors that cannot allocate.
--
-- Every operation restores the stack depth it entered at, on the faulting paths
-- as well as the successful one.
--
-- A Haskell failure that reached a callback outranks whatever Lua reported.
-- Lua may have caught the trampoline's error with @pcall@ and finished
-- successfully; the boundary still re-raises the original Haskell exception,
-- because the caller's code failed and no Lua construct is entitled to decide
-- otherwise. Every path that can run Lua -- including the protected helpers
-- that read a global through an @__index@ metamethod -- goes through that
-- check, or a failure raised by one operation's callback would be raised by the
-- next, unrelated one.
module Hetoimasia.Scripting.Lua.Internal.Call
  ( -- * Chunk names
    ChunkName
  , chunkName
  , chunkNameText
    -- * Running Lua
  , evalChunk
  , evalChunkWith
  , callGlobal
  , MessageHandler (..)
    -- * Reporting
  , reportFault
    -- * Globals
  , globalIsFunction
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Foreign.C (CChar, CInt (CInt), CSize (CSize), withCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, poke)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure
  ( Operation
  , operation
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( ErrorValue (ErrorOpaque)
  , FaultKind (CallFailed, HandlerFailed)
  , LuaFault (LuaFault)
  , classify
  , luaComponent
  , renderFailure
  )
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Vm
  , raiseEscape
  , withOpenVm
  )
import Lua
  ( NumArgs (NumArgs)
  , NumResults (NumResults)
  , StackIndex (StackIndex)
  , State (State)
  , StatusCode (StatusCode)
  , TypeCode (TypeCode)
  , fromStackIndex
  , fromTypeCode
  , lua_gettop
  , lua_pcall
  , lua_settop
  , luaL_loadbuffer
  , data LUA_OK
  , data LUA_TFUNCTION
  , data LUA_TNONE
  )

-- | What a chunk is called in a diagnostic.
--
-- It names the source of the code for a reader, nothing more: it selects no
-- file and reaches nothing on disk.
newtype ChunkName = ChunkName Text
  deriving (Eq, Ord, Show)

-- | Name a chunk. Control characters are replaced, so a chunk name can never
-- rewrite the diagnostic it appears in.
chunkName ∷ Text → ChunkName
chunkName = ChunkName . Text.map tame
  where
    tame character
      | character < ' ' || character == '\DEL' = '.'
      | otherwise = character

-- | The chunk's name.
chunkNameText ∷ ChunkName → Text
chunkNameText (ChunkName name) = name

-- | Whether a protected call runs under a Lua message handler.
--
-- The bridge's own operations use none: a handler is arbitrary Lua running on
-- the error path, which is exactly what a bounded diagnostic must not depend
-- on. The option exists so this package's fixtures can prove that a handler
-- which fails is classified and reported without a diagnostic from it.
data MessageHandler
  = NoHandler
  | -- | Use the named global, which must already be a function in this VM.
    HandlerGlobal !Text
  deriving (Eq, Show)

-- | Load a chunk and run it, with no arguments and no results.
evalChunk ∷ HasCallStack ⇒ Vm → ChunkName → ByteString → IO ()
evalChunk vm = evalChunkWith vm NoHandler

-- | 'evalChunk', under a chosen message handler.
evalChunkWith
  ∷ HasCallStack ⇒ Vm → MessageHandler → ChunkName → ByteString → IO ()
evalChunkWith vm handler name source =
  withOperationContext luaComponent evalOperation [("chunk", chunkNameText name)] $
    withOpenVm vm evalOperation $ \state → do
      entry ← lua_gettop state
      handlerIndex ← pushHandler vm state entry handler
      status ← loadChunk state name source
      if status /= LUA_OK
        then reportFault vm state entry evalOperation (classify status) (chunkNameText name)
        else do
          called ← lua_pcall state (NumArgs 0) (NumResults 0) handlerIndex
          if called /= LUA_OK
            then reportFault vm state entry evalOperation (classify called) (chunkNameText name)
            else do
              lua_settop state entry
              raiseEscape vm

-- | Call a global function this VM already defines, with no arguments and no
-- results.
callGlobal ∷ HasCallStack ⇒ Vm → Text → IO ()
callGlobal vm name =
  withOperationContext luaComponent callOperation [("global", name)] $
    withOpenVm vm callOperation $ \state → do
      entry ← lua_gettop state
      found ← pushGlobalFunction state name
      case found of
        LookupFailed status →
          reportFault vm state entry callOperation (classify status) name
        LookupMissing → do
          lua_settop state entry
          -- A metamethod may have run Haskell and failed without failing the
          -- lookup itself; that failure is the caller's, not this one.
          raiseEscape vm
          notAFunction callOperation CallFailed name
        LookupFunction → do
          called ← lua_pcall state (NumArgs 0) (NumResults 0) (StackIndex 0)
          if called /= LUA_OK
            then reportFault vm state entry callOperation (classify called) name
            else do
              lua_settop state entry
              raiseEscape vm

-- | Whether a global of this VM is currently a function.
--
-- A probe for this package's own fixtures; it leaves the stack as it found it.
globalIsFunction ∷ Vm → Text → IO Bool
globalIsFunction vm name =
  withOpenVm vm probeOperation $ \state → do
    entry ← lua_gettop state
    found ← pushGlobalFunction state name
    lua_settop state entry
    raiseEscape vm
    pure (found == LookupFunction)

-- | Push the message handler, if there is one, and answer the stack index
-- @lua_pcall@ should be given for it. Zero means no handler.
pushHandler
  ∷ HasCallStack ⇒ Vm → State → StackIndex → MessageHandler → IO StackIndex
pushHandler _ _ _ NoHandler = pure (StackIndex 0)
pushHandler vm state entry (HandlerGlobal name) = do
  found ← pushGlobalFunction state name
  case found of
    -- The handler sits directly above the entry depth, below the chunk.
    LookupFunction → pure (StackIndex (fromStackIndex entry + 1))
    LookupFailed status →
      reportFault vm state entry evalOperation (classify status) name
    LookupMissing → do
      lua_settop state entry
      raiseEscape vm
      notAFunction evalOperation HandlerFailed name

-- | What reading a global found.
data GlobalLookup
  = -- | The read itself failed, and left its error value on the stack.
    --
    -- The globals table can carry an @__index@ metamethod, so reading a global
    -- can run arbitrary Lua, which can error or can call a Haskell function
    -- that fails. Collapsing that into "not a function" would report the wrong
    -- failure and leave the real one recorded for a later operation to raise.
    LookupFailed !StatusCode
  | -- | The read succeeded and the global is not a function. The stack is as
    -- it was.
    LookupMissing
  | -- | The read succeeded and the function is on the stack.
    LookupFunction
  deriving (Eq, Show)

-- | Read a global through this package's protected getter, leaving it on the
-- stack when it is a function and when the read failed.
--
-- The binding's own getter allocates the key before entering its protected
-- call, so a first lookup under memory exhaustion would panic rather than
-- report; this one puts the whole lookup inside the call.
pushGlobalFunction ∷ State → Text → IO GlobalLookup
pushGlobalFunction state name = do
  entry ← lua_gettop state
  (status, kind) ←
    ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
      alloca $ \reported → do
        poke reported (fromTypeCode LUA_TNONE)
        status ← hetoimasia_lua_getglobal state bytes (fromIntegral len ∷ CSize) reported
        found ← peek reported
        pure (status, TypeCode found)
  if status /= LUA_OK
    then pure (LookupFailed status)
    else
      if kind == LUA_TFUNCTION
        then pure LookupFunction
        else lua_settop state entry >> pure LookupMissing

-- | Read a global, with the whole lookup inside one protected Lua call.
--
-- @safe@: the globals table can carry an @__index@ metamethod, which can run
-- Lua, which can call back into Haskell.
foreign import ccall safe "hetoimasia_lua_bridge.h hetoimasia_lua_getglobal"
  hetoimasia_lua_getglobal
    ∷ State → Ptr CChar → CSize → Ptr CInt → IO StatusCode

-- | Report that a named global the caller relies on is not a callable
-- function in this VM.
notAFunction ∷ HasCallStack ⇒ Operation → FaultKind → Text → IO a
notAFunction name kind subject =
  throwFailure
    luaComponent
    name
    [("global", subject)]
    (LuaFault kind subject (ErrorOpaque "not-a-function"))

-- | Load a chunk from memory. Nothing is read from disk.
loadChunk ∷ State → ChunkName → ByteString → IO StatusCode
loadChunk state name source =
  ByteString.unsafeUseAsCStringLen source $ \(bytes, len) →
    -- A leading '=' tells Lua to use the name verbatim rather than quoting it
    -- as a source string.
    withCString (Text.unpack ("=" <> chunkNameText name)) $ \label →
      luaL_loadbuffer state bytes (fromIntegral len ∷ CSize) label

-- | Report a failed Lua operation: render what it left, restore the stack, and
-- raise. An escaped Haskell failure is raised in its place.
reportFault
  ∷ HasCallStack
  ⇒ Vm → State → StackIndex → Operation → FaultKind → Text → IO a
reportFault vm state entry name kind subject = do
  value ← renderFailure state entry
  lua_settop state entry
  raiseEscape vm
  throwFailure luaComponent name [("subject", subject)] (LuaFault kind subject value)

evalOperation ∷ Operation
evalOperation = operation "eval-chunk"

callOperation ∷ Operation
callOperation = operation "call-global"

probeOperation ∷ Operation
probeOperation = operation "probe-global"
