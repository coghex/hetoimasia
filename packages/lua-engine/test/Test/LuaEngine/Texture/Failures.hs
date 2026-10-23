{-# LANGUAGE OverloadedStrings #-}

-- | What goes wrong, and how it is told: each expected content failure with its code and the root and
-- path that failed, without a backend call and with every charge returned; the required and optional
-- policy; and the engine's own faults (the reader, the backend, the allocator), which are never
-- content failures, never busy, and fatal whatever the request's policy.
module Test.LuaEngine.Texture.Failures (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..))
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Hetoimasia.Scripting.Lua.Admission (ProviderDefect (..))
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (small)
import Test.LuaEngine.Texture.Png
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "failures" $ do
  content
  policy
  faults
  workspace

files ∷ Layout
files =
  Layout
    [ ("a.png", opaque 8 4)
    , ("b.png", translucent 8 4)
    , ("bad.png", corruptedData 8 4)
    , ("trunc.png", truncatedStream 8 4)
    , ("text.png", notAPng)
    , ("anim.png", animated 8 4)
    , ("big.png", opaque 64 64)
    , ("huge.png", BS.replicate 70000 7)
    , ("changed.png", opaque 8 4)
    ]

-- | Load this path optionally, wait for the settlement and take it.
optionally ∷ Session → Vm → Text → Text → Text → IO Text
optionally session vm name key path = do
  commandWith session vm name "start" key (Just (Load path True))
  awaitNote session (name <> " start " <> key <> " started")
  command session vm name "wait_take" key
  lineStarting session (name <> " wait_take " <> key <> " ")

content ∷ Spec
content = describe "expected content failures" $ do
  it "name their code, the root and the path, call the backend never, and give every charge back once the result is taken" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "content" OnArrival
      admitDriver session vm "i"
      forM_
        [ ("not_found", "gone.png")
        , ("unsupported_format", "text.png")
        , ("unsupported_format", "anim.png")
        , ("invalid_image", "bad.png")
        , ("invalid_image", "trunc.png")
        , ("too_large", "big.png")
        , ("too_large", "huge.png")
        ]
        $ \(code, path) → do
          line ← optionally session vm "i" (Text.takeWhile (/= '.') path) path
          Text.unpack line `shouldContain` "status=failure"
          Text.unpack line `shouldContain` Text.unpack ("code=" <> code <> ",")
          Text.unpack line `shouldContain` Text.unpack ("path=" <> path <> ",root=texture-test")
          awaitOwner vm "i" (== OwnerReading 0 0)
          lanesCharged session `shouldReturn` [0, 0]
      uploadsSeen (ssFake session) `shouldReturn` 0
      -- The files the inventory knows to be absent or over the limit were never opened.
      startedPaths (ssProbe session) >>= (`shouldBe` ["text.png", "anim.png", "bad.png", "trunc.png", "big.png"])
      sessionNow session `shouldReturn` 0

  it "keeps a refused image's conservative charge until the request is taken: nothing was validated to shrink it" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "refused" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (Load "bad.png" True))
      awaitNote session "i start k started"
      awaitPipeline session ((== 1) . readingSettled)
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      command session vm "i" "take" "k"
      _ ← lineStarting session "i take k "
      awaitOwner vm "i" (== OwnerReading 0 0)

  it "is content_changed when the file is not what the scan pinned, and a texture loaded before stays valid" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "changed" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "old" (Just (Load "changed.png" False))
      awaitNote session "i start old started"
      awaitUploads (ssFake session) 1
      identity ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      command session vm "i" "wait_take" "old"
      _ ← lineStarting session "i wait_take old "
      rewrite session "changed.png" (opaque 8 4 <> "tampered")
      line ← optionally session vm "i" "new" "changed.png"
      line `shouldSatisfy` Text.isInfixOf "code=content_changed,"
      uploadsSeen (ssFake session) `shouldReturn` 1
      command session vm "i" "use" "old"
      awaitNote session ("i use old " <> Text.pack (show identity))

  it "is io_error when the read reports an access failure (injected: the reader answers it, no filesystem produced it)" $
    withSession ((config small files) {cfgReader = injectedIoError ["a.png"]}) $ \session _ runtime → do
      vm ← startVm session runtime "io" OnArrival
      admitDriver session vm "i"
      line ← optionally session vm "i" "k" "a.png"
      line `shouldSatisfy` Text.isInfixOf "code=io_error,"
      uploadsSeen (ssFake session) `shouldReturn` 0

  it "hands the backend the decoder's texels: an opaque image unchanged, a translucent one premultiplied once" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "texels" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (Load "b.png" False))
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      let texels = uploadTexels (heldUpload held)
      BS.length texels `shouldBe` 8 * 4 * 4
      -- Alpha is kept and the colour is scaled by it: the stored red of 200 is no longer 200.
      (BS.index texels 3, BS.index texels 0 < 200) `shouldBe` (128, True)

