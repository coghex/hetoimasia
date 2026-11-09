-- | TRA-17: the pure material model against the independent exact expectation, at EVERY pixel of the
-- fixtures whose device read-back is partly exempt (the unsnapped fractional ones), and so at every
-- exempted pixel. Only the device's read-back may be undecided there; the model is exact.
--
-- The model ('terrainModel') is given what the shader is given: the quad's record, the push block, the
-- fragment's coordinates (the exact position across the canvas) and a sampler over the real colour and
-- normal atlas images (nearest, at the texel centres the model asks for). Its colour is encoded to display
-- bytes and compared, within the declared tolerance, with the hand expectation's.
module Test.TerrainRender2D.ModelAtBand (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.Maybe (listToMaybe)
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialInput (..), MaterialModel (..))
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle)
import Hetoimasia.Terrain.Render2D.CellPick (CellHit (..), CellPickResult (..))
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightSettings)
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Data.List (sortOn)
import Data.Ord (Down (..))
import Test.Hspec
import Test.TerrainRender2D.CellFixtures (pickPixel)
import Test.TerrainRender2D.Fixtures (tileAt)

spec ∷ Spec
spec = describe "TRA-17 the pure material model at every pixel of the fractional fixtures" $
  it "agrees with the independent exact expectation, including at every pixel the device band exempts" $ do
    style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
    colour ← either (fail . show) pure (bindColourParent (styleColour style) (textureHandle 3 1))
    normal ← either (fail . show) pure (bindDataParent (styleNormal style) (textureHandle 4 1))
    let textures = packedTextures colour normal
        assets = styleAssets style
        art = styleArt style
        scenes =
          [ fractionalCamera
          , viewportOffset 0.125
          , -- The native evidence's own fixture `fractional@0.1875` (round-5 review): 136 banded pixels there.
            atZoom 0.1875 fractionalCamera
          ]
            <> [atZoom z (rampsCorners FaceSouth) | z ← [0.125, 0.1875, 0.25, 0.375]]
            <> [atZoom 0.125 (rampsCorners FaceEast), atZoom 0.25 (rampsCorners FaceWest)]
    results ← mapM (modelAgainstExpectation style textures assets art) scenes
    forM_ (zip scenes results) $ \(scene, Result compared mismatches banded bandedCompared unevaluated) → do
      (sceneName scene, mismatches) `shouldBe` (sceneName scene, [])
      (sceneName scene, compared > 0) `shouldBe` (sceneName scene, True)
      -- No covered pixel is silently skipped, and EVERY banded pixel was model-compared: none is accepted as not evaluable.
      (sceneName scene, unevaluated) `shouldBe` (sceneName scene, 0)
      (sceneName scene, bandedCompared) `shouldBe` (sceneName scene, banded)
    -- The fractional fixtures really do have exempted pixels, and the model was compared at all of them.
    sum [banded | Result _ _ banded _ _ ← results] `shouldSatisfy` (> 0)
    -- The native fixture's own count: 136 banded pixels at zoom 3/16 (the evidence's `fractional@0.1875`).
    [banded | (scene, Result _ _ banded _ _) ← zip scenes results, sceneName scene == sceneName (atZoom 0.1875 fractionalCamera)]
      `shouldBe` [136]

-- | What the model was compared on: covered pixels compared, the first mismatches, the pixels the device band (at
-- b = 8) leaves undecided, how many of those were model-compared, and the covered pixels that could not be evaluated
-- at all (a hit with no record, say).
data Result = Result !Int [String] !Int !Int !Int

