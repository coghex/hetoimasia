-- | Registering textures with their cutout marks, swapping them under the mark
-- rule, and the logical release marker (R2D-8; D-19, D-27, D-28).
--
-- = Registration
--
-- 'registerTexture' registers an uploaded texture with the table through the
-- host's builders and answers a @render-api@ 'TextureHandle', made from the
-- backend's index and generation, so a stale handle never aliases a reused
-- index. It takes the texture's decoded image and a 'MarkPolicy': the mark is
-- by default the image's @decodedBinaryAlpha@ — whether its alpha is binary,
-- which @asset-image@ computes — or an explicit override. The mark is stored
-- with the complete handle for the handle's life and is never changed by
-- anything but the handle's release; 'registeredMarks' answers the
-- 'CutoutMarks' of the handles registered. Planning keeps using
-- 'noCutoutMarks' until R2D-9, so a mark changes nothing rendered here.
--
-- = Swaps (D-27)
--
-- 'swapTexture' gives a registered handle a replacement through the table's
-- swap, unchanged, under the mark rule: a replacement whose computed mark
-- differs from the registered one is refused, naming both, unless the caller
-- states 'KeepRegisteredMark'. A genuine change of rendering semantics takes a
-- new handle. A refusal of any kind changes nothing: the handle keeps its
-- image, its mark and any swap already pending, because the rule is checked
-- before the table is asked.
--
-- = Release
--
-- 'markReleased' is the /logical/ release: it marks a handle released at once,
-- for publication's check, and answers 'False' for one never registered or
-- already marked. The table release ('releaseTextureNow') is the backend's,
-- run on the owner's thread once nothing adopted still shows the handle; the
-- window adapter ("Hetoimasia.Render.TwoD.Vulkan.Window") sequences the two.
--
-- = State
--
-- Each registered handle's mark and release flag are owned by a 'Textures'.
-- 'registerTexture' adds a handle, 'markReleased' flags it and
-- 'releaseTextureNow' removes its mark; any thread reads them, in STM. They
-- live from the registration until the table release, and are never reset.
--
-- The registrations and the swap run on the graphics owner's thread, as every
-- backend construction does; the state is read from any thread.
module Hetoimasia.Render.TwoD.Vulkan.Textures
  ( Textures
  , newTextures
  , MarkPolicy (..)
  , SwapPolicy (..)
  , TextureRefusal (..)
  , registerTexture
  , swapTexture
  , releaseTextureNow
  , markReleased
  , isReleased
  , registeredMark
  , registeredMarks
  , toBackendHandle
  , fromBackendHandle
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Image, Refusal)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (SwapTicket, TextureHandle (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))

-- | The registry: each registered handle's mark, and the handles marked
-- released.
newtype Textures = Textures (TVar Ledger)

data Ledger = Ledger
  { ledgerMarks ∷ !(Map Api.TextureHandle Bool)
  , ledgerReleased ∷ !(Set Api.TextureHandle)
  }

newTextures ∷ IO Textures
newTextures = Textures <$> newTVarIO (Ledger Map.empty Set.empty)

-- | How a registration chooses the texture's mark.
data MarkPolicy
  = -- | The decoded image's own computed mark, @decodedBinaryAlpha@.
    DefaultMark
  | -- | This mark, whatever the image computes (D-19).
    OverrideMark !Bool
  deriving (Eq, Show)

-- | What a swap does about a replacement whose computed mark differs.
data SwapPolicy
  = -- | Refuse it, naming both marks (D-27).
    RefuseMarkChange
  | -- | Accept it and keep the registered mark: the caller's explicit
    -- statement that the rendering semantics did not change.
    KeepRegisteredMark
  deriving (Eq, Show)

-- | Why a registration or a swap was refused, before anything changed.
data TextureRefusal
  = -- | The backend refused.
    TextureRefusedByBackend !Refusal
  | -- | A swap to an image whose computed mark differs from the registered
    -- one, without an explicit keep: the registered mark, then the
    -- replacement's.
    MarkMismatch !Bool !Bool
  | -- | The handle was never registered here.
    TextureUnknown !Api.TextureHandle
  | -- | The handle has been released: its release was requested.
    TextureReleased !Api.TextureHandle
  deriving (Eq, Show)

