-- | The independent oracle and the probes it sets: every probe well inside a
-- face or outside both cubes; each occlusion probe at a pixel both cubes
-- cover, where the nearer cube — drawn first — must show, and a scene drawn
-- without depth testing, the farther cube last, would show the other; each
-- camera-moved probe on a face the other pose cannot see, or a pixel the
-- other pose reads differently; and an oracle that tells a right image from
-- one drawn without depth.
module Test.Sample.Scene3d.Oracle (spec) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (nub)
import Test.Hspec

import Hetoimasia.Sample.Scene3d.Oracle
import Hetoimasia.Sample.Scene3d.Scene

spec ∷ Spec
spec = describe "Scene3d oracle" $ do
  it "sets only probes well inside a face, or outside both cubes, so no edge rule decides one" $ do
    [probeName probe | probe ← sceneProbes, not (interior (poseNamed (probePose probe)) (probePixel probe))] `shouldBe` []
    interiorMargin `shouldSatisfy` (>= 3)

  it "sets probes of every purpose in each pose, with exact expectations: a face's flat colour, or the clear colour" $ do
    forM' poses $ \pose →
      nub [probePurpose probe | probe ← sceneProbes, probePose probe == poseName pose] `shouldBe` [FaceColour, CameraMovedPlace, CameraMovedFace, Occlusion, Clear]
    forM' sceneProbes $ \probe → do
      let pose = poseNamed (probePose probe)
          pixel = probePixel probe
      expectedColour pose pixel `shouldBe` maybe clearColour (\hit → faceColour (hitCube hit) (hitFace hit)) (nearestHit pose pixel)
      (probePurpose probe == Clear) `shouldBe` (nearestHit pose pixel == Nothing)

  it "puts each occlusion probe where both cubes are struck, the nearer first, so a scene drawn without depth testing would show the farther cube's colour instead" $ do
    let occlusion = [probe | probe ← sceneProbes, probePurpose probe == Occlusion]
    length occlusion `shouldBe` 4
    forM' occlusion $ \probe → do
      let pose = poseNamed (probePose probe)
          pixel = probePixel probe
      map hitCube (hitsAt pose pixel) `shouldBe` [NearCube, FarCube]
      fmap hitCube (nearestHit pose pixel) `shouldBe` Just NearCube
      -- Drawn nearer first, the farther cube would be the last to write the pixel.
      withoutDepthTest pose pixel `shouldBe` Just FarCube
      expectedColour pose pixel `shouldSatisfy` (`notElem` [faceColour FarCube face | face ← [minBound .. maxBound]])

  it "puts each camera-moved-face probe on a face the other pose cannot see anywhere" $ do
    let moved = [probe | probe ← sceneProbes, probePurpose probe == CameraMovedFace]
    length moved `shouldBe` 2
    forM' moved $ \probe → do
      let others = [pose | pose ← poses, poseName pose /= probePose probe]
          seen = nub [(hitCube hit, hitFace hit) | other ← others, x ← [0 .. targetWidth - 1], y ← [0 .. targetHeight - 1], Just hit ← [nearestHit other (x, y)]]
      length others `shouldBe` 1
      case nearestHit (poseNamed (probePose probe)) (probePixel probe) of
        Just hit → seen `shouldSatisfy` notElem (hitCube hit, hitFace hit)
        Nothing → expectationFailure "the probe strikes nothing"

  it "puts a pixel the two poses read differently, and a face both see at different pixels, among the camera-moved-place probes" $ do
    let place = [probe | probe ← sceneProbes, probePurpose probe == CameraMovedPlace]
        samePixel = [(a, b) | a ← place, b ← place, probePose a == FrontPose, probePose b == SidePose, probePixel a == probePixel b]
    length samePixel `shouldBe` 1
    forM' samePixel $ \(front, side) →
      expectedColour (poseNamed FrontPose) (probePixel front) `shouldSatisfy` (/= expectedColour (poseNamed SidePose) (probePixel side))
    -- A face seen from both poses, at pixels more than a few apart.
    let facesAt name = [(hitCube hit, hitFace hit, probePixel probe) | probe ← place, probePose probe == name, Just hit ← [nearestHit (poseNamed name) (probePixel probe)]]
        shared = [(front, side) | (cubeA, faceA, front) ← facesAt FrontPose, (cubeB, faceB, side) ← facesAt SidePose, (cubeA, faceA) == (cubeB, faceB), front /= side]
    shared `shouldSatisfy` (not . null)

  it "passes an image the oracle draws with depth, and fails exactly the occlusion probes on the same scene drawn without depth testing" $ do
    forM' [FrontPose, SidePose] $ \name → do
      let correct = evaluateProbes name (imageOf name True)
          painted = evaluateProbes name (imageOf name False)
      probesPassed correct `shouldBe` True
      [probePurpose (resultProbe result) | result ← painted, not (resultPassed result)] `shouldBe` [Occlusion, Occlusion]
      length correct `shouldBe` length [() | probe ← sceneProbes, probePose probe == name]

  it "fails a probe whose pixel reads one value wrong, and every probe against an image that is missing" $ do
    let name = FrontPose
        bytes = imageOf name True
    case [probePixel probe | probe ← sceneProbes, probePose probe == name] of
      (x, y) : _ → do
        let offset = (y * targetWidth + x) * 4
            altered = ByteString.take offset bytes <> ByteString.singleton (ByteString.index bytes offset + 1) <> ByteString.drop (offset + 1) bytes
        [resultPassed result | result ← evaluateProbes name altered] `shouldBe` False : replicate (length (evaluateProbes name altered) - 1) True
        probesPassed (evaluateProbes name mempty) `shouldBe` False
        probesPassed [] `shouldBe` False
      [] → expectationFailure "the front pose has no probes"
  where
    forM' items action = mapM_ action items

-- | The target the oracle's rays paint: with a depth test, the nearest hit's
-- face colour; without one, the last-drawn cube's entry face colour.
imageOf ∷ PoseName → Bool → ByteString
imageOf name depthTested =
  ByteString.pack
    [ byte
    | y ← [0 .. targetHeight - 1]
    , x ← [0 .. targetWidth - 1]
    , let Rgba r g b a = colourAt (x, y)
    , byte ← [r, g, b, a]
    ]
  where
    pose = poseNamed name
    colourAt pixel
      | depthTested = expectedColour pose pixel
      | otherwise = case withoutDepthTest pose pixel of
          Nothing → clearColour
          Just cube → case [hit | hit ← hitsAt pose pixel, hitCube hit == cube] of
            hit : _ → faceColour cube (hitFace hit)
            [] → clearColour