policy ∷ Spec
policy = describe "the required and optional policy" $ do
  it "fails the instance at a required request's settlement even if never read, naming the texture request" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "required" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (load "text.png"))
      awaitNote session "i start k started"
      failure ← awaitFailure session "i"
      fmap fst (requestFailureOf failure) `shouldBe` Just "texture"
      fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isPrefixOf "(texture text.png) unsupported_format: ")

  it "is a result for the script when optional, and the instance goes on" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "optional" OnArrival
      admitDriver session vm "i"
      line ← optionally session vm "i" "k" "gone.png"
      line `shouldSatisfy` Text.isInfixOf "code=not_found,"
      awaitPhase session vm "i" Active
      d ← vmDiagnostics vm
      rdLatched d `shouldBe` 0

faults ∷ Spec
faults = describe "the engine's own faults" $ do
  it "are a provider defect and not an optional failure when the backend reports a device failure: the owner fails, and the pipeline latches the fault" $ do
    ExceptionWithContext _ failure ← fatalSession (config small files) $ \session control runtime → do
      vm ← startVm session runtime "device" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (Load "a.png" True))
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      _ ← failUpload (ssFake session) held "the device was lost"
      reading ← pipelineNow session
      readingFailed reading `shouldBe` True
      _ ← awaitEnd control vm
      pure ()
    (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)

  it "are a provider defect when the backend raises as it is handed a level (an allocator failure, injected)" $ do
    ExceptionWithContext _ failure ← fatalSession (config small files) $ \session control runtime → do
      vm ← startVm session runtime "allocator" OnArrival
      admitDriver session vm "i"
      setRaiseOnUpload (ssFake session) True
      commandWith session vm "i" "start" "k" (Just (Load "a.png" True))
      awaitNote session "i start k started"
      _ ← awaitEnd control vm
      pure ()
    (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)

  it "are a provider defect when the read raises (injected: an engine defect, not a refusal)" $ do
    ExceptionWithContext _ failure ← fatalSession ((config small files) {cfgReader = injectedDefect ["a.png"] (userError "injected reader defect")}) $ \session control runtime → do
      vm ← startVm session runtime "reader" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (Load "a.png" True))
      awaitNote session "i start k started"
      _ ← awaitEnd control vm
      pure ()
    (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)

workspace ∷ Spec
workspace = describe "the lane's workspace bank" $
  it "refuses a decode that needs more than the lane's workspace as too_large, charges the lane nothing afterwards, and holds the validated charge until the request is taken" $
    withSession (config tight files) $ \session _ runtime → do
      vm ← startVm session runtime "workspace" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (Load "a.png" True))
      awaitNote session "i start k started"
      awaitPipeline session ((== 1) . readingSettled)
      -- The dimensions were validated before the decode asked for its scratch: the charge shrank, then
      -- the workspace refused the decode.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      lanesCharged session `shouldReturn` [0, 0]
      command session vm "i" "take" "k"
      line ← lineStarting session "i take k "
      line `shouldSatisfy` Text.isInfixOf "code=too_large,"
      awaitOwner vm "i" (== OwnerReading 0 0)
      uploadsSeen (ssFake session) `shouldReturn` 0
  where
    -- Less than the decoder's fixed scratch of 173,056 bytes.
    tight =
      smaller
        [(PngPixels, 1024), (PngAxisMaximum, 32)]
        [ (PngEncodedBytes, 65536)
        , (PngInflatedScanlineBytes, 65536)
        , (PngPipelineWorkspaceBytes, 100000)
        , (TextureBytesPerUiInstance, 16384)
        , (TextureBytesPerSession, 32768)
        ]