-- | The backend's handle for a @render-api@ one: the same index and generation.
toBackendHandle ∷ Api.TextureHandle → TextureHandle
toBackendHandle handle = TextureHandle (ApiBackend.handleIndex handle) (ApiBackend.handleGeneration handle)

-- | The @render-api@ handle for a backend one.
fromBackendHandle ∷ TextureHandle → Api.TextureHandle
fromBackendHandle backend = ApiBackend.textureHandle (handleIndex backend) (handleGeneration backend)

-- | Register an uploaded texture with the table, storing its mark with the
-- handle it returns. Refused as the table refuses: nothing is stored.
registerTexture
  ∷ Builders q inst msgr phys dev cmd
  → Textures
  → Image
  → DecodedImage
  → MarkPolicy
  → IO (Either TextureRefusal Api.TextureHandle)
registerTexture builders (Textures ledger) image decoded policy =
  registerImage builders image >>= \case
    Left refusal → pure (Left (TextureRefusedByBackend refusal))
    Right backend → do
      let handle = fromBackendHandle backend
          mark = case policy of
            DefaultMark → decodedBinaryAlpha decoded
            OverrideMark explicit → explicit
      atomically $ do
        held ← readTVar ledger
        writeTVar ledger held {ledgerMarks = Map.insert handle mark (ledgerMarks held), ledgerReleased = Set.delete handle (ledgerReleased held)}
      pure (Right handle)

-- | Swap a registered handle to a replacement under the mark rule. Refused,
-- changing nothing: a handle never registered or already released, a mark
-- that differs without 'KeepRegisteredMark', and whatever the table refuses.
swapTexture
  ∷ Builders q inst msgr phys dev cmd
  → Textures
  → Api.TextureHandle
  → Image
  → DecodedImage
  → SwapPolicy
  → IO (Either TextureRefusal SwapTicket)
swapTexture builders (Textures ledger) handle image decoded policy = do
  held ← readTVarIO ledger
  case Map.lookup handle (ledgerMarks held) of
    Nothing → pure (Left (TextureUnknown handle))
    Just registered
      | Set.member handle (ledgerReleased held) → pure (Left (TextureReleased handle))
      | registered /= computed && policy == RefuseMarkChange → pure (Left (MarkMismatch registered computed))
      | otherwise → either (Left . TextureRefusedByBackend) Right <$> swapImage builders (toBackendHandle handle) image
  where
    computed = decodedBinaryAlpha decoded

-- | Release a handle in the table, on the owner's thread: it resolves to the
-- placeholder from the next version on. Its mark is forgotten with it.
releaseTextureNow ∷ Builders q inst msgr phys dev cmd → Textures → Api.TextureHandle → IO (Either Refusal ())
releaseTextureNow builders (Textures ledger) handle =
  releaseImage builders (toBackendHandle handle) >>= \case
    Left refusal → pure (Left refusal)
    Right () → do
      atomically $ do
        held <- readTVar ledger
        writeTVar ledger held {ledgerMarks = Map.delete handle (ledgerMarks held)}
      pure (Right ())

-- | Mark a handle released, at once, for publication's check. 'False' for one
-- never registered here or already marked.
markReleased ∷ Textures → Api.TextureHandle → IO Bool
markReleased (Textures ledger) handle = atomically $ do
  held ← readTVar ledger
  if Map.member handle (ledgerMarks held) && not (Set.member handle (ledgerReleased held))
    then True <$ writeTVar ledger held {ledgerReleased = Set.insert handle (ledgerReleased held)}
    else pure False

-- | Whether the handle has been marked released.
isReleased ∷ Textures → Api.TextureHandle → STM Bool
isReleased (Textures ledger) handle = Set.member handle . ledgerReleased <$> readTVar ledger

-- | The mark stored with a registered handle, 'Nothing' for one never
-- registered or already released in the table.
registeredMark ∷ Textures → Api.TextureHandle → IO (Maybe Bool)
registeredMark (Textures ledger) handle = Map.lookup handle . ledgerMarks <$> readTVarIO ledger

-- | The 'CutoutMarks' of the registered handles whose mark is set. Planning
-- ignores them until R2D-9.
registeredMarks ∷ Textures → IO CutoutMarks
registeredMarks (Textures ledger) = do
  held ← readTVarIO ledger
  pure (cutoutMarks [handle | (handle, True) ← Map.toList (ledgerMarks held)])
