-- | The constructions the recorder and the texture registry need from their
-- host (R2D-7, R2D-8), as the host lends them inside an owner-thread action or
-- a frame.
--
-- The record is the package's whole seam to the host: the window integration
-- fills it from the 'Construction' it lends, the headless examples from the
-- backend's own recording, and nothing else in the package names a host. Its
-- type parameters are the host session's, which only a batch's recorder names.
module Hetoimasia.Render.TwoD.Vulkan.Builders
  ( Builders (..)
  ) where

import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( Image
  , Pipeline
  , PipelineBlend
  , PipelineLayout
  , Refusal
  , RingSize
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders)
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( SwapTicket
  , TableConfig
  , TextureHandle
  )

data Builders q inst msgr phys dev cmd = Builders
  { buildRing ∷ RingSize → IO (Either Refusal ())
  , buildTable ∷ TableConfig → IO (Either Refusal ())
  , buildTableLayout ∷ CheckedShaders → IO (Either Refusal PipelineLayout)
    -- ^ A shader-sampled table pipeline layout: one that declares no sampler
    -- offset, over these shaders.
  , buildPipeline ∷ PipelineLayout → CheckedShaders → Word32 → PipelineBlend → IO (Either Refusal Pipeline)
    -- ^ A pipeline over the layout for a colour format's @VkFormat@ code.
  , registerImage ∷ Image → IO (Either Refusal TextureHandle)
    -- ^ Register an uploaded texture with the table, answering the backend's
    -- handle for it.
  , swapImage ∷ TextureHandle → Image → IO (Either Refusal SwapTicket)
    -- ^ Give a live handle a replacement texture whose upload is admitted or
    -- complete (GRS-9).
  , releaseImage ∷ TextureHandle → IO (Either Refusal ())
    -- ^ Release a handle in the table: it resolves to the placeholder from the
    -- next version on, and its image is destroyed once no batch holds a
    -- version that maps it.
  }
