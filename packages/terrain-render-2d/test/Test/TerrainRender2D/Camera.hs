-- | Camera follow, manual slices, zoom, rotation and jump transitions, over
-- small authored terrain with hand-stated levels.
module Test.TerrainRender2D.Camera (spec, variedSource, variedFacts) where

import Hetoimasia.Terrain.Cell (ZRange, mkZRange)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), RemoveOutcome (..), emptyChanges, removeCell)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisMaxValue, axisValue)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Fixtures

-- | Stone below level 1 everywhere, with authored differences by column:
-- (1,0) rises to level 4, (2,0) to level 2, (3,0) has a hole from -5 up so its
-- highest solid cell is -6, and (4,0) is air throughout.
variedSource ∷ Source
variedSource =
  source
    SourceSpec
      { specMaterials = ["stone", "soil"]
      , specLayers = [LayerSpec Nothing (Just 1) "stone" 0]
      , specPatches =
          [ PatchSpec 1 0 1 5 (SpecSolid "soil" 0)
          , PatchSpec 2 0 1 3 (SpecSolid "soil" 0)
          , PatchSpec 3 0 (-5) 1 SpecAir
          , PatchSpec 4 0 (-4611686018427387904) 1 SpecAir
          ]
      }

variedFacts ∷ TerrainFacts
variedFacts = factsOf variedSource

cfg ∷ CameraConfig
cfg = defaultCameraConfig

step ∷ Command → TerrainFacts → CameraState → Step
step command facts camera = either (\e → error (show e)) id (applyCommand cfg facts command camera)

camera' ∷ Command → TerrainFacts → CameraState → CameraState
camera' command facts = stepCamera . step command facts

start ∷ CameraState
start = followCamera variedFacts 0 0

level ∷ AxisCoord → Integer
level = toInteger . axisValue

zr ∷ Integer → Integer → ZRange
zr lo hi = either (\e → error (show e)) id (mkZRange lo hi)

