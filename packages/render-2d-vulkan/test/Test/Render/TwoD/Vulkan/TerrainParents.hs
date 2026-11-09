-- | TRA-17 requirement 6 over the real recorder (device-free, over the headless native layer): the terrain's two
-- atlas parents are registered through the texture registry, the terrain adapter's own records name them, and a frame
-- is RECORDED from those records. What holds the parents is read from the recording and from the adopted revision, never
-- set by hand:
--
-- * the adopted revision made of the adapted records holds both parents once each, however many quads draw from them;
-- * a recorded, uncompleted batch holds a table version that maps both slots, so releasing the original ownership while
--   it is pending frees nothing, and the slots free only once the batch completes;
-- * the request to release the original ownership waits for the adopted revision's last recording;
-- * a snapshot naming a REQUIRED parent whose release was requested is refused whole, holds nothing new, and leaves the
--   previously adopted revision holding both parents and drawing as before.
--
-- The terrain adapter allocates no texture and holds no lease; this is the contract its handles live under. The
-- expected values are written here from the recorder's rules, never read from the code under test.
module Test.Render.TwoD.Vulkan.TerrainParents (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))
import Hetoimasia.GPU.Vulkan.Native.TextureTable (LookupEntry (..), TableView (..), readTable)
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (handleIndex)
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Textures (MarkPolicy (..), releaseTextureNow)
import Hetoimasia.Render.TwoD.Vulkan.Window
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Terrain.Render2D.CellPick (CellPickError, CellPickQuery (..), CellPickResult (..), pickCells)
import Hetoimasia.Terrain.Render2D.Cells (CellPlan, cellPlanIdentity)
import Hetoimasia.Terrain.Render2D.Evidence (sceneTarget, scenePlan)
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightSettings)
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec
import Test.Render.TwoD.Vulkan.Environment
import Test.Render.TwoD.Vulkan.Materials.Layouts (terrainShapedMaterial)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "a terrain's two atlas parents through the recorder" $ do
  it "holds both parents, once each, with the adopted revision made of the adapted records, and releases them only after it" $
    withTerrain $ \env colour normal made → do
      revision ← publishTerrain env 1 made >>= either (fail . show) pure
      adopt env 1 revision
      (,) <$> textureHolds (envAdapter env) colour <*> textureHolds (envAdapter env) normal >>= (`shouldBe` (1, 1))
      -- The original ownership's release is requested and the barrier met, but the adopted revision's records still show both.
      release2DTexture (envAdapter env) colour >>= (`shouldBe` Right ())
      release2DTexture (envAdapter env) normal >>= (`shouldBe` Right ())
      _ ← runQueued env
      (,) <$> resolves env colour <*> resolves env normal >>= (`shouldBe` (True, True))
      -- A revision without them is adopted and the first released: only now are they released.
      without ← publishOk env 1 []
      adopt env 1 without
      releaseRevision env 1 revision
      _ ← runQueued env
      (,) <$> resolves env colour <*> resolves env normal >>= (`shouldBe` (False, False))
      (,) <$> textureHolds (envAdapter env) colour <*> textureHolds (envAdapter env) normal >>= (`shouldBe` (0, 0))

  it "keeps both slots mapped while a batch recorded from the adapted records is incomplete, after the original ownership is released, and frees them when it completes" $
    withTerrain $ \env colour normal made → do
      (colourSlot, normalSlot) ← (,) <$> slotOf env colour <*> slotOf env normal
      let picksBefore = picksOf made
      picksBefore `shouldSatisfy` any (\case Right (CellPickHit _) → True; _ → False)
      frame ← frameOf env made
      Render.prepareSnapshot (builders (envRig env)) (envRenderer env) frame >>= \case
        Left refusal → expectationFailure (show refusal)
        Right recording →
          framelessOnce (envRig env) $ \recorder → do
            recording recorder >>= (`shouldBe` Right ())
            -- Recorded and not completed: the batch holds a table version that maps both slots. The original
            -- ownership is released while it is pending: no longer resolvable, still mapped.
            releaseTextureNow (builders (envRig env)) (envTextures env) colour >>= (`shouldBe` Right ())
            releaseTextureNow (builders (envRig env)) (envTextures env) normal >>= (`shouldBe` Right ())
            (,) <$> resolves env colour <*> resolves env normal >>= (`shouldBe` (False, False))
            mapped ← mappedSlots env
            mapped `shouldSatisfy` Set.member colourSlot
            mapped `shouldSatisfy` Set.member normalSlot
            -- The CPU coverage answers the same while the batch is pending, with both parents' ownership released.
            picksOf made `shouldBe` picksBefore
      -- Submitted, not completed: the batch's version still maps them, and neither slot is free to reuse.
      afterSubmit ← mappedSlots env
      afterSubmit `shouldSatisfy` Set.member colourSlot
      afterSubmit `shouldSatisfy` Set.member normalSlot
      -- The batch completes: now, and only now, both slots free.
      settleUploads (envRig env)
      refreshTable (envRig env)
      afterCompletion ← mappedSlots env
      afterCompletion `shouldSatisfy` (not . Set.member colourSlot)
      afterCompletion `shouldSatisfy` (not . Set.member normalSlot)
      -- And the same once it has completed: the coverage is the adaptation's, not the device's.
      picksOf made `shouldBe` picksBefore

  it "refuses a snapshot whose records name a required parent whose release was requested, whole, holding nothing new and leaving the prior revision holding both" $
    withTerrain $ \env colour normal made → do
      first ← publishTerrain env 1 made >>= either (fail . show) pure
      adopt env 1 first
      (,) <$> textureHolds (envAdapter env) colour <*> textureHolds (envAdapter env) normal >>= (`shouldBe` (1, 1))
      -- The required normal parent's release is requested: a second acquisition naming it fails whole.
      release2DTexture (envAdapter env) normal >>= (`shouldBe` Right ())
      second ← publishTerrain env 1 made
      second `shouldBe` Left (TextureReleasedInSnapshot normal)
      -- Nothing partial: the colour parent, which the refused snapshot also named, holds exactly what the first revision gave it.
      (,) <$> textureHolds (envAdapter env) colour <*> textureHolds (envAdapter env) normal >>= (`shouldBe` (1, 1))
      -- The prior usable description is unchanged: its revision still draws from both parents.
      frame ← frameOf env made
      Render.prepareSnapshot (builders (envRig env)) (envRenderer env) frame >>= \case
        Left refusal → expectationFailure (show refusal)
        Right recording → framelessOnce (envRig env) $ \recorder → recording recorder >>= (`shouldBe` Right ())
      -- The release was only requested and the adopted revision holds the normal parent: both still resolve for it.
      (,) <$> resolves env colour <*> resolves env normal >>= (`shouldBe` (True, True))
      (,) <$> textureHolds (envAdapter env) colour <*> textureHolds (envAdapter env) normal >>= (`shouldBe` (1, 1))
  where
    publishTerrain env window made = publish2DSnapshot (envAdapter env) window (Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [madeView made]])
    frameOf env made = do
      let (w, h) = madeSize made
      image ← target (envRig env) Rgba8Linear w h
      depth ← depthTarget (envRig env) Depth32Float w h
      case validateSnapshot (Snapshot [Pass (OffscreenTarget (targetRef 2 1)) (ClearColour 0 0 0 1) [madeView made]]) of
        Left refused → fail ("the snapshot was refused: " <> show refused)
        Right valid →
          pure
            ( FrameInput
                valid
                noCutoutMarks
                (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear w h) (Just (DepthBinding depth Depth32Float))))
                Nothing
                Nothing
                (const Nothing)
                Set.empty
            )

