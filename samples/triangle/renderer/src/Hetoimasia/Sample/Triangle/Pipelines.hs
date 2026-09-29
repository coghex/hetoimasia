-- | The triangle sample's pipelines: one per color format, each over a
-- pipeline layout of its own, built the first time a frame of that format
-- needs one.
--
-- A format's layout is built once and held from then on. When the pipeline
-- over it is refused, the layout is kept for the format's next attempt rather
-- than built again, so a refusal that recurs frame after frame — a pending
-- diagnostic, backpressure, a construction that raised — spends no more of the
-- host's object budget than the first attempt did.
--
-- The handles are type parameters only so that the cache's decisions can be
-- checked without a device: "Hetoimasia.Sample.Triangle" instantiates them at
-- the backend's 'Hetoimasia.GPU.Vulkan.Native.Recording.PipelineLayout' and
-- 'Hetoimasia.GPU.Vulkan.Native.Recording.Pipeline'.
module Hetoimasia.Sample.Triangle.Pipelines
  ( Builders (..)
  , Pipelines
  , newPipelines
  , pipelineFor
  , pipelineFormats
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Recording (PipelineShaders, Refusal)
import Hetoimasia.Sample.Triangle.Shaders (triangleShaders)

-- | The two managed constructions drawing needs, as the host lends them with
-- each frame.
data Builders layout pipeline = Builders
  { buildLayout ∷ IO (Either Refusal layout)
    -- ^ A pipeline layout with no descriptor sets and no push constants.
  , buildPipeline ∷ layout → PipelineShaders → Word32 → IO (Either Refusal pipeline)
    -- ^ A graphics pipeline over a layout, for a color format.
  }

-- | What is held for one color format.
data Held layout pipeline
  = Pending !layout
    -- ^ The layout, whose pipeline has not been built yet.
  | Ready !layout !pipeline

-- | The layout and pipeline held for each color format met so far.
newtype Pipelines layout pipeline = Pipelines (IORef (Map Word32 (Held layout pipeline)))

newPipelines ∷ IO (Pipelines layout pipeline)
newPipelines = Pipelines <$> newIORef Map.empty

-- | The color formats a pipeline has been built for so far. A format whose
-- layout is held but whose pipeline was refused is not one of them.
pipelineFormats ∷ Pipelines layout pipeline → IO [Word32]
pipelineFormats (Pipelines held) = Map.keys . Map.filter ready <$> readIORef held
  where
    ready = \case
      Ready _ _ → True
      Pending _ → False

-- | The triangle's pipeline for this color format: the one already built, or
-- one built now over the format's held layout, building and holding that
-- layout first if the format has none. A refusal is answered as it is, with
-- whatever layout was built still held for the next attempt.
pipelineFor ∷ Pipelines layout pipeline → Builders layout pipeline → Word32 → IO (Either Refusal pipeline)
pipelineFor (Pipelines held) builders format =
  (Map.lookup format <$> readIORef held) >>= \case
    Just (Ready _ pipeline) → pure (Right pipeline)
    Just (Pending layout) → overLayout layout
    Nothing →
      buildLayout builders >>= \case
        Left refusal → pure (Left refusal)
        Right layout → hold (Pending layout) *> overLayout layout
  where
    overLayout layout =
      buildPipeline builders layout triangleShaders format >>= \case
        Left refusal → pure (Left refusal)
        Right pipeline → Right pipeline <$ hold (Ready layout pipeline)
    hold entry = atomicModifyIORef' held (\known → (Map.insert format entry known, ()))
