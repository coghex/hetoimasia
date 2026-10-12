-- | The windowed mode's pure parts (GRS-13): the orbiting camera and its
-- matrices for a window's own aspect ratio, the front pose's probes scaled to
-- a window's framebuffer, and the sRGB encoding the swapchain stores colors
-- in.
module Test.Sample.Scene3d.Windowed (spec) where

import Data.List (nub)
import Test.Hspec

import Hetoimasia.Sample.Scene3d.Camera (projectionMatrix, projectionMatrixFor, transform, transformFor)
import Hetoimasia.Sample.Scene3d.Oracle (Hit (..), expectedColourIn, hitsAtIn, interiorIn, nearestHitIn)
import Hetoimasia.Sample.Scene3d.Scene
import Hetoimasia.Sample.Scene3d.Windowed

spec ∷ Spec
spec = describe "Scene3d windowed mode" $ do
  describe "the orbiting camera" $ do
    it "stays on its circle at its height, looking at the scene's centre, whatever its angle" $
      mapM_
        ( \degrees → do
            let pose = orbitPose degrees
                (x, y, z) = poseEye pose
            sqrt (x * x + z * z) `shouldSatisfy` (\radius → abs (radius - orbitRadius) < 1.0e-9)
            y `shouldBe` orbitHeight
            poseTarget pose `shouldBe` (0, 0.2, 0)
        )
        [0, 0.25, 45, 90, 180, 270, 359.75, 720]

    it "turns by a fraction of a degree a frame, so a full orbit takes minutes of frames" $ do
      orbitDegreesPerFrame `shouldSatisfy` (\turn → turn > 0 && turn <= 1)
      poseEye (orbitPose 0) `shouldNotBe` poseEye (orbitPose orbitDegreesPerFrame)
      poseEye (orbitPose 360) `shouldSatisfy` (\(x, _, z) → abs x < 1.0e-9 && abs (z - orbitRadius) < 1.0e-9)

    it "has matrices for every angle of the orbit at a window's own aspect ratio, and the evidence target's for its own" $ do
      mapM_ (\degrees → mapM_ (\cube → transformFor (16 / 9) (orbitPose degrees) cube `shouldSatisfy` (/= Nothing)) cubes) [0, 30 .. 330]
      projectionMatrixFor (fromIntegral targetWidth / fromIntegral targetHeight) (poseNamed FrontPose) `shouldBe` projectionMatrix (poseNamed FrontPose)
      mapM_ (\cube → transformFor (fromIntegral targetWidth / fromIntegral targetHeight) (poseNamed SidePose) cube `shouldBe` transform (poseNamed SidePose) cube) cubes
      projectionMatrixFor (4 / 3) (poseNamed FrontPose) `shouldNotBe` projectionMatrixFor (16 / 9) (poseNamed FrontPose)

  describe "the probes at a window's framebuffer" $ do
    it "scale the front pose's probes to the framebuffer, keep those well inside a face there, and give each the oracle's color" $
      mapM_
        ( \extent → do
            let probes = windowedProbes extent
                pose = poseNamed FrontPose
            probes `shouldSatisfy` (not . null)
            mapM_
              ( \probe → do
                  probePose (windowedProbe probe) `shouldBe` FrontPose
                  windowedPixel probe `shouldBe` scaledPixel extent (probePixel (windowedProbe probe))
                  interiorIn extent pose (windowedPixel probe) `shouldBe` True
                  windowedExpected probe `shouldBe` expectedColourIn extent pose (windowedPixel probe)
              )
              probes
        )
        framebuffers

    it "keep an occlusion probe, a face probe and a clear probe at each framebuffer the native case may meet, the occlusion ones where both cubes are struck and the nearer shows" $
      mapM_
        ( \extent → do
            let probes = windowedProbes extent
                purposes = nub (map (probePurpose . windowedProbe) probes)
            purposes `shouldSatisfy` (\found → all (`elem` found) [Occlusion, FaceColour, Clear])
            mapM_
              ( \probe → do
                  map hitCube (hitsAtIn extent (poseNamed FrontPose) (windowedPixel probe)) `shouldBe` [NearCube, FarCube]
                  fmap hitCube (nearestHitIn extent (poseNamed FrontPose) (windowedPixel probe)) `shouldBe` Just NearCube
              )
              [probe | probe ← probes, probePurpose (windowedProbe probe) == Occlusion]
        )
        framebuffers

    it "are the evidence target's own probes, unscaled, at the evidence target's extent" $
      map (windowedPixel) (windowedProbes (targetWidth, targetHeight))
        `shouldBe` [probePixel probe | probe ← sceneProbes, probePose probe == FrontPose]

  describe "the sRGB encoding" $ do
    it "stores black and white as they are and a mid grey brighter than its byte, monotonically" $ do
      storedChannel 0 `shouldBe` 0
      storedChannel 255 `shouldBe` 255
      storedChannel 128 `shouldBe` 188
      let stored = map storedChannel [0 .. 255]
      and (zipWith (<=) stored (drop 1 stored)) `shouldBe` True

    it "encodes a color's channels and leaves its alpha" $
      storedColour (Rgba 255 128 0 255) `shouldBe` Rgba 255 188 0 255
  where
    -- The framebuffers a window of 160 by 120 or 200 by 150 points has at one
    -- or two pixels a point.
    framebuffers = [(160, 120), (200, 150), (320, 240), (400, 300), (256, 192)]
