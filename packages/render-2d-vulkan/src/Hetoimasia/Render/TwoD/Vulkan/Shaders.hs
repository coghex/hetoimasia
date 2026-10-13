{-# LANGUAGE TemplateHaskell #-}

-- | The recorder's shaders (R2D-7, R2D-9), compiled while the package builds
-- and checked against "Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces" (GRS-16),
-- under the shader-sampled table layout (R2D-16). The GLSL is in
-- "Hetoimasia.Render.TwoD.Vulkan.ShaderSources".
--
-- = Vertex stage
--
-- Shared by the ordered and the cutout pipelines. For each instance and each of
-- the six corners of the unit square [0, 1]² (two triangles, from
-- @gl_VertexIndex@), with the instance's transform @(a, b, c, d, tx, ty)@ and
-- the view's @(va, vb, vc, vd, vtx, vty)@, in target pixels:
--
-- > world  = (a·x + c·y + tx, b·x + d·y + ty)
-- > target = (va·wx + vc·wy + vtx, vb·wx + vd·wy + vty)
-- > origin = (va·tx + vc·ty + vtx, vb·tx + vd·ty + vty)         the mapped (0, 0)
-- > shift  = floor(origin + ½) − origin                          when the view snaps, else 0
-- >                                                              (evaluated exactly: floor(origin) plus 1 when its fraction is at least ½)
-- > clip   = ((target + shift) / extent) · 2 − 1                 Vulkan's Y down
-- > depth  = (2²⁴ − 1 − k) / 2²⁴                                 for the instance's key k, constant across the quad
-- > clip   = flags >> 16                                         the instance's clip index, passed on flat
--
-- so with snap on the quad moves rigidly until its origin lands on
-- @floor(p + ½)@ of its mapped origin, the arithmetic of
-- 'Hetoimasia.Render.TwoD.Mapping.snapPoint'. The texture coordinates
-- interpolate affinely from @(u0, v0)@ at (0, 0) to @(u1, v1)@ at (1, 1). The
-- handle, the tint, the flags and the parameter word pass on as flat values. The
-- depth is written to every pipeline's position, but only a pipeline that tests
-- or writes depth reads it back, in a pass that has a depth attachment.
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
-- > s = m × c
--
-- The ordered variant ('orderedShaders'):
--
-- > s.rgb = s.rgb × b                    wrapMaterial: tint, then brightness
-- > s.a = 0 for an additive instance     blendOutput
-- > result = s + destination × (1 − s.a) the pipeline's premultiplied blend
--
-- The cutout variant ('cutoutShaders', design D-26), drawn only for an
-- instance whose tint alpha is 255 and which is not additive:
--
-- > discard when s.a < ½
-- > result = (s.rgb / s.a) × b, alpha 1  un-premultiplied by the sample's own alpha
--
-- so a filtered edge sample @(0.6, 0.6, 0.6, 0.6)@ writes white, not grey.
--
-- = Clipping (R2D-12, design D-11)
--
-- Both variants end with the clip test, after the sample is taken, so a quad's
-- neighbouring invocations keep their derivatives. With the instance's clip
-- index @k@ (the flags word's top 16 bits), the view's @clipBase@ and the
-- table the batch bound as set 2, binding 0:
--
-- > k = 0                          no clip: nothing is read
-- > r = rectangles[clipBase + k − 1]                  (left, top, right, bottom)
-- > p = inverseLinear · (gl_FragCoord.xy − clipCentre)   the pixel centre's offset, in the layer's space
-- > discard unless  r.left ≤ p.x < r.right  and  r.top ≤ p.y < r.bottom
--
-- The table's edges were written as their distance from the layer-space point
-- under @clipCentre@ (see "Hetoimasia.Render.TwoD.Vulkan.Layout"), so the test
-- never forms an absolute coordinate in the layer's space, which in single
-- precision is too coarse far from the origin: a view looking at world
-- coordinates near 65536 at a zoom of 100 would misplace an edge by most of a
-- pixel. @inverseLinear@ is the linear part of the exact inverse of the
-- transform the layer's instances are placed with, so a sprite's own origin snap
-- neither moves nor is undone by the clip, and the view's snapped translation (in
-- the reference), the zoom, the rotation, and the UI scale and content scale
-- are all in it. A discarded fragment writes neither
-- colour nor depth, in the ordered and the cutout variant alike. Instances of
-- different clip indices share one draw: the index travels with the instance.
--
-- Material, wrapping and output are separate functions, and both variants share
-- the lookup, the sampler choice and the material, so an application material
-- (R2D-11) replaces @material@ alone and cannot omit the tint, the brightness
-- or the output.
module Hetoimasia.Render.TwoD.Vulkan.Shaders
  ( orderedShaders
  , cutoutShaders
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader)
import Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces (orderedFragmentInterface, orderedVertexInterface)
import Hetoimasia.Render.TwoD.Vulkan.ShaderSources (cutoutTail, fragmentPrelude, orderedTail, vertexSource)

-- | The ordered path's shaders: premultiplied-alpha blending's source.
orderedShaders ∷ CheckedShaders
orderedShaders =
  CheckedShaders
    { checkedVertex = $(checkedVertexShader orderedVertexInterface vertexSource)
    , checkedFragment = $(checkedFragmentShader orderedFragmentInterface (fragmentPrelude <> orderedTail))
    }

-- | The cutout path's shaders: the same vertex stage and the cutout variant of
-- the fragment stage.
cutoutShaders ∷ CheckedShaders
cutoutShaders =
  CheckedShaders
    { checkedVertex = $(checkedVertexShader orderedVertexInterface vertexSource)
    , checkedFragment = $(checkedFragmentShader orderedFragmentInterface (fragmentPrelude <> cutoutTail))
    }
