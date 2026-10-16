-- | The standard libraries a VM may be given, one at a time.
--
-- Lua's @luaL_openlibs@ opens every standard library at once, including @io@,
-- @os@, @debug@, and the native module loader in @package@. Untrusted execution
-- later depends on opening a chosen few and nothing else, so this bridge never
-- calls it: a VM is built from an explicit list, and the empty list is a
-- supported VM with no standard library at all.
--
-- Which libraries a given domain may have is not decided here. This module only
-- makes each one separately nameable; which libraries an owner opens is the
-- application's configuration, and the namespaces it exposes beside them are the
-- owner's policy over a registration (LUA-3).
--
-- @coroutine@ and @utf8@ are absent because the binding exports no opener for
-- them. Adding one is a change to the binding, not a policy decision here.
module Hetoimasia.Scripting.Lua.Internal.Library
  ( Library (..)
  , libraryModuleName
  , libraryOpener
  ) where

import Data.ByteString (ByteString)
import Lua
  ( CFunction
  , luaopen_base
  , luaopen_io
  , luaopen_math
  , luaopen_os
  , luaopen_package
  , luaopen_string
  , luaopen_table
  )

-- | One standard library.
data Library
  = -- | The basic functions, in the globals table: @print@, @pairs@,
    -- @pcall@, @error@, @type@, and the rest.
    LibraryBase
  | -- | @package@, and with it @require@ and the native module loader.
    LibraryPackage
  | -- | @string@, and the string metatable's index.
    LibraryString
  | -- | @table@.
    LibraryTable
  | -- | @math@.
    LibraryMath
  | -- | @io@.
    LibraryIo
  | -- | @os@.
    LibraryOs
  | -- | @debug@.
    LibraryDebug
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The debug library without @sethook@. A hook is script-defined Lua that Lua
-- runs on a call, a return, a line or a count, including when it dispatches the
-- message handler that records a fault's traceback; a script that could set one
-- could run code, or replace the original failure with its own, while a fault is
-- recorded. The rest of the library is as Lua ships it.
foreign import ccall "hetoimasia_lua_bridge.h &hetoimasia_luaopen_debug"
  luaopenDebug ∷ CFunction

-- | The module name the library is registered and globally bound under.
--
-- The basic functions are the globals table itself, which Lua names @_G@.
libraryModuleName ∷ Library → ByteString
libraryModuleName = \case
  LibraryBase → "_G"
  LibraryPackage → "package"
  LibraryString → "string"
  LibraryTable → "table"
  LibraryMath → "math"
  LibraryIo → "io"
  LibraryOs → "os"
  LibraryDebug → "debug"

-- | The C function that opens the library.
libraryOpener ∷ Library → CFunction
libraryOpener = \case
  LibraryBase → luaopen_base
  LibraryPackage → luaopen_package
  LibraryString → luaopen_string
  LibraryTable → luaopen_table
  LibraryMath → luaopen_math
  LibraryIo → luaopen_io
  LibraryOs → luaopen_os
  LibraryDebug → luaopenDebug
