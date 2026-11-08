-- | Examples proving what the terrain package's boundary exposes to a client.
--
-- A suite inside the package shares its module environment and can reach every
-- constructor, so it cannot observe the boundary. These examples compile
-- separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@ and @hetoimasia-terrain@ and
-- hiding everything else.
--
-- Three clients must be accepted, linked and run: one uses the public coordinate,
-- shape and geometry interfaces end to end, one uses the opening interface (the
-- exact portals of a cell and the connections between neighbors, TRA-13), and the
-- other validates limits and drives the residency model, which is both the
-- environment control and the evidence that the supported operations stay usable.
-- Every
-- other client must be refused, each for the specific diagnostic that names its
-- cause, so a missing package or an absent compiler can never pass for the
-- boundary holding:
--
-- * the constructor of a checked value (an axis coordinate, a local offset, a
--   shape identity, a rotation count, a ray, a solid, an opening region, a cell's
--   openings, a component, a portal, a placed portal, a component reference, a
--   portal connection, validated limits, the residency model or a coverage)
--   cannot be named, so a
--   client cannot build an out-of-range coordinate, an unsupported identity, an
--   unnormalized turn, a ray with no direction or a forged solid: @GHC-10237@
--   for an import, and @GHC-01928@ (an illegal term-level use of the type
--   constructor) for a use of the constructor in an expression;
-- * an exported accessor of a checked value (a solid or a ray) is a function,
--   never a field label, and the fields of validated limits and of the model are
--   not exported at all, so record-update syntax cannot rewrite one;
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
  forM_ accepted $ \(label, source, expected) →
   it label $
    withClient "Main.hs" source $ \compile → do
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
      lines out `shouldBe` expected

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

  forM_ recordUpdates $ \(name, imports, source) →
    it ("rejects a client that rewrites " <> name <> " with record-update syntax") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome ← compile Typecheck
        -- Every accessor is a plain function, not a field label, so the update
        -- is refused for naming something that is not a record field.
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"
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

-- | The clients that must be accepted, linked and run, with their output.
accepted ∷ [(String, String, [String])]
accepted =
  [ ("accepts and runs a client using the public coordinate, shape and geometry interfaces", supportedClient, supportedOutput)
  , ("accepts and runs a client using the public opening interface: portals, components and connections", openingClient, openingOutput)
  , ("accepts and runs a client that validates limits and drives the residency model through its public interface", residencyClient, residencyOutput)
  ]

-- | The modules hidden inside the main library.
hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Internal.Cell"
  , "Hetoimasia.Terrain.Internal.Changes"
  , "Hetoimasia.Terrain.Internal.Column"
  , "Hetoimasia.Terrain.Internal.Coordinate"
  , "Hetoimasia.Terrain.Internal.Interval"
  , "Hetoimasia.Terrain.Internal.Packed"
  , "Hetoimasia.Terrain.Internal.Polygon"
  , "Hetoimasia.Terrain.Internal.Polytope"
  , "Hetoimasia.Terrain.Internal.Residency.Coverage"
  , "Hetoimasia.Terrain.Internal.Residency.Limits"
  , "Hetoimasia.Terrain.Internal.Residency.Model"
  , "Hetoimasia.Terrain.Internal.Shape"
  , "Hetoimasia.Terrain.Internal.Source"
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
  , ("Opening", ["import Hetoimasia.Terrain.Opening (Opening (Opening))"], [])
  , ("CellOpenings", ["import Hetoimasia.Terrain.Opening (CellOpenings (CellOpenings))"], [])
  , ("Component", ["import Hetoimasia.Terrain.Opening (Component (Component))"], [])
  , ("Portal", ["import Hetoimasia.Terrain.Opening (Portal (Portal))"], [])
  , ("PlacedPortal", ["import Hetoimasia.Terrain.Opening (PlacedPortal (PlacedPortal))"], [])
  , ("ComponentRef", ["import Hetoimasia.Terrain.Opening (ComponentRef (ComponentRef))"], [])
  , ("PortalConnection", ["import Hetoimasia.Terrain.Opening (PortalConnection (PortalConnection))"], [])
  , ("MaterialId", ["import Hetoimasia.Terrain.Cell (MaterialId (MaterialId))"], [])
  , ("ZRange", ["import Hetoimasia.Terrain.Cell (ZRange (ZRange))"], [])
  , ("PackedCell", ["import Hetoimasia.Terrain.Palette (PackedCell (PackedCell))"], [])
  , ("Palette", ["import Hetoimasia.Terrain.Palette (Palette (Palette))"], [])
  , ("Source", ["import Hetoimasia.Terrain.Source (Source (Source))"], [])
  , ("Changes", ["import Hetoimasia.Terrain.Changes (Changes (Changes))"], [])
  , ("Segment", ["import Hetoimasia.Terrain.Segment (Segment (Segment))"], [])
  , ("Resident", ["import Hetoimasia.Terrain.Resident (Resident (Resident))"], [])
  , ("Limits", ["import Hetoimasia.Terrain.Residency (Limits (Limits))"], [])
  , ("Model", ["import Hetoimasia.Terrain.Residency (Model (Model))"], [])
  , ("Coverage", ["import Hetoimasia.Terrain.Residency (Coverage (Coverage))"], [])
  ]

