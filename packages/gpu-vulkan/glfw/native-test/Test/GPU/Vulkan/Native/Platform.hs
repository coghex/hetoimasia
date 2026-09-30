-- | How every session of the Vulkan native suite asks for the backend its
-- run's consent names ("Test.GPU.Vulkan.Native.Consent", 'consentBackend').
--
-- A session enters GLFW one of two ways, and each carries the request:
--
-- * the production host, whose GLFW session is the package's own and is
--   configured through 'HostConfig' ('requestingBackend'). A session that
--   requests a backend is refused when GLFW selects any other, so a host that
--   runs at all runs on the backend requested;
-- * the proof shim's raw initialization ('initRequested'), which sets GLFW's
--   platform hint itself and fails an initialization that selected another
--   platform, and which records in the case's journal what GLFW selected.
--
-- No request is 'Nothing': the platform's own backend, exactly as before the
-- suite accepted Wayland.
module Test.GPU.Vulkan.Native.Platform
  ( requestingBackend
  , initRequested
  , notePlatform
  ) where

import Control.Monad (when)
import qualified Data.Text as Text

import Hetoimasia.GLFW.Session (Backend, SessionConfig (..))
import Hetoimasia.Runtime.GLFW (HostConfig (..))
import Test.Vulkan.Proof.Interop (glfwInit, glfwPlatform)
import Test.Vulkan.Proof.Journal (Journal, note)

-- | A host whose session requests the backend named.
requestingBackend ∷ Maybe Backend → HostConfig → HostConfig
requestingBackend backend host = host {hostSessionConfig = (hostSessionConfig host) {requestedBackend = backend}}

-- | Initialize GLFW through the proof shim for the backend requested, and note
-- which platform it selected.
initRequested ∷ Journal → Maybe Backend → IO Bool
initRequested journal backend = do
  started ← glfwInit backend
  when started (notePlatform journal backend)
  pure started

-- | Note which platform the initialized GLFW selected, and what was asked.
notePlatform ∷ Journal → Maybe Backend → IO ()
notePlatform journal backend = do
  selected ← glfwPlatform
  note journal $
    "GLFW selected the "
      <> selected
      <> " platform; the session requested "
      <> maybe "none" (Text.pack . show) backend
