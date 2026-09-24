-- | The Haskell values the verification vertex shader interpolates.
--
-- A splice cannot use a value defined in its own module, so what a shader
-- shares with Haskell lives here, exactly as a production shader's layout
-- constants would.
module Test.Shader.Constants
  ( verificationMarker
  , verificationTagLocation
  ) where

import Data.Word (Word32)

-- | A value distinctive enough that finding it among the compiled module's
-- words means it came from the interpolation and from nowhere else.
verificationMarker ∷ Word32
verificationMarker = 0x5EED1234

-- | The interface location the pair shares. The fragment half's include
-- declares the same location in GLSL.
verificationTagLocation ∷ Int
verificationTagLocation = 3