-- | A value forged by applying a private constructor the client never imported.
forged ∷ [(String, [String], [String])]
forged =
  [ ("AxisCoord", ["import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord (..))"], ["outOfRange :: TileCoord", "outOfRange = TileCoord (AxisCoord 4611686018427387904) (AxisCoord 0) (AxisCoord 0)"])
  , ("ShapeId", ["import Hetoimasia.Terrain.Shape (ShapeId)"], ["unsupported :: ShapeId", "unsupported = ShapeId 99"])
  , ("Turns", ["import Hetoimasia.Terrain.Shape (Turns)"], ["unnormalized :: Turns", "unnormalized = Turns 7"])
  , ("Ray", ["import Hetoimasia.Terrain.Geometry (Ray, V3 (..))"], ["noDirection :: Ray", "noDirection = Ray (V3 0 0 0) (V3 0 0 0)"])
  , ("MaterialId", ["import Hetoimasia.Terrain.Cell (MaterialId)"], ["unchecked :: MaterialId", "unchecked = MaterialId \"\""])
  , ("ZRange", ["import Hetoimasia.Terrain.Cell (ZRange)"], ["inverted :: ZRange", "inverted = ZRange 5 5"])
  , ("PackedCell", ["import Hetoimasia.Terrain.Palette (PackedCell)"], ["airWithShape :: PackedCell", "airWithShape = PackedCell 5"])
  , -- A region that claims an opening a shape does not have, an air cell that
    -- claims no component, and a connection that claims an overlap.
    ("Opening", ["import Hetoimasia.Terrain.Opening (Opening)"], ["wholeFace :: Opening", "wholeFace = Opening [[(0, 0), (1, 0), (1, 1), (0, 1)]]"])
  , ("CellOpenings", ["import Hetoimasia.Terrain.Opening (CellOpenings)"], ["sealed :: CellOpenings", "sealed = CellOpenings Nothing []"])
  , ("Component", ["import Hetoimasia.Terrain.Opening (Component)"], ["second :: Component", "second = Component 1 []"])
  , ("Portal", ["import Hetoimasia.Terrain.Opening (Portal)"], ["unowned :: Portal", "unowned = Portal undefined 9 undefined"])
  , ("PlacedPortal", ["import Hetoimasia.Terrain.Opening (PlacedPortal)"], ["elsewhere :: PlacedPortal", "elsewhere = PlacedPortal undefined undefined"])
  , ("ComponentRef", ["import Hetoimasia.Terrain.Opening (ComponentRef)"], ["nowhere :: ComponentRef", "nowhere = ComponentRef undefined 3"])
  , ("PortalConnection", ["import Hetoimasia.Terrain.Opening (PortalConnection)"], ["overlap :: PortalConnection", "overlap = PortalConnection undefined undefined undefined 1 []"])
  , ("Source", ["import Hetoimasia.Terrain.Source (Source)"], ["unvalidated :: Source", "unvalidated = Source [] mempty mempty 0 0 0"])
  , ("Limits", ["import Hetoimasia.Terrain.Residency (Limits)"], ["zeroed :: Limits", "zeroed = Limits 0 0 0 0 0 0 0 0"])
  , ("Model", ["import Hetoimasia.Terrain.Residency (Model)"], ["empty :: Model", "empty = Model"])
  , ("Coverage", ["import Hetoimasia.Terrain.Residency (Coverage)"], ["everything :: Coverage", "everything = Coverage undefined"])
  ]

