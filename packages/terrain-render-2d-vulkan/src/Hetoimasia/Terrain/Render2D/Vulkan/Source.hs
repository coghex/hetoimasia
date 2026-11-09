-- | The GLSL of the terrain material's fragment function (TRA-17), in a module of its own because
-- a Template Haskell splice may use only what another module defines.
--
-- The record it reads is the layout of "Hetoimasia.Terrain.Render2D.Material": two handles, the
-- colour atlas and the normal atlas, and these words:
--
-- > w0..w5    colour region: origin x, origin y, width, height, atlas width, atlas height
-- > w6..w11   normal region: the same six
-- > w12       the cell's depth below the cut, 0 .. 250
--
-- and the push block is three @vec4@s: @lightSun@ (view sun direction x, y, z; ambient),
-- @lightDepth@ (effective sun strength; darkening; haze; reciprocal depth range) and @lightHaze@
-- (haze colour in linear light; padding), as "Hetoimasia.Terrain.Render2D.Presentation" packs them.
--
-- Each atlas is sampled at the texel centre of the texel the quad's UV selects in the region's own
-- extent, @(origin + (i + 1/2, j + 1/2)) / atlasExtent@, so the sampler (nearest, level zero, one
-- level) never mixes a neighbour and the origin is added after the local texel is chosen. Both
-- samples are taken unconditionally, as the sampler's implicit derivatives require. The normal is
-- decoded from the sampled UNORM by rounding to a byte, subtracting 128 and normalizing, with a
-- guard so a transparent sample's colour bytes are never normalized into a NaN; its alpha is the
-- map's coverage. The result is premultiplied linear colour, lit, darkened and hazed in the
-- specified order, and its alpha is the colour's alpha times the map's, which is binary wherever
-- both are, as a cutout-capable material promises.
--
-- State, ownership and lifetime: none.
module Hetoimasia.Terrain.Render2D.Vulkan.Source
  ( terrainSource
  , terrainSourceEquivalent
  , lightPush
  ) where

import Hetoimasia.Render.TwoD.Vulkan.MaterialSources (PushField (..), PushType (..))

-- | The three @vec4@ members of the push block, in the order the host packs them.
lightPush ∷ [PushField]
lightPush = [PushField "lightSun" PushVec4, PushField "lightDepth" PushVec4, PushField "lightHaze" PushVec4]

-- | The material function's source.
terrainSource ∷ String
terrainSource =
  unlines
    [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
    , "    vec2 unit = clamp(uv, 0.0, 1.0);"
    , "    vec2 colourExtent = vec2(float(record.words[2]), float(record.words[3]));"
    , "    vec2 colourLocal = min(colourExtent - 1.0, floor(unit * colourExtent));"
    , "    vec2 colourAt = (vec2(float(record.words[0]), float(record.words[1])) + colourLocal + 0.5)"
    , "        / vec2(float(record.words[4]), float(record.words[5]));"
    , "    vec2 normalExtent = vec2(float(record.words[8]), float(record.words[9]));"
    , "    vec2 normalLocal = min(normalExtent - 1.0, floor(unit * normalExtent));"
    , "    vec2 normalAt = (vec2(float(record.words[6]), float(record.words[7])) + normalLocal + 0.5)"
    , "        / vec2(float(record.words[10]), float(record.words[11]));"
    , "    vec4 colour = sampleTexture(record.handles[0], colourAt);"
    , "    vec4 data = sampleTexture(record.handles[1], normalAt);"
    , "    vec3 bytes = floor(data.rgb * 255.0 + 0.5) - 128.0;"
    , "    float length2 = dot(bytes, bytes);"
    , "    vec3 normal = (length2 > 0.0) ? bytes * inversesqrt(length2) : vec3(0.0, 0.0, 1.0);"
    , "    float diffuse = clamp(dot(normal, pushed.lightSun.xyz), 0.0, 1.0);"
    , "    float ambient = pushed.lightSun.w;"
    , "    float bright = ambient + (1.0 - ambient) * pushed.lightDepth.x * diffuse;"
    , "    float t = clamp(float(record.words[12]) * pushed.lightDepth.w, 0.0, 1.0);"
    , "    float darken = 1.0 - pushed.lightDepth.y * t;"
    , "    float haze = pushed.lightDepth.z * t * t;"
    , "    float alpha = colour.a * data.a;"
    , "    vec3 rgb = (1.0 - haze) * colour.rgb * data.a * bright * darken + haze * pushed.lightHaze.xyz * alpha;"
    , "    return vec4(rgb, alpha);"
    , "}"
    ]

-- | The same function with every commutative operation written the other way round (each
-- product and sum has its operands swapped, which does not change an IEEE result), the
-- derived locals renamed and the guard inverted. It behaves identically and has its own SPIR-V: a
-- second material the renderer registers as another reference, for evidence that the grouping of
-- quads into runs by material does not change what is drawn.
terrainSourceEquivalent ∷ String
terrainSourceEquivalent =
  unlines
    [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
    , "    vec2 inside = min(max(uv, 0.0), 1.0);"
    , "    vec2 cExtent = vec2(float(record.words[2]), float(record.words[3]));"
    , "    vec2 cLocal = min(floor(cExtent * inside), cExtent - 1.0);"
    , "    vec2 cAt = (0.5 + cLocal + vec2(float(record.words[0]), float(record.words[1])))"
    , "        / vec2(float(record.words[4]), float(record.words[5]));"
    , "    vec2 nExtent = vec2(float(record.words[8]), float(record.words[9]));"
    , "    vec2 nLocal = min(floor(nExtent * inside), nExtent - 1.0);"
    , "    vec2 nAt = (0.5 + nLocal + vec2(float(record.words[6]), float(record.words[7])))"
    , "        / vec2(float(record.words[10]), float(record.words[11]));"
    , "    vec4 base = sampleTexture(record.handles[0], cAt);"
    , "    vec4 map = sampleTexture(record.handles[1], nAt);"
    , "    vec3 offsets = floor(255.0 * map.rgb + 0.5) - 128.0;"
    , "    float squared = dot(offsets, offsets);"
    , "    vec3 facing = (squared <= 0.0) ? vec3(0.0, 0.0, 1.0) : offsets * inversesqrt(squared);"
    , "    float lit = clamp(dot(facing, pushed.lightSun.xyz), 0.0, 1.0);"
    , "    float floorLight = pushed.lightSun.w;"
    , "    float light = floorLight + (1.0 - floorLight) * (pushed.lightDepth.x * lit);"
    , "    float depth = clamp(pushed.lightDepth.w * float(record.words[12]), 0.0, 1.0);"
    , "    float dim = 1.0 - pushed.lightDepth.y * depth;"
    , "    float mist = pushed.lightDepth.z * depth * depth;"
    , "    float cover = map.a * base.a;"
    , "    vec3 colourOut = base.rgb * map.a * light * dim * (1.0 - mist) + pushed.lightHaze.xyz * cover * mist;"
    , "    return vec4(colourOut, cover);"
    , "}"
    ]
