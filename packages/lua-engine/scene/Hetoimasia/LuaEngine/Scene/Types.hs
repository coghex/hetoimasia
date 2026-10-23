-- | What scene preparation (LFE-19) produces and refuses: the bounded, immutable scene, the texture
-- authority it was checked against, and the reasons a candidate is not a scene.
--
-- = Ownership
--
-- Every value here is pure, strict and immutable. A 'PreparedScene' holds no Lua table, stack index,
-- registry reference, closure or callback, so nothing authored can change it after it was made. Its
-- one reference to a live object is 'preparedOwner', the instance owner's 'Leases' handle, kept so
-- the publication that follows can revalidate the textures where they are owned. It is the owner's
-- own handle, not a grant: holding it lets nobody use a texture the owner no longer holds.
--
-- = What a 'PreparedScene' is not
--
-- It is the record of a check, made at one moment on the calling instance's thread, that the
-- instance's textures were live, ready and its own. It is not a hold on any of them, not a publication
-- and not a promise that a publication will succeed. The instance may release a texture, or end, the
-- next moment; the publication must ask again, atomically with its own acquisition ('textureUses').
module Hetoimasia.LuaEngine.Scene.Types
  ( -- * The scene
    SceneContent (..)
  , SceneSprite (..)
  , SceneRect (..)
  , TextureUse (..)
  , PreparedScene (..)
  , textureUses

    -- * Refusals
  , SceneRefusal (..)
  , SceneField (..)
  , SceneChannel (..)
  , SceneAxis (..)
  , SceneReason (..)
  , refusalReasonText
  , SceneDefect (..)
  ) where

import Control.Exception (Exception)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Texture (TextureView)
import Hetoimasia.Render.TwoD.Snapshot (ClearColour)
import Hetoimasia.Scripting.Lua.Lease (Leases)

-- | A texture the scene names, as it was checked: the key of the lease the script's handle names, and
-- the texture it borrowed there (the backend's registration identity and the source dimensions).
--
-- The identity is exactly what the backend reported, complete: nothing here derives, narrows or
-- substitutes one, so a stale identity is never read as a newer texture's.
data TextureUse = TextureUse
  { useLease ∷ !Word64
  , useView ∷ !TextureView
  }
  deriving (Eq, Show)

-- | A sprite's rectangle in the UI's logical pixels, from the upper left: the origin and the extent,
-- already converted to the renderer's 32-bit floats and checked (finite, a positive extent, and a far
-- edge in each axis that is not the origin).
data SceneRect = SceneRect
  { rectX ∷ !Float
  , rectY ∷ !Float
  , rectWidth ∷ !Float
  , rectHeight ∷ !Float
  }
  deriving (Eq, Show)

-- | One sprite: the whole image of a texture drawn into a rectangle.
data SceneSprite = SceneSprite
  { spriteTexture ∷ !TextureUse
  , spriteRect ∷ !SceneRect
  }
  deriving (Eq, Show)

-- | A scene's content: its opaque clear colour in linear light, and its sprites in the order the
-- script listed them (the order they are drawn in, later over earlier). Pure data with no owner, so
-- the initial scene ('Hetoimasia.LuaEngine.Scene.initialContent') is one too.
data SceneContent = SceneContent
  { sceneClear ∷ !ClearColour
  , sceneSprites ∷ ![SceneSprite]
  }
  deriving (Eq, Show)

-- | A scene that preparation accepted, with the owner whose textures it was checked against.
data PreparedScene = PreparedScene
  { preparedContent ∷ !SceneContent
  , preparedOwner ∷ !Leases
  }