-- | A checked value rewritten through an exported accessor used as a field
-- label. Each accessor is a function, so none can be updated.
recordUpdates ∷ [(String, [String], [String])]
recordUpdates =
  [ ("solidPlanes", ["import Hetoimasia.Terrain.Geometry (Solid, solidPlanes)"], ["emptied :: Solid → Solid", "emptied s = s {solidPlanes = []}"])
  , ("solidFaces", ["import Hetoimasia.Terrain.Geometry (Solid, solidFaces)"], ["emptied :: Solid → Solid", "emptied s = s {solidFaces = []}"])
  , ("solidVertices", ["import Hetoimasia.Terrain.Geometry (Solid, solidVertices)"], ["emptied :: Solid → Solid", "emptied s = s {solidVertices = []}"])
  , ("solidShape", ["import Hetoimasia.Terrain.Geometry (Solid, solidShape)"], ["swapped :: Solid → Solid", "swapped s = s {solidShape = solidShape s}"])
  , -- Opening values are read through functions only: no field label rewrites an
    -- opening, a component, a portal or the area of a connection.
    ("portalOpening", ["import Hetoimasia.Terrain.Opening (Portal, portalOpening)"], ["widened :: Portal → Portal", "widened p = p {portalOpening = undefined}"])
  , ("componentPortals", ["import Hetoimasia.Terrain.Opening (Component, componentPortals)"], ["emptied :: Component → Component", "emptied c = c {componentPortals = []}"])
  , ("cellComponents", ["import Hetoimasia.Terrain.Opening (CellOpenings, cellComponents)"], ["emptied :: CellOpenings → CellOpenings", "emptied o = o {cellComponents = []}"])
  , ("connectionArea", ["import Hetoimasia.Terrain.Opening (PortalConnection, connectionArea)"], ["inflated :: PortalConnection → PortalConnection", "inflated c = c {connectionArea = 1}"])
  , ("placedTile", ["import Hetoimasia.Terrain.Opening (PlacedPortal, placedTile)"], ["moved :: PlacedPortal → PlacedPortal", "moved p = p {placedTile = undefined}"])
  , ("rayDirection", ["import Hetoimasia.Terrain.Geometry (Ray, V3 (..), rayDirection)"], ["noDirection :: Ray → Ray", "noDirection r = r {rayDirection = V3 0 0 0}"])
  , ("rayOrigin", ["import Hetoimasia.Terrain.Geometry (Ray, V3 (..), rayOrigin)"], ["moved :: Ray → Ray", "moved r = r {rayOrigin = V3 0 0 0}"])
  , -- A validated limit cannot be rewritten after validation: the fields of Limits
    -- are not exported at all, so the update names no field.
    ("lResident", ["import Hetoimasia.Terrain.Residency (Limits, defaultLimits)"], ["zeroed :: Limits", "zeroed = defaultLimits {lResident = 0}"])
  , ("lJobs", ["import Hetoimasia.Terrain.Residency (Limits, defaultLimits)"], ["unlimited :: Limits", "unlimited = defaultLimits {lJobs = 1000000}"])
  , ("mClock", ["import Hetoimasia.Terrain.Residency (Model, defaultLimits, newModel)"], ["rewound :: Model", "rewound = (newModel defaultLimits) {mClock = 0}"])
  , ("mTargets", ["import Hetoimasia.Terrain.Residency (Model, defaultLimits, newModel)"], ["forged :: Model", "forged = (newModel defaultLimits) {mTargets = undefined}"])
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Hetoimasia.Terrain.Cell"
    , "import Hetoimasia.Terrain.Changes"
    , "import Hetoimasia.Terrain.Coordinate"
    , "import Hetoimasia.Terrain.Geometry"
    , "import Hetoimasia.Terrain.Palette"
    , "import Hetoimasia.Terrain.Query"
    , "import Hetoimasia.Terrain.Resident"
    , "import Hetoimasia.Terrain.Segment"
    , "import Hetoimasia.Terrain.Shape"
    , "import Hetoimasia.Terrain.Source"
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
    , "  let definition = SourceSpec [\"soil\", \"stone\"] [LayerSpec Nothing (Just (-3)) \"stone\" 0, LayerSpec (Just (-3)) (Just 1) \"soil\" 5] []"
    , "  print (either show (const \"accepted\") (mkSource defaultSourceLimits definition {specMaterials = [\"a\", \"a\"]}))"
    , "  print (mkZRange 5 5)"
    , "  print (mkMaterialId \"\")"
    , "  case (mkSource defaultSourceLimits definition, tileCoord 0 0 (-1), mkColumn 0 0, mkZRange (-5) 3) of"
    , "    (Right source, Right t, Right column, Right range) -> do"
    , "      case cellAt source emptyChanges t of"
    , "        Solid m s -> print (materialIdString m, shapeIdValue s)"
    , "        Air -> putStrLn \"air\""
    , "      case removeCell (ChangeLimits 4) source t emptyChanges of"
    , "        Right out -> do"
    , "          print (removeChanged out)"
    , "          print (cellAt source (removeResult out) t == Air)"
    , "          print (fmap (map (\\r -> (zRangeLo (runRange r), zRangeHi (runRange r)))) (columnRuns defaultQueryLimits source (removeResult out) column range))"
    , "        Left e -> print e"
    , "      print (fmap (axisValue . occupiedLevel) (highestOccupied source emptyChanges column))"
    , "      case internSourceMaterials source emptyPalette of"
    , "        Right palette -> do"
    , "          print (paletteSize palette)"
    , "          case materialize 64 source emptyChanges palette emptyResident column range of"
    , "            Right (_, resident) -> print (map (\\s -> (segmentLength s, segmentPayloadBytes s)) (residentSegments resident column))"
    , "            Left e -> print e"
    , "        Left e -> print e"
    , "    _ -> putStrLn \"unexpected\""
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
  , "\"DuplicateMaterialId 1 \\\"a\\\"\""
  , "Left (EmptyInterval 5 5)"
  , "Left EmptyMaterialId"
  , "(\"soil\",5)"
  , "True"
  , "True"
  , "Right [(-5,-3),(-3,-1),(-1,0),(0,1),(1,3)]"
  , "Just 0"
  , "2"
  , "[(5,8),(3,6)]"
  ]

