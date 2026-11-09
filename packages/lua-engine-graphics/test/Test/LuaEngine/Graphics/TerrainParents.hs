{-# LANGUAGE OverloadedStrings #-}

-- | TRA-17 requirement 6 over the real texture pipeline (headless rig, #672's backend): a terrain's two atlas parents are
-- uploaded as terrain-sized images, the terrain adapter is built over the handles the pipeline delivered, and the lifetime
-- the adapter relies on holds. Three independent examples:
--
-- * the original lease is released while a batch still reads the pair, and the textures stay unretired until completion;
-- * the adaptation over those handles is made and is unchanged by the release, the pending work and the reclamation;
-- * pressure (no room for another image) leaves nothing partial: the refused job holds no image, the parents are untouched,
--   and it proceeds when a released parent is reclaimed.
--
-- The terrain adapter allocates no texture, holds no lease and calls no recorder: it is a pure function of handles this
-- pipeline admitted, so what keeps a handle valid is exactly what is exercised here.
module Test.LuaEngine.Graphics.TerrainParents (spec) where

import Control.Concurrent.STM (atomically, retry)
import qualified Data.Text as Text
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.LuaEngine.Graphics.Texture (textureHandleOf)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle)
import Hetoimasia.Terrain.Render2D.Evidence (scenePlan)
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightSettings)
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "a terrain's two atlas parents through the texture pipeline" $ do
  it "keeps both parents unretired while a batch still reads them after the original lease is released, and retires them only at completion" $
    withRig terrainConfig $ \rig → do
      (colour, normal, _) ← deliverParents rig
      -- A batch's version still maps both slots (the retained reader), and reclamation is held: the actual completion point.
      setVersionHolders (rigFake rig) 2
      hold (rigFake rig) HoldReclaim
      holdBarrier (rigFake rig)
      colourReading ← textureRelease colour
      normalReading ← textureRelease normal
      -- Authority is gone at once, both are marked released, and nothing was released natively yet.
      awaitFake (rigFake rig) (\r → length (readingMarkedNow r) == 2)
      eventCount (rigFake rig) "release attempted" `shouldReturn` 0
      release (rigFake rig) HoldAdoption
      awaitBackend rig (\r → length (filter (== "retiring") (readingTextureStages r)) == 2)
      -- The table released; the batch's version still maps the slots: pending, never complete.
      mapM_ (\reading → atomically reading >>= (`shouldBe` True) . isPending) [colourReading, normalReading]
      -- The batches completed and the slots are reclaimed: now, and only now, both are retired.
      setVersionHolders (rigFake rig) 0
      release (rigFake rig) HoldReclaim
      atomically (colourReading >>= \case ProviderComplete → pure (); _ → retry)
      atomically (normalReading >>= \case ProviderComplete → pure (); _ → retry)

  it "builds the terrain adaptation over the delivered handles, and the release, the pending work and the reclamation leave that adaptation unchanged" $
    withRig terrainConfig $ \rig → do
      style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
      -- The parents are the committed atlases' own sizes, so the adaptation is the real one.
      (decodedWidth (styleColourImage style), decodedHeight (styleColourImage style)) `shouldBe` (288, 64)
      (decodedWidth (styleNormalImage style), decodedHeight (styleNormalImage style)) `shouldBe` (768, 384)
      (colour, normal, handles) ← deliverParents rig
      let (colourHandle, normalHandle) = handles
      colourParent ← either (fail . show) pure (bindColourParent (styleColour style) colourHandle)
      normalParent ← either (fail . show) pure (bindDataParent (styleNormal style) normalHandle)
      let textures = packedTextures colourParent normalParent
          assets = styleAssets style
          scene = rampsCorners FaceSouth
      plan ← either (fail . show) pure (scenePlan assets scene)
      adapted ← either (fail . describeMaterialRefusal) pure (adaptCells textures defaultLightSettings assets plan)
      atlasColourHandles textures `shouldBe` [colourHandle]
      -- Every quad of the adaptation is routed by the delivered colour texture's handle, and it has records to draw with.
      adaptedQuads adapted `shouldSatisfy` (not . null)
      adaptedQuads adapted `shouldSatisfy` all ((== colourHandle) . adaptedColourHandle)
      adaptedRecords adapted `shouldSatisfy` (not . null)
      -- The original leases are released while a batch still reads them and reclamation is held.
      setVersionHolders (rigFake rig) 2
      hold (rigFake rig) HoldReclaim
      readings ← mapM textureRelease [colour, normal]
      awaitFake (rigFake rig) (\r → length (readingMarkedNow r) == 2)
      -- The adaptation was made from the handles, not from the leases: the same inputs give the same value now.
      adaptCells textures defaultLightSettings assets plan `shouldBe` Right adapted
      setVersionHolders (rigFake rig) 0
      release (rigFake rig) HoldReclaim
      mapM_ (\reading → atomically (reading >>= \case ProviderComplete → pure (); _ → retry)) readings
      adaptCells textures defaultLightSettings assets plan `shouldBe` Right adapted

  it "refuses room for a third image with nothing partial held, leaves the parents untouched, and proceeds when a released parent is reclaimed" $
    withRig terrainConfig {fcImages = 2} $ \rig → do
      (colour, normal, _) ← deliverParents rig
      third ← newProbe
      _ ← submit rig third 288 64 255
      awaitEventCount (rigFake rig) "allocation pressure" 1
      terminals third `shouldReturn` []
      -- Only the two parents' images were ever allocated: the refused job holds no native image (nothing partial).
      allocations ← length . filter (Text.isPrefixOf "allocated") <$> events (rigFake rig)
      allocations `shouldBe` 2
      reading ← readingNow rig
      readingJobs reading `shouldBe` 1
      -- The parents are untouched by the refusal: still delivered, not marked released.
      awaitFake (rigFake rig) (null . readingMarkedNow)
      -- Releasing one parent and reclaiming it makes room: the refused job proceeds and is delivered.
      colourReading ← textureRelease colour
      atomically (colourReading >>= \case ProviderComplete → pure (); _ → retry)
      awaitTerminal third >>= (`shouldSatisfy` \case SeReady _ → True; _ → False)
      -- The other parent was never touched by any of it.
      reading' ← textureRelease normal
      atomically (reading' >>= \case ProviderComplete → pure (); _ → retry)

-- | Staging for the largest parent (768 x 384 x 4 bytes) and one more beside it.
terrainConfig ∷ FakeConfig
terrainConfig = defaultFakeConfig {fcStagingBytes = 4 * 1024 * 1024}

isPending ∷ RetirementState → Bool
isPending = \case ProviderPending → True; _ → False

-- | The two parents through the pipeline: the colour atlas (288 x 64) and the normal atlas (768 x 384), each delivered, with the
-- renderer handles their identities name.
deliverParents ∷ Rig → IO (BackendTexture, BackendTexture, (TextureHandle, TextureHandle))
deliverParents rig = do
  colourProbe ← newProbe
  normalProbe ← newProbe
  _ ← submit rig colourProbe 288 64 255
  _ ← submit rig normalProbe 768 384 255
  _ ← awaitTerminal colourProbe
  _ ← awaitTerminal normalProbe
  colour ← delivered colourProbe
  normal ← delivered normalProbe
  pure (colour, normal, (textureHandleOf (textureIdentity colour), textureHandleOf (textureIdentity normal)))
