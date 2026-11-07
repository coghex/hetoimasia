-- | The GLSL of the terrain material's fragment function (TRA-8), in a module of
-- its own because a Template Haskell splice may use only what another module
-- defines.
--
-- The record it reads is the layout of "Hetoimasia.Terrain.Render2D.Material":
-- one handle, the art sheet, and these words, floats by their bit patterns:
--
-- > w0..w2   a b c   art u = a·u + b·v + c
-- > w3..w5   d e f   art v = d·u + e·v + f
-- > w6       n       the mask's vertex count
-- > w7..     x0 y0 x1 y1 …
--
-- The function samples the sheet at the art coordinates unconditionally (its
-- implicit derivatives need uniform control flow), then covers the fragment by
-- the mask: a convex polygon, closed, of either orientation, so a fragment is
-- outside exactly when two of its edge functions have opposite signs. Outside is
-- transparent black; inside is the sheet's texel, whose alpha is binary wherever
-- the sheet's is, as a cutout-capable material promises.
--
-- State, ownership and lifetime: none.
module Hetoimasia.Terrain.Render2D.Vulkan.Source
  ( terrainSource
  ) where

import Hetoimasia.Terrain.Render2D.Material (maxMaskVertices)

-- | The material function's source.
terrainSource ∷ String
terrainSource =
  unlines
    [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
    , "    vec2 art = vec2("
    , "        uintBitsToFloat(record.words[0]) * uv.x + uintBitsToFloat(record.words[1]) * uv.y + uintBitsToFloat(record.words[2]),"
    , "        uintBitsToFloat(record.words[3]) * uv.x + uintBitsToFloat(record.words[4]) * uv.y + uintBitsToFloat(record.words[5]));"
    , "    vec4 sampled = sampleTexture(record.handles[0], art);"
    , "    uint count = record.words[6];"
    , "    bool positive = false;"
    , "    bool negative = false;"
    , "    for (uint i = 0u; i < " <> show maxMaskVertices <> "u; i++) {"
    , "        if (i < count) {"
    , "            uint j = (i + 1u == count) ? 0u : i + 1u;"
    , "            vec2 from = vec2(uintBitsToFloat(record.words[7u + 2u * i]), uintBitsToFloat(record.words[8u + 2u * i]));"
    , "            vec2 to = vec2(uintBitsToFloat(record.words[7u + 2u * j]), uintBitsToFloat(record.words[8u + 2u * j]));"
    , "            float edge = (to.x - from.x) * (uv.y - from.y) - (to.y - from.y) * (uv.x - from.x);"
    , "            positive = positive || edge > 0.0;"
    , "            negative = negative || edge < 0.0;"
    , "        }"
    , "    }"
    , "    return (positive && negative) ? vec4(0.0) : sampled;"
    , "}"
    ]
