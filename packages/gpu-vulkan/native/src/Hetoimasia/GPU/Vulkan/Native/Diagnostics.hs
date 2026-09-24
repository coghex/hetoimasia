{-# LANGUAGE DuplicateRecordFields #-}

-- | Validation capture on real Vulkan objects: the debug-utils messengers that
-- deliver into a "Hetoimasia.GPU.Vulkan.Diagnostics" lifetime.
--
-- Both messengers an instance can have use the same callback and the same
-- user data. 'captureMessengerCreateInfo' goes in the @VkInstanceCreateInfo@
-- chain, which is the only messenger that hears @vkCreateInstance@ and
-- @vkDestroyInstance@; 'withCaptureMessenger' is the explicit one, which hears
-- everything between and must be destroyed after every child object and
-- immediately before the instance, so a device's own destruction reports
-- somewhere.
--
-- The callback is 'captureMessengerCallback', a C function in this package's
-- @cbits@ that hands its arguments to the diagnostics package's C producer.
-- Nothing on that path is Haskell, so a Vulkan call made through a genuine
-- @unsafe@ import can report through it: this package installs no Haskell
-- callback, no allocation callback and no trampoline. The callback's code is
-- part of the executable, so it lives as long as the process; the user data
-- is the capture's storage, which the diagnostic lifetime keeps until after the
-- body that owns these messengers has returned.
--
-- This package's own use of the binding is recorded in 'nativeFfiConfiguration',
-- which evidence records print beside the build's source digest.
module Hetoimasia.GPU.Vulkan.Native.Diagnostics
  ( -- * Messengers
    captureMessengerCallback
  , captureMessengerCreateInfo
  , createCaptureMessenger
  , destroyCaptureMessenger
  , withCaptureMessenger
  , destroyInstanceQuiesced

    -- * FFI configuration
  , NativeFfiConfiguration (..)
  , nativeFfiConfiguration
  , describeFfiConfiguration
  ) where

import Data.Bits ((.|.))
import Data.Text (Text)
import Vulkan.Core10 (Instance, destroyInstance)
import Vulkan.Extensions.VK_EXT_debug_utils
  ( DebugUtilsMessengerCreateInfoEXT (..)
  , DebugUtilsMessengerEXT
  , PFN_vkDebugUtilsMessengerCallbackEXT
  , createDebugUtilsMessengerEXT
  , destroyDebugUtilsMessengerEXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
  )
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticCapture, Quiesced, afterLastCallback, captureUserData)

-- | The C callback every capture messenger registers.
captureMessengerCallback ∷ PFN_vkDebugUtilsMessengerCallbackEXT
captureMessengerCallback = hetoimasia_vulkan_capture_messenger

foreign import ccall unsafe "hetoimasia_vulkan_native.h &hetoimasia_vulkan_capture_messenger"
  hetoimasia_vulkan_capture_messenger ∷ PFN_vkDebugUtilsMessengerCallbackEXT

-- | A messenger that reports every severity and every message type into this
-- capture. Chain it into @VkInstanceCreateInfo@, or pass it to
-- 'createCaptureMessenger'.
captureMessengerCreateInfo ∷ DiagnosticCapture → DebugUtilsMessengerCreateInfoEXT
captureMessengerCreateInfo capture =
  DebugUtilsMessengerCreateInfoEXT
    { flags = zero
    , messageSeverity =
        DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
    , messageType =
        DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
    , pfnUserCallback = captureMessengerCallback
    , userData = captureUserData capture
    }

-- | Create the explicit messenger. Its caller owns it, and destroys it with
-- 'destroyCaptureMessenger' after every child of the instance.
createCaptureMessenger ∷ Instance → DiagnosticCapture → IO DebugUtilsMessengerEXT
createCaptureMessenger vulkan capture =
  createDebugUtilsMessengerEXT vulkan (captureMessengerCreateInfo capture) Nothing

