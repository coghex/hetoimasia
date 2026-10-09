-- | The interface descriptions the scene3d shaders are compiled against
-- (GRS-16): a per-vertex position and normalized colour in, and the cube's
-- transform in the vertex stage's push constants. They are their own module
-- because a splice runs them.
module Hetoimasia.Sample.Scene3d.ShaderInterfaces
  ( scene3dVertexInterface
  , scene3dFragmentInterface
  , transformBytes
  ) where

import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface

-- | One binding, per vertex, 16 bytes a step: the position as three floats at
-- offset 0, then the colour as four normalized bytes at offset 12
-- ("Hetoimasia.Sample.Scene3d.Scene"'s vertices). The push-constant block is
-- one @mat4@, the transform of the cube being drawn.
scene3dVertexInterface ∷ ShaderInterface
scene3dVertexInterface =
  (interfaceFor VertexInterface)
    { interfacePushConstants = [PushMember 0 transformBytes]
    , interfaceVertexInput =
        VertexInput
          [VertexBinding 0 16 PerVertex]
          [ VertexAttribute 0 0 VertexFloat3 0
          , VertexAttribute 1 0 VertexRgba8Unorm 12
          ]
    }

-- | The fragment stage reads only the colour the vertex stage hands it.
scene3dFragmentInterface ∷ ShaderInterface
scene3dFragmentInterface = interfaceFor FragmentInterface

-- | The bytes of the transform: a @mat4@ of 32-bit floats.
transformBytes ∷ Word32
transformBytes = 64
