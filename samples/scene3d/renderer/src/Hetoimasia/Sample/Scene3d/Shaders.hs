{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The scene3d sample's shaders (GRS-10), compiled while the sample builds
-- and checked against "Hetoimasia.Sample.Scene3d.ShaderInterfaces" (GRS-16).
--
-- The vertex stage multiplies each position by the transform the draw pushed,
-- a model-view-projection matrix whose projection sends depth to 0 at the near
-- plane and 1 at the far plane and the top of the view to clip-space Y = −1
-- (D-36), and hands the vertex colour on unchanged and flat: there is no
-- lighting, so a face's colour is the byte it was given. The fragment stage
-- writes that colour, and nothing else: depth is the fixed-function test's.
module Hetoimasia.Sample.Scene3d.Shaders
  ( scene3dShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader, glsl)
import Hetoimasia.Sample.Scene3d.ShaderInterfaces (scene3dFragmentInterface, scene3dVertexInterface)

scene3dShaders ∷ CheckedShaders
scene3dShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             scene3dVertexInterface
             [glsl|
          #version 450

          layout(location = 0) in vec3 position;
          layout(location = 1) in vec4 colour;

          layout(push_constant) uniform Pushed {
              mat4 transform;
          } pushed;

          layout(location = 0) flat out vec4 shade;

          void main() {
              shade = colour;
              gl_Position = pushed.transform * vec4(position, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             scene3dFragmentInterface
             [glsl|
          #version 450

          layout(location = 0) flat in vec4 shade;
          layout(location = 0) out vec4 colour;

          void main() {
              colour = shade;
          }
        |]
         )
    }