destroyCaptureMessenger ∷ Instance → DebugUtilsMessengerEXT → IO ()
destroyCaptureMessenger vulkan messenger = destroyDebugUtilsMessengerEXT vulkan messenger Nothing

-- | The explicit messenger for the body's duration. Open it before the
-- instance's first child and let the body destroy every child before it
-- returns: the messenger is destroyed on the way out, and the instance after
-- it by its own enclosing scope.
withCaptureMessenger ∷ Instance → DiagnosticCapture → (DebugUtilsMessengerEXT → IO a) → IO a
withCaptureMessenger vulkan capture =
  withResourceLabelled
    "vulkan debug messenger"
    (createCaptureMessenger vulkan capture)
    (destroyCaptureMessenger vulkan)

-- | Destroy an instance whose messengers deliver into this capture, and return
-- the evidence the diagnostic lifetime needs that its callback is quiescent.
--
-- @vkDestroyInstance@ is the last call that can invoke the create-info
-- messenger's callback, and Vulkan invokes a callback only from inside a
-- Vulkan call, so once it returns no invocation can be running or begin. Call
-- this after every child of the instance and the explicit messenger are gone,
-- on the path that returns and on the one that unwinds.
destroyInstanceQuiesced ∷ DiagnosticCapture → Instance → IO Quiesced
destroyInstanceQuiesced capture vulkan = afterLastCallback capture (destroyInstance vulkan Nothing)

-- | How this package calls into Vulkan and what Vulkan can call back into.
data NativeFfiConfiguration = NativeFfiConfiguration
  { ffiBinding ∷ !Text
  , ffiBindingSafeForeignCalls ∷ !Bool
    -- ^ The binding-wide flag `cabal.project.vulkan` constrains. On, the
    -- binding's own imports are @safe@, so any of them may block, wait, or
    -- re-enter Haskell.
  , ffiBindingDarwinLibDirs ∷ !Bool
  , ffiCaptureCallback ∷ !Text
    -- ^ The callback a messenger reaches, and what it runs.
  , ffiHaskellCallbacks ∷ ![Text]
    -- ^ Haskell callbacks this package installs into Vulkan: none.
  , ffiUnsafeImports ∷ ![Text]
    -- ^ Genuine @unsafe@ Vulkan imports this package declares: none yet. The
    -- audited recording subset is VK-11's.
  }
  deriving (Eq, Show)

-- | This package's configuration. The binding flags restate what the project
-- file constrains and `tools/toolchain/binding.pin` records; a proof run checks
-- the two agree.
nativeFfiConfiguration ∷ NativeFfiConfiguration
nativeFfiConfiguration =
  NativeFfiConfiguration
    { ffiBinding = "vulkan-3.27"
    , ffiBindingSafeForeignCalls = True
    , ffiBindingDarwinLibDirs = False
    , ffiCaptureCallback = "hetoimasia_vulkan_capture_messenger (C) → hetoimasia_capture_callback (C)"
    , ffiHaskellCallbacks = []
    , ffiUnsafeImports = []
    }

-- | The configuration as the lines an evidence record prints.
describeFfiConfiguration ∷ NativeFfiConfiguration → [(Text, Text)]
describeFfiConfiguration configuration =
  [ ("binding", ffiBinding configuration)
  , ("binding safe-foreign-calls", onOff (ffiBindingSafeForeignCalls configuration))
  , ("binding darwin-lib-dirs", onOff (ffiBindingDarwinLibDirs configuration))
  , ("capture callback", ffiCaptureCallback configuration)
  , ("Haskell callbacks installed", listed (ffiHaskellCallbacks configuration))
  , ("unsafe imports declared", listed (ffiUnsafeImports configuration))
  ]
  where
    onOff enabled = if enabled then "on" else "off"
    listed [] = "none"
    listed names = mconcat (zipWith (<>) ("" : repeat ", ") names)
