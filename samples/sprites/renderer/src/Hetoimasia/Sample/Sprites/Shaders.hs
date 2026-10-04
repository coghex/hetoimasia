{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The sprites sample's shaders (GRS-8), compiled while the sample builds
-- and checked against "Hetoimasia.Sample.Sprites.ShaderInterfaces" (GRS-16).
--
-- The vertex stage places each instance's unit quad at its rectangle under
-- the fixed orthographic view of the 256×256 scene — target pixels to clip
-- space, with Vulkan's @y@ downwards — and maps its texture-coordinate
-- rectangle across it. The fragment stage resolves the instance's texture
-- handle through the batch's lookup version: an index past the version's
-- entries, or an entry of another generation, resolves to slot 0's
-- transparent placeholder before any descriptor is read. It samples that slot
-- with the sampler the draw selected. The handle differs between a draw's
-- instances, and the profile enables non-uniform indexing rather than dynamic
-- indexing, so every index and the sampled image carry @nonuniformEXT@.
module Hetoimasia.Sample.Sprites.Shaders
  ( spritesShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader, glsl)
import Hetoimasia.Sample.Sprites.ShaderInterfaces (spritesFragmentInterface, spritesVertexInterface)

spritesShaders ∷ CheckedShaders
spritesShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             spritesVertexInterface
             [glsl|
          #version 450

          layout(location = 0) in vec2 corner;
          layout(location = 1) in vec4 rect;
          layout(location = 2) in vec4 uv;
          layout(location = 3) in uint handleIndex;
          layout(location = 4) in uint handleGeneration;

          layout(location = 0) out vec2 at;
          layout(location = 1) flat out uvec2 handle;

          void main() {
              vec2 pixel = rect.xy + corner * rect.zw;
              at = mix(uv.xy, uv.zw, corner);
              handle = uvec2(handleIndex, handleGeneration);
              gl_Position = vec4(pixel / 128.0 - 1.0, 0.0, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             spritesFragmentInterface
             [glsl|
          #version 450
          #extension GL_EXT_nonuniform_qualifier : require

          layout(set = 0, binding = 0) uniform sampler samplers[4];
          layout(set = 0, binding = 1) uniform texture2D textures[];
          layout(set = 1, binding = 0, std430) readonly buffer Lookup {
              uvec2 entries[];
          } lookups;

          layout(push_constant) uniform Pushed {
              uint filtering;
          } pushed;

          layout(location = 0) in vec2 at;
          layout(location = 1) flat in uvec2 handle;
          layout(location = 0) out vec4 colour;

          uint resolve(uvec2 wanted) {
              if (wanted.x >= uint(lookups.entries.length())) {
                  return 0u;
              }
              uvec2 entry = lookups.entries[wanted.x];
              return entry.y == wanted.y ? entry.x : 0u;
          }

          void main() {
              uint slot = resolve(handle);
              colour = texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(min(pushed.filtering, 3u))])), at);
          }
        |]
         )
    }
