-- | The interface descriptions the checked test shaders are compiled against
-- (GRS-16). They are their own module because a splice runs them.
module Test.Shader.Interfaces
  ( checkedVertexInterface
  , checkedFragmentInterface
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface

-- | A two-float position per vertex from binding 0, a four-float color per
-- instance from binding 1, and a four-float tint in the push constants.
checkedVertexInterface ∷ ShaderInterface
checkedVertexInterface =
  ShaderInterface
    { interfaceStage = VertexInterface
    , interfacePushConstants = [PushMember 0 16]
    , interfaceVertexInput =
        VertexInput
          [VertexBinding 0 8 PerVertex, VertexBinding 1 16 PerInstance]
          [VertexAttribute 0 0 VertexFloat2 0, VertexAttribute 1 1 VertexFloat4 0]
    , interfaceDescriptors = []
    }

-- | The same tint, a combined image sampler, a fixed pair of images, a
-- sampler, and a runtime-sized table of images.
checkedFragmentInterface ∷ ShaderInterface
checkedFragmentInterface =
  ShaderInterface
    { interfaceStage = FragmentInterface
    , interfacePushConstants = [PushMember 0 16]
    , interfaceVertexInput = noVertexInput
    , interfaceDescriptors =
        [ DescriptorDeclaration 0 0 CombinedImageSampler (DescriptorCount 1)
        , DescriptorDeclaration 0 1 SampledImage (DescriptorCount 2)
        , DescriptorDeclaration 0 2 Sampler (DescriptorCount 1)
        , DescriptorDeclaration 1 0 SampledImage RuntimeSized
        ]
    }
