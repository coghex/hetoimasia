{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The audited recording subset: the package's only genuine @unsafe@ Vulkan
-- imports (D-28).
--
-- The binding is built with @+safe-foreign-calls@, so every import of its own
-- is @safe@, and a Haskell wrapper around one of those does not change its
-- calling convention. These are separate @dynamic@ imports, declared
-- @unsafe@, of the same entry points: each takes the function pointer the
-- binding's own device dispatch table ('DeviceCmds') resolved for the command
-- buffer's device, and the structures are marshalled with the binding's own
-- 'withCStruct'. Nothing else in the package calls through them.
--
-- The audit, entry point by entry point, is 'unsafeImports' and the contract
-- document (@docs/gpu_backend.md@, "The FFI audit"). In short: each records
-- into a command buffer the calling thread owns and neither waits on the
-- device, blocks on another thread, nor takes a host lock another thread can
-- hold for long; none can call back into Haskell, because this package
-- installs no Haskell callback, no allocation callback and no trampoline, and
-- the one callback a validation layer can reach from inside them is #217's
-- C-only capture messenger, which copies into bounded storage and returns.
-- @vkBeginCommandBuffer@ and @vkEndCommandBuffer@ return a result, which is
-- checked here and raised as the binding raises it.
module Hetoimasia.GPU.Vulkan.Native.Internal.Commands
  ( unsafeImports
  , beginCommandBufferUnsafe
  , endCommandBufferUnsafe
  , pipelineBarrier2Unsafe
  , beginRenderingUnsafe
  , endRenderingUnsafe
  , bindPipelineUnsafe
  , setViewportUnsafe
  , setScissorUnsafe
  , drawUnsafe
  , pushConstantsUnsafe
  , bindDescriptorSetsUnsafe
  , bindVertexBufferUnsafe
  , bindIndexBufferUnsafe
  , drawIndexedUnsafe
  , copyImageToBufferUnsafe
  , copyBufferUnsafe
  , copyBufferToImageUnsafe
  , beginLabelUnsafe
  , endLabelUnsafe
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Unsafe as Unsafe
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Foreign.Marshal.Array (withArrayLen)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullFunPtr)
import Vulkan.CStruct (withCStruct)
import Vulkan.CStruct.Extends (SomeStruct, forgetExtensions)
import Vulkan.Core10
  ( Buffer (..)
  , BufferCopy
  , BufferImageCopy
  , CommandBufferBeginInfo
  , DescriptorSet (..)
  , Image (..)
  , ImageLayout (..)
  , IndexType (..)
  , Pipeline (..)
  , PipelineBindPoint (..)
  , PipelineLayout (..)
  , ShaderStageFlagBits (..)
  , Rect2D
  , Result (..)
  , Viewport
  )
import Vulkan.Core10.Handles (CommandBuffer (..), CommandBuffer_T)
import Vulkan.Core13 (DependencyInfo, RenderingInfo)
import Vulkan.Dynamic (DeviceCmds (..))
import Vulkan.Exception (VulkanException (..))
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsLabelEXT)

-- | Every genuine @unsafe@ import this module declares, by the Vulkan entry
-- point it calls. 'Hetoimasia.GPU.Vulkan.Native.Diagnostics.nativeFfiConfiguration'
-- records this list, and the headless suite holds it to the package's import
-- declarations.
unsafeImports ∷ [Text]
unsafeImports =
  [ "vkBeginCommandBuffer"
  , "vkEndCommandBuffer"
  , "vkCmdPipelineBarrier2"
  , "vkCmdBeginRendering"
  , "vkCmdEndRendering"
  , "vkCmdBindPipeline"
  , "vkCmdSetViewport"
  , "vkCmdSetScissor"
  , "vkCmdDraw"
  , "vkCmdPushConstants"
  , "vkCmdBindDescriptorSets"
  , "vkCmdBindVertexBuffers"
  , "vkCmdBindIndexBuffer"
  , "vkCmdDrawIndexed"
  , "vkCmdCopyImageToBuffer"
  , "vkCmdCopyBuffer"
  , "vkCmdCopyBufferToImage"
  , "vkCmdBeginDebugUtilsLabelEXT"
  , "vkCmdEndDebugUtilsLabelEXT"
  ]

