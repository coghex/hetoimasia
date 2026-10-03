-- | The interface descriptions of the shaders
-- "Hetoimasia.GPU.Vulkan.Native.Recording.Shaders" compiles with checked
-- splices (GRS-16). They are their own module because a splice runs them.
module Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces
  ( quadVertexInterface
  , quadFragmentInterface
  ) where

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
