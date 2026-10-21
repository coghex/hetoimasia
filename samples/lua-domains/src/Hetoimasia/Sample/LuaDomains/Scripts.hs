{-# LANGUAGE TemplateHaskell #-}

-- | The sample's Lua sources, application-owned files under the library's source directory
-- (@src/lua/@) and embedded at compile time, and the modules built from them.
--
-- * @gameplay_init.lua@ is gameplay's initial chunk: it removes @math.random@ and
--   @math.randomseed@ before any module runs.
-- * @gameplay.lua@ is gameplay's behavior module.
-- * @ui_facade.lua@ is the UI's initial chunk: the validation facade in front of the typed
--   intention binding.
-- * @interface.lua@ is the UI's behavior module.
module Hetoimasia.Sample.LuaDomains.Scripts
  ( gameplayChunk
  , gameplayInitSource
  , gameplayFailureSource
  , updateSource
  , gameplayModule
  , gameplaySource
  , interfaceModule
  , interfaceSource
  , facadeChunk
  , facadeSource
  , moduleSource
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains.Embed (embedFile)
import Hetoimasia.Scripting.Lua.Instance (hookEntries)
import Hetoimasia.Scripting.Lua.Owner (ChunkName, EntryPoint, ModuleRef (..), ModuleSource (..), chunkName)

gameplayInitSource ∷ ByteString
gameplayInitSource = $(embedFile "src/lua/gameplay_init.lua")

gameplaySource ∷ ByteString
gameplaySource = $(embedFile "src/lua/gameplay.lua")

facadeSource ∷ ByteString
facadeSource = $(embedFile "src/lua/ui_facade.lua")

-- | The `failure` scenario's gameplay behavior: the normal one, which then raises at tick six.
gameplayFailureSource ∷ ByteString
gameplayFailureSource = gameplaySource <> $(embedFile "src/lua/gameplay_failure.lua")

-- | The update wrapper, appended to every gameplay module.
updateSource ∷ ByteString
updateSource = $(embedFile "src/lua/gameplay_update.lua")

interfaceSource ∷ ByteString
interfaceSource = $(embedFile "src/lua/interface.lua")

-- | A module with this name, source and the hooks an instance's module declares.
moduleSource ∷ Text → ByteString → ModuleSource
moduleSource name source = ModuleSource (ModuleRef name "1") source hookEntries

-- | Gameplay's behavior module: this source, the update wrapper appended, and the hooks declared, with these entry
-- points beside them (what a test's own tasks call).
gameplayModule ∷ [EntryPoint] → ByteString → ModuleSource
gameplayModule extra source = ModuleSource (ModuleRef "gameplay" "1") (source <> updateSource) (hookEntries <> extra)

-- | The UI's behavior module.
interfaceModule ∷ ByteString → ModuleSource
interfaceModule = moduleSource "interface"

-- | Gameplay's initial chunk, named for its diagnostics.
gameplayChunk ∷ (ChunkName, ByteString)
gameplayChunk = (chunkName "gameplay_init", gameplayInitSource)

-- | The UI's initial chunk, named for its diagnostics.
facadeChunk ∷ (ChunkName, ByteString)
facadeChunk = (chunkName "ui_facade", facadeSource)
