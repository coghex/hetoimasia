-- | The service end to end over the ordinary arrival host: open, attach, the
-- three reads, removal, and the authority rules.
module Test.TerrainRuntime.Basic (spec) where

import Hetoimasia.Terrain.Cell (Cell (..), zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Coordinate (axisFromInteger)
import Hetoimasia.Terrain.Query (Occupied (..), QueryError (..), Run (..))
import Hetoimasia.Terrain.Source (CellSpec (..), PatchSpec (..), SourceSpec (..))
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime
import Test.Hspec
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "The terrain service" $ do
  it "opens an arena, reads a cell, removes it and reads air at the next revision" $
    withService defaultConfig $ \svc → do
      client <- okOf (registerClient svc)
      lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
      atFirst <- okOf (cellAt svc lease (tile 3 4 5)) >>= await svc >>= expectSuccess
      cellRevision atFirst `shouldBe` Revision 0
      case cellValue atFirst of
        Solid {} → pure ()
        other → expectationFailure ("expected a solid cell, got " <> show other)
      removed <- okOf (removeAt svc lease (tile 3 4 5) Nothing) >>= await svc >>= expectSuccess
      removed `shouldBe` RemoveAnswer (cellIncarnation atFirst) (Revision 1) True
      atSecond <- okOf (cellAt svc lease (tile 3 4 5)) >>= await svc >>= expectSuccess
      cellRevision atSecond `shouldBe` Revision 1
      cellValue atSecond `shouldBe` Air
      -- A neighbour is untouched.
      neighbour <- okOf (cellAt svc lease (tile 3 4 6)) >>= await svc >>= expectSuccess
      neighbour `shouldBe` atFirst {cellValue = cellValue neighbour, cellRevision = Revision 1}
      inspectInvariants svc >>= (`shouldBe` [])
      inspectDefects svc >>= (`shouldBe` [])
      _ <- pure (ArenaId 0)
      pure ()

  it "answers a complete column, a surface, and an explicit absence, through edits" $
    withService defaultConfig $ \svc → do
      client <- okOf (registerClient svc)
      let definition =
            layered
              [(Just (-10), Just (-3), "stone", 0), (Just (-3), Just 40, "soil", 0)]
              [PatchSpec 5 5 (-100) 100 SpecAir]
      lease <- okOf (openArena svc client "columns" definition) >>= await svc >>= expectSuccess
      runs <- okOf (columnAt svc lease (column 0 0) (range (-5) 3)) >>= await svc >>= expectSuccess
      [(zRangeLo (runRange r), zRangeHi (runRange r), cellMaterial (runCell r)) | r <- columnAnswerRuns runs]
        `shouldBe` [(-5, -3, Just ("stone", 0)), (-3, 3, Just ("soil", 0))]
      top <- okOf (surfaceAt svc lease (column 0 0)) >>= await svc >>= expectSuccess
      fmap occupiedLevel (surfaceTop top) `shouldBe` Just (axis 39)
      -- Remove the top and a cell in the middle: the answers follow the edits.
      _ <- removeCell' svc lease (tile 0 0 39)
      _ <- removeCell' svc lease (tile 0 0 0)
      edited <- okOf (surfaceAt svc lease (column 0 0)) >>= await svc >>= expectSuccess
      (fmap occupiedLevel (surfaceTop edited), surfaceRevision edited) `shouldBe` (Just (axis 38), Revision 2)
      gapped <- okOf (columnAt svc lease (column 0 0) (range (-2) 3)) >>= await svc >>= expectSuccess
      [(zRangeLo (runRange r), zRangeHi (runRange r), cellMaterial (runCell r)) | r <- columnAnswerRuns gapped]
        `shouldBe` [(-2, 0, Just ("soil", 0)), (0, 1, Nothing), (1, 3, Just ("soil", 0))]
      columnRevision gapped `shouldBe` Revision 2
      -- An authored empty column explicitly answers absent; it is not unknown.
      empty <- okOf (surfaceAt svc lease (column 5 5)) >>= await svc >>= expectSuccess
      surfaceTop empty `shouldBe` Nothing
      settleChecks svc

  it "settles too_large for a column answer past the run limit and never truncates" $
    withService defaultConfig $ \svc → do
      client <- okOf (registerClient svc)
      let alternating = [PatchSpec 0 0 (2 * k) (2 * k + 1) SpecAir | k ← [0 .. 599]]
          definition = layered [(Just 0, Just 2000, "stone", 0)] alternating
      lease <- okOf (openArena svc client "busy" definition) >>= await svc >>= expectSuccess
      okOf (columnAt svc lease (column 0 0) (range 0 1200)) >>= await svc
        >>= (`shouldBe` Left (Failed (TooLarge (TooManyRuns 1024))))
      -- A range past the level limit is refused before admission.
      columnAt svc lease (column 0 0) (range 0 9000) >>= \r → fmap (const ()) (refusedWith r) `shouldBe` Just ()
      -- The narrower range is a complete answer.
      narrow <- okOf (columnAt svc lease (column 0 0) (range 0 1000)) >>= await svc >>= expectSuccess
      length (columnAnswerRuns narrow) `shouldBe` 1000
      settleChecks svc

  it "answers a definition error as a settled definition failure and creates nothing" $
    withService defaultConfig $ \svc → do
      client <- okOf (registerClient svc)
      let broken = soilOverStone {specMaterials = ["soil", "soil"]}
      outcome <- okOf (openArena svc client "bad" broken) >>= await svc
      case outcome of
        Left (Failed (Definition _)) → pure ()
        other → expectationFailure ("expected a definition failure, got " <> show other)
      -- The name was never claimed.
      lease <- okOf (openArena svc client "bad" soilOverStone) >>= await svc >>= expectSuccess
      _ <- readCell svc lease (tile 0 0 0)
      settleChecks svc
  where
    axis z = either (error . show) id (axisFromInteger z)
