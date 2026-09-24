-- | The throwaway GLFW/Vulkan interop the proof uses, and the image provenance
-- that makes "one loader" an observation.
--
-- Every declaration here is @safe@. The binding is built with
-- @+safe-foreign-calls@ precisely so a native call may re-enter Haskell, and a
-- GLFW call that ends up inside the loader can reach the debug-utils messenger
-- this proof installs. Marking these @unsafe@ to save a few nanoseconds in a
-- qualification harness would be trading the thing being proved for nothing.
--
-- VK-5 owns the production surface bridge. This is not it.
module Test.Vulkan.Proof.Interop
  ( -- * The shim's window
    ProofWindow

    -- * The shared loader
  , initVulkanLoader
  , vulkanSupported
  , instanceProcAddress

    -- * GLFW
  , glfwInit
  , glfwTerminate
  , requiredInstanceExtensions
  , createProofWindow
  , destroyProofWindow
  , pollEvents
  , createWindowSurface
  , lastGlfwError

    -- * Provenance
  , Provenance (..)
  , provenanceOf
  , osThread
  , describeProvenance
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (FunPtr, Ptr, castFunPtrToPtr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek)
import Data.Word (Word64)

-- | The shim's opaque window. No GLFW type crosses into Haskell.
data ProofWindow

foreign import ccall safe "hetoimasia_proof_init_vulkan_loader"
  c_initVulkanLoader ∷ Ptr () → IO CInt

foreign import ccall safe "hetoimasia_proof_glfw_init"
  c_glfwInit ∷ IO CInt

foreign import ccall safe "hetoimasia_proof_glfw_terminate"
  c_glfwTerminate ∷ IO ()

foreign import ccall safe "hetoimasia_proof_vulkan_supported"
  c_vulkanSupported ∷ IO CInt

foreign import ccall safe "hetoimasia_proof_instance_proc_address"
  c_instanceProcAddress ∷ Ptr () → CString → IO (Ptr ())

foreign import ccall safe "hetoimasia_proof_required_extensions"
  c_requiredExtensions ∷ Ptr CString → CSize → CSize → IO CInt

foreign import ccall safe "hetoimasia_proof_create_window"
  c_createWindow ∷ CInt → CInt → CString → IO (Ptr ProofWindow)

foreign import ccall safe "hetoimasia_proof_destroy_window"
  c_destroyWindow ∷ Ptr ProofWindow → IO ()

foreign import ccall safe "hetoimasia_proof_poll_events"
  c_pollEvents ∷ IO ()

foreign import ccall safe "hetoimasia_proof_create_window_surface"
  c_createWindowSurface ∷ Ptr () → Ptr ProofWindow → Ptr Word64 → IO CInt

foreign import ccall safe "hetoimasia_proof_last_error"
  c_lastError ∷ IO CString

-- | The OS thread the caller is running on, as @pthread_self@ answers it. It
-- neither blocks nor calls back, so the import is @unsafe@: there is nothing
-- to gain from releasing the capability around it.
foreign import ccall unsafe "hetoimasia_proof_os_thread"
  osThread ∷ IO Word64

foreign import ccall safe "hetoimasia_proof_image_of"
  c_imageOf ∷ Ptr () → CString → CSize → CString → CSize → IO CInt

-- | Hand GLFW the loader entry point the Haskell binding itself dispatches
-- through, before 'glfwInit'.
initVulkanLoader ∷ FunPtr a → IO ()
initVulkanLoader entry = () <$ c_initVulkanLoader (castFunPtrToPtr entry)

glfwInit ∷ IO Bool
glfwInit = (/= 0) <$> c_glfwInit

glfwTerminate ∷ IO ()
glfwTerminate = c_glfwTerminate

vulkanSupported ∷ IO Bool
vulkanSupported = (/= 0) <$> c_vulkanSupported

-- | What GLFW's loader resolves a name to. A null instance asks for a
-- global-level entry point.
instanceProcAddress ∷ Ptr () → String → IO (Ptr ())
instanceProcAddress handle name = withCString name (c_instanceProcAddress handle)

-- | The instance extensions GLFW requires for this platform's surfaces.
requiredInstanceExtensions ∷ IO (Maybe [ByteString])
requiredInstanceExtensions =
  allocaBytes (slots * stride) $ \buffer → do
    reported ← c_requiredExtensions (castPtr buffer) (fromIntegral slots) (fromIntegral stride)
    if reported < 0
      then pure Nothing
      else do
        let taken = min slots (fromIntegral reported)
        names ← mapM (\index → Char8.pack <$> peekCString (buffer `plusPtr` (index * stride))) [0 .. taken - 1]
        pure (Just names)
  where
    slots = 16
    stride = 128

createProofWindow ∷ Int → Int → String → IO (Maybe (Ptr ProofWindow))
createProofWindow width height title = do
  window ← withCString title (c_createWindow (fromIntegral width) (fromIntegral height))
  pure (if window == nullPtr then Nothing else Just window)

destroyProofWindow ∷ Ptr ProofWindow → IO ()
destroyProofWindow = c_destroyWindow

pollEvents ∷ IO ()
pollEvents = c_pollEvents

-- | @glfwCreateWindowSurface@. The @Int@ is the @VkResult@ the platform
-- returned; the @Word64@ is the surface handle, meaningful only on success.
createWindowSurface ∷ Ptr () → Ptr ProofWindow → IO (Int, Word64)
createWindowSurface handle window =
  with 0 $ \surface → do
    result ← c_createWindowSurface handle window surface
    (,) (fromIntegral result) <$> peek surface

lastGlfwError ∷ IO Text
lastGlfwError = Text.pack <$> (c_lastError >>= peekCString)

-- | Which loaded image defines an address, and under what symbol.
data Provenance = Provenance
  { provenanceAddress ∷ Ptr ()
  , provenanceImage ∷ Maybe Text
  , provenanceSymbol ∷ Maybe Text
  }
  deriving (Eq, Show)

provenanceOf ∷ Ptr () → IO Provenance
provenanceOf address =
  allocaArray capacity $ \image →
    allocaArray capacity $ \symbol → do
      attributed ← c_imageOf address image (fromIntegral capacity) symbol (fromIntegral capacity)
      if attributed == 0
        then pure (Provenance address Nothing Nothing)
        else do
          imageName ← nonEmpty <$> peekCString image
          symbolName ← nonEmpty <$> peekCString symbol
          pure (Provenance address imageName symbolName)
  where
    capacity = 1024
    nonEmpty text = if null text then Nothing else Just (Text.pack text)

describeProvenance ∷ Provenance → Text
describeProvenance provenance =
  Text.pack (show (provenanceAddress provenance))
    <> " in "
    <> maybe "an unattributed image" id (provenanceImage provenance)
    <> maybe "" (\name → " as " <> name) (provenanceSymbol provenance)
