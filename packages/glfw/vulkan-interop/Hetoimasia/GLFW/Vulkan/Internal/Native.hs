-- | The Vulkan interop shim's foreign imports, and the production operations a
-- loader integration capability carries.
--
-- Every import here is @safe@: a GLFW call that reaches the Vulkan loader can
-- reach the layers it enabled, and the binding is built with
-- @+safe-foreign-calls@ so that such a call may re-enter Haskell. The shim's
-- header names no Vulkan or GLFW type, so nothing here does either: an instance
-- is an untyped pointer, a window the model's opaque 'NativeWindow', and a
-- surface a 'Word64'.
module Hetoimasia.GLFW.Vulkan.Internal.Native
  ( bindingLoaderEntry
  , productionIntegration
  , installedLoader
  , glfwInstanceProcAddress
  , DestroyEntryUnresolved (..)
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word64)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (peekArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, castFunPtrToPtr, nullPtr)
import Foreign.Storable (peek)
import Hetoimasia.GLFW.Internal.Session (IntegrationNative (..), NativeWindow)
import Vulkan.Dynamic (getInstanceProcAddr')

foreign import ccall safe "hetoimasia_glfw_vulkan_set_loader"
  c_setLoader ∷ Ptr () → IO ()

foreign import ccall safe "hetoimasia_glfw_vulkan_installed_loader"
  c_installedLoader ∷ IO (Ptr ())

foreign import ccall safe "hetoimasia_glfw_vulkan_supported"
  c_supported ∷ IO CInt

foreign import ccall safe "hetoimasia_glfw_vulkan_required_extensions"
  c_requiredExtensions ∷ Ptr Word32 → IO (Ptr CString)

foreign import ccall safe "hetoimasia_glfw_vulkan_instance_proc_address"
  c_instanceProcAddress ∷ Ptr () → CString → IO (Ptr ())

foreign import ccall safe "hetoimasia_glfw_vulkan_create_surface"
  c_createSurface ∷ Ptr () → Ptr NativeWindow → Ptr Word64 → IO CInt

foreign import ccall safe "hetoimasia_glfw_vulkan_destroy_surface"
  c_destroySurface ∷ Ptr () → Ptr () → Word64 → IO CInt

-- | The loader entry point the Vulkan binding itself dispatches through: its
-- own linked @vkGetInstanceProcAddr@, asked for its own address. Null when the
-- loader answers nothing for it.
bindingLoaderEntry ∷ IO (FunPtr ())
bindingLoaderEntry =
  castFunPtr <$> ByteString.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)

-- | The production operations for one loader entry point.
productionIntegration ∷ FunPtr () → IntegrationNative
productionIntegration entry =
  IntegrationNative
    { integrationInstallLoader = c_setLoader (castFunPtrToPtr entry)
    , integrationResetLoader = c_setLoader nullPtr
    , integrationVulkanSupported = (/= 0) <$> c_supported
    , integrationRequiredExtensions = requiredExtensions
    , integrationCreateSurface = \handle window →
        with 0 $ \surface → do
          result ← c_createSurface handle window surface
          (,) (fromIntegral result) <$> peek surface
    , integrationDestroySurface = \handle surface → do
        result ← c_destroySurface (castFunPtrToPtr entry) handle surface
        when (result /= 0) (throwIO DestroyEntryUnresolved)
    }

-- | GLFW's required instance extensions, each name copied whole out of GLFW's
-- storage before this returns.
requiredExtensions ∷ IO (Maybe [ByteString])
requiredExtensions =
  alloca $ \count → do
    names ← c_requiredExtensions count
    if names == nullPtr
      then pure Nothing
      else do
        reported ← peek count
        pointers ← peekArray (fromIntegral reported) names
        Just <$> mapM ByteString.packCString pointers

-- | The loader entry point the shim last handed GLFW, or null.
installedLoader ∷ IO (Ptr ())
installedLoader = c_installedLoader

-- | What GLFW's loader resolves a name to, for provenance evidence.
glfwInstanceProcAddress ∷ Ptr () → ByteString → IO (Ptr ())
glfwInstanceProcAddress handle name = ByteString.useAsCString name (c_instanceProcAddress handle)

-- | The capability's loader resolved no @vkDestroySurfaceKHR@ for the
-- instance, so nothing was destroyed. The obligation is then uncertain, as for
-- any destruction that did not return.
data DestroyEntryUnresolved = DestroyEntryUnresolved
  deriving (Eq, Show)

instance Exception DestroyEntryUnresolved