-- | A client that reads the exact openings of the catalog, connects neighbors only
-- through real shared-face openings and keeps the point and ray queries beside them,
-- all through the public interface.
openingClient ∷ String
openingClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Hetoimasia.Terrain.Coordinate"
    , "import Hetoimasia.Terrain.Geometry"
    , "import Hetoimasia.Terrain.Opening"
    , "import Hetoimasia.Terrain.Shape"
    , ""
    , "main :: IO ()"
    , "main = do"
    , "  let shape n = either (error . show) id (mkShapeId n)"
    , "      tile x y z = either (error . show) id (tileCoord x y z)"
    , "      faceArea ops face = sum [openingArea (portalOpening p) | p <- portalsOn face ops]"
    , "      areas a b = map connectionArea (connectCells (tile 0 0 0) a (tile 1 0 0) b)"
    , "  print (map (faceArea (shapeOpenings (shape 15))) cellFaces)"
    , "  print (length (cellComponents (shapeOpenings (shape 0))), length (cellComponents (shapeOpenings (shape 15))))"
    , "  print (areas (shapeOpenings (shape 1)) (shapeOpenings (shape 4)))"
    , "  print (areas (shapeOpenings (shape 1)) (shapeOpenings (shape 0)))"
    , "  print (map connectionArea (connectCells (tile 0 0 0) airOpenings (tile 1 1 0) airOpenings))"
    , "  print (classifyPoint (shapeSolid (shape 15)) (V3 (1/2) (1/2) (1/2)))"
    , "  print (fmap (fmap hitParameter . castRay (shapeSolid (shape 15))) (mkRay (V3 (1/2) (1/2) 2) (V3 0 0 (-1))))"
    , "  print (rotateOpenings (turns 4) (shapeOpenings (shape 1)) == shapeOpenings (shape 1))"
    , "  print (map componentIndex (cellComponents airOpenings))"
    ]

