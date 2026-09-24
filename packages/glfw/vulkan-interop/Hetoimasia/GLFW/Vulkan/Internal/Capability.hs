-- | The loader integration capability's representation, private to the
-- Vulkan interop component: "Hetoimasia.GLFW.Vulkan" exports it abstractly and
-- "Hetoimasia.GLFW.Vulkan.Provenance" reads the entry point it was made from.
module Hetoimasia.GLFW.Vulkan.Internal.Capability
  ( LoaderIntegration (..)
  , LoaderUnavailable (..)
  , allocLoaderIntegration
  , withLoaderIntegration
  ) where

import Control.Exception (Exception)
import Foreign.Ptr (FunPtr, nullFunPtr)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Resource (Scoped, allocResource, withScoped)
import Hetoimasia.GLFW.Internal.Native (productionNative)
import Hetoimasia.GLFW.Internal.Session
  ( SessionIntegration
  , endSessionIntegration
  , glfwComponent
  , nativeGuard
  , newSessionIntegration
  )
import Hetoimasia.GLFW.Vulkan.Internal.Native (bindingLoaderEntry, productionIntegration)

-- | The opaque loader integration capability, made from the Vulkan binding's
-- own loader entry point for the production GLFW library.
data LoaderIntegration = LoaderIntegration
  { loaderCapability ∷ !SessionIntegration
    -- ^ The session-level capability, for
    -- 'Hetoimasia.GLFW.Session.allocIntegratedSession' and for code that
    -- composes a host over it.
  , loaderEntry ∷ !(FunPtr ())
  }

-- | The Vulkan binding's loader answered no entry point for
-- @vkGetInstanceProcAddr@, so there is no loader to share.
data LoaderUnavailable = LoaderUnavailable
  deriving (Eq, Show)

instance Exception LoaderUnavailable

-- | Build the capability for the rest of the enclosing scope. Its release ends
-- it: a capability no session took, or whose session restored GLFW's default,
-- ends; one GLFW may still hold is retained, and a scope that ends while its
-- session still uses it fails, as
-- 'Hetoimasia.GLFW.Internal.Session.endSessionIntegration' describes.
allocLoaderIntegration ∷ Scoped LoaderIntegration
allocLoaderIntegration = allocResource acquire (endSessionIntegration . loaderCapability)
  where
    acquire = do
      entry ← bindingLoaderEntry
      if entry == nullFunPtr
        then throwFailure glfwComponent (operation "construct loader integration") [] LoaderUnavailable
        else do
          capability ← newSessionIntegration (nativeGuard productionNative) (productionIntegration entry)
          pure (LoaderIntegration capability entry)

-- | Build the capability, lend it to the body, and end it.
withLoaderIntegration ∷ (LoaderIntegration → IO r) → IO r
withLoaderIntegration = withScoped allocLoaderIntegration

