-- | The limits scene preparation works under, read once from a validated 'Profile'.
--
-- The fixed M1 profile gives 4,096 sprites, a 2 MiB encoded scene input, nesting of 4, a coordinate
-- magnitude and an extent of 1,000,000, all inside the common copied-value ceilings (16 MiB, depth 8,
-- 65,536 elements) that the profile's validation already related. An injected, smaller profile
-- shrinks any of them and can be exercised where the fixed schema cannot reach a ceiling before
-- another limit refuses it.
--
-- The three crossing limits become one 'ValueLimits' ('sceneValueLimits') that the scene binding
-- reads its argument under ('Hetoimasia.Scripting.Lua.Registration.withArgumentLimits'), so the
-- reader stops at the scene's own bytes, depth and elements while it copies, and never admits the
-- common ceiling first. The element limit is the profile's 'sceneElementBound': the scene table, the
-- clear table with its three channels and the sprites table, and six values for each sprite.
module Hetoimasia.LuaEngine.Scene.Limits
  ( SceneLimits
  , sceneLimits
  , SceneLimitsRefused (..)
  , sceneSpriteLimit
  , sceneValueLimits
  , scenePublishLimits
  , sceneCallWindowBytes
  , sceneCoordinateLimit
  , sceneExtentLimit
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (SceneInputBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CoordinateMagnitude, SceneDepth, SceneSprites, SpriteExtentMaximum)
  , Profile
  , bytesLimit
  , countLimit
  , sceneCallExtraElements
  , sceneElementBound
  )
import Hetoimasia.Scripting.Lua.Value (LimitsRefusal, ValueLimits, valueLimits)

-- | What preparation reads: the sprite limit, the crossing limits and the coordinate and extent
-- ranges.
data SceneLimits = SceneLimits
  { sceneSpriteLimit ∷ !Int
  , sceneValueLimits ∷ !ValueLimits
  , scenePublishLimits ∷ !ValueLimits
    -- ^ The crossing limits of a call that carries a window handle beside the scene: the scene's own, plus the
    -- handle's one element and exactly the bytes the reader charges a capability ('sceneCallWindowBytes'). A binding
    -- that takes the window and the scene reads its arguments under these, because the reader keeps one counter for
    -- all the arguments of a call; the scene's own bytes and elements are then exactly its bound, no more. A
    -- validated profile always has room for them ('Hetoimasia.LuaEngine.Profile.sceneCallElementBound'; its
    -- byte allowance, 'Hetoimasia.LuaEngine.Profile.sceneCallExtraBytes', is the larger figure validation reserves).
  , sceneCoordinateLimit ∷ !Int
  , sceneExtentLimit ∷ !Int
  }
  deriving (Eq, Show)

-- | The bytes the value reader charges for a capability, and so for the window handle beside the scene: 21 (one
-- element). The binding's allowance for the handle is this charge exactly, never the profile validation's larger
-- reserve, which would let a scene encode more than 'SceneInputBytes'.
sceneCallWindowBytes ∷ Int
sceneCallWindowBytes = 21

-- | Why a profile cannot be turned into scene limits.
data SceneLimitsRefused
  = -- | A profile value that does not fit the machine integer it is held in: which one.
    LimitNotRepresentable !Text
  | -- | The crossing limits the host accepts do not hold the scene's.
    LimitsRefused !LimitsRefusal
  deriving (Eq, Show)

-- | The scene limits of a validated profile.
sceneLimits ∷ Profile → Either SceneLimitsRefused SceneLimits
sceneLimits profile = do
  sprites ← machine "SceneSprites" (count SceneSprites)
  bytes ← machine "SceneInputBytes" (let Bytes value = bytesLimit profile SceneInputBytes in value)
  depth ← machine "SceneDepth" (count SceneDepth)
  elements ← machine "sceneElementBound" (let Count value = sceneElementBound profile in value)
  coordinate ← machine "CoordinateMagnitude" (count CoordinateMagnitude)
  extent ← machine "SpriteExtentMaximum" (count SpriteExtentMaximum)
  limits ← either (Left . LimitsRefused) Right (valueLimits bytes depth elements)
  publish ← either (Left . LimitsRefused) Right (valueLimits (bytes + sceneCallWindowBytes) depth (elements + fromIntegral sceneCallExtraElements))
  Right (SceneLimits sprites limits publish coordinate extent)
  where
    count limit = let Count value = countLimit profile limit in value
    machine ∷ Text → Word64 → Either SceneLimitsRefused Int
    machine name value
      | value <= fromIntegral (maxBound ∷ Int) = Right (fromIntegral value)
      | otherwise = Left (LimitNotRepresentable name)
