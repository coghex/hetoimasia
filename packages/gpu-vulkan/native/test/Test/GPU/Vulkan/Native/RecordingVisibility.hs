-- | Examples proving that the managed recording's decomposition (#265) left
-- its public entry points as they were and its implementation modules out of
-- a client's reach.
--
-- The recording examples import the public modules from inside this package's
-- own suite, so they cannot observe what the package boundary exposes. These
-- examples therefore compile separate single-module clients with the same
-- compiler against this build's package database and the dependency store,
-- exposing only @base@ and this package's main library unit and hiding
-- everything else, as the shader suite's external client does. Typechecking is
-- the whole question, so no client is linked, and none needs the loader.
--
-- One client must be accepted: it imports, by name, every name the public
-- recording module exports — each type with the constructors it exports and
-- no others — and the entry points of @Recording.Shaders@ and
-- @Recording.Vulkan@. It is the control proving the environment is sound, and
-- the evidence that supported imports still compile.
--
-- Every other client must be rejected. One per implementation module imports
-- that module, and is refused because the module is hidden: GHC's code
-- @GHC-87110@ naming this package's unit, never a missing package or module,
-- which would be an environment failure. 'rejectedBecause' cannot express that
-- case, because GHC words a hidden module as one it "could not load". One per
-- abstract handle asks the public module for the handle's constructor, and is
-- refused because the module does not export it (@GHC-10237@).
module Test.GPU.Vulkan.Native.RecordingVisibility (spec) where

import Control.Monad (forM_)
import Data.List (intercalate)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Recording visibility across the package boundary" $ do
  it "accepts a client importing every public recording name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported recording imports did not compile (" <> show status <> "):\n" <> clientOutput outcome)

  describe "rejects a client importing an implementation module" $
    forM_ implementationModules $ \name →
      it name $
        withClient (importing name) $ \compile → do
          outcome ← compile Typecheck
          case clientStatus outcome of
            ExitFailure _ → pure ()
            ExitSuccess →
              expectationFailure ("the client compiled, so " <> name <> " is reachable:\n" <> clientOutput outcome)
          -- Found in this package's library and refused as hidden; naming the
          -- unit tells this apart from a missing package.
          clientOutput outcome `shouldContain` "GHC-87110"
          clientOutput outcome `shouldContain` name
          clientOutput outcome `shouldContain` "hetoimasia-gpu-vulkan-native-0.1.0.0"
          clientOutput outcome `shouldNotContain` "cannot satisfy"
          clientOutput outcome `shouldNotContain` "Could not find module"

  describe "rejects a client naming an abstract handle's constructor" $
    forM_ abstractHandles $ \handle →
      it handle $
        withClient (constructing handle) $ \compile → do
          outcome ← compile Typecheck
          rejectedBecause outcome "GHC-10237"
          clientOutput outcome `shouldContain` handle

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "hetoimasia-gpu-vulkan-native-0.1.0.0-inplace"] "Client.hs"

-- | The modules the public recording module is implemented by.
implementationModules ∷ [String]
implementationModules =
  map
    ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording." <>)
    ["Batches", "Construction", "Disposal", "Layer", "Readback", "Recorder", "State"]

-- | The types the public recording module exports without their
-- constructors, each of which has one of its own name.
abstractHandles ∷ [String]
abstractHandles = ["Recording", "PipelineLayout", "Pipeline", "FrameStorage", "Readback", "Recorder"]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client (supported) where"
    , ""
    , "import Hetoimasia.GPU.Vulkan.Native.Recording"
    , "  ( " <> intercalate "\n  , " publicNames
    , "  )"
    , "import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (verificationShaders)"
    , "import Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan (transitionScopes, vulkanRecordingOps)"
    , ""
    , "supported = (vulkanRecordingOps, transitionScopes, verificationShaders, RefusedNotOwner, supportedTransition)"
    ]
  where
    publicNames =
      [ "RecordingOps (..)"
      , "PipelineRequest (..)"
      , "PipelineShaders (..)"
      , "ReadbackAllocation (..)"
      , "NativeCommand (..)"
      , "ImageLayout (..)"
      , "ClearColor (..)"
      , "Viewport (..)"
      , "Rect (..)"
      , "Recording"
      , "newRecording"
      , "Refusal (..)"
      , "PipelineLayout"
      , "Pipeline"
      , "FrameStorage"
      , "Readback"
      , "Managed (managedResource)"
      , "createPipelineLayout"
      , "createPipeline"
      , "replacePipeline"
      , "createFrameStorage"
      , "createReadback"
      , "releaseManaged"
      , "Recorder"
      , "recorderBatch"
      , "recordFrame"
      , "transitionImage"
      , "supportedTransition"
      , "beginRendering"
      , "endRendering"
      , "bindPipeline"
      , "setViewport"
      , "setScissor"
      , "draw"
      , "copyToReadback"
      , "readbackBytesFor"
      , "discardBatch"
      , "resetFrameRecorder"
      , "noteBatchSubmitted"
      , "readReadback"
      , "fillReadback"
      , "mappedRange"
      , "disposeResources"
      , "retireRecording"
      , "ManagedStanding (..)"
      , "ManagedView (..)"
      , "readManaged"
      , "BatchStanding (..)"
      , "BatchView (..)"
      , "readBatch"
      , "readBatches"
      , "BatchInvalidationFailed (..)"
      , "ResourceDestructionFailed (..)"
      , "ResourcesRetained (..)"
      ]

importing ∷ String → String
importing name =
  unlines
    [ "module Client () where"
    , ""
    , "import " <> name <> " ()"
    ]

constructing ∷ String → String
constructing handle =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GPU.Vulkan.Native.Recording (" <> handle <> " (" <> handle <> "))"
    ]
