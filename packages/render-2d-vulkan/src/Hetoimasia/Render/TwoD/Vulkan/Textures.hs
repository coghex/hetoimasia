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
-- with the handle for the handle's life and is never changed by
-- anything but the handle's release; 'registeredMarks' answers the
-- 'CutoutMarks' of the handles registered. A frame is planned with them, and they
-- decide which instances take the cutout path (D-22): an instance of a marked
-- texture, in a layer that allows it, is drawn by the cutout pipeline, and every
-- other instance takes the ordered one.
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
-- for publication's check, and answers 'False' for one never registered,
-- already marked, or whose table release already ran. The table release
-- ('releaseTextureNow') is the backend's, run on the owner's thread once
-- nothing adopted still shows the handle; the window adapter
-- ("Hetoimasia.Render.TwoD.Vulkan.Window") sequences the two.
--
-- = What 'isReleased' reports (GUIDE-5)
--
-- * A /stale/ handle — one at a registered index whose generation is not the
--   one registered there last — is reported released, whether or not its
--   release was marked, and 'swapTexture' answers 'TextureUnknown' for it.
--   "Before" is the order of registration at the index, not a numeric
--   comparison, so it holds across the table's generation wraparound.
-- * The /current/ handle — the generation registered last — is reported
--   released while its release is marked, and the marker persists through the
--   table release until a later generation is registered at the index. An
--   unmarked current handle is not, including after a direct table release.
-- * A handle never registered here, at an index never registered at, is not.
-- * A handle reissued with the index and generation of the current one, after
--   the generation wraps, is the new live handle: unmarked as released until
--   it is marked again.
--
-- 'swapTexture' keeps its precedence: 'TextureUnknown' for a handle that holds
-- no mark (one never registered, stale, or whose table release removed its
-- mark), then 'TextureReleased' for a registered handle whose release is
-- marked, then 'MarkMismatch', then the table's answer.
--
-- = State
--
-- A 'Textures' owns one 'Ledger' ("Hetoimasia.Render.TwoD.Vulkan.Textures.Ledger"):
-- for each lookup index a handle was registered at, the generation registered
-- last, that handle's mark and whether its release is marked. The state is
-- bounded by the number of indices registered at, independent of how many
-- textures were registered and released ('retainedEntries'): a registration at
-- an index overwrites that index's entry, so what stale handles needed is
-- implied by the generation alone. An index's entry is created by its first
-- registration and lives as long as the 'Textures'. 'registerTexture' writes
-- it, 'markReleased' sets its marker and 'releaseTextureNow' removes its mark;
-- any thread reads it, in STM.
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
  , swapCheck
  , releaseTextureNow
  , markReleased
  , markReleasedSTM
  , isReleased
  , registeredMark
  , registeredMarks
  , retainedEntries
  , currentLedger
  , toBackendHandle
  , fromBackendHandle
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Image, Refusal)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (SwapTicket, TextureHandle (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import qualified Hetoimasia.Render.TwoD.Vulkan.Textures.Ledger as Ledger

-- | The registry: for each registered lookup index, the handle registered last
-- with its mark and whether its release is marked.
newtype Textures = Textures (TVar Ledger.Ledger)

newTextures ∷ IO Textures
newTextures = Textures <$> newTVarIO Ledger.emptyLedger

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
      -- Both are evaluated here, before the transaction: the mark is computed from
      -- the decoded image, which the ledger must not keep alive through a thunk.
      let !handle = fromBackendHandle backend
          !mark = case policy of
            DefaultMark → decodedBinaryAlpha decoded
            OverrideMark explicit → explicit
      atomically $ do
        held ← readTVar ledger
        -- Strict: a lazy write would keep the previous ledger alive in a thunk, a
        -- history of updates as long as the number of registrations.
        writeTVar ledger $! Ledger.registerHandle handle mark held
      pure (Right handle)

-- | Swap a registered handle to a replacement under the mark rule. Refused,
-- changing nothing: a handle never registered, stale or released, a mark
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
  case swapCheck held handle (decodedBinaryAlpha decoded) policy of
    Left refusal → pure (Left refusal)
    Right () → either (Left . TextureRefusedByBackend) Right <$> swapImage builders (toBackendHandle handle) image

-- | What a swap is checked against before the table is asked, in this order:
-- 'TextureUnknown' for a handle holding no mark (never registered, stale, or
-- its table release removed the mark), 'TextureReleased' for a registered
-- handle whose release is marked, then 'MarkMismatch' for a replacement
-- whose computed mark differs from the registered one without
-- 'KeepRegisteredMark'. Pure, so the precedence is checked on constructed
-- handles.
swapCheck ∷ Ledger.Ledger → Api.TextureHandle → Bool → SwapPolicy → Either TextureRefusal ()
swapCheck held handle computed policy = case Ledger.markOf held handle of
  Nothing → Left (TextureUnknown handle)
  Just registered
    | Ledger.handleReleased held handle → Left (TextureReleased handle)
    | registered /= computed && policy == RefuseMarkChange → Left (MarkMismatch registered computed)
    | otherwise → Right ()

-- | Release a handle in the table, on the owner's thread: it resolves to the
-- placeholder from the next version on. Its mark is forgotten with it; its
-- release marker, if set, stays until a later generation is registered at the
-- index.
releaseTextureNow ∷ Builders q inst msgr phys dev cmd → Textures → Api.TextureHandle → IO (Either Refusal ())
releaseTextureNow builders (Textures ledger) handle =
  releaseImage builders (toBackendHandle handle) >>= \case
    Left refusal → pure (Left refusal)
    Right () → do
      atomically $ do
        held <- readTVar ledger
        writeTVar ledger $! Ledger.forgetMark handle held
      pure (Right ())

-- | Mark a handle released, at once, for publication's check. 'False' for one
-- never registered here, stale, already marked, or whose table release ran.
markReleased ∷ Textures → Api.TextureHandle → IO Bool
markReleased textures handle = atomically (markReleasedSTM textures handle)

-- | 'markReleased' as a transaction, for a caller that commits the marker
-- together with its own state.
markReleasedSTM ∷ Textures → Api.TextureHandle → STM Bool
markReleasedSTM (Textures ledger) handle = do
  held ← readTVar ledger
  case Ledger.markHandleReleased handle held of
    Just marked → True <$ (writeTVar ledger $! marked)
    Nothing → pure False

-- | Whether the handle is released: its release is marked and it is its
-- index's current handle, or it is stale, a handle of a registered index other
-- than the one registered last. Not for the current handle unmarked, or an
-- index never registered. See the module's description.
isReleased ∷ Textures → Api.TextureHandle → STM Bool
isReleased (Textures ledger) handle = (`Ledger.handleReleased` handle) <$> readTVar ledger

-- | The mark stored with a registered handle, 'Nothing' for one never
-- registered, stale, or already released in the table.
registeredMark ∷ Textures → Api.TextureHandle → IO (Maybe Bool)
registeredMark (Textures ledger) handle = (`Ledger.markOf` handle) <$> readTVarIO ledger

-- | The ledger as the registry stores it, without evaluating it, for a test to
-- inspect that the stored value is evaluated rather than a chain of pending
-- updates (see 'registerTexture').
currentLedger ∷ Textures → IO Ledger.Ledger
currentLedger (Textures ledger) = readTVarIO ledger

-- | How many entries the registry retains: all of its state, one per lookup
-- index registered at.
retainedEntries ∷ Textures → IO Int
retainedEntries (Textures ledger) = Ledger.retainedEntries <$> readTVarIO ledger

-- | The 'CutoutMarks' of the registered handles whose mark is set: what a frame
-- is planned with, and so what decides the cutout routing.
registeredMarks ∷ Textures → IO CutoutMarks
registeredMarks (Textures ledger) = do
  held ← readTVarIO ledger
  pure (cutoutMarks (Ledger.markedCutouts held))
