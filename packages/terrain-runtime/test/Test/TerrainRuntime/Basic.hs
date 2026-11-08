-- | The service end to end over the ordinary arrival host: open, attach, the
-- three reads, removal, and the authority rules.
module Test.TerrainRuntime.Basic (spec) where

import Hetoimasia.Terrain.Cell (Cell (..))
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