foreign import ccall unsafe "dynamic"
  mkBeginCommandBuffer
    ∷ FunPtr (Ptr CommandBuffer_T → Ptr (SomeStruct CommandBufferBeginInfo) → IO Result)
    → Ptr CommandBuffer_T
    → Ptr (SomeStruct CommandBufferBeginInfo)
    → IO Result

foreign import ccall unsafe "dynamic"
  mkEndCommandBuffer ∷ FunPtr (Ptr CommandBuffer_T → IO Result) → Ptr CommandBuffer_T → IO Result

foreign import ccall unsafe "dynamic"
  mkCmdPipelineBarrier2
    ∷ FunPtr (Ptr CommandBuffer_T → Ptr (SomeStruct DependencyInfo) → IO ())
    → Ptr CommandBuffer_T
    → Ptr (SomeStruct DependencyInfo)
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBeginRendering
    ∷ FunPtr (Ptr CommandBuffer_T → Ptr (SomeStruct RenderingInfo) → IO ())
    → Ptr CommandBuffer_T
    → Ptr (SomeStruct RenderingInfo)
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdEndRendering ∷ FunPtr (Ptr CommandBuffer_T → IO ()) → Ptr CommandBuffer_T → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBindPipeline
    ∷ FunPtr (Ptr CommandBuffer_T → PipelineBindPoint → Pipeline → IO ())
    → Ptr CommandBuffer_T
    → PipelineBindPoint
    → Pipeline
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdSetViewport
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Ptr Viewport → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Ptr Viewport
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdSetScissor
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Ptr Rect2D → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Ptr Rect2D
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdDraw
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Word32 → Word32 → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Word32
    → Word32
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdPushConstants
    ∷ FunPtr (Ptr CommandBuffer_T → PipelineLayout → ShaderStageFlagBits → Word32 → Word32 → Ptr () → IO ())
    → Ptr CommandBuffer_T
    → PipelineLayout
    → ShaderStageFlagBits
    → Word32
    → Word32
    → Ptr ()
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBindDescriptorSets
    ∷ FunPtr (Ptr CommandBuffer_T → PipelineBindPoint → PipelineLayout → Word32 → Word32 → Ptr DescriptorSet → Word32 → Ptr Word32 → IO ())
    → Ptr CommandBuffer_T
    → PipelineBindPoint
    → PipelineLayout
    → Word32
    → Word32
    → Ptr DescriptorSet
    → Word32
    → Ptr Word32
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBindVertexBuffers
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Ptr Buffer → Ptr Word64 → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Ptr Buffer
    → Ptr Word64
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBindIndexBuffer
    ∷ FunPtr (Ptr CommandBuffer_T → Buffer → Word64 → IndexType → IO ())
    → Ptr CommandBuffer_T
    → Buffer
    → Word64
    → IndexType
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdDrawIndexed
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Word32 → Int32 → Word32 → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Word32
    → Int32
    → Word32
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdCopyImageToBuffer
    ∷ FunPtr (Ptr CommandBuffer_T → Image → ImageLayout → Buffer → Word32 → Ptr BufferImageCopy → IO ())
    → Ptr CommandBuffer_T
    → Image
    → ImageLayout
    → Buffer
    → Word32
    → Ptr BufferImageCopy
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdCopyBuffer
    ∷ FunPtr (Ptr CommandBuffer_T → Buffer → Buffer → Word32 → Ptr BufferCopy → IO ())
    → Ptr CommandBuffer_T
    → Buffer
    → Buffer
    → Word32
    → Ptr BufferCopy
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdCopyBufferToImage
    ∷ FunPtr (Ptr CommandBuffer_T → Buffer → Image → ImageLayout → Word32 → Ptr BufferImageCopy → IO ())
    → Ptr CommandBuffer_T
    → Buffer
    → Image
    → ImageLayout
    → Word32
    → Ptr BufferImageCopy
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdBeginDebugUtilsLabelEXT
    ∷ FunPtr (Ptr CommandBuffer_T → Ptr DebugUtilsLabelEXT → IO ())
    → Ptr CommandBuffer_T
    → Ptr DebugUtilsLabelEXT
    → IO ()

foreign import ccall unsafe "dynamic"
  mkCmdEndDebugUtilsLabelEXT ∷ FunPtr (Ptr CommandBuffer_T → IO ()) → Ptr CommandBuffer_T → IO ()

