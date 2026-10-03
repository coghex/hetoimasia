{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The verification pipeline's shaders, embedded as SPIR-V by VK-9's adapter:
-- one triangle whose corners are in the vertex shader itself, so the pipeline
-- takes no vertex input, and one solid color. They are what the native cases
-- build a managed pipeline from and record a draw with; the triangle
-- consumer's own shaders and draw order are VK-17's.
--
-- 'endpointShaders' draw the same triangle in pure yellow, whose every channel
-- is 0 or 1: its stored 8-bit value is exact in every RGBA8 format, sRGB or
-- linear, so an offscreen readback of it can be probed exactly (GRS-5).
--
-- 'quadShaders' take their geometry from vertex input and their color from a
-- push constant (GRS-4): a two-float position per vertex at location 0, a
-- two-float offset per instance at location 1, added together, and a
-- four-float color in the fragment stage's push constants at offset 0.
module Hetoimasia.GPU.Vulkan.Native.Recording.Shaders
  ( verificationShaders
  , endpointShaders
  , quadShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Recording (PipelineShaders (..))
import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShader, glsl, vertexShader)

verificationShaders ∷ PipelineShaders
verificationShaders =
  PipelineShaders
    { shaderVertex =
        $( vertexShader
             [glsl|
          #version 450

          const vec2 corners[3] = vec2[](vec2(0.0, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));

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
              colour = vec4(1.0, 0.5, 0.0, 1.0);
          }
        |]
         )
    }

endpointShaders ∷ PipelineShaders
endpointShaders =
  PipelineShaders
    { shaderVertex =
        $( vertexShader
             [glsl|
          #version 450

          const vec2 corners[3] = vec2[](vec2(0.0, -0.5), vec2(0.5, 0.5), vec2(-0.5, 0.5));

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
              colour = vec4(1.0, 1.0, 0.0, 1.0);
          }
        |]
         )
    }

quadShaders ∷ PipelineShaders
quadShaders =
  PipelineShaders
    { shaderVertex =
        $( vertexShader
             [glsl|
          #version 450

          layout(location = 0) in vec2 position;
          layout(location = 1) in vec2 offset;

          void main() {
              gl_Position = vec4(position + offset, 0.0, 1.0);
          }
        |]
         )
    , shaderFragment =
        $( fragmentShader
             [glsl|
          #version 450

          layout(push_constant) uniform Pushed {
              vec4 colour;
          } pushed;

          layout(location = 0) out vec4 colour;

          void main() {
              colour = pushed.colour;
          }
        |]
         )
    }
