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
  , commandPoolName
  , commandBufferName
  , readbackBufferName
  , readbackMemoryName

    -- * Recording labels
  , batchLabel
  , passLabel
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
  | ObjectBuffer
  | ObjectDeviceMemory
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The kind's @VkObjectType@ value.
objectTypeCode ∷ NativeObjectKind → Int32
objectTypeCode = \case
  ObjectDevice → 3
  ObjectQueue → 4
  ObjectCommandBuffer → 6
  ObjectDeviceMemory → 8
  ObjectBuffer → 9
  ObjectImage → 10
  ObjectImageView → 14
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

-- | A frame slot's command pool: its resource, and the target and slot it
-- serves.
commandPoolName ∷ ResourceId → TargetId → Natural → ByteString
commandPoolName resource target slot = boundedName (resourceText resource <> " command pool " <> targetText target <> " slot " <> shown slot)

commandBufferName ∷ ResourceId → TargetId → Natural → ByteString
commandBufferName resource target slot = boundedName (resourceText resource <> " command buffer " <> targetText target <> " slot " <> shown slot)

readbackBufferName ∷ ResourceId → ByteString
readbackBufferName resource = boundedName (resourceText resource <> " readback buffer")

readbackMemoryName ∷ ResourceId → ByteString
readbackMemoryName resource = boundedName (resourceText resource <> " readback memory")

-- ---------------------------------------------------------------------------
-- Recording labels

-- | The label around a whole batch: the batch, and the target and generation
-- of the frame it records.
batchLabel ∷ BatchId → GenerationId → ByteString
batchLabel batch generation = boundedName (batchText batch <> " " <> generationText generation)

-- | The label around one dynamic-rendering pass of that batch.
passLabel ∷ BatchId → GenerationId → ByteString
passLabel batch generation = boundedName ("pass " <> batchText batch <> " " <> generationText generation)

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
