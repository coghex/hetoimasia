-- | Evidence about the shared loader, for the native proof and nothing else.
--
-- These answer what GLFW holds and what it resolves, so a proof can hold the
-- claim that GLFW and the Vulkan binding dispatch through one loader to the
-- addresses and images that decide it, rather than assuming it. They change
-- nothing, and no application needs them.
--
-- GLFW offers no way to read back the loader hint it was given, so
-- 'installedLoaderEntry' answers the value the interop shim last handed it:
-- the shim is the only code in the process that sets that hint.
module Hetoimasia.GLFW.Vulkan.Provenance
  ( capabilityLoaderEntry
  , installedLoaderEntry
  , glfwResolvedEntry
  ) where

import Data.ByteString (ByteString)
import Foreign.Ptr (FunPtr, Ptr)
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.GLFW.Internal.Session (Session, ownerOperation)
import Hetoimasia.GLFW.Vulkan.Internal.Capability (LoaderIntegration (..))
import Hetoimasia.GLFW.Vulkan.Internal.Native (glfwInstanceProcAddress, installedLoader)

-- | The loader entry point a capability was made from: the Vulkan binding's
-- own @vkGetInstanceProcAddr@.
capabilityLoaderEntry ∷ LoaderIntegration → FunPtr ()
capabilityLoaderEntry = loaderEntry

-- | The loader entry point the interop shim last handed GLFW, or null when it
-- has handed none or last restored GLFW's default search. Any thread may ask,
-- although only a session's owner thread changes it.
installedLoaderEntry ∷ IO (Ptr ())
installedLoaderEntry = installedLoader

-- | What GLFW's own loader resolves a name to, through
-- @glfwGetInstanceProcAddress@, for an instance given as its dispatchable
-- handle or null for a global entry point. An owner operation of a live
-- session.
glfwResolvedEntry ∷ Session → Ptr () → ByteString → IO (Ptr ())
glfwResolvedEntry session handle name =
  ownerOperation session (operation "resolve vulkan entry point") [] (glfwInstanceProcAddress handle name)
