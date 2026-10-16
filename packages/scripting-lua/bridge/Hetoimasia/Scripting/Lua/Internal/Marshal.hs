-- | The protected C operations of the value boundary, as Haskell calls them.
--
-- Each wrapper is one @safe@ foreign call into a function that runs entirely
-- inside a @lua_pcall@ (see @hetoimasia_lua_values.h@), so a Lua error --
-- memory exhaustion above all -- is a status here and never an unwind through a
-- Haskell frame. That is what lets the same wrappers be used from an operation
-- of the VM's owner and from inside a callback, where an allocating Lua call
-- made directly would not be safe.
--
-- A wrapper restores nothing: the stack it leaves is the stack it found, plus
-- what its documentation says it adds, and a caller that gets a failed status
-- restores its own entry depth, exactly as the rest of the bridge does.
module Hetoimasia.Scripting.Lua.Internal.Marshal
  ( -- * Reading and writing values
    Reading (..)
  , readValues
  , Pushing (..)
  , pushValues
    -- * Preparing the VM
  , prepareValues
  , declareNamespace
  , installBindingAt
    -- * Modules
  , Loaded (..)
  , loadModuleSource
  , Lookup (..)
  , lookupEntry
  , moduleReferences
  , releaseModule
    -- * Calling
  , callProtected
  , captureContext
  , serviceCollector
  , traceLimit
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Foreign.C (CChar, CInt (CInt), CLong, CSize (CSize))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.StablePtr (StablePtr)
import Foreign.Storable (peek, poke)
import Hetoimasia.Scripting.Lua.Internal.Value
  ( ValueLimits (..)
  , ValueRule (..)
  , VmIdentity (VmIdentity)
  )
import Lua (State (State), StatusCode (StatusCode), data LUA_OK)

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_read_values"
  c_read_values
    ∷ State
    → CInt
    → CInt
    → CSize
    → CSize
    → CSize
    → Word64
    → Ptr CInt
    → Ptr CInt
    → Ptr CInt
    → Ptr CSize
    → Ptr (Ptr ())
    → Ptr CSize
    → IO StatusCode

foreign import ccall unsafe "hetoimasia_lua_values.h hetoimasia_lua_free"
  c_free ∷ Ptr () → IO ()

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_push_values"
  c_push_values ∷ State → Ptr () → CSize → CInt → CSize → Ptr CInt → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_values_setup"
  c_values_setup ∷ State → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_module_count"
  c_module_count ∷ State → Ptr CLong → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_namespace"
  c_namespace ∷ State → Ptr CChar → CSize → Ptr CInt → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_install_binding"
  c_install_binding
    ∷ State → StablePtr a → Ptr CChar → CSize → Ptr CChar → CSize → Ptr CInt → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_load_module"
  c_load_module
    ∷ State
    → Ptr CChar
    → CSize
    → Ptr CChar
    → CSize
    → Ptr ()
    → CSize
    → CInt
    → Int64
    → Ptr CChar
    → CSize
    → Ptr CSize
    → Ptr CInt
    → Ptr CInt
    → Ptr CInt
    → Ptr CInt
    → Ptr CInt
    → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_module_release"
  c_module_release ∷ State → Int64 → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_entry_lookup"
  c_entry_lookup ∷ State → Int64 → Ptr CChar → CSize → Ptr CInt → Ptr CInt → IO StatusCode

-- Safe: a collection step runs finalizers, which can call back into Haskell.
foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_gc_service"
  c_gc_service ∷ State → IO ()

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_context"
  c_context ∷ State → Ptr CChar → CSize → Ptr CSize → Ptr CChar → CSize → Ptr CSize → IO StatusCode

foreign import ccall safe "hetoimasia_lua_values.h hetoimasia_lua_call"
  c_call ∷ State → CInt → CInt → Ptr CChar → CSize → Ptr CSize → IO StatusCode

-- | What reading values off the stack came to.
data Reading
  = -- | The protected call itself failed, with Lua's status; its error value is
    -- on the stack.
    ReadStatus !StatusCode
  | -- | The copy was refused: the rule, the 1-based position of the value it
    -- concerned, and how many values had been visited.
    ReadRefused !ValueRule !Int !Int
  | -- | The copy: its encoding and how many values were visited.
    ReadCopied !ByteString !Int

-- | Read @count@ consecutive values of the current frame from index @first@ into
-- a copy bounded by the limits. Runs no Lua and takes nothing from the registry.
readValues ∷ State → ValueLimits → VmIdentity → Int → Int → IO Reading
readValues state limits (VmIdentity identity) first count =
  alloca $ \refusal →
    alloca $ \argument →
      alloca $ \typeTag →
        alloca $ \visited →
          alloca $ \buffer →
            alloca $ \len → do
              status ←
                c_read_values
                  state
                  (fromIntegral first)
                  (fromIntegral count)
                  (fromIntegral (limitBytes limits))
                  (fromIntegral (limitDepth limits))
                  (fromIntegral (limitElements limits))
                  identity
                  refusal
                  argument
                  typeTag
                  visited
                  buffer
                  len
              code ← peek refusal
              position ← peek argument
              luaType ← peek typeTag
              seen ← peek visited
              pointer ← peek buffer
              size ← peek len
              if status /= LUA_OK
                then pure (ReadStatus status)
                else
                  if code /= 0
                    then pure (ReadRefused (readRule limits code luaType) (fromIntegral position) (fromIntegral seen))
                    else do
                      copied <-
                        if pointer == nullPtr
                          then pure ByteString.empty
                          else do
                            bytes ← ByteString.packCStringLen (castPtr pointer, fromIntegral size)
                            c_free pointer
                            pure bytes
                      pure (ReadCopied copied (fromIntegral seen))

-- | The rule a refusal code of the reader stands for.
readRule ∷ ValueLimits → CInt → CInt → ValueRule
readRule limits code luaType = case code of
  1 → RuleBytesLimit (limitBytes limits)
  2 → RuleDepthLimit (limitDepth limits)
  3 → RuleElementLimit (limitElements limits)
  4 → RuleCycle
  5 → RuleUnsupportedType (typeName luaType)
  6 → RuleMetatable
  7 → RuleKeyType
  8 → RuleStack
  9 → RuleMemory
  10 → RuleForeignHandle
  _ → RuleUnsupportedType "unknown"

-- | Lua's name for a type tag.
typeName ∷ CInt → Text
typeName = \case
  0 → "nil"
  1 → "boolean"
  2 → "light userdata"
  3 → "number"
  4 → "string"
  5 → "table"
  6 → "function"
  7 → "userdata"
  8 → "thread"
  _ → "unknown"

-- | What pushing values came to.
data Pushing
  = Pushed
  | -- | The protected call failed with Lua's status; its error value is on the
    -- stack.
    PushStatus !StatusCode
  | -- | The encoding was malformed, or the stack could not be reserved. A bug
    -- in this package, or a stack Lua would not grow.
    PushMalformed !Int

-- | Push the values of an encoding onto the current frame's stack.
pushValues ∷ State → ValueLimits → ByteString → Int → IO Pushing
pushValues state limits bytes count =
  ByteString.unsafeUseAsCStringLen bytes $ \(pointer, size) →
    alloca $ \malformed → do
      status ← c_push_values state (castPtr pointer) (fromIntegral size) (fromIntegral count) (fromIntegral (limitDepth limits)) malformed
      problem ← peek malformed
      pure $
        if status /= LUA_OK
          then PushStatus status
          else
            if problem /= 0
              then PushMalformed (fromIntegral problem)
              else Pushed

-- | Make what the value boundary keeps in the registry. Idempotent.
prepareValues ∷ State → IO StatusCode
prepareValues = c_values_setup

-- | Create a namespace table in the globals, answering whether the name was
-- already something other than a table.
declareNamespace ∷ State → Text → IO (StatusCode, Bool)
declareNamespace state name =
  ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(pointer, size) →
    alloca $ \collision → do
      status ← c_namespace state pointer (fromIntegral size) collision
      found ← peek collision
      pure (status, found /= (0 ∷ CInt))

-- | Install a stable pointer's function as @namespace.name@, with the same
-- ownership report as publishing a global: the flag says whether Lua took the
-- pointer.
installBindingAt ∷ State → StablePtr a → Text → Text → Ptr CInt → IO StatusCode
installBindingAt state carried space name acquired =
  ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 space) $ \(spacePointer, spaceSize) →
    ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(namePointer, nameSize) →
      c_install_binding state carried spacePointer (fromIntegral spaceSize) namePointer (fromIntegral nameSize) acquired

