-- | What the package's boundary exposes to a client.
--
-- A suite inside the package can reach every constructor, so it cannot observe
-- the boundary. These examples compile separate single-module clients with the
-- harness from "Test.Support.ExternalClient". One client must be accepted,
-- linked and run: it plans and picks through the public interfaces. Every other
-- client must be refused for the specific diagnostic that names its cause.
module Test.TerrainRender2D.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withStorePackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "Terrain render-2d opacity across the package boundary" $ do
  it "accepts and runs a client that plans and picks through the public interfaces" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ←
        runCaptured
          clientRunBound
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out `shouldBe` supportedOutput

  forM_ constructors $ \(name, imports) →
    it ("rejects a client that names the constructor of " <> name) $
      withClient "Client.hs" (unlines (["module Client () where", ""] <> imports)) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  it "rejects a client that rewrites a camera with record-update syntax" $
    withClient
      "Client.hs"
      ( unlines
          [ "module Client () where"
          , ""
          , "import Hetoimasia.Terrain.Render2D.Camera (CameraState, camZoom)"
          , ""
          , "rewrite :: CameraState -> CameraState"
          , "rewrite camera = camera {camZoom = 100}"
          ]
      )
      $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"

  forM_ hidden $ \module' →
    it ("rejects a client that imports the hidden module " <> module') $
      withClient "Client.hs" (unlines ["module Client () where", "", "import " <> module']) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess → expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-terrain-render-2d-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  -- The library's cell-quad path reads the asset package's coverage planes and
  -- the map catalog's lookup (TRA-16), so both units, and the store the first
  -- resolves its Hackage dependencies from, must be exposed for the unit to
  -- load; a client still names only what it imports.
  withStorePackageClient
    [ "base"
    , "hetoimasia-terrain-render-2d-0.1.0.0-inplace"
    , "hetoimasia-terrain-render-2d-0.1.0.0-inplace-terrain-mapbake"
    , "hetoimasia-asset-image-0.1.0.0-inplace"
    , "hetoimasia-terrain"
    , "hetoimasia-render-2d"
    , "hetoimasia-math"
    ]

hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Render2D.Internal.Order"
  , "Hetoimasia.Terrain.Render2D.Internal.Polygon"
  ]

constructors ∷ [(String, [String])]
constructors =
  [ ("CameraState", ["import Hetoimasia.Terrain.Render2D.Camera (CameraState (CameraState))"])
  , ("Plan", ["import Hetoimasia.Terrain.Render2D.Plan (Plan (Plan))"])
  , ("RenderView", ["import Hetoimasia.Terrain.Render2D.Projection (RenderView (RenderView))"])
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), offscreenMetrics)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))"
    , "import Hetoimasia.Terrain.Changes (emptyChanges)"
    , "import Hetoimasia.Terrain.Coordinate (axisFromInteger)"
    , "import Hetoimasia.Terrain.Render2D.Camera"
    , "import Hetoimasia.Terrain.Render2D.Facts"
    , "import Hetoimasia.Terrain.Render2D.Pick"
    , "import Hetoimasia.Terrain.Render2D.Plan"
    , "import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))"
    , "import Hetoimasia.Terrain.Source"
    , ""
    , "main :: IO ()"
    , "main = do"
    , "  let spec = SourceSpec [\"stone\"] [LayerSpec Nothing (Just 1) \"stone\" 0] []"
    , "  case (mkSource defaultSourceLimits spec, axisFromInteger 0) of"
    , "    (Right source, Right zero) -> do"
    , "      let facts = TerrainFacts (Versions 1 1 1) source emptyChanges AllKnown"
    , "          setup = ViewSetup (offscreenMetrics (PixelExtent 288 144)) (Viewport (V2 0 0) (V2 288 144)) defaultViewSettings"
    , "      case newCamera defaultCameraConfig zero zero zero of"
    , "        Right fresh -> do"
    , "          let camera = either (error . show) stepCamera (refollow defaultCameraConfig facts fresh)"
    , "          print (camSurface camera, camZoom camera)"
    , "          case planTerrain (PlanRequest (Versions 1 1 1) 3 camera setup defaultPlanConfig) facts of"
    , "            Right plan -> do"
    , "              print (planCompleteness plan, length (planFaces plan) > 0)"
    , "              print (pickPlan plan (PickQuery (planIdentity plan) (V2 144 72)) == pickPlan plan (PickQuery (planIdentity plan) (V2 144 72)))"
    , "              print (fmap (const ()) (pickPlan plan (PickQuery (planIdentity plan) (V2 0 (0/0)))))"
    , "            Left e -> print e"
    , "        Left e -> print e"
    , "    _ -> putStrLn \"unexpected\""
    ]

supportedOutput ∷ [String]
supportedOutput =
  [ "(Just (AxisCoord 0),1.0)"
  , "(Complete,True)"
  , "True"
  , "Left PickInvalidPoint"
  ]