-- | The entry point the command buffer's device resolved, which must exist.
resolved ∷ String → FunPtr a → IO (FunPtr a)
resolved name entry = do
  when (entry == nullFunPtr) (throwIO (userError ("the device resolved no " <> name)))
  pure entry

handle ∷ CommandBuffer → Ptr CommandBuffer_T
handle = commandBufferHandle

commands ∷ CommandBuffer → DeviceCmds
commands buffer = buffer.deviceCmds

checked ∷ Result → IO ()
checked result = unless (result == SUCCESS) (throwIO (VulkanException result))

beginCommandBufferUnsafe ∷ CommandBuffer → CommandBufferBeginInfo '[] → IO ()
beginCommandBufferUnsafe buffer info = do
  entry ← resolved "vkBeginCommandBuffer" (pVkBeginCommandBuffer (commands buffer))
  withCStruct info $ \pointer → mkBeginCommandBuffer entry (handle buffer) (forgetExtensions pointer) >>= checked

endCommandBufferUnsafe ∷ CommandBuffer → IO ()
endCommandBufferUnsafe buffer = do
  entry ← resolved "vkEndCommandBuffer" (pVkEndCommandBuffer (commands buffer))
  mkEndCommandBuffer entry (handle buffer) >>= checked

pipelineBarrier2Unsafe ∷ CommandBuffer → DependencyInfo '[] → IO ()
pipelineBarrier2Unsafe buffer info = do
  entry ← resolved "vkCmdPipelineBarrier2" (pVkCmdPipelineBarrier2 (commands buffer))
  withCStruct info $ \pointer → mkCmdPipelineBarrier2 entry (handle buffer) (forgetExtensions pointer)

beginRenderingUnsafe ∷ CommandBuffer → RenderingInfo '[] → IO ()
beginRenderingUnsafe buffer info = do
  entry ← resolved "vkCmdBeginRendering" (pVkCmdBeginRendering (commands buffer))
  withCStruct info $ \pointer → mkCmdBeginRendering entry (handle buffer) (forgetExtensions pointer)

endRenderingUnsafe ∷ CommandBuffer → IO ()
endRenderingUnsafe buffer = do
  entry ← resolved "vkCmdEndRendering" (pVkCmdEndRendering (commands buffer))
  mkCmdEndRendering entry (handle buffer)

bindPipelineUnsafe ∷ CommandBuffer → PipelineBindPoint → Pipeline → IO ()
bindPipelineUnsafe buffer point pipeline = do
  entry ← resolved "vkCmdBindPipeline" (pVkCmdBindPipeline (commands buffer))
  mkCmdBindPipeline entry (handle buffer) point pipeline

setViewportUnsafe ∷ CommandBuffer → Viewport → IO ()
setViewportUnsafe buffer viewport = do
  entry ← resolved "vkCmdSetViewport" (pVkCmdSetViewport (commands buffer))
  withCStruct viewport $ \pointer → mkCmdSetViewport entry (handle buffer) 0 1 pointer

setScissorUnsafe ∷ CommandBuffer → Rect2D → IO ()
setScissorUnsafe buffer rect = do
  entry ← resolved "vkCmdSetScissor" (pVkCmdSetScissor (commands buffer))
  withCStruct rect $ \pointer → mkCmdSetScissor entry (handle buffer) 0 1 pointer

drawUnsafe ∷ CommandBuffer → Word32 → Word32 → Word32 → Word32 → IO ()
drawUnsafe buffer vertices instances firstVertex firstInstance = do
  entry ← resolved "vkCmdDraw" (pVkCmdDraw (commands buffer))
  mkCmdDraw entry (handle buffer) vertices instances firstVertex firstInstance

-- | Push the bytes, which the caller has checked are a non-empty multiple of
-- four, through a pointer into them that lives only for the call.
pushConstantsUnsafe ∷ CommandBuffer → PipelineLayout → ShaderStageFlagBits → Word32 → ByteString → IO ()
pushConstantsUnsafe buffer layout stages offset bytes = do
  entry ← resolved "vkCmdPushConstants" (pVkCmdPushConstants (commands buffer))
  Unsafe.unsafeUseAsCStringLen bytes $ \(pointer, count) →
    mkCmdPushConstants entry (handle buffer) layout stages offset (fromIntegral count) (castPtr pointer)

