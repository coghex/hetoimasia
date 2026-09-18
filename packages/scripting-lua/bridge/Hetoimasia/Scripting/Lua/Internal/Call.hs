-- | Loading a chunk, calling into Lua, and reporting what came back.
--
-- Every call into Lua is protected. Lua signals errors with @longjmp@, which
-- cannot cross a Haskell frame, so an unprotected call that errors ends the
-- process; @lua_pcall@ contains it and returns a status instead. The status is
-- classified, the error value is rendered under a bound without running further
-- Lua, and the result is an ordinary Haskell exception.
--
-- Every operation restores the stack depth it entered at, on the faulting paths
-- as well as the successful one. The error value survives that restore in a
-- temporary registry reference, which is released before the operation returns.
--
-- A Haskell failure that reached a callback outranks whatever Lua reported.
-- Lua may have caught the trampoline's error with @pcall@ and finished
-- successfully; the boundary still re-raises the original Haskell exception,
-- because the caller's code failed and no Lua construct is entitled to decide
-- otherwise.
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
    -- * Globals
  , globalIsFunction
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Foreign.C (CSize, peekCString, withCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peek, poke)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure
  ( Operation
  , operation
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( ErrorValue (ErrorAbsent, ErrorMessage, ErrorOpaque)
  , FaultKind
      ( CallFailed
      , ChunkRejected
      , HandlerFailed
      , MemoryExhausted
      , UnclassifiedStatus
      )
  , LuaFault (LuaFault)
  , diagnosticLimit
  , luaComponent
  )
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Vm
  , raiseEscape
  , withOpenVm
  , withTemporaryReference
  )
