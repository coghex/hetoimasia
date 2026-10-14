{-# LANGUAGE QuasiQuotes #-}

-- | The GLSL the package's shaders are compiled from (R2D-7, R2D-9, R2D-11,
-- R2D-12), kept as text apart from "Hetoimasia.Render.TwoD.Vulkan.Shaders"
-- because a splice can run only what another module has compiled. The vertex
-- stage is shared by every pipeline; the fragment stage is a shared start (the
-- bindings, the push block, the table lookup, the sampler choice, the tint and
-- the clip test), then a material (the built-in default's, or an application's
-- from "Hetoimasia.Render.TwoD.Vulkan.MaterialSources"), followed by the tail of
-- the path it serves, so the variants differ in their wrapping and output alone
-- and a material replaces @material@ alone.
--
-- Every shader declares the same push block, 128 bytes: the engine's members,
-- then the application's, then the rest as reserved words ('pushBlockSource'),
-- so a pipeline layout serves them all. Set 2's one storage buffer is read as
-- words: the clip tables' edges as the floats whose bits they are, and the
-- material records as they are.
module Hetoimasia.Render.TwoD.Vulkan.ShaderSources
  ( vertexSource
  , fragmentHead
  , fragmentCommon
  , defaultMaterialSource
  , orderedTail
  , cutoutTail
  , pushBlockSource
  , enginePushMembers
  , reservedDeclaration
  , builtInPushTail
  , builtInFragmentSource
  ) where

import Data.List (intercalate)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Shader (glsl)
import Hetoimasia.Render.TwoD.Vulkan.Layout (applicationPushLimit, applicationPushOffset, reservedPushWords)

-- | The vertex stage: the unit square placed through the instance's and the
-- view's transforms, snapped rigidly when the view snaps, with the depth the
-- instance's key gives constant across the quad, and the instance's clip index
-- passed on flat. An animated instance (frame-table index in the flags' bits
-- 4–15, R2D-18) takes its texture rectangle from the current frame of its view's
-- table, which the batch's region holds, in place of its own.
vertexSource ∷ String → String
vertexSource appMembers = vertexHead <> pushBlockSource appMembers <> vertexBody

vertexHead ∷ String
vertexHead =
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

          // The batch's storage region (R2D-12, R2D-11, R2D-18), read as words:
          // here only the view's frame tables, which a vertex of an animated
          // instance reads its texture rectangle from.
          layout(set = 2, binding = 0, std430) readonly buffer Region {
              uint words[];
          } region;

        |]

vertexBody ∷ String
vertexBody =
  [glsl|
          layout(location = 0) out vec2 at;
          layout(location = 1) flat out uvec2 handle;
          layout(location = 2) flat out vec4 tinted;
          layout(location = 3) flat out uvec2 attributes;
          layout(location = 4) flat out uint clipIndex;

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

          // The texture rectangle of the current frame of the view's table for a
          // frame-table index k > 0 (R2D-18): the directory at frameBase gives
          // the word, from frameBase, where table k - 1's record begins; the
          // record holds the table's current frame, as the host computed it,
          // then its count and two reserved words, then one vec4 rectangle for
          // each frame. No time arithmetic is done here.
          vec4 frameRectangle(uint index) {
              uint record = pushed.frameBase + region.words[pushed.frameBase + index - 1u];
              uint at4 = record + 4u + region.words[record] * 4u;
              return vec4(
                  uintBitsToFloat(region.words[at4]),
                  uintBitsToFloat(region.words[at4 + 1u]),
                  uintBitsToFloat(region.words[at4 + 2u]),
                  uintBitsToFloat(region.words[at4 + 3u]));
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
              // The instance's own rectangle, or its table's current frame's:
              // the flags' bits 4-15 hold the table's index, 0 meaning none.
              uint frameIndex = (flags >> 4u) & 0xFFFu;
              vec4 rectangle = frameIndex == 0u ? uvRect : frameRectangle(frameIndex);
              at = mix(rectangle.xy, rectangle.zw, corner);
              handle = uvec2(handleIndex, handleGeneration);
              tinted = tint;
              attributes = uvec2(flags, parameter);
              // The clip index is the flags word's top 16 bits; 0 means none.
              clipIndex = flags >> 16u;
              gl_Position = vec4(target / pushed.extent * 2.0 - 1.0, depthOf(depthKey), 1.0);
          }
        |]

