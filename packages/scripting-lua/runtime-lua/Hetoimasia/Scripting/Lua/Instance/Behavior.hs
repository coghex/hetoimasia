-- | The driver of M1 behavior instances: a module the owner loads beside the
-- instance driver's, and the only Lua that runs a captured hook.
--
-- An M1 behavior instance's @self@, facade and hook functions are values of the VM
-- that its capture holds, by the capture's slot, in a table only the bridge reaches
-- (see "Hetoimasia.Scripting.Lua.Internal.Export"). Running a hook is not looking one
-- up by name: the host pushes the captured hook, the capture's @self@ and its facade
-- after this driver's function and the driver calls the hook with them. What the hook
-- is handed is the instance's own, never a field looked up again, so replacing a
-- field of the behavior table, or the role table, cannot change a running instance.
--
-- The driver builds no @api@ and keeps no record of its own: the legacy instance
-- driver's @api@ (@connect@, @subscribe@, @unsubscribe@) is not handed to a behavior
-- and is engine-internal. The one binding the driver calls is the instance layer's
-- @delta@, to take an update's @dt@, which is the same binding, with the same
-- meaning, as the instance driver's.
module Hetoimasia.Scripting.Lua.Instance.Behavior
  ( behaviorDriverRef
  , behaviorDriverSource
  , behaviorInit
  , behaviorUpdate
  , behaviorShutdown
  ) where

import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (..), ModuleRef (..), ModuleSource (..), Requirement (..))
import Hetoimasia.Scripting.Lua.Value (Schema (..))

-- | The driver's module.
behaviorDriverRef ∷ ModuleRef
behaviorDriverRef = ModuleRef "hetoimasia.instance.behavior" "1"

-- | The entry points, by what they run: each takes the instance's number, and the
-- shutdown reason as well.
behaviorInit, behaviorUpdate, behaviorShutdown ∷ Text
behaviorInit = "init"
behaviorUpdate = "update"
behaviorShutdown = "shutdown"

-- | The driver as a module. Its entry points take the hook, @self@ and the facade
-- from the host, and the instance's number (and the reason) as the declared values.
behaviorDriverSource ∷ ModuleSource
behaviorDriverSource =
  ModuleSource
    { sourceIdentity = behaviorDriverRef
    , sourceText = Char8.pack (Text.unpack (Text.unlines luaBody))
    , sourceEntries =
        [ EntryPoint behaviorInit Required [SInteger] []
        , EntryPoint behaviorUpdate Required [SInteger] []
        , EntryPoint behaviorShutdown Required [SInteger, SText] []
        ]
    }

-- The hook runs in the coroutine the driver runs in, so a wait or a yield inside an
-- update reaches the scheduler exactly as it would from a task's entry point, and is
-- refused in init and shutdown, which are finite calls.
luaBody ∷ [Text]
luaBody =
  [ "local host = hetoimasia_instance"
  , ""
  , "function init(hook, self, api, slot)"
  , "  hook(self, api)"
  , "end"
  , ""
  , "function update(hook, self, api, slot)"
  , "  local dt = host.delta(slot)"
  , "  if dt < 0 then error('no update is due for this instance', 0) end"
  , "  hook(self, dt)"
  , "end"
  , ""
  , "function shutdown(hook, self, api, slot, reason)"
  , "  hook(self, reason)"
  , "end"
  ]
