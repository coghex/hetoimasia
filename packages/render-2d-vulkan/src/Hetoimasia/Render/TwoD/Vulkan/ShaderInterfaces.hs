-- | The interface descriptions the ordered path's shaders are compiled
-- against (GRS-16): the instance attributes and the push block in the vertex
-- stage, and the push block, the texture table's bindings and the clip table's
-- binding in the fragment stage. They are their own module because a splice runs
-- them, and they are built from "Hetoimasia.Render.TwoD.Vulkan.Layout" so the
-- shaders, the recorder and the tests agree on every offset.
module Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces
  ( orderedVertexInterface
  , orderedFragmentInterface
  ) where

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
import Hetoimasia.Render.TwoD.Vulkan.Layout (instanceVertexInput, pushMembers, reservedPushMember)

-- | The instance attributes ('instanceVertexInput') and the push block.
orderedVertexInterface ∷ ShaderInterface
orderedVertexInterface =
  (interfaceFor VertexInterface)
    { interfacePushConstants = pushMembers <> [reservedPushMember 0]
    , interfaceVertexInput = instanceVertexInput
    }

-- | The push block, the texture table's bindings and the storage table's
-- binding, which holds the batch's clip tables (R2D-12).
orderedFragmentInterface ∷ ShaderInterface
orderedFragmentInterface =
  (interfaceFor FragmentInterface)
    { interfacePushConstants = pushMembers <> [reservedPushMember 0]
    , interfaceDescriptors = textureTableDescriptors <> storageTableDescriptors
    }