-- | The fragment stage's start: the version, the extension, the texture table's
-- bindings and set 2's storage buffer, which holds the batch's clip tables
-- (R2D-12) and then its material records (R2D-11), read as words.
fragmentHead ∷ String
fragmentHead =
  [glsl|
          #version 450
          #extension GL_EXT_nonuniform_qualifier : require

          layout(set = 0, binding = 0) uniform sampler samplers[4];
          layout(set = 0, binding = 1) uniform texture2D textures[];
          layout(set = 1, binding = 0, std430) readonly buffer Lookup {
              uvec2 entries[];
          } lookups;
          // The batch's storage region (R2D-12, R2D-11): the clip tables, one
          // entry of four floats per resolved clip (left, top, right and bottom
          // edges, about a reference point), and after them the material
          // records, as the words they are. Both are read as words, the floats
          // through their bits.
          layout(set = 2, binding = 0, std430) readonly buffer Region {
              uint words[];
          } region;
        |]

-- | What both fragment variants share after the push block (which
-- 'pushBlockSource' declares between them): the interpolants, the handle's
-- lookup, the sampler choice, 'sampleTexture', the tint and the clip test.
fragmentCommon ∷ String
fragmentCommon =
  [glsl|
          layout(location = 0) in vec2 at;
          layout(location = 1) flat in uvec2 handle;
          layout(location = 2) flat in vec4 tinted;
          layout(location = 3) flat in uvec2 attributes;
          layout(location = 4) flat in uint clipIndex;
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

          // A texture sampled at coordinates: the handle resolved through the
          // lookup with its generation check, so an index past the version, or
          // an entry of another generation, is the transparent placeholder, and
          // the instance's own sampler choice.
          vec4 sampleTexture(uvec2 wanted, vec2 uv) {
              uint slot = resolve(wanted);
              // The sampler choice comes from instance data the backend cannot
              // see, so it is clamped to the table's last sampler. The profile
              // enables non-uniform sampled-image indexing, not dynamic
              // indexing, so every index and the combined operand the sample
              // consumes are marked non-uniform.
              uint chosen = min(chosenSampler(attributes.x), 3u);
              return texture(nonuniformEXT(sampler2D(textures[nonuniformEXT(slot)], samplers[nonuniformEXT(chosen)])), uv);
          }

          // The engine's tint, the first stage of wrapping any material.
          vec4 tintMaterial(vec4 m, vec4 tint) {
              return m * tint;
          }

          // Whether the instance's clip excludes this fragment (design D-11).
          // The fragment's pixel centre must lie in the clip's half-open
          // rectangle in the layer's space: left and top inside, right and
          // bottom outside. Clip index 0 means none, and reads nothing; index k
          // reads the layer's table's entry k - 1. The comparison is made about
          // a reference point, never in absolute layer coordinates, which are
          // too coarse in single precision far from the origin: the fragment's
          // offset from the push block's clipCentre goes through the inverse's
          // linear part, and the table's edges were written as their distance
          // from the layer-space point under that centre.
          bool clippedOut() {
              if (clipIndex == 0u) {
                  return false;
              }
              uint at4 = (pushed.clipBase + clipIndex - 1u) * 4u;
              vec4 clip = vec4(
                  uintBitsToFloat(region.words[at4]),
                  uintBitsToFloat(region.words[at4 + 1u]),
                  uintBitsToFloat(region.words[at4 + 2u]),
                  uintBitsToFloat(region.words[at4 + 3u]));
              vec2 offset = gl_FragCoord.xy - pushed.clipCentre;
              vec2 local = vec2(
                  pushed.inverseLinear.x * offset.x + pushed.inverseLinear.z * offset.y,
                  pushed.inverseLinear.y * offset.x + pushed.inverseLinear.w * offset.y);
              return !(local.x >= clip.x && local.x < clip.z && local.y >= clip.y && local.y < clip.w);
          }
        |]

