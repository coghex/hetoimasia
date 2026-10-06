-- | The instance scope of a native case that owns its own instance and
-- explicit messenger outside the production roots: VK-6's capture
-- ("Test.Vulkan.Proof.Diagnostics") and the synchronization-validation hazard
-- ("Test.GPU.Vulkan.Native.Hazard").
--
-- Both are 'withResourceLabelled' scopes, so they keep the failure table of
-- @docs/resources.md@: when the body fails, its exception propagates with its
-- own type, value and context even if a destruction raises too, and every
-- destruction that raised is retained beside it under its scope's label. The
-- instance is the outermost of them. The explicit messenger is destroyed after
-- everything the body made, and the instance after the messenger, once, on the
-- returning and the unwinding path alike; an instance that was never created
-- runs neither the body nor any destruction.
--
-- The instance's destruction yields the evidence a diagnostic capture needs
-- that no callback can still run. Evidence is returned only from a destruction
-- that returned: one that raised returns none and becomes the scope's
-- exception when the body succeeded, so the body's result is discarded with
-- it.
--
-- The operations are passed in, so the same scope runs over the native layer
-- in a session and over injected operations in the examples that need none.
module Test.GPU.Vulkan.Native.InstanceScope
  ( InstanceOps (..)
  , withInstanceScope
  ) where

import Control.Exception (throwIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)

import Hetoimasia.Foundation.Resource (withResourceLabelled)

-- | What the scope does to the instance and its explicit messenger.
data InstanceOps inst msgr q = InstanceOps
  { instanceCreate ∷ IO inst
  , instanceDestroy ∷ inst → IO q
    -- ^ The last destruction that can report, and its evidence.
  , messengerCreate ∷ inst → IO msgr
  , messengerDestroy ∷ inst → msgr → IO ()
  }

-- | Create the instance and its explicit messenger, run the body, and destroy
-- both, recording a destruction that raised under the label given for it.
withInstanceScope
  ∷ Text
    -- ^ The instance's cleanup label.
  → Text
    -- ^ The explicit messenger's cleanup label.
  → InstanceOps inst msgr q
  → (inst → IO r)
  → IO (r, q)
withInstanceScope instanceLabel messengerLabel ops body = do
  issued ← newIORef Nothing
  result ←
    withResourceLabelled
      instanceLabel
      (instanceCreate ops)
      (\vulkan → instanceDestroy ops vulkan >>= writeIORef issued . Just)
      ( \vulkan →
          withResourceLabelled
            messengerLabel
            (messengerCreate ops vulkan)
            (messengerDestroy ops vulkan)
            (\_ → body vulkan)
      )
  -- The scope returned, so the instance's destruction returned and wrote its
  -- evidence.
  readIORef issued
    >>= maybe (throwIO (userError "the instance scope returned without its destruction's evidence")) (pure . (result,))