openingOutput ∷ [String]
openingOutput =
  [ "[1 % 1,1 % 1,1 % 1,1 % 1,1 % 1,0 % 1]"
  , "(0,1)"
  , "[1 % 4]"
  , "[]"
  , "[]"
  , "Boundary"
  , "Right (Just (3 % 2))"
  , "True"
  , "[0]"
  ]

-- | A client that validates limits (a zero or unrepresentable figure is refused,
-- never clamped) and drives the model only through its public functions.
residencyClient ∷ String
residencyClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Hetoimasia.Terrain.Coordinate (RegionCoord (..))"
    , "import Hetoimasia.Terrain.Residency"
    , ""
    , "main :: IO ()"
    , "main = do"
    , "  let spec0 = LimitsSpec 1000 192 2048 3 3 2 3 2 1 1 1 0 0"
    , "  putStrLn (either show (const \"valid\") (mkLimits spec0))"
    , "  putStrLn (either show (const \"valid\") (mkLimits spec0 {specLoadJobs = 0}))"
    , "  putStrLn (either show (const \"valid\") (mkLimits spec0 {specResidentBytes = limitCeiling + 1}))"
    , "  putStrLn (either show (const \"valid\") (mkLimits spec0 {specResidentBytes = 963}))"
    , "  case mkLimits spec0 of"
    , "    Left e -> print e"
    , "    Right limits -> do"
    , "      let (m1, r1) = step (newModel limits) (OpenArena (ArenaId 1) (Revision 0))"
    , "      putStrLn (either show (show . reportDecision) r1)"
    , "      case coverageBox 0 1 0 1 0 1 of"
    , "        Left e -> print e"
    , "        Right cov -> do"
    , "          let (m2, r2) = step m1 (SubmitQuery (RequestId 1) (ArenaId 1) (Revision 0) [RegionDemand (RegionCoord 0 0 0) cov])"
    , "          case r2 of"
    , "            Right rep -> case reportDecision rep of"
    , "              Accepted a -> print (map fst (admissionJobs a))"
    , "              other -> print other"
    , "            Left e -> print e"
    , "          let l = bankLedger m2 ResidentBank"
    , "          print (ledgerOccupied l, ledgerReserved l)"
    , "          let (m3, r3) = step m2 (SubmitQuery (RequestId 2) (ArenaId 1) (Revision 0) [])"
    , "          putStrLn (either show (const \"accepted\") r3)"
    , "          print (m3 == m2)"
    ]

residencyOutput ∷ [String]
residencyOutput =
  [ "valid"
  , "LimitNotPositive FieldLoadJobs 0"
  , "LimitUnrepresentable FieldResidentBytes 1099511627777"
  , "BankBelowMinimum ResidentBank 964 963"
  , "ArenaOpened"
  , "[JobId 0]"
  , "(0,400)"
  , "Invalid EmptyDemand"
  , "True"
  ]
