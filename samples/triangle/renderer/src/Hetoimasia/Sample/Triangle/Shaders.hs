{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The triangle sample's shaders, compiled from GLSL to SPIR-V while the
-- sample builds, through the native backend's shader adapter
-- ("Hetoimasia.GPU.Vulkan.Native.Shader"), with the corners and the colour
-- interpolated from "Hetoimasia.Sample.Triangle.Geometry".
--
-- They are compiled in a package that depends on the native backend alone: a
-- splice loads every package the component compiling it depends on, and the
-- window integration's GLFW native code is not one a splice can load.
module Hetoimasia.Sample.Triangle.Shaders
  ( triangleShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Recording (PipelineShaders (..))
import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShader, glsl, vertexShader)
import Hetoimasia.Sample.Triangle.Geometry

-- | The triangle's two shaders: the corners are in the vertex shader, so the
-- pipeline takes no vertex input, and the fragment shader writes one colour.
triangleShaders ∷ PipelineShaders
triangleShaders =
  PipelineShaders
    { shaderVertex =
        $( vertexShader
             [glsl|
          #version 450

          const vec2 corners[3] = vec2[](
              vec2(${cornerTopX}, ${cornerTopY}),
              vec2(${cornerRightX}, ${cornerRightY}),
              vec2(${cornerLeftX}, ${cornerLeftY}));

          void main() {
              gl_Position = vec4(corners[gl_VertexIndex], 0.0, 1.0);
          }
        |]
         )
    , shaderFragment =
        $( fragmentShader
             [glsl|
          #version 450

          layout(location = 0) out vec4 colour;

          void main() {
              colour = vec4(${triangleRed}, ${triangleGreen}, ${triangleBlue}, 1.0);
          }
        |]
         )
    }
