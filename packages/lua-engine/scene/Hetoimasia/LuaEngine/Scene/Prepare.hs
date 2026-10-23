-- | Scene preparation: the copied value a script handed over, checked and turned into a 'PreparedScene'
-- or refused whole.
--
-- = What it reads
--
-- The value is the host's bounded copy of the script's table, already read raw (no metamethod ran, no
-- metatable or cycle was admitted) and checked against 'Hetoimasia.LuaEngine.Scene.Binding.sceneSchema':
-- exactly @clear@ and @sprites@, exactly @r@, @g@ and @b@ in the clear, a dense list of sprites with
-- exactly @texture@, @x@, @y@, @width@ and @height@. Preparation does not trust that: a client that
-- builds the value itself is checked for the same shape ('NotTheDeclaredShape'), and the sprite count
-- is checked against the limit before any sprite is read, by walking at most one past the limit, so
-- work is bounded by the limit and not by the list.
--
-- = Order, and what is whole
--
-- The first refusal in field order (clear, then each sprite's texture, x, y, width, height, in list
-- order) is the whole answer: no sprite is skipped, no partial scene escapes, and nothing is
-- published, held or changed. A sprite that repeats another's table, or a texture used again, is read
-- at each of its occurrences and keeps each of its places.
--
-- = Texture authority
--
-- Each distinct texture is borrowed once, through the calling instance's own lease, for as long as it
-- takes to copy its identity and dimensions ('withTextureOr'); the borrow decides and reads in one
-- step on this thread. A lease that has ended, is another instance's (a peer sharing the VM
-- included), or holds another type is a refusal ('TextureAuthorityRefused') and never an exception; whatever
-- the borrow itself raises (a defect, a cancellation) is raised, not refused. Success is the answer
-- for this moment; see "Hetoimasia.LuaEngine.Scene.Types".
--
-- = Threads and temporary state
--
-- It runs on the calling thread, inside the binding call, and keeps nothing: the only state is the
-- accumulating list and a map of the textures already borrowed, both dropped when it returns or
-- raises.
module Hetoimasia.LuaEngine.Scene.Prepare
  ( prepareScene
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Scene.Colour (channelByte, clearOfBytes)
import Hetoimasia.LuaEngine.Scene.Geometry (coordinate, extent, rectangle)
import Hetoimasia.LuaEngine.Scene.Limits (SceneLimits, sceneSpriteLimit)
import Hetoimasia.LuaEngine.Scene.Types
import Hetoimasia.LuaEngine.Texture (textureHandleType, withTextureOr)
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Scripting.Lua.Value
  ( Value (VCapability, VList, VRecord)
  , capabilityKey
  , capabilityTypeName
  )

-- | Prepare a scene for the instance that owns these leases, or refuse it.
prepareScene ∷ SceneLimits → Leases → Value → IO (Either SceneRefusal PreparedScene)
prepareScene limits leases = \case
  VRecord fields
    | Just [clear, sprites] ← fieldsOf ["clear", "sprites"] fields →
        case (clear, sprites) of
          (VRecord channels, VList list) → case clearColour channels of
            Left refusal → pure (Left refusal)
            Right clearColour' → case spriteList list of
              Left refusal → pure (Left refusal)
              Right sprites' → do
                found ← readSprites Map.empty 1 sprites' []
                pure $ do
                  readSprites' ← found
                  Right (PreparedScene (SceneContent clearColour' readSprites') leases)
          (VRecord _, _) → pure (Left (SceneRefusal AtSprites NotTheDeclaredShape))
          _ → pure (Left (SceneRefusal AtClear NotTheDeclaredShape))
  _ → pure (Left (SceneRefusal AtScene NotTheDeclaredShape))
  where
    -- The sprites, if there are not more than the limit: at most one past it is ever walked.
    spriteList list
      | length (take (sceneSpriteLimit limits + 1) list) > sceneSpriteLimit limits =
          Left (SceneRefusal AtSprites (TooManySprites (sceneSpriteLimit limits)))
      | otherwise = Right list

    clearColour channels = case fieldsOf ["r", "g", "b"] channels of
      Nothing → Left (SceneRefusal AtClear NotTheDeclaredShape)
      Just [r, g, b] → do
        r' ← at ChannelRed r
        g' ← at ChannelGreen g
        b' ← at ChannelBlue b
        Right (clearOfBytes r' g' b')
      Just _ → Left (SceneRefusal AtClear NotTheDeclaredShape)
      where
        at channel value = either (Left . SceneRefusal (AtClearChannel channel)) Right (channelByte value)

    -- Each sprite in turn. @seen@ holds the textures already borrowed, by lease key, so a texture
    -- used by many sprites is borrowed once and every occurrence still carries it.
    readSprites ∷ Map.Map Word64 TextureUse → Int → [Value] → [SceneSprite] → IO (Either SceneRefusal [SceneSprite])
    readSprites _ _ [] done = pure (Right (reverse done))
    readSprites seen index (value : rest) done = case value of
      VRecord fields
        | Just [texture, x, y, width, height] ← fieldsOf ["texture", "x", "y", "width", "height"] fields →
            borrow seen index texture >>= \case
              Left refusal → pure (Left refusal)
              Right (use, seen') → case geometry index x y width height of
                Left refusal → pure (Left refusal)
                Right rect → readSprites seen' (index + 1) rest (SceneSprite use rect : done)
      _ → pure (Left (SceneRefusal (AtSprite index) NotTheDeclaredShape))

    geometry index x y width height = do
      x' ← wrap (AtX index) (coordinate limits x)
      y' ← wrap (AtY index) (coordinate limits y)
      w' ← wrap (AtWidth index) (extent limits width)
      h' ← wrap (AtHeight index) (extent limits height)
      wrap (AtSprite index) (rectangle x' y' w' h')
    wrap field = either (Left . SceneRefusal field) Right

    borrow ∷ Map.Map Word64 TextureUse → Int → Value → IO (Either SceneRefusal (TextureUse, Map.Map Word64 TextureUse))
    borrow seen index = \case
      VCapability handle
        | capabilityTypeName handle /= textureHandleType → pure (Left (SceneRefusal (AtTexture index) TextureRequired))
        | Just use ← Map.lookup (capabilityKey handle) seen → pure (Right (use, seen))
        | otherwise → checked seen index handle
      _ → pure (Left (SceneRefusal (AtTexture index) TextureRequired))

    checked seen index handle =
      withTextureOr leases (capabilityKey handle) (\why → pure (Left why)) (pure . Right) >>= \case
        Left why → pure (Left (SceneRefusal (AtTexture index) (TextureAuthorityRefused why)))
        Right view →
          let use = TextureUse (capabilityKey handle) view
           in pure (Right (use, Map.insert (capabilityKey handle) use seen))

-- | The values of exactly these fields, in this order, if the record has exactly these and no other.
fieldsOf ∷ [Text] → [(Text, Value)] → Maybe [Value]
fieldsOf names fields
  | length fields /= length names = Nothing
  | otherwise = traverse (`lookup` fields) names
