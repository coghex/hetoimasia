-- | Examples proving that the frames' public entry points compile for a client
-- and that their implementation modules, and the 'Frames' representation, are
-- out of its reach — the proof "Test.GPU.Vulkan.Native.RecordingVisibility"
-- makes for the recording, made the same way: single-module clients
-- typechecked against this build's package database, exposing only @base@ and
-- this package's main library unit.
--
-- The accepted client imports every name the public frames module exports and
-- the production layer's entry point. Every other client must be rejected: one
-- per implementation module, refused as hidden (@GHC-87110@ naming this
-- package's unit), and one asking for the abstract 'Frames' constructor,
-- refused because the module does not export it (@GHC-10237@).
module Test.GPU.Vulkan.Native.FramesVisibility (spec) where

import Control.Monad (forM_)
import Data.List (intercalate)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Frames visibility across the package boundary" $ do
  it "accepts a client importing every public frames name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported frames imports did not compile (" <> show status <> "):\n" <> clientOutput outcome)

  describe "rejects a client importing an implementation module" $
    forM_ implementationModules $ \name →
      it name $
        withClient (importing name) $ \compile → do
          outcome ← compile Typecheck
          case clientStatus outcome of
            ExitFailure _ → pure ()
            ExitSuccess →
              expectationFailure ("the client compiled, so " <> name <> " is reachable:\n" <> clientOutput outcome)
          clientOutput outcome `shouldContain` "GHC-87110"
          clientOutput outcome `shouldContain` name
          clientOutput outcome `shouldContain` "hetoimasia-gpu-vulkan-native-0.1.0.0"
          clientOutput outcome `shouldNotContain` "cannot satisfy"
          clientOutput outcome `shouldNotContain` "Could not find module"

  it "rejects a client naming the Frames constructor" $
    withClient constructing $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Frames"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "hetoimasia-gpu-vulkan-native-0.1.0.0-inplace"] "Client.hs"

-- | The modules the public frames module is implemented by.
implementationModules ∷ [String]
implementationModules =
  map
    ("Hetoimasia.GPU.Vulkan.Native.Internal.Frames." <>)
    ["Abandonment", "Acquisition", "Layer", "Presentation", "Progress", "State", "Submission"]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client (supported) where"
    , ""
    , "import Hetoimasia.GPU.Vulkan.Native.Frames"
    , "  ( " <> intercalate "\n  , " publicNames
    , "  )"
    , "import Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan (vulkanFrameOps)"
    , ""
    , "supported = (vulkanFrameOps, WaitAtColorOutput, PendingNoImage, FenceIdle)"
    ]
  where
    publicNames =
      [ "FrameOps (..)"
      , "AcquireResult (..)"
      , "WaitStage (..)"
      , "SubmitBatch (..)"
      , "PresentRequest (..)"
      , "PresentStatus (..)"
      , "Frames"
      , "newFrames"
      , "tryAcquireFrame"
      , "Acquisition (..)"
      , "OwnedFrame (..)"
      , "PendingReason (..)"
      , "submitFrames"
      , "Submitted (..)"
      , "presentFrame"
      , "Presented (..)"
      , "PresentReading (..)"
      , "classifyPresent"
      , "skipFrame"
      , "closeUnpresentedFrame"
      , "closeTargetFrames"
      , "progressFrames"
      , "awaitFrames"
      , "drainWaitLimit"
      , "Progress (..)"
      , "retireTargetFrames"
      , "FrameStage (..)"
      , "FrameStanding (..)"
      , "readFrameStandings"
      , "FenceState (..)"
      , "SemaphoreState (..)"
      , "SlotSync (..)"
      , "SlotView (..)"
      , "readSlots"
      , "readOutstandingSubmissions"
      , "PoolHolder (..)"
      , "PoolSync (..)"
      , "PoolView (..)"
      , "readPool"
      , "PresentStanding (..)"
      , "PresentationStanding (..)"
      , "readPresentations"
      , "FrameEffectUncertain (..)"
      , "FrameCleanupFailed (..)"
      , "FramesRetained (..)"
      , "PresentationUncertain (..)"
      ]

importing ∷ String → String
importing name =
  unlines
    [ "module Client () where"
    , ""
    , "import " <> name <> " ()"
    ]

constructing ∷ String
constructing =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GPU.Vulkan.Native.Frames (Frames (Frames))"
    ]
