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
-- four-float color in the fragment stage's push constants at offset 0. They
-- declare an interface, so they are checked shaders (GRS-16), compiled against
-- the descriptions in "Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces",
-- and a pipeline takes its layout's range and its vertex input from them.
--
-- 'tableShaders' sample the texture table (GRS-7) across a triangle covering
-- the whole render area: the fragment stage resolves the pushed handle
-- through the bound lookup version — slot 0's placeholder for an index past
-- the version's entries or a generation it does not hold, before any
-- descriptor is read — and samples that slot with the pushed sampler. A
-- pipeline over them needs a layout from 'createTablePipelineLayout' given
-- 'tableSamplerOffset'.
--
-- 'tableInstanceShaders' sample the same table with the sampler chosen per
-- instance (render-2d D-4): the vertex stage draws one rectangle for each
-- instance, whose vertex input carries the rectangle in clip space, a texture
-- handle and a sampler index; the fragment stage resolves the handle as
-- 'tableShaders' do and samples with that index, clamped to the table's last
-- sampler. They declare no push constants, so a pipeline over them needs a
-- layout from 'createShaderSampledTablePipelineLayout', and draws with no
-- 'selectSampler'.
module Hetoimasia.GPU.Vulkan.Native.Recording.Shaders
  ( verificationShaders
  , endpointShaders
  , quadShaders
  , tableShaders
  , tableInstanceShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Recording (PipelineShaders (..))
import Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces
  ( quadFragmentInterface
  , quadVertexInterface
  , tableFragmentInterface
  , tableInstanceFragmentInterface
  , tableInstanceVertexInterface
  , tableVertexInterface
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader, fragmentShader, glsl, vertexShader)

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

quadShaders ∷ CheckedShaders
quadShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             quadVertexInterface
             [glsl|
          #version 450

          layout(location = 0) in vec2 position;
          layout(location = 1) in vec2 offset;

          void main() {
              gl_Position = vec4(position + offset, 0.0, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             quadFragmentInterface
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

tableShaders ∷ CheckedShaders
tableShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             tableVertexInterface
             [glsl|
          #version 450

          layout(location = 0) out vec2 at;

          void main() {
              vec2 corner = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
              at = corner;
              gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             tableFragmentInterface
             [glsl|
          #version 450
          #extension GL_EXT_nonuniform_qualifier : require

          layout(set = 0, binding = 0) uniform sampler samplers[4];
          layout(set = 0, binding = 1) uniform texture2D textures[];
          layout(set = 1, binding = 0, std430) readonly buffer Lookup {
              uvec2 entries[];
          } lookups;

          layout(push_constant) uniform Pushed {
              uvec2 handle;
              uint filtering;
          } pushed;

          layout(location = 0) in vec2 at;
          layout(location = 0) out vec4 colour;

          // A handle's slot in the bound version: its entry's, when the
          // index is within the version and the entry holds the handle's
          // generation; otherwise slot 0, the placeholder.
          uint resolve(uvec2 handle) {
              if (handle.x >= uint(lookups.entries.length())) {
                  return 0u;
              }
              uvec2 entry = lookups.entries[handle.x];
              return entry.y == handle.y ? entry.x : 0u;
          }

          void main() {
              uint slot = resolve(pushed.handle);
              // The profile enables non-uniform sampled-image indexing, not
              // dynamic indexing, so every index and the combined operand the
              // sample consumes are marked non-uniform.
              colour = texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(min(pushed.filtering, 3u))])), at);
          }
        |]
         )
    }

tableInstanceShaders ∷ CheckedShaders
tableInstanceShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             tableInstanceVertexInterface
             [glsl|
          #version 450

          layout(location = 0) in vec4 rectangle;
          layout(location = 1) in uint lookupIndex;
          layout(location = 2) in uint generation;
          layout(location = 3) in uint samplerIndex;

          layout(location = 0) out vec2 at;
          layout(location = 1) flat out uvec2 handle;
          layout(location = 2) flat out uint filtering;

          // Two triangles over the unit square.
          const vec2 corners[6] = vec2[](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

          void main() {
              vec2 corner = corners[gl_VertexIndex];
              at = corner;
              handle = uvec2(lookupIndex, generation);
              filtering = samplerIndex;
              gl_Position = vec4(mix(rectangle.xy, rectangle.zw, corner), 0.0, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             tableInstanceFragmentInterface
             [glsl|
          #version 450
          #extension GL_EXT_nonuniform_qualifier : require

          layout(set = 0, binding = 0) uniform sampler samplers[4];
          layout(set = 0, binding = 1) uniform texture2D textures[];
          layout(set = 1, binding = 0, std430) readonly buffer Lookup {
              uvec2 entries[];
          } lookups;

          layout(location = 0) in vec2 at;
          layout(location = 1) flat in uvec2 handle;
          layout(location = 2) flat in uint filtering;
          layout(location = 0) out vec4 colour;

          // A handle's slot in the bound version: its entry's, when the
          // index is within the version and the entry holds the handle's
          // generation; otherwise slot 0, the placeholder.
          uint resolve(uvec2 handle) {
              if (handle.x >= uint(lookups.entries.length())) {
                  return 0u;
              }
              uvec2 entry = lookups.entries[handle.x];
              return entry.y == handle.y ? entry.x : 0u;
          }

          void main() {
              uint slot = resolve(handle);
              // The sampler index comes from instance data the backend cannot
              // see, so the shader clamps it to the table's last sampler. The
              // profile enables non-uniform sampled-image indexing, not
              // dynamic indexing, so every index and the combined operand the
              // sample consumes are marked non-uniform.
              colour = texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(min(filtering, 3u))])), at);
          }
        |]
         )
    }
