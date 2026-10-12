-- | The depth image of a swapchain generation (GRS-13): what the recording
-- supplies to the generations ("Hetoimasia.GPU.Vulkan.Native.Generations") so
-- that, when the session asked for windowed depth, each generation owns one
-- depth image of its extent, shared by its frames in flight.
--
-- The image is an ordinary managed 'DepthTarget' image of the recording's
-- ('createImage'): its memory is charged to the model's accounting and
-- recovered as any allocation is (VK-14), it awaits initialization until the
-- first pass that clears it has been submitted (D-26), and a batch that records
-- a pass with it retains it until that batch has completed. What differs is
-- who owns it. The generation's construction makes it and records it; the
-- generation releases it, in the transaction its destruction is recorded in, and the
-- recording destroys it once the model reports every hold on it ended. No
-- handle releases it ('releaseManaged' refuses), and the frame's recorder
-- takes it only from the request of a frame of its own generation
-- ('windowDepthOf').
--
-- This module owns no state: the set of depth images of generations lives in
-- the recording's state, written here when a depth image is made and by the
-- recording's disposal when it is destroyed.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.WindowDepth
  ( supplyRecordingWindowDepth
  , windowDepthOf
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception (onException, throwIO)
import Control.Monad (void)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text

import Hetoimasia.GPU.Model.Identity (GenerationId, ResourceId, generationTarget)
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory (..))
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationView (..)
  , TargetGenerationsView (..)
  , WindowDepth (..)
  , WindowDepthRefused (..)
  , readTargetGenerations
  , supplyWindowDepth
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Allocation (nameAllocation)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( createImage
  , releaseLive
  , selectDepthFormat
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( ImageDescription (..)
  , ImageKind (DepthTarget)
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( Image (..)
  , ManagedRecord (..)
  , NativeResource (..)
  , Recording (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..), windowDepthName, windowDepthViewName)
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (nameRootsObject, readRootsInstrumentation)

-- | Supply the generations with what makes and releases their depth images.
-- It asks for them too: every generation constructed from now on owns one.
supplyRecordingWindowDepth ∷ Recording q inst msgr phys dev cmd → STM ()
supplyRecordingWindowDepth recording =
  supplyWindowDepth
    (recordingGenerations recording)
    WindowDepth
      { windowDepthCreate = createWindowDepth recording
      , windowDepthRelease = releaseWindowDepth recording
      }

-- | The depth image of a generation, when it has one and it is still live to
-- record with: the handle a frame of that generation's request names.
windowDepthOf ∷ Recording q inst msgr phys dev cmd → GenerationId → STM (Maybe Image)
windowDepthOf recording generation = do
  view ← readTargetGenerations (recordingGenerations recording) (generationTarget generation)
  pure $ do
    target ← view
    entry ← lookup generation [(viewGeneration held, held) | held ← viewGenerations target]
    Image <$> viewDepth entry

-- | Make a generation's depth image, in the depth format the device supports
-- ('selectDepthFormat'), of the generation's extent, and name it from the
-- generation's identity. Anything that stops it raises 'WindowDepthRefused' —
-- or raises as the native call did — having made nothing: an image whose
-- naming raised is released before the failure propagates.
createWindowDepth ∷ Recording q inst msgr phys dev cmd → GenerationId → SurfaceExtent → IO ResourceId
createWindowDepth recording generation extent =
  selectDepthFormat recording >>= \case
    Left refusal → refused ("no depth format: " <> tshow refusal)
    Right format →
      createImage recording (ImageDescription DepthTarget format (extentWidth extent) (extentHeight extent) 1) >>= \case
        Left refusal → refused (tshow refusal)
        Right (Image resource) → do
          atomically (modifyTVar' (recordingWindowDepths recording) (Set.insert resource))
          naming resource `onException` atomically (void (releaseWindowDepth recording resource))
          pure resource
  where
    refused ∷ Text → IO a
    refused = throwIO . WindowDepthRefused generation
    naming resource = do
      managed ← atomically (readTVar (recordingManaged recording))
      for_ (Map.lookup resource managed) $ \record → case managedNative record of
        NativeImage _ memory view → do
          nameAllocation (recordingRoots recording) memory (windowDepthName generation)
          readRootsInstrumentation (recordingRoots recording) >>= \case
            Nothing → pure ()
            Just (_, instrumentation) → do
              nameRootsObject (recordingRoots recording) instrumentation ObjectImage (memoryResource memory) (windowDepthName generation)
              nameRootsObject (recordingRoots recording) instrumentation ObjectImageView view (windowDepthViewName generation)
        _ → pure ()

-- | Release a generation's depth image in the model, in the transaction that
-- records the generation's destruction. A batch that recorded it keeps it until its
-- own references end.
releaseWindowDepth ∷ Recording q inst msgr phys dev cmd → ResourceId → STM ()
releaseWindowDepth recording resource = void (releaseLive recording resource)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