-- | The built-in default material: the texel itself. 'sampleMaterial' is the
-- instance's material at its fragment, before the engine's wrapping.
defaultMaterialSource ∷ String
defaultMaterialSource =
  [glsl|
          // The material: the built-in default, which is the texel itself.
          vec4 material(vec4 texel) {
              return texel;
          }

          // The instance's material at this fragment.
          vec4 sampleMaterial() {
              return material(sampleTexture(handle, at));
          }
        |]

-- | The engine's members of the push block, in declaration order, each as its
-- GLSL type and its name. This is the one place they are declared: 'pushBlockSource'
-- writes the block from it, and the names a material may not declare for a member
-- of its own ("Hetoimasia.Render.TwoD.Vulkan.MaterialSources") are read from it,
-- so a member added here is refused there too. Their layout is
-- 'Hetoimasia.Render.TwoD.Vulkan.Layout.pushMembers'.
enginePushMembers ∷ [(String, String)]
enginePushMembers =
  [ ("vec4", "viewLinear")
  , ("vec2", "viewTranslation")
  , ("vec2", "extent")
  , ("float", "brightness")
  , ("uint", "filtering")
  , ("uint", "snap")
  , ("uint", "clipBase")
  , ("vec4", "inverseLinear")
  , ("vec2", "clipCentre")
  , ("uint", "recordBase")
  , ("uint", "frameBase")
  ]

-- | The push block both stages declare, 128 bytes: the engine's members
-- ('enginePushMembers'), then these declarations of the application's own members
-- and of the words reserved after them ('applicationPushOffset',
-- 'applicationPushLimit'). Every shader declares the whole range, so one pipeline
-- layout serves them all.
pushBlockSource ∷ String → String
pushBlockSource appMembers =
  intercalate
    "\n"
    ( ["layout(push_constant) uniform Pushed {"]
        <> ["    " <> glslType <> " " <> name <> ";" | (glslType, name) ← enginePushMembers]
        <> [ appMembers
           , "} pushed;"
           , ""
           ]
    )

-- | The words reserved after an application's own members, which have used this
-- many bytes of the block: one array member that makes the block span the whole
-- range. Nothing for a block that has used it all.
reservedDeclaration ∷ Word32 → String
reservedDeclaration used
  | count == 0 = ""
  | otherwise = "    layout(offset = " <> show (applicationPushOffset + used) <> ") uint reserved[" <> show count <> "];\n"
  where
    count = reservedPushWords (min applicationPushLimit used)

-- | What the built-in shaders declare after the engine's members: all of the
-- application's bytes, reserved.
builtInPushTail ∷ String
builtInPushTail = reservedDeclaration 0

-- | The built-in fragment stage with the tail of its path.
builtInFragmentSource ∷ String → String
builtInFragmentSource tailSource = fragmentHead <> pushBlockSource builtInPushTail <> fragmentCommon <> defaultMaterialSource <> tailSource

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
              // The sample is taken first, so the neighbouring invocations of a
              // quad that the clip discards still take part in its derivatives.
              vec4 s = wrapMaterial(sampleMaterial(), tinted, pushed.brightness);
              if (clippedOut()) {
                  discard;
              }
              colour = blendOutput(s, attributes.x);
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
              vec4 s = tintMaterial(sampleMaterial(), tinted);
              if (clippedOut()) {
                  discard;
              }
              colour = cutoutOutput(s, pushed.brightness);
          }
        |]
