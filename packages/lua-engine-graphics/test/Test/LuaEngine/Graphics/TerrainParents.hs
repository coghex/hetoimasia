{-# LANGUAGE OverloadedStrings #-}

-- | TRA-17 requirement 6 over the real texture pipeline (headless rig, #672's backend): a terrain's two atlas parents are
-- uploaded as terrain-sized images and the terrain adapter is built over the handles the pipeline delivered. Three
-- independent examples:
--
-- * the adaptation over those handles is unchanged by the release of the original ownership and by the reclamation;
-- * a REQUIRED parent whose registration is refused fails its acquisition and rolls back: no native image is left for it,
--   the parent already delivered with it is untouched until the caller releases it, and a prior terrain's parents and
--   adaptation are unchanged;
-- * a required parent that waits for room under pressure and is then withdrawn leaves nothing partial the same way.
--
-- No holder count is set by hand here: what holds a texture while a frame that names it is recorded or pending is read
-- from the real recorder in @Test.Render.TwoD.Vulkan.TerrainParents@ (render-2d-vulkan's suite), and the byte banks'
-- charges from the real pipeline in @Test.LuaEngine.Texture.TerrainParents@ (lua-engine's suite). The terrain adapter
-- allocates no texture, holds no lease and calls no recorder: it is a pure function of handles this pipeline admitted.
module Test.LuaEngine.Graphics.TerrainParents (spec) where

import Control.Concurrent.STM (atomically, retry)
import qualified Data.Text as Text
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.LuaEngine.Graphics.Texture (textureHandleOf)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Fault (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..), UploadWork (..))
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
  it "builds the terrain adaptation over the delivered handles, and the release of the original ownership and its reclamation leave that adaptation unchanged" $
    withRig terrainConfig $ \rig → do
      terrain ← terrainOver
      (colour, normal, handles) ← deliverParents rig
      made ← adaptOver terrain handles
      -- Every quad of the adaptation is routed by the delivered colour texture's handle, and it has records to draw with.
      adaptedQuads (madeAdapted made) `shouldSatisfy` (not . null)
      adaptedQuads (madeAdapted made) `shouldSatisfy` all ((== fst handles) . adaptedColourHandle)
      atlasColourHandles (madeTextures made) `shouldBe` [fst handles]
      -- The original leases are released: the adaptation was made from the handles, not from the leases, so the same inputs
      -- give the same value before and after the textures' retirement.
      readings ← mapM textureRelease [colour, normal]
      mapM_ (\reading → atomically (reading >>= \case ProviderComplete → pure (); _ → retry)) readings
      adaptAgain terrain made `shouldBe` Right (madeAdapted made)

  it "rolls a required parent's refused registration back: no image left for it, the parent delivered with it untouched, and a prior terrain unchanged" $
    withRig terrainConfig $ \rig → do
      terrain ← terrainOver
      -- A prior terrain's parents are delivered and adapted.
      (priorColour, priorNormal, priorHandles) ← deliverParents rig
      prior ← adaptOver terrain priorHandles
      -- A new terrain: its colour parent is delivered, its normal parent's registration is refused.
      colourProbe ← newProbe
      _ ← submit rig colourProbe 288 64 255
      _ ← awaitTerminal colourProbe
      newColour ← delivered colourProbe
      awaitFake (rigFake rig) ((== 3) . readingImagesAlive)
      inject (rigFake rig) (FailRegister (FaultFatal "the table refused the image"))
      normalProbe ← newProbe
      _ ← submit rig normalProbe 768 384 255
      failed ← awaitTerminal normalProbe
      failed `shouldSatisfy` \case SeFailed text → Text.isInfixOf "the table refused the image" text; _ → False
      -- Nothing partial: the failed parent's image was discarded, and the three delivered are exactly what is alive.
      awaitFake (rigFake rig) ((== 3) . readingImagesAlive)
      -- The caller rolls the acquisition back by releasing the parent that did arrive; the prior terrain is untouched.
      rollback ← textureRelease newColour
      atomically (rollback >>= \case ProviderComplete → pure (); _ → retry)
      awaitFake (rigFake rig) ((== 2) . readingImagesAlive)
      adaptAgain terrain prior `shouldBe` Right (madeAdapted prior)
      readings ← mapM textureRelease [priorColour, priorNormal]
      mapM_ (\reading → atomically (reading >>= \case ProviderComplete → pure (); _ → retry)) readings

  it "rolls back a required parent that waits for room under pressure and is then withdrawn: no image for it, the parent beside it and a prior terrain unchanged" $
    withRig terrainConfig {fcImages = 3} $ \rig → do
      terrain ← terrainOver
      (priorColour, priorNormal, priorHandles) ← deliverParents rig
      prior ← adaptOver terrain priorHandles
      colourProbe ← newProbe
      _ ← submit rig colourProbe 288 64 255
      _ ← awaitTerminal colourProbe
      newColour ← delivered colourProbe
      -- The third image is the colour parent: no room for the required normal parent, which waits.
      normalProbe ← newProbe
      work ← submit rig normalProbe 768 384 255
      awaitEventCount (rigFake rig) "allocation pressure" 1
      terminals normalProbe `shouldReturn` []
      allocated ← length . filter (Text.isPrefixOf "allocated") <$> events (rigFake rig)
      allocated `shouldBe` 3
      -- The acquisition is withdrawn: the waiting parent never gets an image, and the colour parent is released by the caller.
      uploadCancel work
      awaitFake (rigFake rig) ((== 3) . readingImagesAlive)
      rollback ← textureRelease newColour
      atomically (rollback >>= \case ProviderComplete → pure (); _ → retry)
      awaitFake (rigFake rig) ((== 2) . readingImagesAlive)
      adaptAgain terrain prior `shouldBe` Right (madeAdapted prior)
      readings ← mapM textureRelease [priorColour, priorNormal]
      mapM_ (\reading → atomically (reading >>= \case ProviderComplete → pure (); _ → retry)) readings

-- | The committed style and the inputs of the adaptation, loaded once for an example.
data Terrain = Terrain
  { terrainStyle ∷ !AtlasStyle
  }

terrainOver ∷ IO Terrain
terrainOver = do
  style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
  -- The parents are the committed atlases' own sizes, so the adaptation is the real one.
  (decodedWidth (styleColourImage style), decodedHeight (styleColourImage style)) `shouldBe` (288, 64)
  (decodedWidth (styleNormalImage style), decodedHeight (styleNormalImage style)) `shouldBe` (768, 384)
  pure (Terrain style)

data Made = Made
  { madeTextures ∷ !AtlasTextures
  , madeAdapted ∷ !Adapted
  }

-- | The adaptation of a real plan over these parent handles.
adaptOver ∷ Terrain → (TextureHandle, TextureHandle) → IO Made
adaptOver terrain (colourHandle, normalHandle) = do
  let style = terrainStyle terrain
  colourParent ← either (fail . show) pure (bindColourParent (styleColour style) colourHandle)
  normalParent ← either (fail . show) pure (bindDataParent (styleNormal style) normalHandle)
  let textures = packedTextures colourParent normalParent
  plan ← either (fail . show) pure (scenePlan (styleAssets style) (rampsCorners FaceSouth))
  adapted ← either (fail . describeMaterialRefusal) pure (adaptCells textures defaultLightSettings (styleAssets style) plan)
  pure (Made textures adapted)

-- | The same adaptation again, from the same inputs.
adaptAgain ∷ Terrain → Made → Either MaterialRefusal Adapted
adaptAgain terrain made = do
  let style = terrainStyle terrain
  plan ← either (const (Left StaleAssets)) Right (scenePlan (styleAssets style) (rampsCorners FaceSouth))
  adaptCells (madeTextures made) defaultLightSettings (styleAssets style) plan

-- | Staging for the largest parent (768 x 384 x 4 bytes) and one more beside it.
terrainConfig ∷ FakeConfig
terrainConfig = defaultFakeConfig {fcStagingBytes = 4 * 1024 * 1024}

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
