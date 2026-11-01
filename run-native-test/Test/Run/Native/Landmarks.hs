{-# LANGUAGE OverloadedStrings #-}

-- | The shipped quad scene's landmarks, specified from the fixture and the content, not from any captured image.
--
-- The inputs are written down in samples/lua-quad (its README, @tools/generate_quad_png.py@ and @content/lua/main.lua@):
-- an 8 x 8 texture of four 4 x 4 quadrants (top left red, top right green, bottom left blue, bottom right yellow) with a
-- white texel at its top-left corner and a black one at its bottom-right, drawn once as a 256 x 256 logical-pixel
-- rectangle at (32, 32) over the clear colour (24, 24, 24). Each texel is therefore a 32 x 32 block, and a pixel's
-- colour is the texel's byte value passed through an sRGB target unchanged (the same property the offscreen oracle of
-- LFE-24 established); the landmarks are the centres of blocks, away from any texel boundary, plus background points.
--
-- Nothing here is derived from a first capture, so a capture cannot define its own expected value. The tolerance is the
-- per-channel difference allowed for the X server's 8-bit handling of an sRGB-encoded presentation (Xvfb applies no
-- colour management; any difference is rounding of the software rasteriser); it is stated beside every judgement and is
-- never relaxed to make an image pass.
module Test.Run.Native.Landmarks
  ( Landmark (..)
  , tolerance
  , quadLandmarks
  , redClearLandmarks
  , blackLandmarks
  , judge
  , Judgement (..)
  ) where

import Data.Text (Text)

data Landmark = Landmark
  { lmName ∷ !Text
  , lmPoint ∷ !(Int, Int)
  , lmExpected ∷ !(Int, Int, Int)
  }
  deriving (Eq, Show)

-- | Per-channel tolerance, in 8-bit steps.
tolerance ∷ Int
tolerance = 2

clear ∷ (Int, Int, Int)
clear = (24, 24, 24)

-- | Landmark points for a client area of this logical size at content scale 1. A quad landmark appears only when its
-- point lies inside the client area (a shrunken window clips the quad: what is clipped is not expected to be seen), and
-- background points only where the quad is not.
quadLandmarks ∷ (Int, Int) → [Landmark]
quadLandmarks (width, height) = filter inside (quad <> background)
  where
    inside (Landmark _ (x, y) _) = x >= 0 && y >= 0 && x < width && y < height
    -- the centre of texel (i, j): the rectangle's origin plus 32 logical pixels a texel plus half a texel
    centre i j = (32 + 32 * i + 16, 32 + 32 * j + 16)
    quad =
      [ Landmark "white texel (0,0), the quad's top-left corner" (centre 0 0) (255, 255, 255)
      , Landmark "red quadrant (texel 2,2)" (centre 2 2) (255, 0, 0)
      , Landmark "green quadrant (texel 5,2)" (centre 5 2) (0, 255, 0)
      , Landmark "blue quadrant (texel 2,5)" (centre 2 5) (0, 0, 255)
      , Landmark "yellow quadrant (texel 5,5)" (centre 5 5) (255, 255, 0)
      , Landmark "black texel (7,7), the quad's bottom-right corner" (centre 7 7) (0, 0, 0)
      ]
    background =
      [ Landmark "clear, left of the quad" (8, 100) clear
      , Landmark "clear, above the quad" (150, 8) clear
      , Landmark "clear, right of the quad" (300, 100) clear
      , Landmark "clear, below the quad" (150, 300) clear
      , Landmark "clear, far corner" (width - 8, height - 8) clear
      ]

-- | Landmarks of the scene the shipped content publishes when the logical role has failed: the exact empty red clear
-- (96, 0, 0) and no sprite (samples/lua-quad content/lua/main.lua), so every point is the clear colour.
redClearLandmarks ∷ (Int, Int) → [Landmark]
redClearLandmarks (width, height) =
  [ Landmark ("red clear at " <> label) point (96, 0, 0)
  | (label, point) ←
      [ ("the top-left corner area", (8, 8))
      , ("where the quad would be", (112, 112))
      , ("the centre", (width `div` 2, height `div` 2))
      , ("the far corner", (width - 8, height - 8))
      ]
  ]

-- | Landmarks of a window that has only its initial scene: the host's initial scene is an opaque black clear and nothing
-- else, so every point is black. (A window that has adopted nothing else yet is allowed to look like this.)
blackLandmarks ∷ (Int, Int) → [Landmark]
blackLandmarks (width, height) =
  [ Landmark ("initial black at " <> label) point (0, 0, 0)
  | (label, point) ←
      [ ("the top-left corner area", (8, 8))
      , ("where the quad will be", (112, 112))
      , ("the centre", (width `div` 2, height `div` 2))
      , ("the far corner", (width - 8, height - 8))
      ]
  ]

-- | What a capture said at a landmark.
data Judgement = Judgement
  { judgedLandmark ∷ !Landmark
  , judgedActual ∷ !(Maybe (Int, Int, Int))
  , judgedPassed ∷ !Bool
  }
  deriving (Eq, Show)

-- | Judge the colours a capture reported at each landmark's point; a point it did not report fails.
judge ∷ [((Int, Int), (Int, Int, Int))] → [Landmark] → [Judgement]
judge sampled = map one
  where
    one landmark =
      let actual = lookup (lmPoint landmark) sampled
          close (r, g, b) (r', g', b') = abs (r - r') <= tolerance && abs (g - g') <= tolerance && abs (b - b') <= tolerance
       in Judgement landmark actual (maybe False (close (lmExpected landmark)) actual)