spec ∷ Spec
spec = describe "Camera" $ do
  describe "follow mode" $ do
    it "starts following with the default zoom, facing South and the configured range" $ do
      level (camClip start) `shouldBe` 25
      (camMode start, camZoom start, camFacing start) `shouldBe` (Following, 1, FaceSouth)
      (ccZoomMin cfg, ccZoomMax cfg, ccZoomDefault cfg, ccHeadroom cfg) `shouldBe` (0.125, 8, 1, 25)
      newCamera cfg {ccZoomMin = 0} (axis 0) (axis 0) (axis 0) `shouldBe` Left InvalidConfig
      newCamera cfg {ccZoomDefault = 9} (axis 0) (axis 0) (axis 0) `shouldBe` Left InvalidConfig
    it "adopts the highest solid cell of the anchor column plus 25 levels of headroom" $ do
      (camSurface start, level (camClip start), camRef start) `shouldBe` (Just (axis 0), 25, 1)
      let at1 = camera' (Pan 1 0) variedFacts start
          at2 = camera' (Pan 1 0) variedFacts at1
          at3 = camera' (Pan 1 0) variedFacts at2
      (camSurface at1, level (camClip at1), camRef at1) `shouldBe` (Just (axis 4), 29, 5)
      (camSurface at2, level (camClip at2), camRef at2) `shouldBe` (Just (axis 2), 27, 3)
      -- A hole from -5 up leaves the highest solid cell at -6.
      (camSurface at3, level (camClip at3), camRef at3) `shouldBe` (Just (axis (-6)), 19, -5)
    it "separates the headroom from the surface: it is configurable" $ do
      let c = cfg {ccHeadroom = 7}
          s = case newCamera c (axis 1) (axis 0) (axis 0) of
            Right camera → either (error . show) stepCamera (refollow c variedFacts camera)
            Left e → error (show e)
      level (camClip s) `shouldBe` 11
    it "follows an edited surface: a removed top cell lowers the followed level" $ do
      let removal = either (error . show) removeResult (removeCell (ChangeLimits 8) variedSource (tileAt 1 0 4) emptyChanges)
          edited = factsWith variedSource removal AllKnown
          s = followCamera edited 1 0
      (camSurface s, level (camClip s), camRef s) `shouldBe` (Just (axis 3), 28, 4)
    it "preserves the slice and reports a known empty column as absent" $ do
      let at3 = camera' (Pan 3 0) variedFacts start
          Step moved followed _ = step (Pan 1 0) variedFacts at3
      followed `shouldBe` FollowColumnEmpty
      camSurface moved `shouldBe` Nothing
      (level (camClip moved), camRef moved) `shouldBe` (level (camClip at3), camRef at3)
    it "keeps the current slice over an unloaded anchor column, reports the demand and adopts the surface only when supplied" $ do
      let partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          before = followCamera partial 0 0
          Step moved followed _ = step (Pan 16 0) partial before
      followed `shouldBe` FollowUnavailable (demandFrom [(ChunkKey 1 0, 0, 1)])
      (level (camClip moved), camRef moved, camSurface moved) `shouldBe` (level (camClip before), camRef before, camSurface before)
      -- The same column is not "empty": with the facts supplied it is adopted.
      let Step adopted outcome _ = ok (refollow cfg variedFacts moved)
      outcome `shouldBe` FollowAdopted (axis 0)
      level (camClip adopted) `shouldBe` 25
    it "does not report a surface whose level is not ready, even in a published chunk" $ do
      let notReady = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) (-50)])])
      surfaceAt notReady (column 0 0) `shouldBe` SurfaceUnavailable (ChunkKey 0 0) (Just (axis 0))
      surfaceAt notReady (column 4 0) `shouldBe` SurfaceAbsent
      surfaceAt variedFacts (column 4 0) `shouldBe` SurfaceAbsent

  describe "manual slices" $ do
    it "enters manual mode at the exact level, with no headroom, and keeps the reference" $ do
      let m = camera' (SelectSlice (axis 3)) variedFacts start
      (camMode m, level (camClip m), camRef m) `shouldBe` (Manual (axis 3), 3, camRef start)
    it "keeps the exact depth through pan, zoom and rotation" $ do
      let m = camera' (SelectSlice (axis 3)) variedFacts start
          moved = foldl (flip (\c → camera' c variedFacts)) m [Pan 2 0, ZoomBy 4, RotateBy 1, Pan (-5.5) 3.25, SetZoom 0.5, SetFacing FaceWest]
      (camMode moved, level (camClip moved), camRef moved) `shouldBe` (Manual (axis 3), 3, camRef m)
      stepFollow (step (Pan 1 0) variedFacts m) `shouldBe` FollowNotApplied
    it "adds whole levels to the effective clip level for a slice delta" $ do
      level (camClip (camera' (SliceBy (-3)) variedFacts start)) `shouldBe` 22
      camMode (camera' (SliceBy 2) variedFacts start) `shouldBe` Manual (axis 27)
      let m = camera' (SelectSlice (axis 3)) variedFacts start
      level (camClip (camera' (SliceBy 4) variedFacts m)) `shouldBe` 7
      let top = camera' (SelectSlice (axis axisMaxValue)) variedFacts start
      applyCommand cfg variedFacts (SliceBy 1) top `shouldBe` Left SliceOutOfRange
      applyCommand cfg variedFacts (SliceBy 0) top `shouldSatisfy` isRight

  describe "zoom and rotation" $ do
    it "clamps zoom to the configured finite range" $ do
      camZoom (camera' (ZoomBy 1000) variedFacts start) `shouldBe` 8
      camZoom (camera' (SetZoom 0.001) variedFacts start) `shouldBe` 0.125
      camZoom (camera' (ZoomBy 0.5) variedFacts start) `shouldBe` 0.5
    it "refuses a non-finite or non-positive zoom, changing nothing" $ do
      mapM_
        (\z → applyCommand cfg variedFacts (SetZoom z) start `shouldBe` Left NonFiniteInput)
        [0 / 0, 1 / 0, -1 / 0, 0, -2]
      applyCommand cfg variedFacts (ZoomBy (0 / 0)) start `shouldBe` Left NonFiniteInput
    it "turns the facing and leaves the world anchor alone" $ do
      let r = camera' (RotateBy 1) variedFacts start
      camFacing r `shouldBe` FaceEast
      (camAnchorX r, camAnchorY r, camFrac r, camRef r) `shouldBe` (camAnchorX start, camAnchorY start, camFrac start, camRef start)
      camFacing (camera' (RotateBy 4) variedFacts start) `shouldBe` FaceSouth
      camFacing (camera' (RotateBy (-1)) variedFacts start) `shouldBe` FaceWest
      camFacing (camera' (RotateBy 2) variedFacts start) `shouldBe` FaceNorth

  describe "panning" $ do
    it "carries whole tiles into the exact anchor and keeps the fraction" $ do
      let p = camera' (Pan 0.75 0) variedFacts start
      (axisValue (camAnchorX p), camFrac p) `shouldBe` (1, (1 / 4, 1 / 2))
      let q = camera' (Pan (-0.75) (-0.5)) variedFacts start
      -- Half a tile back from the centre lands exactly on the tile's edge: y stays.
      (axisValue (camAnchorX q), axisValue (camAnchorY q), camFrac q) `shouldBe` (-1, 0, (3 / 4, 0))
    it "refuses a pan outside the supported range and a non-finite pan, changing nothing" $ do
      let farCamera = either (error . show) id (newCamera cfg (axis axisMaxValue) (axis 0) (axis 0))
      applyCommand cfg variedFacts (Pan 1 0) farCamera `shouldBe` Left PanOutOfRange
      applyCommand cfg variedFacts (Pan 0 (0 / 0)) start `shouldBe` Left NonFiniteInput
      applyCommand cfg variedFacts (Pan 1e300 0) start `shouldBe` Left PanOutOfRange
    it "keeps the integer address exact at the supported extreme" $ do
      let farCamera = either (error . show) id (newCamera cfg (axis (axisMaxValue - 1)) (axis 0) (axis 0))
          p = camera' (Pan 0.25 0) variedFacts farCamera
      (level (camAnchorX p), camFrac p) `shouldBe` (axisMaxValue - 1, (3 / 4, 1 / 2))
      level (camAnchorX (camera' (Pan 0.5 0) variedFacts farCamera)) `shouldBe` axisMaxValue

  describe "jumps" $ do
    let manual = camera' (RotateBy 1) variedFacts (camera' (SetZoom 2) variedFacts (camera' (SelectSlice (axis 3)) variedFacts start))
    it "restores following at the destination when no Z is given, keeping zoom and facing" $ do
      let Step j followed event = step (Jump (JumpTarget (axis 2) (axis 0) Nothing)) variedFacts manual
      (camMode j, level (camClip j), camRef j, camSurface j) `shouldBe` (Following, 27, 3, Just (axis 2))
      (camZoom j, camFacing j, camPending j) `shouldBe` (2, FaceEast, Nothing)
      (level (camAnchorX j), camFrac j) `shouldBe` (2, (1 / 2, 1 / 2))
      followed `shouldBe` FollowAdopted (axis 2)
      event `shouldBe` JumpApplied (JumpId 1)
    it "enters manual mode at the given depth, keeping zoom and facing" $ do
      let j = camera' (Jump (JumpTarget (axis 1) (axis 0) (Just (axis 7)))) variedFacts start
      (camMode j, level (camClip j), camRef j) `shouldBe` (Manual (axis 7), 7, 8)
      (level (camAnchorX j), camZoom j, camFacing j) `shouldBe` (1, 1, FaceSouth)
    it "keeps the last coherent view while the destination is pending, and applies it when completed" $ do
      let partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          Step waiting _ event = step (Jump (JumpTarget (axis 32) (axis 0) Nothing)) partial start
      event `shouldSatisfy` isPending
      (camAnchorX waiting, camClip waiting, camRef waiting, camMode waiting) `shouldBe` (camAnchorX start, camClip start, camRef start, camMode start)
      camPending waiting `shouldBe` Just (PendingJump (JumpId 1) (JumpTarget (axis 32) (axis 0) Nothing))
      -- Still not ready: still pending.
      stepJump (ok (completeJump cfg partial (JumpId 1) waiting)) `shouldSatisfy` isPending
      let Step landed _ done = ok (completeJump cfg variedFacts (JumpId 1) waiting)
      done `shouldBe` JumpApplied (JumpId 1)
      (level (camAnchorX landed), camPending landed) `shouldBe` (32, Nothing)
    it "refuses a late completion of a cancelled jump" $ do
      let partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          waiting = stepCamera (step (Jump (JumpTarget (axis 32) (axis 0) Nothing)) partial start)
          cancelled = cancelJump (JumpId 1) waiting
          Step after _ event = ok (completeJump cfg variedFacts (JumpId 1) cancelled)
      camPending cancelled `shouldBe` Nothing
      event `shouldBe` JumpStale (JumpId 1)
      after `shouldBe` cancelled
    it "refuses a late completion of a superseded jump and applies the newer one" $ do
      let partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          first = stepCamera (step (Jump (JumpTarget (axis 32) (axis 0) Nothing)) partial start)
          second = stepCamera (step (Jump (JumpTarget (axis 48) (axis 0) (Just (axis 5)))) partial first)
          Step unmoved _ stale = ok (completeJump cfg variedFacts (JumpId 1) second)
      stale `shouldBe` JumpStale (JumpId 1)
      unmoved `shouldBe` second
      let Step landed _ done = ok (completeJump cfg variedFacts (JumpId 2) second)
      done `shouldBe` JumpApplied (JumpId 2)
      (level (camAnchorX landed), camMode landed) `shouldBe` (48, Manual (axis 5))
      -- And once the newer jump has landed the older identity still cannot move it.
      stepCamera (ok (completeJump cfg variedFacts (JumpId 1) landed)) `shouldBe` landed
    it "waits on a with-Z jump whose destination level is not ready" $ do
      let partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          Step waiting _ event = step (Jump (JumpTarget (axis 0) (axis 0) (Just (axis 500)))) partial start
      event `shouldBe` JumpPending (JumpId 1) (demandFrom [(ChunkKey 0 0, 500, 501)])
      camMode waiting `shouldBe` camMode start

  describe "configuration" $ do
    it "refuses an invalid configuration in every transition, keeping the camera" $ do
      let bad = cfg {ccHeadroom = -1}
          partial = factsWith variedSource emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-100) 100])])
          waiting = stepCamera (step (Jump (JumpTarget (axis 32) (axis 0) Nothing)) partial start)
      applyCommand bad variedFacts (Pan 1 0) start `shouldBe` Left InvalidConfig
      refollow bad variedFacts start `shouldBe` Left InvalidConfig
      completeJump bad variedFacts (JumpId 1) waiting `shouldBe` Left InvalidConfig
      -- The pending jump is untouched and still completes under a valid configuration.
      camPending waiting `shouldSatisfy` (/= Nothing)
      stepJump (ok (completeJump cfg variedFacts (JumpId 1) waiting)) `shouldBe` JumpApplied (JumpId 1)

  describe "revisions" $ do
    it "advances the camera revision on a change and not on a no-op" $ do
      camRevision (camera' (Pan 1 0) variedFacts start) `shouldSatisfy` (> camRevision start)
      camera' (ZoomBy 1) variedFacts start `shouldBe` start
      camera' (SetFacing FaceSouth) variedFacts start `shouldBe` start

ok ∷ Either CameraError Step → Step
ok = either (\e → error (show e)) id

isRight ∷ Either a b → Bool
isRight (Right _) = True
isRight _ = False

isPending ∷ JumpEvent → Bool
isPending (JumpPending _ _) = True
isPending _ = False
