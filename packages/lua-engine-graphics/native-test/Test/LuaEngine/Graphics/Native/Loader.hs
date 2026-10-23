-- | Which loader the run actually loaded, held to the one the prefix recorded.
--
-- The binding links the loader by soname, so the file the dynamic linker opens
-- is whatever answers that name at run time. `native.py prepare` verifies the
-- pinned file, but a runtime search path can put an ABI-compatible substitute
-- ahead of it, and GLFW and the binding would then share that substitute
-- faithfully. Sharing a loader is not the same as sharing the qualified one,
-- so the image the binding's own entry point resolves into is compared with
-- the recorded file, both canonicalized by the caller.
module Test.LuaEngine.Graphics.Native.Loader
  ( loaderVariable
  , loaderSelection
  , checkLoader
  ) where

import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr, castFunPtrToPtr, nullPtr)
import System.Directory (canonicalizePath)
import System.Environment (lookupEnv)
import Vulkan.Dynamic (getInstanceProcAddr')

foreign import ccall safe "hetoimasia_lege_image_of"
  c_imageOf ∷ Ptr () → CString → CSize → CString → CSize → IO CInt

-- | Hold the loader this process loaded to the one the prefix recorded: the image that defines the Vulkan
-- binding's own @vkGetInstanceProcAddr@, canonicalized, against the recorded file. The answer is the loaded
-- path, or why this run is not on the qualified loader.
checkLoader ∷ IO (Either Text FilePath)
checkLoader = do
  entry ← Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)
  loaded ← imageOf (castFunPtrToPtr entry)
  recorded ← lookupEnv loaderVariable >>= traverse canonicalizePath
  loadedPath ← traverse canonicalizePath loaded
  pure (loaderSelection recorded loadedPath)

-- | The image that defines an address, if the dynamic linker attributes it.
imageOf ∷ Ptr () → IO (Maybe FilePath)
imageOf address =
  allocaArray capacity $ \image →
    allocaArray capacity $ \symbol → do
      attributed ← c_imageOf address image (fromIntegral capacity) symbol (fromIntegral capacity)
      if attributed == 0
        then pure Nothing
        else do
          name ← peekCString image
          pure (if null name then Nothing else Just name)
  where
    capacity = 1024

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