-- | The model's colour at every covered pixel against the exact expectation.
modelAgainstExpectation ∷ AtlasStyle → AtlasTextures → AssetSnapshot → ArtSource → Scene → IO Result
modelAgainstExpectation style textures assets art scene = do
  plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
  adapted ← either (fail . describeMaterialRefusal) pure (adaptCells textures defaultLightSettings assets plan)
  let camera = sceneCameraFollowed scene
      (w, h) = sceneTarget scene
      colourAtlas = styleColourImage style
      normalAtlas = styleNormalImage style
      texelOf image atX atY =
        let (aw, ah) = (fromIntegral (decodedWidth image), fromIntegral (decodedHeight image)) ∷ (Double, Double)
            i = min (decodedWidth image - 1) (floor (atX * aw))
            j = min (decodedHeight image - 1) (floor (atY * ah))
            bytes = head' (decodedLevels image)
            at k = ByteString.index bytes (4 * (fromIntegral j * fromIntegral (decodedWidth image) + fromIntegral i) + k)
         in (at 0, at 1, at 2, at 3)
      head' xs = case xs of x : _ → x; [] → ByteString.empty
      colourHandleOf = textureHandle 3 1
      sampler handle (atX, atY)
        | handle == colourHandleOf =
            let (r, g, b, a) = texelOf colourAtlas atX atY
             in Right (Colour (srgbDecode r) (srgbDecode g) (srgbDecode b) (fromIntegral a / 255))
        | otherwise =
            let (r, g, b, a) = texelOf normalAtlas atX atY
             in Right (Colour (fromIntegral r / 255) (fromIntegral g / 255) (fromIntegral b / 255) (fromIntegral a / 255))
      pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
      isBanded pixel = case expectedForDevice 8 3 art defaultHandLight scene camera plan pixel of Ambiguous _ → 1; _ → 0 ∷ Int
      step (Result compared bad banded bandedCompared unevaluated) pixel = case expectedAt art defaultHandLight scene camera plan pixel of
        ExpectedHit {expectedFront = q, expectedLinear = lin} →
          case (pixelWorldPoint plan pixel, pickPixel plan pixel) of
            (Just (sx, sy), CellPickHit hit)
              | Just entry ← listToMaybe [e | e ← adaptedQuads adapted, quadCell (adaptedQuad e) == Just (hitCell hit), quadPart (adaptedQuad e) == hitPart hit]
              , record : _ ← drop (fromIntegral (adaptedParameter entry)) (adaptedRecords adapted) →
                  let (cx, cy) = hqCorner q
                      u = fromRational ((sx - fromInteger cx) / 96) ∷ Double
                      v = fromRational ((sy - fromInteger cy) / 64) ∷ Double
                      input =
                        MaterialInput
                          { materialTexel = Colour 0 0 0 0
                          , materialUv = (u, v)
                          , materialParameter = 0
                          , materialRecord = record
                          , materialPush = adaptedPush adapted
                          , materialSample = sampler
                          , materialSampleScaled = \handle at _ → sampler handle at
                          }
                   in case runMaterialModel terrainModel input of
                        Right (Colour r g b _) →
                          let (mr, mg, mb) = shadedByte (r, g, b)
                              (er, eg, eb) = shadedByte lin
                              close a c = abs (fromIntegral a - fromIntegral c) <= (3 ∷ Int)
                              exempt = isBanded pixel
                              bad' = if close mr er && close mg eg && close mb eb then bad else take 4 (bad <> [show pixel <> ": model " <> show (mr, mg, mb) <> " against exact " <> show (er, eg, eb)])
                           in Result (compared + 1) bad' (banded + exempt) (bandedCompared + exempt) unevaluated
                        Left _ → Result (compared + 1) (take 4 (bad <> [show pixel <> ": the model gave no value"])) (banded + isBanded pixel) bandedCompared unevaluated
            _ → Result compared bad (banded + isBanded pixel) bandedCompared (unevaluated + 1)
        ExpectedClear
          -- A banded pixel the exact expectation leaves clear: the model is composed over the hand quads whose canvas holds
          -- the point, nearest first, exactly as the draw would, and every one of them must give no colour (a hole).
          | isBanded pixel == 1, Just (sx, sy) ← pixelWorldPoint plan pixel →
              let covering = [q | q ← sortOn (Down . hqKey) (handQuads scene camera), insideCanvas q sx sy]
                  evaluate q = case [e | e ← adaptedQuads adapted, quadCell (adaptedQuad e) == Just (tileAt cx cy cz), quadPart (adaptedQuad e) == partOf (hqRole q)] of
                    entry : _ | record : _ ← drop (fromIntegral (adaptedParameter entry)) (adaptedRecords adapted) →
                      let (qx, qy) = hqCorner q
                       in either (const Nothing) Just (runMaterialModel terrainModel (modelInput record (fromRational ((sx - fromInteger qx) / 96), fromRational ((sy - fromInteger qy) / 64))))
                    _ → Nothing
                    where (cx, cy, cz) = hqCell q
                  results' = map evaluate covering
               in if all (maybe False (\(Colour _ _ _ a) → a < 1e-9)) results'
                    then Result compared bad (banded + 1) (bandedCompared + 1) unevaluated
                    else Result compared (take 4 (bad <> [show pixel <> ": the exact expectation is clear but the model draws"])) (banded + 1) (bandedCompared + 1) unevaluated
        _ → Result compared bad (banded + isBanded pixel) bandedCompared unevaluated
      insideCanvas q sx sy = let (qx, qy) = hqCorner q; fu = sx - fromInteger qx; fv = sy - fromInteger qy in fu >= 0 && fu < 96 && fv >= 0 && fv < 64
      partOf = \case
        Ordinary → PartOrdinary
        MixedKnown → PartKnown
        _ → PartFog
      modelInput record uv =
        MaterialInput
          { materialTexel = Colour 0 0 0 0
          , materialUv = uv
          , materialParameter = 0
          , materialRecord = record
          , materialPush = adaptedPush adapted
          , materialSample = sampler
          , materialSampleScaled = \handle at _ → sampler handle at
          }
  pure (foldl step (Result 0 [] 0 0 0) pixels)
