-- | The scene as an argument of a binding: the schema the host reads, the check that refuses a
-- candidate as an ordinary Lua error, and a publication binding for a controlled sink.
--
-- = What the host does, and what this adds
--
-- The host reads the script's table raw, under the scene's own limits ('sceneValueLimits', applied with
-- 'withArgumentLimits': the reader stops at the scene's bytes, depth and elements while it copies, and
-- the common 16 MiB ceiling is never admitted first), refuses a metatable, a cycle, a hole, an extra or
-- a missing key, a wrong type and a handle that is not a live texture handle of this VM, and copies a
-- table shared by several places at each of them. The argument check ('sceneArgumentCheck') then runs
-- the preparation ('prepareScene') over the copied value: the sprite limit, the colour, the geometry
-- and the calling instance's authority over each texture. Any refusal is an ordinary Lua error
-- (@namespace.name: scene.sprites[3].width: ...@, at most 160 bytes of reason) raised before the
-- action: no sink call, no hold, no effect, and a @pcall@ that catches it goes on and can prepare a
-- valid next candidate. An uncaught one is the script's own error under the existing classification of
-- an ordinary Lua error: the calling instance fails with that bounded message.
--
-- = The action prepares again
--
-- The check keeps nothing, because a binding's closure is shared by every owner that registers it. The
-- action therefore prepares the copied value again, on the same thread in the same call, and hands the
-- result to the sink. A refusal there cannot come from the script (the value and the instance are the
-- same, and nothing runs between), so it is a 'SceneDefect', the engine's failure, never recoverable.
-- The sink is called only on complete success and receives a 'PreparedScene': the sink (LFE-20) owns the
-- window's admission and the atomic replacement, and revalidates the textures when it acquires them.
--
-- The binding this module builds is a helper for that consumer and for tests; which namespace and
-- name the graphics facade installs it under is the facade's (LFE-21).
module Hetoimasia.LuaEngine.Scene.Binding
  ( sceneSchema
  , sceneArgumentCheck
  , scenePublishBinding
  ) where

import Control.Exception (throwIO)
import Data.Text (Text)
import Hetoimasia.LuaEngine.Scene.Limits (SceneLimits, sceneValueLimits)
import Hetoimasia.LuaEngine.Scene.Prepare (prepareScene)
import Hetoimasia.LuaEngine.Scene.Types
import Hetoimasia.LuaEngine.Texture (textureHandleType)
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , stateOperation
  , withArgumentCheck
  , withArgumentLimits
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SList, SNumber, SRecord))
import qualified Data.Text as Text

-- | The M1 scene: exactly @clear@ (exactly @r@, @g@ and @b@) and @sprites@ (a dense list of records
-- with exactly @texture@, @x@, @y@, @width@ and @height@). The numbers are read as numbers, keeping
-- which representation they were, because the colour rule accepts an integral float that an integer
-- schema refuses; their ranges are checked by preparation.
sceneSchema ∷ Schema
sceneSchema =
  SRecord
    [ ("clear", SRecord [("r", SNumber), ("g", SNumber), ("b", SNumber)])
    , ("sprites", SList (SRecord [("texture", SCapability textureHandleType), ("x", SNumber), ("y", SNumber), ("width", SNumber), ("height", SNumber)]))
    ]

-- | The check of a scene binding's copied argument: 'Nothing' when it prepares, otherwise the bounded
-- reason. It borrows each texture only to read it and keeps nothing.
sceneArgumentCheck ∷ SceneLimits → Leases → ArgumentCheck
sceneArgumentCheck limits leases _ = \case
  [scene] →
    prepareScene limits leases scene >>= \case
      Left refusal → pure (Just (refusalReasonText refusal))
      Right _ → pure Nothing
  other → pure (Just (Text.pack ("a scene is one argument, not " <> show (length other))))

-- | A binding that takes one scene, refuses it as an ordinary Lua error when it is not one, and
-- otherwise calls the sink with the prepared scene. Answers nothing to the script.
scenePublishBinding ∷ Text → SceneLimits → Leases → (PreparedScene → IO ()) → Binding
scenePublishBinding name limits leases sink =
  withArgumentLimits (sceneValueLimits limits) $
    withArgumentCheck (sceneArgumentCheck limits leases) $
      stateOperation name [sceneSchema] [] $ \case
        [scene] →
          prepareScene limits leases scene >>= \case
            Left refusal → throwIO (SceneDefect (refusalReasonText refusal))
            Right prepared → [] <$ sink prepared
        _ → throwIO (SceneDefect "the host handed a scene binding other than one argument")
