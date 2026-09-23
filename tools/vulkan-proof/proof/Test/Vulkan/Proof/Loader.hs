-- | Which loader the run actually loaded, held to the one the prefix recorded.
--
-- The binding links the loader by soname, so the file the dynamic linker opens
-- is whatever answers that name at run time. `native.py prepare` verifies the
-- pinned file, but a runtime search path can put an ABI-compatible substitute
-- ahead of it, and GLFW and the binding would then share that substitute
-- faithfully. Sharing a loader is not the same as sharing the qualified one,
-- so the image the binding's own entry point resolves into is compared with
-- the recorded file, both canonicalized by the caller.
module Test.Vulkan.Proof.Loader
  ( loaderVariable
  , loaderSelection
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | Where the runner names the loader file the prefix's record hashed.
loaderVariable ∷ String
loaderVariable = "HETOIMASIA_VULKAN_QUALIFIED_LOADER"

-- | The recorded loader and the image the binding's entry point resolved into,
-- each already canonicalized, and either the loaded path or why it is not the
-- recorded one.
loaderSelection ∷ Maybe FilePath → Maybe FilePath → Either Text FilePath
loaderSelection Nothing _ =
  Left
    ( "the runner named no recorded loader in "
        <> Text.pack loaderVariable
        <> ", so the loader this run loaded could not be held to the qualified one"
    )
loaderSelection _ Nothing =
  Left "the binding's vkGetInstanceProcAddr is attributed to no image, so which loader this run loaded is unknown"
loaderSelection (Just recorded) (Just loaded)
  | recorded == loaded = Right loaded
  | otherwise =
      Left
        ( "the binding loaded "
            <> Text.pack loaded
            <> ", not the recorded loader "
            <> Text.pack recorded
            <> "; a loader found through a runtime search path is not the qualified one"
        )
