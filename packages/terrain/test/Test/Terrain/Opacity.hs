-- | Examples proving what the terrain package's boundary exposes to a client.
--
-- A suite inside the package shares its module environment and can reach every
-- constructor, so it cannot observe the boundary. These examples compile
-- separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@ and @hetoimasia-terrain@ and
-- hiding everything else.
--
-- One client must be accepted, linked and run: it uses the public coordinate,
-- shape and geometry interfaces end to end, which is both the environment
-- control and the evidence that the supported operations stay usable. Every
-- other client must be refused, each for the specific diagnostic that names its
-- cause, so a missing package or an absent compiler can never pass for the
-- boundary holding:
--
-- * the constructor of a checked value (an axis coordinate, a local offset, a
--   shape identity, a rotation count, a ray or a solid) cannot be named, so a
--   client cannot build an out-of-range coordinate, an unsupported identity, an
--   unnormalized turn, a ray with no direction or a forged solid: @GHC-10237@
--   for an import, and @GHC-01928@ (an illegal term-level use of the type
--   constructor) for a use of the constructor in an expression;
-- * each private module is refused as a hidden module of the package's main
--   library, @GHC-87110@.
module Test.Terrain.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withPackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "Terrain opacity across the package boundary" $ do
  it "accepts and runs a client using the public coordinate, shape and geometry interfaces" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        runCaptured
          clientRunBound
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out `shouldBe` supportedOutput

  forM_ constructors $ \(name, imports, source) →
    it ("rejects a client that names the constructor of " <> name) $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ forged $ \(name, imports, source) →
    it ("rejects a client that builds " <> name <> " from its constructor") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome ← compile Typecheck
        -- The type is imported without its constructor, so using the
        -- constructor in an expression is an illegal term-level use of the type.
        rejectedBecause outcome "GHC-01928"
        clientOutput outcome `shouldContain` "Illegal term-level use of the type constructor"
        clientOutput outcome `shouldContain` name

  forM_ hidden $ \module' →
    it ("rejects a client that imports the hidden module " <> module') $
      withClient "Client.hs" (unlines ["module Client () where", "", "import " <> module']) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        -- Found in the main library and refused as hidden; naming that unit
        -- tells this apart from a missing module or an unresolvable package.
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-terrain-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-terrain"]

-- | The modules hidden inside the main library.
hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Internal.Coordinate"
  , "Hetoimasia.Terrain.Internal.Polytope"
  , "Hetoimasia.Terrain.Internal.Shape"
  ]

clientImporting ∷ [String] → [String] → String
clientImporting imports body = unlines (["module Client () where", ""] <> imports <> [""] <> body)

-- | A constructor imported by name: the constructor is private, so the import
-- is refused (the type is exported abstractly).
constructors ∷ [(String, [String], [String])]
constructors =
  [ ("AxisCoord", ["import Hetoimasia.Terrain.Coordinate (AxisCoord (AxisCoord))"], [])
  , ("LocalCoord", ["import Hetoimasia.Terrain.Coordinate (LocalCoord (LocalCoord))"], [])
  , ("ShapeId", ["import Hetoimasia.Terrain.Shape (ShapeId (ShapeId))"], [])
  , ("Turns", ["import Hetoimasia.Terrain.Shape (Turns (Turns))"], [])
  , ("Ray", ["import Hetoimasia.Terrain.Geometry (Ray (Ray))"], [])
  , ("Solid", ["import Hetoimasia.Terrain.Geometry (Solid (Solid))"], [])
  ]

-- | A value forged by applying a private constructor the client never imported.
forged ∷ [(String, [String], [String])]
forged =
  [ ("AxisCoord", ["import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord (..))"], ["outOfRange :: TileCoord", "outOfRange = TileCoord (AxisCoord 4611686018427387904) (AxisCoord 0) (AxisCoord 0)"])
  , ("ShapeId", ["import Hetoimasia.Terrain.Shape (ShapeId)"], ["unsupported :: ShapeId", "unsupported = ShapeId 99"])
  , ("Turns", ["import Hetoimasia.Terrain.Shape (Turns)"], ["unnormalized :: Turns", "unnormalized = Turns 7"])
  , ("Ray", ["import Hetoimasia.Terrain.Geometry (Ray, V3 (..))"], ["noDirection :: Ray", "noDirection = Ray (V3 0 0 0) (V3 0 0 0)"])
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Hetoimasia.Terrain.Coordinate"
    , "import Hetoimasia.Terrain.Geometry"
    , "import Hetoimasia.Terrain.Shape"
    , ""
    , "main :: IO ()"
    , "main = do"
    , "  print (fmap axisValue (axisFromInteger 4611686018427387903))"
    , "  print (axisFromInteger 4611686018427387904)"
    , "  print (fmap shapeIdValue (mkShapeId 15))"
    , "  print (mkShapeId 16)"
    , "  case tileCoord (-1) 0 (-33) of"
    , "    Left e -> print e"
    , "    Right t -> let (RegionCoord rx _ rz, l) = decomposeTile t in print (rx, rz, localX l, localZ l)"
    , "  case mkShapeId 3 of"
    , "    Left e -> print e"
    , "    Right s -> do"
    , "      let solid = shapeSolid s"
    , "      print (length (solidFaces solid))"
    , "      print (classifyPoint solid (V3 (1/4) (3/4) (1/4)))"
    , "      print (shapeName s, shapeName (rotateShape (turns 1) s))"
    , "      print (fmap (fmap hitParameter . castRay solid) (mkRay (V3 (1/4) (3/4) 2) (V3 0 0 (-1))))"
    ]

supportedOutput ∷ [String]
supportedOutput =
  [ "Right 4611686018427387903"
  , "Left (AxisOutOfRange 4611686018427387904)"
  , "Right 15"
  , "Left (UnsupportedShapeId 16)"
  , "(-1,-2,15,31)"
  , "5"
  , "Interior"
  , "(\"NE\",\"ES\")"
  , "Right (Just (5 % 4))"
  ]