-- | The textures the scene names, once each, in order of first use: what a publication revalidates
-- (through the owner's 'Leases') and holds before it publishes.
textureUses ∷ PreparedScene → [TextureUse]
textureUses = distinct [] . map spriteTexture . sceneSprites . preparedContent
  where
    distinct _ [] = []
    distinct seen (use : rest)
      | useLease use `elem` seen = distinct seen rest
      | otherwise = use : distinct (useLease use : seen) rest

-- Refusals -------------------------------------------------------------------------------------------

-- | A candidate that is not a scene, and where.
data SceneRefusal = SceneRefusal
  { refusalField ∷ !SceneField
  , refusalReason ∷ !SceneReason
  }
  deriving (Eq, Show)

-- | Where in the candidate a refusal is. A sprite's index counts from 1, as the script's list does.
data SceneField
  = AtScene
  | AtSprites
  | AtClear
  | AtClearChannel !SceneChannel
  | AtSprite !Int
  | AtTexture !Int
  | AtX !Int
  | AtY !Int
  | AtWidth !Int
  | AtHeight !Int
  deriving (Eq, Show)

-- | A clear colour channel.
data SceneChannel = ChannelRed | ChannelGreen | ChannelBlue
  deriving (Eq, Show, Enum, Bounded)

-- | A rectangle's axis.
data SceneAxis = AxisX | AxisY
  deriving (Eq, Show)

-- | Why a candidate is refused. Expected refusals only: a defect of the validator or the converter is
-- an exception, never one of these.
data SceneReason
  = -- | The value is not of the declared shape: a missing or extra field, a list that is not a list.
    NotTheDeclaredShape
  | -- | More sprites than the profile allows: the limit.
    TooManySprites !Int
  | -- | A number was required.
    NumberRequired
  | NotFinite
  | -- | A colour channel is a float with a fraction.
    ChannelNotIntegral
  | ChannelOutOfRange
  | -- | A coordinate outside the closed range of minus to plus this.
    CoordinateOutOfRange !Int
  | -- | A width or height of zero or less.
    ExtentNotPositive
  | -- | A width or height above this.
    ExtentOutOfRange !Int
  | -- | A positive extent that is zero as a 32-bit float.
    ExtentUnderflows
  | -- | The far edge on this axis is the origin as a 32-bit float, or not finite.
    FarEdgeCollapses !SceneAxis
  | -- | A capability of the wrong type where a texture is required.
    TextureRequired
  | -- | The calling instance's authority refused the texture: the bounded reason.
    TextureAuthorityRefused !Text
  deriving (Eq, Show)

-- | A refusal's reason as the bounded text a script sees: the place, then the reason, in fixed words
-- and numbers only. Nothing of the authored value is in it, so its length is bounded by construction;
-- it is at most 160 bytes.
refusalReasonText ∷ SceneRefusal → Text
refusalReasonText (SceneRefusal field reason) = clip (place field <> ": " <> why reason)
  where
    place = \case
      AtScene → "scene"
      AtSprites → "scene.sprites"
      AtClear → "scene.clear"
      AtClearChannel channel → "scene.clear." <> channelName channel
      AtSprite index → sprite index
      AtTexture index → sprite index <> ".texture"
      AtX index → sprite index <> ".x"
      AtY index → sprite index <> ".y"
      AtWidth index → sprite index <> ".width"
      AtHeight index → sprite index <> ".height"
    sprite index = "scene.sprites[" <> number index <> "]"
    channelName = \case
      ChannelRed → "r"
      ChannelGreen → "g"
      ChannelBlue → "b"
    why = \case
      NotTheDeclaredShape → "not the declared shape"
      TooManySprites limit → "more than " <> number limit <> " sprites"
      NumberRequired → "a number is required"
      NotFinite → "not finite"
      ChannelNotIntegral → "a colour channel is a whole number"
      ChannelOutOfRange → "a colour channel is from 0 to 255"
      CoordinateOutOfRange limit → "a coordinate is from -" <> number limit <> " to " <> number limit
      ExtentNotPositive → "an extent is greater than zero"
      ExtentOutOfRange limit → "an extent is at most " <> number limit
      ExtentUnderflows → "the extent is too small to represent"
      FarEdgeCollapses axis → "the far edge is the origin on the " <> axisName axis <> " axis"
      TextureRequired → "a texture is required"
      TextureAuthorityRefused found → "texture refused: " <> found
    axisName = \case
      AxisX → "x"
      AxisY → "y"
    number = Text.pack . show
    clip text
      | ByteString.length (Encoding.encodeUtf8 text) <= 160 = text
      | otherwise = Text.take 157 text <> "..."

-- | A defect of preparation's own: a scene its argument check accepted was refused when the action
-- prepared it again. The check and the action run in one call on one thread, so this is not a refusal
-- a script can cause; it is the engine's failure, raised as the application's and never recoverable.
newtype SceneDefect = SceneDefect Text
  deriving (Eq, Show)

instance Exception SceneDefect

