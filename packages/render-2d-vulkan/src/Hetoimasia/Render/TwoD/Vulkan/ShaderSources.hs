{-# LANGUAGE QuasiQuotes #-}

-- | The GLSL the package's shaders are compiled from (R2D-7, R2D-9), kept as
-- text apart from "Hetoimasia.Render.TwoD.Vulkan.Shaders" because a splice can
-- run only what another module has compiled. The vertex stage is shared by every
-- pipeline; the fragment stage is a shared prelude, which holds the table
-- lookup, the sampler choice, the default material and the tint, followed by
-- the tail of the path it serves, so the two variants differ in their wrapping
-- and output alone and R2D-11 substitutes the material alone.
module Hetoimasia.Render.TwoD.Vulkan.ShaderSources
  ( vertexSource
  , fragmentPrelude
  , orderedTail
  , cutoutTail
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader (glsl)

-- | The vertex stage: the unit square placed through the instance's and the
-- view's transforms, snapped rigidly when the view snaps, with the depth the
-- instance's key gives constant across the quad.
vertexSource ∷ String
vertexSource =
  [glsl|
          #version 450

          layout(location = 0) in vec4 linear;
          layout(location = 1) in vec2 translation;
          layout(location = 2) in vec4 uvRect;
          layout(location = 3) in uint handleIndex;
          layout(location = 4) in uint handleGeneration;
          layout(location = 5) in vec4 tint;
          layout(location = 6) in uint flags;
          layout(location = 7) in uint parameter;
          layout(location = 8) in uint depthKey;

          layout(push_constant) uniform Pushed {
              vec4 viewLinear;
              vec2 viewTranslation;
              vec2 extent;
              float brightness;
              uint filtering;
              uint snap;
          } pushed;

          layout(location = 0) out vec2 at;
          layout(location = 1) flat out uvec2 handle;
          layout(location = 2) flat out vec4 tinted;
          layout(location = 3) flat out uvec2 attributes;

          // Two triangles over the unit square.
          const vec2 corners[6] = vec2[](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

          vec2 viewed(vec2 world) {
              return vec2(
                  pushed.viewLinear.x * world.x + pushed.viewLinear.z * world.y + pushed.viewTranslation.x,
                  pushed.viewLinear.y * world.x + pushed.viewLinear.w * world.y + pushed.viewTranslation.y);
          }

          // floor(p + 0.5) exactly, as Mapping.snapPixel evaluates it: the
          // fraction p - floor(p) is exact in single precision, whereas p + 0.5
          // is not (the largest float below one half would round up to 1.0).
          vec2 snapped(vec2 p) {
              vec2 whole = floor(p);
              return whole + step(vec2(0.5), p - whole);
          }

          // (2^24 - 1 - k) / 2^24 for a key below 2^24 (design D-23): the
          // numerator has 24 bits at most and the denominator is a power of
          // two, so the depth is exact, and a larger key is nearer.
          float depthOf(uint key) {
              return float(0xFFFFFFu - key) / 16777216.0;
          }

          void main() {
              vec2 corner = corners[gl_VertexIndex];
              vec2 world = vec2(
                  linear.x * corner.x + linear.z * corner.y + translation.x,
                  linear.y * corner.x + linear.w * corner.y + translation.y);
              vec2 target = viewed(world);
              if (pushed.snap != 0u) {
                  vec2 origin = viewed(translation);
                  target += snapped(origin) - origin;
              }
              at = mix(uvRect.xy, uvRect.zw, corner);
              handle = uvec2(handleIndex, handleGeneration);
              tinted = tint;
              attributes = uvec2(flags, parameter);
              gl_Position = vec4(target / pushed.extent * 2.0 - 1.0, depthOf(depthKey), 1.0);
          }
        |]

-- | What both fragment variants share: the table's bindings, the push block,
-- the handle's lookup, the sampler choice, the default material and the tint.
-- 'sampleMaterial' is the instance's material at its fragment, before the
-- engine's wrapping.
fragmentPrelude ∷ String
fragmentPrelude =
  [glsl|
          #version 450
          #extension GL_EXT_nonuniform_qualifier : require

          layout(set = 0, binding = 0) uniform sampler samplers[4];
          layout(set = 0, binding = 1) uniform texture2D textures[];
          layout(set = 1, binding = 0, std430) readonly buffer Lookup {
              uvec2 entries[];
          } lookups;

          layout(push_constant) uniform Pushed {
              vec4 viewLinear;
              vec2 viewTranslation;
              vec2 extent;
              float brightness;
              uint filtering;
              uint snap;
          } pushed;

          layout(location = 0) in vec2 at;
          layout(location = 1) flat in uvec2 handle;
          layout(location = 2) flat in vec4 tinted;
          layout(location = 3) flat in uvec2 attributes;
          layout(location = 0) out vec4 colour;

          // A handle's slot in the bound version: its entry's, when the index
          // is within the version and the entry holds the handle's
          // generation; otherwise slot 0, the placeholder.
          uint resolve(uvec2 wanted) {
              if (wanted.x >= uint(lookups.entries.length())) {
                  return 0u;
              }
              uvec2 entry = lookups.entries[wanted.x];
              return entry.y == wanted.y ? entry.x : 0u;
          }

          // The table sampler an instance samples with: its own choice in the
          // flags' low two bits (1 nearest, 2 linear), or the view's default
          // for 0. Nearest is sampler 0 and linear sampler 2, both clamping
          // to the edge.
          uint chosenSampler(uint flags) {
              uint choice = flags & 3u;
              uint filtering = (choice == 1u || choice == 2u) ? choice : pushed.filtering;
              return filtering == 2u ? 2u : 0u;
          }

          // The material: the built-in default, which is the texel itself.
          vec4 material(vec4 texel) {
              return texel;
          }

          // The instance's material at this fragment.
          vec4 sampleMaterial() {
              uint slot = resolve(handle);
              // The sampler choice comes from instance data the backend cannot
              // see, so it is clamped to the table's last sampler. The profile
              // enables non-uniform sampled-image indexing, not dynamic
              // indexing, so every index and the combined operand the sample
              // consumes are marked non-uniform.
              uint chosen = min(chosenSampler(attributes.x), 3u);
              vec4 texel = texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(chosen)])), at);
              return material(texel);
          }

          // The engine's tint, the first stage of wrapping any material.
          vec4 tintMaterial(vec4 m, vec4 tint) {
              return m * tint;
          }
        |]

