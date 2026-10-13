-- | Examples proving what the package boundary shows a client: a validated
-- snapshot and a validated layer cannot be built or rewritten from outside the
-- validation module, an offscreen target reference cannot be built or taken
-- apart through its public module, and the backend-facing target module and the
-- documented validate-then-encode route do work.
--
-- Each compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @hetoimasia-math@,
-- @hetoimasia-render-api@ and @hetoimasia-render-2d@ and hiding everything
-- else. A rejected client must be refused for the diagnostic that names its
-- cause, so a missing package or an absent compiler can never pass for the
-- boundary holding. The accepted clients are the environment control: they show
-- the harness compiles against these packages at all.
module Test.Render.TwoD.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Validated value and target opacity across the package boundary" $ do
  rejected "a client that names the validated snapshot's constructor" snapshotConstructor "GHC-10237" "ValidSnapshot"
  rejected "a client that names the validated layer's constructor" layerConstructor "GHC-10237" "ValidLayer"
  rejected "a client that rewrites a validated layer by record update" layerRecordUpdate "GHC-22385" "validLayerContents"
  rejected "a client that names the offscreen target reference's constructor" targetConstructor "GHC-10237" "TargetRef"
  rejected "a client that reads the target reference's index through the public module" targetReader "GHC-61689" "targetRefIndex"
  rejected "a client that builds a target reference through the public module" targetBuilder "GHC-61689" "targetRef"
  rejected "a client that names the view mapping's constructor" mappingConstructor "GHC-10237" "ViewMapping"
  accepted "a client that validates a candidate and encodes its layers" validateAndEncode
  accepted "a client that builds a view mapping and converts a cursor position" buildMapping
  accepted "a client that builds and reads a target reference through the backend-facing module" backendTarget

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient
    ["base", "hetoimasia-math", "hetoimasia-render-api", "hetoimasia-render-2d"]
    "Client.hs"

rejected ∷ String → String → String → String → Spec
rejected name source code mention =
  it ("rejects " <> name) $
    withClient source $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome code
      clientOutput outcome `shouldContain` mention

accepted ∷ String → String → Spec
accepted name source =
  it ("accepts " <> name) $
    withClient source $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

snapshotConstructor ∷ String
snapshotConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Snapshot)"
    , "import Hetoimasia.Render.TwoD.Validation (ValidSnapshot (ValidSnapshot))"
    , ""
    , "forged ∷ Snapshot → ValidSnapshot"
    , "forged snapshot = ValidSnapshot snapshot []"
    ]

layerConstructor ∷ String
layerConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Layer)"
    , "import Hetoimasia.Render.TwoD.Validation (Location (AtLayer), ValidLayer (ValidLayer))"
    , ""
    , "forged ∷ Layer → ValidLayer"
    , "forged layer = ValidLayer (AtLayer 0 0 0) layer"
    ]

layerRecordUpdate ∷ String
layerRecordUpdate =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Layer)"
    , "import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayerContents)"
    , ""
    , "rewritten ∷ ValidLayer → Layer → ValidLayer"
    , "rewritten valid layer = valid { validLayerContents = layer }"
    ]

targetConstructor ∷ String
targetConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Target (TargetRef (TargetRef))"
    , ""
    , "forged ∷ TargetRef"
    , "forged = TargetRef 1 1"
    ]

targetReader ∷ String
targetReader =
  unlines
    [ "module Client (index) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Target (TargetRef, targetRefIndex)"
    , ""
    , "index ∷ TargetRef → Word32"
    , "index = targetRefIndex"
    ]

targetBuilder ∷ String
targetBuilder =
  unlines
    [ "module Client (made) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Target (TargetRef, targetRef)"
    , ""
    , "made ∷ TargetRef"
    , "made = targetRef 1 1"
    ]

-- | What game code does with the package: build a candidate, validate it, and
-- encode each layer of the result.
validateAndEncode ∷ String
validateAndEncode =
  unlines
    [ "module Client (frame) where"
    , ""
    , "import Hetoimasia.Math.Affine2 (identity)"
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , "import Hetoimasia.Render.TwoD.Encoding (encodeLayer)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot"
    , "import Hetoimasia.Render.TwoD.Validation (validLayers, validateSnapshot)"
    , ""
    , "-- The result is unit: the encoded buffers are forced, then dropped, because"
    , "-- their type belongs to a package this client deliberately does not expose."
    , "frame ∷ TextureHandle → ()"
    , "frame texture = either (const ()) (foldr seq () . map encodeLayer . validLayers) (validateSnapshot snapshot)"
    , "  where"
    , "    snapshot = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [view]]"
    , "    view = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 640 480)) defaultViewSettings [] [layer]"
    , "    layer = UiLayer [Instance identity (UvRect 0 0 1 1) texture 0 (Tint 255 255 255 255) SamplerDefault False False 0 0]"
    ]

backendTarget ∷ String
backendTarget =
  unlines
    [ "module Client (issued, numbers) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Target (TargetRef)"
    , "import Hetoimasia.Render.TwoD.Target.Backend (targetRef, targetRefGeneration, targetRefIndex)"
    , ""
    , "issued ∷ Word32 → Word32 → TargetRef"
    , "issued = targetRef"
    , ""
    , "numbers ∷ TargetRef → (Word32, Word32)"
    , "numbers reference = (targetRefIndex reference, targetRefGeneration reference)"
    ]

mappingConstructor ∷ String
mappingConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Mapping (ViewMapping (ViewMapping))"
    , ""
    , "forged ∷ ViewMapping"
    , "forged = ViewMapping undefined undefined undefined undefined undefined undefined"
    ]

-- | What game code does with the mapping: build it from the window's metrics
-- and a view, and turn a cursor position into a world point.
buildMapping ∷ String
buildMapping =
  unlines
    [ "module Client (pick) where"
    , ""
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.TwoD.Mapping (viewMapping, windowToWorld)"
    , "import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot (Camera (..), View (..), Viewport (..))"
    , ""
    , "pick ∷ V2 → Maybe V2"
    , "pick cursor = viewMapping metrics view >>= \\mapping → windowToWorld mapping cursor"
    , "  where"
    , "    metrics = TargetMetrics (PixelExtent 640 480) (PixelExtent 1280 960) 2 2"
    , "    view = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 1280 960)) defaultViewSettings [] []"
    ]
