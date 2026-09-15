{-# LANGUAGE DeriveGeneric #-}

-- | The observation vocabulary windows, window controls, and monitors share: an
-- attribute the platform observed or cannot provide, a content scale, and a
-- window's size and placement.
--
-- It holds no state. "Hetoimasia.GLFW.Internal.Window" and
-- "Hetoimasia.GLFW.Internal.Monitor" both publish observations built from these
-- values, and the public modules re-export them, so a client sees one
-- 'Attribute' whichever observation it reads.
module Hetoimasia.GLFW.Internal.Attribute
  ( Attribute (..)
  , ContentScale (..)
  , Extent (..)
  , Placement (..)
  ) where

import Control.DeepSeq (NFData)
import GHC.Generics (Generic)

-- | One observed attribute.
data Attribute a
  = Observed !a
    -- ^ The value the platform reported when sampled or called back.
  | Unavailable
    -- ^ The platform cannot provide this attribute, or reported a value that is
    -- not a consistent one.
  deriving (Eq, Show, Generic)

instance NFData a ⇒ NFData (Attribute a)

-- | The ratio between the platform's DPI and its default DPI, per axis.
data ContentScale = ContentScale
  { scaleX ∷ !Float
  , scaleY ∷ !Float
  }
  deriving (Eq, Show, Generic)

instance NFData ContentScale

-- | A size: logical in screen coordinates, or a framebuffer's in pixels.
data Extent = Extent
  { extentWidth ∷ !Int
  , extentHeight ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData Extent

-- | The content area's upper-left corner in desktop screen coordinates.
data Placement = Placement
  { placementX ∷ !Int
  , placementY ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData Placement