-- | The ordered path's fragment tail: brightness after the tint, then the
-- blend output, an additive instance contributing no coverage.
orderedTail ∷ String
orderedTail =
  [glsl|
          // The engine's wrapping around any material: tint, then brightness.
          vec4 wrapMaterial(vec4 m, vec4 tint, float brightness) {
              vec4 s = tintMaterial(m, tint);
              s.rgb *= brightness;
              return s;
          }

          // The blend output: an additive instance contributes no coverage.
          vec4 blendOutput(vec4 s, uint flags) {
              if ((flags & 8u) != 0u) {
                  s.a = 0.0;
              }
              return s;
          }

          void main() {
              colour = blendOutput(wrapMaterial(sampleMaterial(), tinted, pushed.brightness), attributes.x);
          }
        |]

-- | The cutout variant's fragment tail (design D-26): with @s = m × c@, a
-- fragment whose alpha, before brightness, is below one half is discarded, and
-- any other writes its colour un-premultiplied and then brightened, with alpha
-- 1. Routing leaves the tint's alpha at 255 and the additive flag clear.
cutoutTail ∷ String
cutoutTail =
  [glsl|
          // The cutout output: the surviving fragment's colour is the
          // material's own, not weighted by its coverage.
          vec4 cutoutOutput(vec4 s, float brightness) {
              if (s.a < 0.5) {
                  discard;
              }
              return vec4((s.rgb / s.a) * brightness, 1.0);
          }

          void main() {
              colour = cutoutOutput(tintMaterial(sampleMaterial(), tinted), pushed.brightness);
          }
        |]
