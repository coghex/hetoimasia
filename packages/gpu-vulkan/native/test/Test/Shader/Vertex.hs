{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The vertex half of VK-9's verification pair: inline source that
-- interpolates a Haskell constant and a layout location.
--
-- The two halves are separate modules so each is its own unit of rebuilding:
-- a change to the fragment half's file or includes recompiles that module and
-- leaves this one, and its shader compilation, alone. They are verification
-- fixtures, not production shaders.
module Test.Shader.Vertex (verificationVertex) where

import Data.ByteString (ByteString)

import Hetoimasia.GPU.Vulkan.Native.Shader (glsl, vertexShader)
import Test.Shader.Constants (verificationMarker, verificationTagLocation)

-- | Writes the marker to the tag the fragment half reads.
verificationVertex ∷ ByteString
verificationVertex =
  $( vertexShader
       [glsl|
    #version 450

    layout(location = ${verificationTagLocation}) flat out uint tag;

    void main() {
        tag = ${verificationMarker}u;
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
    }
  |]
   )
