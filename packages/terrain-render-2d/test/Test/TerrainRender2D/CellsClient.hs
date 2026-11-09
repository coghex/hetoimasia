-- | What the cell-quad path exposes across the package boundary (TRA-16).
--
-- A suite inside the package reaches every constructor, so it cannot observe
-- the boundary. These examples compile separate single-module clients with the
-- harness from "Test.Support.ExternalClient". One client must be accepted,
-- linked and run: it builds supplied knowledge and assets, plans and picks
-- through the public interfaces, with no private module and no effectful
-- engine dependency. Every other client must be refused for the diagnostic
-- that names its cause: a plan, identity, quad, preparation, knowledge or asset
-- snapshot cannot be built or edited by constructor or record update.
module Test.TerrainRender2D.CellsClient (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withStorePackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "Cell quads across the package boundary (TRA-16)" $ do
  it "accepts and runs a client that builds supplied inputs, plans and picks through the public interfaces" $
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
      lines out `shouldBe` ["quads: 1", "progress: Settled", "pick: hit (0,0,0)", "stale: CellPickStale"]

  forM_ constructors $ \(name, imports) →
    it ("rejects a client that names the constructor of " <> name) $
      withClient "Client.hs" (unlines (["module Client () where", ""] <> imports)) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ updates $ \(name, imports, body) →
    it ("rejects a client that rewrites " <> name <> " with record-update syntax") $
      withClient "Client.hs" (unlines (["module Client () where", ""] <> imports <> ["", body])) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"

  it "rejects a client that imports the hidden planner module" $
    withClient "Client.hs" (unlines ["module Client () where", "", "import Hetoimasia.Terrain.Render2D.Internal.Cells"]) $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the hidden module is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Terrain.Render2D.Internal.Cells"
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldNotContain` "cannot satisfy"
      clientOutput outcome `shouldNotContain` "Could not find module"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withStorePackageClient
    [ "base"
    , "bytestring"
    , "hetoimasia-terrain-render-2d-0.1.0.0-inplace"
    , "hetoimasia-terrain-render-2d-0.1.0.0-inplace-terrain-mapbake"
    , "hetoimasia-asset-image-0.1.0.0-inplace"
    , "hetoimasia-terrain"
    , "hetoimasia-render-2d"
    , "hetoimasia-math"
    ]

constructors ∷ [(String, [String])]
constructors =
  [ ("CellIdentity", ["import Hetoimasia.Terrain.Render2D.Cells (CellIdentity (CellIdentity))"])
  , ("CellPlan", ["import Hetoimasia.Terrain.Render2D.Cells (CellPlan (CellPlan))"])
  , ("CellQuad", ["import Hetoimasia.Terrain.Render2D.Cells (CellQuad (CellQuad))"])
  , ("CellPrep", ["import Hetoimasia.Terrain.Render2D.Cells (CellPrep (CellPrep))"])
  , ("Knowledge", ["import Hetoimasia.Terrain.Render2D.Knowledge (Knowledge (Knowledge))"])
  , ("AssetSnapshot", ["import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot (AssetSnapshot))"])
  ]

updates ∷ [(String, [String], String)]
updates =
  [
    ( "an identity"
    , ["import Hetoimasia.Terrain.Render2D.Cells (CellIdentity, cellIdentityKnowledge)"]
    , "rewrite :: CellIdentity -> CellIdentity\nrewrite identity = identity {cellIdentityKnowledge = 99}"
    )
  ,
    ( "a quad's rank"
    , ["import Hetoimasia.Terrain.Render2D.Cells (CellQuad, quadDepthKey)"]
    , "rewrite :: CellQuad -> CellQuad\nrewrite quad = quad {quadDepthKey = 0}"
    )
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString as ByteString"
    , "import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), buildBinaryCoverage)"
    , "import Hetoimasia.Asset.Image.Region (fullImageView)"
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), offscreenMetrics)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))"
    , "import Hetoimasia.Terrain.Cell (mkMaterialId)"
    , "import Hetoimasia.Terrain.Changes (emptyChanges)"
    , "import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisFromInteger, axisValue)"
    , "import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys)"
    , "import Hetoimasia.Terrain.Render2D.Assets"
    , "import Hetoimasia.Terrain.Render2D.Camera"
    , "import Hetoimasia.Terrain.Render2D.CellPick"
    , "import Hetoimasia.Terrain.Render2D.Cells"
    , "import Hetoimasia.Terrain.Render2D.Facts"
    , "import Hetoimasia.Terrain.Render2D.Knowledge"
    , "import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))"
    , "import Hetoimasia.Terrain.Source"
    , ""
    , "main :: IO ()"
    , "main = do"
    , "  let spec = SourceSpec [\"stone\"] [] [PatchSpec 0 0 0 1 (SpecSolid \"stone\" 0)]"
    , "      opaquePlane = either (error . show) id (buildBinaryCoverage 96 64 (ByteString.replicate (96 * 64 * 4) 255))"
    , "      opaque = either (error . show) id (fullImageView 3 opaquePlane)"
    , "  case (mkSource defaultSourceLimits spec, axisFromInteger 0, mkMaterialId \"stone\") of"
    , "    (Right source, Right zero, Right stone) -> do"
    , "      let facts = TerrainFacts (Versions 1 1 1) source emptyChanges AllKnown"
    , "          mkColour ref = either (error . show) id (mkColourAsset ref 3 3 opaque)"
    , "          maps = [(key, either (error . show) id (mkMapAsset key 3 3 (Just UnitNormalRgbV1) opaque)) | key <- catalogKeys]"
    , "          assets = either (error . show) id (mkAssetSnapshot 3 (mkColour ColourBlank) [(stone, mkColour (ColourMaterial stone))] maps)"
    , "          knowledge = either (error . show) id (mkKnowledge (KnowledgeSpec 1 CellDiscovered [] []))"
    , "          camera = either (error . show) id (newCamera defaultCameraConfig zero zero zero)"
    , "          extent = PixelExtent 320 240"
    , "          setup = ViewSetup (offscreenMetrics extent) (Viewport (V2 0 0) (V2 320 240)) defaultViewSettings"
    , "          inputs = CellInputs (CellRequest (Versions 1 1 1) camera setup defaultCellConfig) facts knowledge assets"
    , "      case planCells inputs of"
    , "        Left refusal -> putStrLn (\"refused: \" <> show refusal)"
    , "        Right plan -> do"
    , "          putStrLn (\"quads: \" <> show (length (cellPlanQuads plan)))"
    , "          putStrLn (\"progress: \" <> show (cellPlanProgress plan))"
    , "          let centre = case map quadTarget (cellPlanQuads plan) of"
    , "                TargetRect l t _ _ : _ -> V2 (fromRational l + 48) (fromRational t + 32)"
    , "                [] -> V2 0 0"
    , "          case pickCells plan (CellPickQuery (cellPlanIdentity plan) centre) of"
    , "            Right (CellPickHit hit) ->"
    , "              let TileCoord x y z = hitCell hit"
    , "               in putStrLn (\"pick: hit (\" <> show (axisValue x) <> \",\" <> show (axisValue y) <> \",\" <> show (axisValue z) <> \")\")"
    , "            other -> putStrLn (\"pick: \" <> show other)"
    , "          let moved = inputs {inputsKnowledge = either (error . show) id (mkKnowledge (KnowledgeSpec 2 CellDiscovered [] []))}"
    , "          case planCells moved of"
    , "            Right other -> putStrLn (\"stale: \" <> either show (const \"fresh\") (pickCells plan (CellPickQuery (cellPlanIdentity other) centre)))"
    , "            Left refusal -> putStrLn (\"refused: \" <> show refusal)"
    , "    _ -> putStrLn \"fixture refused\""
    ]
