{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The ordered path's shaders (R2D-7), compiled while the package builds and
-- checked against "Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces" (GRS-16),
-- under the shader-sampled table layout (R2D-16).
--
-- = Vertex stage
--
-- For each instance and each of the six corners of the unit square [0, 1]²
-- (two triangles, from @gl_VertexIndex@), with the instance's transform
-- @(a, b, c, d, tx, ty)@ and the view's @(va, vb, vc, vd, vtx, vty)@, in target
-- pixels:
--
-- > world  = (a·x + c·y + tx, b·x + d·y + ty)
-- > target = (va·wx + vc·wy + vtx, vb·wx + vd·wy + vty)
-- > origin = (va·tx + vc·ty + vtx, vb·tx + vd·ty + vty)         the mapped (0, 0)
-- > shift  = floor(origin + ½) − origin                          when the view snaps, else 0
-- >                                                              (evaluated exactly: floor(origin) plus 1 when its fraction is at least ½)
-- > clip   = ((target + shift) / extent) · 2 − 1                 Vulkan's Y down
--
-- so with snap on the quad moves rigidly until its origin lands on
-- @floor(p + ½)@ of its mapped origin, the arithmetic of
-- 'Hetoimasia.Render.TwoD.Mapping.snapPoint'. The texture coordinates
-- interpolate affinely from @(u0, v0)@ at (0, 0) to @(u1, v1)@ at (1, 1). The
-- handle, the tint, the flags and the parameter word pass on as flat values.
--
-- = Fragment stage
--
-- The handle resolves through the batch's lookup version, as the backend's
-- reference shaders do: an index past the version's entries, or an entry of
-- another generation, is slot 0's transparent placeholder, before any
-- descriptor is read. The sampler choice in the flags' low two bits is 0 for
-- the view's default filter, 1 nearest, 2 linear; nearest is the table's
-- sampler 0 and linear its sampler 2, clamped to the last sampler and marked
-- non-uniform, because the profile enables non-uniform indexing and the choice
-- differs between instances of one draw. With @t@ the texel (sRGB decoded by
-- the hardware on an sRGB image), @c@ the tint, @b@ the view's brightness:
--
-- > m = material(t)                      the built-in default: m = t
-- > s = m × c;  s.rgb = s.rgb × b        wrapMaterial: tint, then brightness
-- > s.a = 0 for an additive instance     blendOutput
-- > result = s + destination × (1 − s.a) the pipeline's premultiplied blend
--
-- Material, wrapping and blend output are separate functions, so an
-- application material (R2D-11) replaces @material@ alone and cannot omit the
-- tint, the brightness or the blend output.
module Hetoimasia.Render.TwoD.Vulkan.Shaders
  ( orderedShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader, glsl)
import Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces (orderedFragmentInterface, orderedVertexInterface)

orderedShaders ∷ CheckedShaders
orderedShaders =
  CheckedShaders
    { checkedVertex =
        $( checkedVertexShader
             orderedVertexInterface
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
              gl_Position = vec4(target / pushed.extent * 2.0 - 1.0, 0.0, 1.0);
          }
        |]
         )
    , checkedFragment =
        $( checkedFragmentShader
             orderedFragmentInterface
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

          // The engine's wrapping around any material: tint, then brightness.
          vec4 wrapMaterial(vec4 m, vec4 tint, float brightness) {
              vec4 s = m * tint;
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
              uint slot = resolve(handle);
              // The sampler choice comes from instance data the backend cannot
              // see, so it is clamped to the table's last sampler. The profile
              // enables non-uniform sampled-image indexing, not dynamic
              // indexing, so every index and the combined operand the sample
              // consumes are marked non-uniform.
              uint chosen = min(chosenSampler(attributes.x), 3u);
              vec4 texel = texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(chosen)])), at);
              colour = blendOutput(wrapMaterial(material(texel), tinted, pushed.brightness), attributes.x);
          }
        |]
         )
    }