-- | The terrain adapter's own assembly: the view of a plan adapted over the registered parents.
data Made = Made
  { madeView ∷ !View
  , madeSize ∷ !(Word32, Word32)
  , madePlan ∷ !CellPlan
  }

-- | An environment with the two parents registered through the real registry (the colour atlas first), the terrain
-- material registered, and the adaptation of a real plan over those handles.
withTerrain ∷ (Env → Api.TextureHandle → Api.TextureHandle → Made → IO a) → IO a
withTerrain action = withEnv [1] $ \env → do
  style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
  colour ← registered env 1 True DefaultMark
  normal ← registered env 2 True DefaultMark
  material ← Render.registerMaterial (envRenderer env) terrainShapedMaterial
  colourParent ← either (fail . show) pure (bindColourParent (styleColour style) colour)
  normalParent ← either (fail . show) pure (bindDataParent (styleNormal style) normal)
  let textures = packedTextures colourParent normalParent
      assets = styleAssets style
      scene = rampsCorners FaceSouth
  plan ← either (fail . show) pure (scenePlan assets scene)
  adapted ← either (fail . describeMaterialRefusal) pure (adaptCells textures defaultLightSettings assets plan)
  let instances = [adaptedInstance material adapted quad | quad ← adaptedQuads adapted]
  view ← either (fail . describeMaterialRefusal) pure (terrainView plan adapted [(material, adaptedMaterialData adapted)] [WorldLayer DepthEnabled instances])
  action env colour normal (Made view (fromIntegral (fst (sceneTarget scene)), fromIntegral (snd (sceneTarget scene))) plan)

-- | What the CPU coverage answers for the plan, at a lattice of pixel centres: the picker reads the plan's own coverage
-- planes, which the adaptation holds by reference and no GPU completion can change.
picksOf ∷ Made → [Either CellPickError CellPickResult]
picksOf made =
  let (w, h) = madeSize made
      plan = madePlan made
   in [ pickCells plan (CellPickQuery (cellPlanIdentity plan) (V2 (fromIntegral x + 0.5) (fromIntegral y + 0.5)))
      | y ← [3, 11 .. fromIntegral h - 1 ∷ Int]
      , x ← [5, 13 .. fromIntegral w - 1 ∷ Int]
      ]

-- | The slot a registered handle maps to.
slotOf ∷ Env → Api.TextureHandle → IO Word32
slotOf env handle =
  atomically (readTable (rigRecording (envRig env))) >>= \case
    Just view | Just entry ← Map.lookup (handleIndex handle) (tableViewMapping view) → pure (entrySlot entry)
    _ → fail "the handle is not mapped"

-- | The slots a live table version maps: the current one and every one a batch holds.
mappedSlots ∷ Env → IO (Set.Set Word32)
mappedSlots env = maybe Set.empty tableViewMapped <$> atomically (readTable (rigRecording (envRig env)))
