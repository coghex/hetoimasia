-- | What the triangle sample draws, as values: the triangle's corners in
-- normalized device coordinates, the point inside it every check samples, and
-- the two linear colours. The shaders interpolate these into their source
-- ("Hetoimasia.Sample.Triangle"), which a splice can do only from another
-- module, and a verifier reads the same values to know what a frame should
-- hold.
module Hetoimasia.Sample.Triangle.Geometry
  ( -- * The triangle
    cornerTopX
  , cornerTopY
  , cornerRightX
  , cornerRightY
  , cornerLeftX
  , cornerLeftY
  , interior

    -- * The colours
  , triangleRed
  , triangleGreen
  , triangleBlue
  , triangleColour
  , clearColour
  ) where

-- | The top corner. Vulkan's normalized device coordinates put -1 at the top
-- of the image.
cornerTopX, cornerTopY ∷ Float
cornerTopX = 0
cornerTopY = -0.6

-- | The bottom-right corner.
cornerRightX, cornerRightY ∷ Float
cornerRightX = 0.6
cornerRightY = 0.6

-- | The bottom-left corner.
cornerLeftX, cornerLeftY ∷ Float
cornerLeftX = -0.6
cornerLeftY = 0.6

-- | The triangle's centroid, in normalized device coordinates: the point
-- inside it every check samples, as far from each edge as any.
interior ∷ (Float, Float)
interior =
  ( (cornerTopX + cornerRightX + cornerLeftX) / 3
  , (cornerTopY + cornerRightY + cornerLeftY) / 3
  )

-- | The triangle's linear colour, which the fragment shader writes.
triangleRed, triangleGreen, triangleBlue ∷ Float
triangleRed = 0.9
triangleGreen = 0.6
triangleBlue = 0.1

-- | The triangle's linear colour, red, green and blue.
triangleColour ∷ (Float, Float, Float)
triangleColour = (triangleRed, triangleGreen, triangleBlue)

-- | The linear colour each frame is cleared to, red, green and blue.
clearColour ∷ (Float, Float, Float)
clearColour = (0.05, 0.05, 0.2)
