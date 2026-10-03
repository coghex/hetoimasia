-- | Debug names for the native objects the backend creates, and the labels
-- that bracket its recording regions, as pure decisions.
--
-- Every name and label is derived only from identities the backend already
-- holds — the GPU model's 'TargetId', 'GenerationId', 'ResourceId' and
-- 'BatchId', a frame slot, an image index, the session's queue family — and is
-- built by 'boundedName', so none is longer than 'maximumNameBytes' and none
-- carries caller-supplied text. The calls that assign them are the native
-- layers': 'Instrumentation' is what a device offers, and a device that offers
-- none ('Nothing' where an instrumentation is asked for) names nothing and
-- labels nothing, and nothing fails for it.
--
-- The explicit debug messenger has no name here, and never will: the pinned
-- loader hands the application its own wrapper for a messenger and forwards a
-- naming call without translating it, which MoltenVK reads as one of its own
-- objects and crashes on (#250). Vulkan permits naming it; this backend makes
-- no naming call for one.
--
-- Nothing here makes a native call or names a binding type; the native
-- package's examples hold 'objectTypeCode' to the binding's own constants.
module Hetoimasia.GPU.Vulkan.Native.Naming
  ( -- * Instrumentation
    Instrumentation (..)
  , NativeObjectKind (..)
  , objectTypeCode
  , ShaderStage (..)

    -- * Bounds
  , maximumNameBytes
  , boundedName

    -- * Object names
  , deviceName
  , queueName
  , surfaceName
  , swapchainName
  , swapchainImageName
  , imageViewName
  , pipelineLayoutName
  , pipelineName
  , shaderModuleName
  , commandPoolName
  , commandBufferName
  , framelessPoolName
  , framelessBufferName
  , framelessFenceName
  , readbackBufferName
  , readbackMemoryName
  , bufferName
  , imageName
  , ownedViewName
  , SlotObject (..)
  , slotObjectName
  , PoolObject (..)
  , poolObjectName

    -- * Recording labels
  , batchLabel
  , framelessBatchLabel
  , passLabel
  , targetPassLabel
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , GenerationId
  , ResourceId
  , TargetId
  , batchNumber
  , generationNumber
  , generationTarget
  , resourceGeneration
  , resourceNumber
  , targetIncarnation
  , targetNumber
  )

-- | What a device offers for naming: one call that gives a native object a
-- debug name. A device that has it also records command-buffer labels; one
-- that does not is left unnamed and unlabelled.
newtype Instrumentation = Instrumentation
  { instrumentName ∷ NativeObjectKind → Word64 → ByteString → IO ()
    -- ^ @vkSetDebugUtilsObjectNameEXT@: the object's kind, its handle — a
    -- dispatchable handle as its pointer's value — and the name.
  }

-- | The kinds of native object the backend names. The debug messenger is
-- deliberately not one of them.
data NativeObjectKind
  = ObjectDevice
  | ObjectQueue
  | ObjectSurface
  | ObjectSwapchain
  | ObjectImage
  | ObjectImageView
  | ObjectCommandPool
  | ObjectCommandBuffer
  | ObjectPipelineLayout
  | ObjectPipeline
  | ObjectShaderModule
  | ObjectBuffer
  | ObjectDeviceMemory
  | ObjectSemaphore
  | ObjectFence
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The kind's @VkObjectType@ value.
objectTypeCode ∷ NativeObjectKind → Int32
objectTypeCode = \case
  ObjectDevice → 3
  ObjectQueue → 4
  ObjectSemaphore → 5
  ObjectCommandBuffer → 6
  ObjectFence → 7
  ObjectDeviceMemory → 8
  ObjectBuffer → 9
  ObjectImage → 10
  ObjectImageView → 14
  ObjectShaderModule → 15
  ObjectPipelineLayout → 17
  ObjectPipeline → 19
  ObjectCommandPool → 25
  ObjectSurface → 1000000000
  ObjectSwapchain → 1000001000

-- ---------------------------------------------------------------------------
-- Bounds

-- | The most bytes a name or a label has.
maximumNameBytes ∷ Int
maximumNameBytes = 64

-- | A name as the native call takes it: UTF-8, at most 'maximumNameBytes',
-- and without a NUL, which would end it early. Every name and label here is
-- built by this, from identities alone.
boundedName ∷ Text → ByteString
boundedName = ByteString.take maximumNameBytes . ByteString.filter (/= 0) . Encoding.encodeUtf8

-- ---------------------------------------------------------------------------
-- Object names

deviceName ∷ ByteString
deviceName = boundedName "hetoimasia device"

-- | The session's one queue: the family the device was selected for, and the
-- queue's index in it.
queueName ∷ Word32 → Word32 → ByteString
queueName family index = boundedName ("hetoimasia queue family " <> shown family <> " index " <> shown index)

surfaceName ∷ TargetId → ByteString
surfaceName target = boundedName (targetText target <> " surface")

swapchainName ∷ GenerationId → ByteString
swapchainName generation = boundedName (generationText generation <> " swapchain")

swapchainImageName ∷ GenerationId → Natural → ByteString
swapchainImageName generation index = boundedName (generationText generation <> " image " <> shown index)

imageViewName ∷ GenerationId → Natural → ByteString
imageViewName generation index = boundedName (generationText generation <> " view " <> shown index)

pipelineLayoutName ∷ ResourceId → ByteString
pipelineLayoutName resource = boundedName (resourceText resource <> " pipeline layout")

pipelineName ∷ ResourceId → ByteString
pipelineName resource = boundedName (resourceText resource <> " pipeline")

-- | The stage a pipeline's shader module serves.
data ShaderStage = VertexStage | FragmentStage
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One of the shader modules a pipeline is built from, which exist only
-- while it is built: the pipeline's resource, and the stage.
shaderModuleName ∷ ResourceId → ShaderStage → ByteString
shaderModuleName resource stage =
  boundedName
    ( resourceText resource <> " pipeline " <> case stage of
        VertexStage → "vertex shader"
        FragmentStage → "fragment shader"
    )

-- | A frame slot's command pool: its resource, and the target and slot it
-- serves.
commandPoolName ∷ ResourceId → TargetId → Natural → ByteString
commandPoolName resource target slot = boundedName (resourceText resource <> " command pool " <> targetText target <> " slot " <> shown slot)

commandBufferName ∷ ResourceId → TargetId → Natural → ByteString
commandBufferName resource target slot = boundedName (resourceText resource <> " command buffer " <> targetText target <> " slot " <> shown slot)

-- | A frame-less slot's command pool and buffer (GRS-12).
framelessPoolName ∷ ResourceId → Natural → ByteString
framelessPoolName resource slot = boundedName (resourceText resource <> " command pool frame-less slot " <> shown slot)

framelessBufferName ∷ ResourceId → Natural → ByteString
framelessBufferName resource slot = boundedName (resourceText resource <> " command buffer frame-less slot " <> shown slot)

-- | A frame-less slot's submission fence (GRS-12), which belongs to the slot
-- rather than to its storage's resource.
framelessFenceName ∷ Natural → ByteString
framelessFenceName slot = boundedName ("frame-less slot " <> shown slot <> " submission fence")

readbackBufferName ∷ ResourceId → ByteString
readbackBufferName resource = boundedName (resourceText resource <> " readback buffer")

readbackMemoryName ∷ ResourceId → ByteString
readbackMemoryName resource = boundedName (resourceText resource <> " readback memory")

-- | A managed buffer (GRS-2). Its allocation is named the same inside the
-- allocator.
bufferName ∷ ResourceId → ByteString
bufferName resource = boundedName (resourceText resource <> " buffer")

-- | A managed image (GRS-2). Its allocation is named the same inside the
-- allocator.
imageName ∷ ResourceId → ByteString
imageName resource = boundedName (resourceText resource <> " image")

-- | A managed image's one owned view.
ownedViewName ∷ ResourceId → ByteString
ownedViewName resource = boundedName (resourceText resource <> " image view")

-- | One of the synchronization objects a frame slot owns (VK-12).
data SlotObject
  = AcquisitionSemaphore
  | SubmissionFence
  | CleanupFence
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A frame slot's synchronization object: the target and slot it serves, and
-- which of the slot's objects it is.
slotObjectName ∷ TargetId → Natural → SlotObject → ByteString
slotObjectName target slot object =
  boundedName
    ( targetText target <> " slot " <> shown slot <> case object of
        AcquisitionSemaphore → " acquisition semaphore"
        SubmissionFence → " submission fence"
        CleanupFence → " cleanup fence"
    )

-- | One of the synchronization objects a presentation-pool record owns
-- (VK-13).
data PoolObject
  = RenderFinishedSemaphore
  | PresentFence
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A presentation-pool record's synchronization object: the target and
-- record it serves, and which of the record's objects it is.
poolObjectName ∷ TargetId → Natural → PoolObject → ByteString
poolObjectName target record object =
  boundedName
    ( targetText target <> " presentation record " <> shown record <> case object of
        RenderFinishedSemaphore → " render-finished semaphore"
        PresentFence → " present fence"
    )

-- ---------------------------------------------------------------------------
-- Recording labels

-- | The label around a whole batch: the batch, and the target and generation
-- of the frame it records.
batchLabel ∷ BatchId → GenerationId → ByteString
batchLabel batch generation = boundedName (batchText batch <> " " <> generationText generation)

-- | The label around one frame-less batch, which renders no generation.
framelessBatchLabel ∷ BatchId → ByteString
framelessBatchLabel batch = boundedName (batchText batch <> " frame-less")

-- | The label around one dynamic-rendering pass of that batch.
passLabel ∷ BatchId → GenerationId → ByteString
passLabel batch generation = boundedName ("pass " <> batchText batch <> " " <> generationText generation)

-- | The label around one dynamic-rendering pass of that batch into a managed
-- color target (GRS-5).
targetPassLabel ∷ BatchId → ResourceId → ByteString
targetPassLabel batch resource = boundedName ("pass " <> batchText batch <> " into " <> resourceText resource)

-- ---------------------------------------------------------------------------
-- Identities as text

targetText ∷ TargetId → Text
targetText target = "target " <> shown (targetNumber target) <> "." <> shown (targetIncarnation target)

generationText ∷ GenerationId → Text
generationText generation = targetText (generationTarget generation) <> " generation " <> shown (generationNumber generation)

resourceText ∷ ResourceId → Text
resourceText resource = "resource " <> shown (resourceNumber resource) <> "." <> shown (resourceGeneration resource)

batchText ∷ BatchId → Text
batchText batch = "batch " <> shown (batchNumber batch)

shown ∷ Show a ⇒ a → Text
shown = Text.pack . show
