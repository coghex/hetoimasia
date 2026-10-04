-- | The bindless texture table (GRS-7; resource services design D-1, D-11,
-- D-20, D-22, D-23, D-27, D-31 and D-35): stable texture handles, resolved in
-- shaders through lookup versions that each batch freezes, over one
-- update-after-bind array of sampled images and four shared samplers.
--
-- = Making it
--
-- 'validateTableConfig' checks the application's cap, initial size and
-- version count once (D-11); 'createTextureTable' then checks them against
-- the device and makes the table's two engine-owned descriptor sets — set 0,
-- the samplers and then the variable-count array as its highest binding;
-- set 1, one dynamic storage buffer over the version ring — and slot 0's
-- transparent-black placeholder, whose upload it admits. The table binds
-- once that upload has completed.
--
-- = Handles
--
-- 'registerTexture' takes an uploaded texture (GRS-6) and answers a stable
-- 'TextureHandle', a lookup index and a generation, never persisted. Until
-- the texture's upload completes it resolves to slot 0; afterwards, to its
-- own slot, in versions published since. The table holds the image from
-- then on: 'releaseTexture' ends the handle, and the image is released only
-- once no live version maps its slot. A stale handle is refused wherever it
-- is used ('RefusedStaleHandle'), and a shader resolving one — through the
-- bounds and generation check its lookup makes ('resolveHandle' states it) —
-- reads the placeholder, never another texture or an unwritten descriptor.
--
-- = Swaps
--
-- 'swapTexture' asks a live handle to show a replacement texture, the image
-- an admitted or completed upload fills (GRS-9). The handle keeps resolving
-- to what it shows until that upload completes; the first version published
-- after completion resolves it to the replacement, and the texture it
-- replaced is released then, to be destroyed once no batch retains it, its
-- slot reused once no live version maps it. A batch that took an earlier
-- version keeps sampling the old texture through submission and completion.
-- A second swap on the handle while one is pending supersedes it, and
-- releasing the handle ends it; either releases the pending replacement,
-- which is never shown. The 'SwapTicket' reports where a swap stands.
--
-- = Versions
--
-- A batch takes the current version when it first binds the table
-- ('bindTable'), and keeps it for the rest of its life: it retains the
-- version, and every set and buffer it binds, through the model's recorded
-- reference and then its submitted use, until it completes or is discarded.
-- A new version is written only when a mapping changed, into a ring entry no
-- batch holds; with none free, binding is backpressure
-- ('LookupVersionBudget'). A slot is reused, and its descriptor rewritten,
-- only once no live version maps it, so a batch recorded before a texture is
-- released or re-registered still samples the original image when it is
-- submitted later.
--
-- = Pipelines and draws
--
-- A consumer asks for the table when it makes a pipeline layout
-- ('createTablePipelineLayout'): both sets are declared, its checked shaders
-- may declare the table's own bindings ('textureTableDescriptors') and no
-- other, and it names the push-constant offset of its draws' sampler index.
-- A draw with such a pipeline needs the table bound under a compatible layout
-- and a sampler selected ('selectSampler'); binding the table without one is
-- refused with no native call.
module Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( -- * Configuration
    Book.TableConfig
  , Book.tableCapacity
  , Book.tableInitialSlots
  , Book.tableVersionCount
  , Book.defaultVersionCount
  , Book.TableConfigRefused (..)
  , Book.validateTableConfig

    -- * The table
  , createTextureTable
  , refreshTextureTable
  , TableView (..)
  , readTable

    -- * Handles
  , Book.TextureHandle (..)
  , Book.LookupEntry (..)
  , Book.resolveHandle
  , registerTexture
  , RegistrationNotUndone (..)
  , releaseTexture

    -- * Swaps (GRS-9)
  , swapTexture
  , SwapTicket
  , SwapState (..)
  , readSwapTicket

    -- * Pipelines and draws
  , textureTableDescriptors
  , createTablePipelineLayout
  , TableSampler (..)
  , tableSamplerIndex
  , bindTable
  , selectSampler
  ) where

import qualified Hetoimasia.GPU.Model.TextureTable as Book
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer (TableSampler (..), tableSamplerIndex)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder (bindTable, selectSampler)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Table
  ( RegistrationNotUndone (..)
  , TableView (..)
  , createTablePipelineLayout
  , createTextureTable
  , readTable
  , refreshTextureTable
  , registerTexture
  , releaseTexture
  , swapTexture
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State (SwapState (..), SwapTicket, readSwapTicket)
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (textureTableDescriptors)