-- | Bind descriptor sets for graphics, from set 0 on, with their dynamic
-- offsets in order (GRS-7), through arrays that live only for the call.
bindDescriptorSetsUnsafe ∷ CommandBuffer → PipelineLayout → [Word64] → [Word32] → IO ()
bindDescriptorSetsUnsafe buffer layout sets offsets = do
  entry ← resolved "vkCmdBindDescriptorSets" (pVkCmdBindDescriptorSets (commands buffer))
  withArrayLen (map DescriptorSet sets) $ \setCount setPointer →
    withArrayLen offsets $ \offsetCount offsetPointer →
      mkCmdBindDescriptorSets entry (handle buffer) PIPELINE_BIND_POINT_GRAPHICS layout 0 (fromIntegral setCount) setPointer (fromIntegral offsetCount) offsetPointer

-- | Bind one buffer, at one offset, to one vertex input binding.
bindVertexBufferUnsafe ∷ CommandBuffer → Word32 → Buffer → Word64 → IO ()
bindVertexBufferUnsafe buffer binding vertices offset = do
  entry ← resolved "vkCmdBindVertexBuffers" (pVkCmdBindVertexBuffers (commands buffer))
  with vertices $ \buffers → with offset $ \offsets → mkCmdBindVertexBuffers entry (handle buffer) binding 1 buffers offsets

bindIndexBufferUnsafe ∷ CommandBuffer → Buffer → Word64 → IndexType → IO ()
bindIndexBufferUnsafe buffer indices offset kind = do
  entry ← resolved "vkCmdBindIndexBuffer" (pVkCmdBindIndexBuffer (commands buffer))
  mkCmdBindIndexBuffer entry (handle buffer) indices offset kind

drawIndexedUnsafe ∷ CommandBuffer → Word32 → Word32 → Word32 → Int32 → Word32 → IO ()
drawIndexedUnsafe buffer indices instances firstIndex vertexOffset firstInstance = do
  entry ← resolved "vkCmdDrawIndexed" (pVkCmdDrawIndexed (commands buffer))
  mkCmdDrawIndexed entry (handle buffer) indices instances firstIndex vertexOffset firstInstance

copyImageToBufferUnsafe ∷ CommandBuffer → Image → ImageLayout → Buffer → BufferImageCopy → IO ()
copyImageToBufferUnsafe buffer image layout destination region = do
  entry ← resolved "vkCmdCopyImageToBuffer" (pVkCmdCopyImageToBuffer (commands buffer))
  withCStruct region $ \pointer → mkCmdCopyImageToBuffer entry (handle buffer) image layout destination 1 pointer

copyBufferUnsafe ∷ CommandBuffer → Buffer → Buffer → BufferCopy → IO ()
copyBufferUnsafe buffer source destination region = do
  entry ← resolved "vkCmdCopyBuffer" (pVkCmdCopyBuffer (commands buffer))
  withCStruct region $ \pointer → mkCmdCopyBuffer entry (handle buffer) source destination 1 pointer

copyBufferToImageUnsafe ∷ CommandBuffer → Buffer → Image → ImageLayout → BufferImageCopy → IO ()
copyBufferToImageUnsafe buffer source image layout region = do
  entry ← resolved "vkCmdCopyBufferToImage" (pVkCmdCopyBufferToImage (commands buffer))
  withCStruct region $ \pointer → mkCmdCopyBufferToImage entry (handle buffer) source image layout 1 pointer

beginLabelUnsafe ∷ CommandBuffer → DebugUtilsLabelEXT → IO ()
beginLabelUnsafe buffer label = do
  entry ← resolved "vkCmdBeginDebugUtilsLabelEXT" (pVkCmdBeginDebugUtilsLabelEXT (commands buffer))
  withCStruct label $ \pointer → mkCmdBeginDebugUtilsLabelEXT entry (handle buffer) pointer

endLabelUnsafe ∷ CommandBuffer → IO ()
endLabelUnsafe buffer = do
  entry ← resolved "vkCmdEndDebugUtilsLabelEXT" (pVkCmdEndDebugUtilsLabelEXT (commands buffer))
  mkCmdEndDebugUtilsLabelEXT entry (handle buffer)
