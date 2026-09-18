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
  , classify
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
  , lua_isinteger
  , lua_pcall
  , lua_settop
  , lua_tointegerx
  , lua_tolstring
  , lua_tonumberx
  , lua_type
  , lua_typename
  , luaL_loadbuffer
  , data FALSE
  , data LUA_ERRERR
  , data LUA_ERRMEM
  , data LUA_ERRRUN
  , data LUA_ERRSYNTAX
  , data LUA_OK
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

-- | Read a global through the binding's protected getter, leaving it on the
-- stack when it is a function and when the read failed.
pushGlobalFunction ∷ State → Text → IO GlobalLookup
pushGlobalFunction state name = do
  entry ← lua_gettop state
  (status, kind) ←
    ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(bytes, len) →
      alloca $ \reported → do
        poke reported LUA_OK
        found ← hslua_getglobal state bytes (fromIntegral len ∷ CSize) reported
        status ← peek reported
        pure (status, found)
  if status /= LUA_OK
    then pure (LookupFailed status)
    else
      if kind == LUA_TFUNCTION
        then pure LookupFunction
        else lua_settop state entry >> pure LookupMissing

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

-- | Render what a failed call left above the depth it was given, running no Lua
-- and using nothing that can raise one.
--
-- Absence is read from the stack: an operation that left nothing above its
-- entry depth left no error value, and no value's own contents are taken as
-- evidence of that. @lua_tolstring@ is called only on something that is already
-- a string, where it converts nothing and allocates nothing; a number is read
-- with the non-allocating accessors and formatted here; anything else is named
-- by its Lua type and nothing else.
renderFailure ∷ State → StackIndex → IO ErrorValue
renderFailure state entry = do
  top ← lua_gettop state
  if top <= entry
    then pure ErrorAbsent
    else do
      kind ← lua_type state index
      if kind == LUA_TSTRING
        then readString
        else
          if kind == LUA_TNUMBER
            then readNumber
            else do
              named ← lua_typename state kind >>= peekName
              pure (ErrorOpaque named)
  where
    index = StackIndex (-1)
    readString = alloca $ \reported → do
      bytes ← lua_tolstring state index reported
      if bytes == nullPtr
        then pure (ErrorOpaque "string")
        else do
          len ← peek reported
          let full = fromIntegral (len ∷ CSize) ∷ Int
              kept = min full diagnosticLimit
          taken ← ByteString.packCStringLen (bytes, kept)
          pure (ErrorMessage (Text.decodeUtf8Lenient taken) (full > diagnosticLimit))
    readNumber = do
      integral ← lua_isinteger state index
      rendered ←
        if integral /= FALSE
          then Text.pack . show <$> lua_tointegerx state index nullPtr
          else Text.pack . show <$> lua_tonumberx state index nullPtr
      pure (ErrorMessage rendered False)
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