-- | The bound on a traceback, in bytes.
traceLimit ∷ Int
traceLimit = 2048

-- | What loading a module came to.
data Loaded = Loaded
  { loadedStatus ∷ !StatusCode
    -- ^ The protected call's status; on failure its error value is on the stack.
  , loadedChunkStatus ∷ !StatusCode
    -- ^ Loading the chunk: not 'LUA_OK' for a rejected chunk, whose message is on
    -- the stack.
  , loadedMissing ∷ !Int
    -- ^ The 1-based position of the first required entry point that is not a
    -- function, or 0.
  , loadedMissingPresent ∷ !Bool
    -- ^ Whether it was there as something else.
  , loadedStored ∷ !Bool
  , loadedStarted ∷ !Bool
    -- ^ Whether the module's chunk began to run. If not, nothing executed.
  , loadedTrace ∷ !(Maybe Text)
  }

-- | Load a module's source in an environment of its own, run it, check the
-- required entry points and keep it in a slot. The stack gains one value, which
-- is the error or the chunk's message or nil.
loadModuleSource ∷ State → ByteString → Text → [Text] → Int → IO Loaded
loadModuleSource state source chunk required slot =
  ByteString.unsafeUseAsCStringLen source $ \(sourcePointer, sourceSize) →
    ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 ("=" <> chunk <> "\0")) $ \(chunkPointer, chunkSize) →
      ByteString.unsafeUseAsCStringLen requiredBytes $ \(requiredPointer, requiredSize) →
        allocaBytes traceLimit $ \trace →
          alloca $ \traceLength →
            alloca $ \loadStatus →
              alloca $ \missing →
                alloca $ \missingKind →
                  alloca $ \stored →
                   alloca $ \started → do
                    status <-
                      c_load_module
                        state
                        sourcePointer
                        (fromIntegral sourceSize)
                        chunkPointer
                        (fromIntegral chunkSize)
                        (castPtr requiredPointer)
                        (fromIntegral requiredSize)
                        (fromIntegral (length required))
                        (fromIntegral slot)
                        trace
                        (fromIntegral traceLimit)
                        traceLength
                        loadStatus
                        missing
                        missingKind
                        stored
                        started
                    ranChunk ← peek started
                    chunkStatus ← peek loadStatus
                    gone ← peek missing
                    kind ← peek missingKind
                    kept ← peek stored
                    traced ← readTrace trace traceLength
                    pure
                      Loaded
                        { loadedStatus = status
                        , loadedChunkStatus = StatusCode chunkStatus
                        , loadedMissing = fromIntegral gone
                        , loadedMissingPresent = kind /= 0
                        , loadedStored = kept /= 0
                        , loadedStarted = ranChunk /= 0
                        , loadedTrace = traced
                        }
  where
    requiredBytes =
      ByteString.concat
        [ lengthPrefix (ByteString.length name) <> name
        | entry ← required
        , let name = Text.encodeUtf8 entry
        ]
    lengthPrefix size = ByteString.pack [fromIntegral (size `div` (256 ^ i) `mod` 256) | i ← [0 .. 3 ∷ Int]]