import Lua
  ( NumArgs (NumArgs)
  , NumResults (NumResults)
  , StackIndex (StackIndex)
  , State
  , StatusCode
  , fromStackIndex
  , hslua_getglobal
  , lua_gettop
  , lua_pcall
  , lua_rawgeti
  , lua_settop
  , lua_tolstring
  , lua_topointer
  , lua_type
  , lua_typename
  , luaL_loadbuffer
  , data LUA_ERRERR
  , data LUA_ERRMEM
  , data LUA_ERRRUN
  , data LUA_ERRSYNTAX
  , data LUA_OK
  , data LUA_REGISTRYINDEX
  , data LUA_TFUNCTION
  , data LUA_TNUMBER
  , data LUA_TSTRING
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
      handlerIndex ← pushHandler state entry handler
      status ← loadChunk state name source
      if status /= LUA_OK
        then fault vm state entry evalOperation (classify status) (chunkNameText name)
        else do
          called ← lua_pcall state (NumArgs 0) (NumResults 0) handlerIndex
          if called /= LUA_OK
            then fault vm state entry evalOperation (classify called) (chunkNameText name)
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
      isFunction ← pushGlobalFunction state name
      if not isFunction
        then do
          lua_settop state entry
          notAFunction callOperation CallFailed name
        else do
          called ← lua_pcall state (NumArgs 0) (NumResults 0) (StackIndex 0)
          if called /= LUA_OK
            then fault vm state entry callOperation (classify called) name
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
    pure found

-- | Push the message handler, if there is one, and answer the stack index
-- @lua_pcall@ should be given for it. Zero means no handler.
pushHandler ∷ HasCallStack ⇒ State → StackIndex → MessageHandler → IO StackIndex
pushHandler _ _ NoHandler = pure (StackIndex 0)
pushHandler state entry (HandlerGlobal name) = do
  isFunction ← pushGlobalFunction state name
  if isFunction
    then -- The handler sits directly above the entry depth, below the chunk.
      pure (StackIndex (fromStackIndex entry + 1))
    else do
      lua_settop state entry
      notAFunction evalOperation HandlerFailed name

-- | Push a global if it is a function, answering whether it was.
--
-- The global is read through the binding's protected getter, which cannot
-- raise a Lua error however the globals table is indexed. A global that is not
-- a function is left off the stack.
pushGlobalFunction ∷ State → Text → IO Bool
pushGlobalFunction state name = do
  entry ← lua_gettop state
  reached ←
    ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
      alloca $ \reported → do
        poke reported LUA_OK
        kind ← hslua_getglobal state bytes (fromIntegral len ∷ CSize) reported
        status ← peek reported
        pure (status == LUA_OK && kind == LUA_TFUNCTION)
  if reached then pure True else lua_settop state entry >> pure False

-- | Report that a named global the caller relies on is not a callable
-- function in this VM.
notAFunction ∷ HasCallStack ⇒ Operation → FaultKind → Text → IO a
notAFunction name kind subject =
  throwFailure
    luaComponent
    name
    [("global", subject)]
    (LuaFault kind subject (ErrorOpaque "not-a-function" subject))

-- | Load a chunk from memory. Nothing is read from disk.
loadChunk ∷ State → ChunkName → ByteString → IO StatusCode
loadChunk state name source =
  ByteString.unsafeUseAsCStringLen source $ \(bytes, len) →
    -- A leading '=' tells Lua to use the name verbatim rather than quoting it
    -- as a source string.
    withCString (Text.unpack ("=" <> chunkNameText name)) $ \label →
      luaL_loadbuffer state bytes (fromIntegral len ∷ CSize) label

-- | Report a failed Lua operation: restore the stack, render the error value
-- under a bound, and raise. An escaped Haskell failure is raised in its place.
fault
  ∷ HasCallStack
  ⇒ Vm → State → StackIndex → Operation → FaultKind → Text → IO a
fault vm state entry name kind subject = do
  value ← withTemporaryReference vm $ \reference → do
    -- The error value is in the registry now, so the stack can go back to the
    -- depth this operation entered at before anything else happens.
    lua_settop state entry
    _ ← lua_rawgeti state LUA_REGISTRYINDEX (fromIntegral reference)
    rendered ← renderErrorValue state
    lua_settop state entry
    pure rendered
  raiseEscape vm
  throwFailure luaComponent name [("subject", subject)] (LuaFault kind subject value)

-- | Render the value on top of the stack without running any Lua.
--
-- @lua_tolstring@ converts a string or a number and answers @NULL@ for
-- everything else; it runs no @__tostring@ metamethod, which is the point.
-- Anything it declines is reported by type name and address.
renderErrorValue ∷ State → IO ErrorValue
renderErrorValue state = do
  kind ← lua_type state index
  if kind /= LUA_TSTRING && kind /= LUA_TNUMBER
    then opaque kind
    else alloca $ \reported → do
      bytes ← lua_tolstring state index reported
      if bytes == nullPtr
        then opaque kind
        else do
          len ← peek reported
          let full = fromIntegral (len ∷ CSize) ∷ Int
              kept = min full diagnosticLimit
          taken ← ByteString.packCStringLen (bytes, kept)
          pure (ErrorMessage (Text.decodeUtf8Lenient taken) (full > diagnosticLimit))
  where
    index = StackIndex (-1)
    opaque kind = do
      named ← lua_typename state kind >>= peekName
      address ← lua_topointer state index
      pure $
        if address == nullPtr
          then ErrorAbsent
          else ErrorOpaque named (Text.pack (show address))
    peekName pointer
      | pointer == nullPtr = pure "unknown"
      | otherwise = Text.pack <$> peekCString pointer

-- | Classify one of Lua's own status codes.
classify ∷ StatusCode → FaultKind
classify status
  | status == LUA_ERRSYNTAX = ChunkRejected
  | status == LUA_ERRRUN = CallFailed
  | status == LUA_ERRMEM = MemoryExhausted
  | status == LUA_ERRERR = HandlerFailed
  | otherwise = UnclassifiedStatus (Text.pack (show status))

evalOperation ∷ Operation
evalOperation = operation "eval-chunk"

callOperation ∷ Operation
callOperation = operation "call-global"

probeOperation ∷ Operation
probeOperation = operation "probe-global"
