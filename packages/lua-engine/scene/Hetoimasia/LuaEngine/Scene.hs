-- | The fixed M1 scene schema (LFE-19): a script's plain table checked, copied and turned into bounded,
-- immutable CPU data for the publication that follows, without a window, a GPU or a native action.
--
-- = What a script writes
--
-- @
-- { clear = {r = 0, g = 0, b = 0}
-- , sprites = { {texture = texture, x = 32, y = 32, width = 256, height = 256} } }
-- @
--
-- Exactly those fields and no others, at every level; @sprites@ is a dense list, empty allowed; a
-- colour channel is an integer or an integral float from 0 to 255 (sRGB); a coordinate is a finite
-- number within a million of the origin; an extent is greater than zero and at most a million;
-- @texture@ is the instance's own live texture handle. No field has a default and nothing is coerced,
-- clamped, snapped or skipped. A table may be repeated anywhere in the scene: each occurrence is a
-- sprite of its own, in its place.
--
-- = The pieces
--
-- * "Hetoimasia.LuaEngine.Scene.Limits": the limits, from a validated profile.
-- * 'prepareScene': the copied value to a 'PreparedScene', or the first refusal, whole.
-- * 'sceneCandidate': a scene's content as the renderer's pure frame for given target metrics.
-- * 'sceneSchema', 'sceneArgumentCheck', 'scenePublishBinding': the host-facing parts.
--
-- = Owned state, threads and lifetime
--
-- None is owned. Preparation runs on the calling instance's thread inside the binding call, borrows
-- each texture only to copy its identity and dimensions, and returns a pure value; a refusal or an
-- exception leaves nothing behind, and there is no history, queue or cache of drafts. A prepared scene
-- holds no Lua object and nothing it was prepared from can reach it. It is the record of a check at one
-- moment, not a hold on any texture: the publication (LFE-20) owns the window's single draft and its
-- atomic replacement, and must revalidate and hold the textures ('textureUses') itself, in the same
-- step as its publication, against the instance releasing a texture or ending.
module Hetoimasia.LuaEngine.Scene
  ( -- * Limits
    SceneLimits
  , sceneLimits
  , SceneLimitsRefused (..)
  , sceneSpriteLimit
  , sceneValueLimits
  , scenePublishLimits
  , sceneCallWindowBytes
  , sceneCoordinateLimit
  , sceneExtentLimit

    -- * Preparing
  , prepareScene
  , PreparedScene (..)
  , SceneContent (..)
  , SceneSprite (..)
  , SceneRect (..)
  , TextureUse (..)
  , textureUses

    -- * Refusals
  , SceneRefusal (..)
  , SceneField (..)
  , SceneChannel (..)
  , SceneAxis (..)
  , SceneReason (..)
  , refusalReasonText
  , SceneDefect (..)

    -- * The renderer's frame
  , initialContent
  , sceneCandidate
  , SnapshotRefusal (..)

    -- * The binding
  , sceneSchema
  , sceneArgumentCheck
  , scenePublishBinding

    -- * Conversions
  , linearOfByte
  ) where

import Hetoimasia.LuaEngine.Scene.Binding
import Hetoimasia.LuaEngine.Scene.Colour (linearOfByte)
import Hetoimasia.LuaEngine.Scene.Limits
import Hetoimasia.LuaEngine.Scene.Prepare
import Hetoimasia.LuaEngine.Scene.Snapshot
import Hetoimasia.LuaEngine.Scene.Types
