-- | The interface descriptions of the shaders
-- "Hetoimasia.GPU.Vulkan.Native.Recording.Shaders" compiles with checked
-- splices (GRS-16). They are their own module because a splice runs them.
module Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces
  ( quadVertexInterface
  , quadFragmentInterface
  , tableVertexInterface
  , tableFragmentInterface
  , tableSamplerOffset
  ) where

import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface

-- | A two-float position per vertex at location 0, from binding 0, and a
-- two-float offset per instance at location 1, from binding 1, each binding
-- eight bytes a step.
quadVertexInterface ∷ ShaderInterface
quadVertexInterface =
  (interfaceFor VertexInterface)
    { interfaceVertexInput =
        VertexInput
          [VertexBinding 0 8 PerVertex, VertexBinding 1 8 PerInstance]
          [VertexAttribute 0 0 VertexFloat2 0, VertexAttribute 1 1 VertexFloat2 0]
    }

-- | A four-float color, the fragment stage's push constants at offset 0.
quadFragmentInterface ∷ ShaderInterface
quadFragmentInterface = (interfaceFor FragmentInterface) {interfacePushConstants = [PushMember 0 16]}

-- | No vertex input and no push constants: the corners and coordinates are
-- the shader's own.
tableVertexInterface ∷ ShaderInterface
tableVertexInterface = interfaceFor VertexInterface

-- | The texture table's bindings (GRS-7), and in the push constants a
-- texture handle — its lookup index and generation — at offset 0 and the
-- sampler index at 'tableSamplerOffset'.
tableFragmentInterface ∷ ShaderInterface
tableFragmentInterface =
  (interfaceFor FragmentInterface)
    { interfacePushConstants = [PushMember 0 8, PushMember tableSamplerOffset 4]
    , interfaceDescriptors = textureTableDescriptors
    }

-- | Where the table shaders read the sampler index 'selectSampler' pushes.
tableSamplerOffset ∷ Word32
tableSamplerOffset = 8