-- | What looking an entry point up found.
data Lookup
  = LookupStatus !StatusCode
  | -- | The module's slot holds nothing.
    LookupNoModule
  | LookupAbsent
  | -- | Present, and not a function.
    LookupNotFunction
  | -- | A function, left on the stack.
    LookupFunctionOnStack

-- | Look an entry point up in a module's environment by raw access. The stack
-- gains one value, the function or nil.
lookupEntry ∷ State → Int → Text → IO Lookup
lookupEntry state slot name =
  ByteString.unsafeUseAsCStringLen (Text.encodeUtf8 name) $ \(pointer, size) →
    alloca $ \kind →
      alloca $ \found → do
        status ← c_entry_lookup state (fromIntegral slot) pointer (fromIntegral size) kind found
        what ← peek kind
        present ← peek found
        pure $
          if status /= LUA_OK
            then LookupStatus status
            else
              if (present ∷ CInt) == 0
                then LookupNoModule
                else case what ∷ CInt of
                  0 → LookupAbsent
                  2 → LookupFunctionOnStack
                  _ → LookupNotFunction

-- | How many modules the registry holds: the references the bridge retains for
-- them, one for each.
moduleReferences ∷ State → IO (Either StatusCode Int)
moduleReferences state =
  alloca $ \count → do
    poke count 0
    status ← c_module_count state count
    found ← peek count
    pure (if status /= LUA_OK then Left status else Right (fromIntegral found))

-- | Pay what the host-side phases, which hold the collector, allocated since it
-- was last paid, as a collection step. Where script code may run, and only there:
-- a step can run finalizers.
serviceCollector ∷ State → IO ()
serviceCollector = c_gc_service

-- | Empty a module's slot.
releaseModule ∷ State → Int → IO StatusCode
releaseModule state slot = c_module_release state (fromIntegral slot)

-- | Call the function below @nargs@ arguments under a handler that captures a
-- bounded traceback without running script-defined Lua.
callProtected ∷ State → Int → Int → IO (StatusCode, Maybe Text)
callProtected state nargs nresults =
  allocaBytes traceLimit $ \trace →
    alloca $ \traceLength → do
      status ← c_call state (fromIntegral nargs) (fromIntegral nresults) trace (fromIntegral traceLimit) traceLength
      traced ← readTrace trace traceLength
      pure (status, traced)

-- | Where the running Lua code is, from inside a function Lua called: the short
-- source of the Lua function that called it and a bounded traceback from there.
-- Runs no script-defined Lua; failing to build either leaves it out.
captureContext ∷ State → IO (Maybe Text, Maybe Text)
captureContext state =
  allocaBytes chunkLimit $ \chunk →
    alloca $ \chunkLength →
      allocaBytes traceLimit $ \trace →
        alloca $ \traceLength → do
          status ← c_context state chunk (fromIntegral chunkLimit) chunkLength trace (fromIntegral traceLimit) traceLength
          if status /= LUA_OK
            then pure (Nothing, Nothing)
            else (,) <$> readTrace chunk chunkLength <*> readTrace trace traceLength
  where
    chunkLimit = 128

readTrace ∷ Ptr CChar → Ptr CSize → IO (Maybe Text)
readTrace trace traceLength = do
  size ← peek traceLength
  if size == 0
    then pure Nothing
    else do
      bytes ← ByteString.packCStringLen (trace, fromIntegral size)
      pure (Just (Text.decodeUtf8Lenient bytes))
