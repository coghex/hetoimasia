-- | The port the texture backend runs over: what the graphics owner lends, and what it answers. This is the package's public face; the
-- implementation, with its contract, is "Hetoimasia.LuaEngine.Graphics.Texture.Port.Internal", in the package's private
-- sub-library.
module Hetoimasia.LuaEngine.Graphics.Texture.Port
  ( -- * The port
    Port (..)
  , Standing (..)
  , PortRefusal (..)
  , Submitted (..)
  , Outcome (..)

    -- * The owner's thread
  , Device (..)
  , Fault (..)
  , Registration (..)
  , Disposal (..)
  , Level (..)
  , TextureRef (..)
  , textureIdentity
  , textureRefOf

    -- * Uploads and the table
  , AdmissionRefusal (..)
  , TicketStanding (..)
  , CancelStanding (..)
  , TableReading (..)
  ) where

import Hetoimasia.LuaEngine.Graphics.Texture.Port.Internal
