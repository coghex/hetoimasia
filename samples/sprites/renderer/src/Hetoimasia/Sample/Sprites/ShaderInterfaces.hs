-- | The interface descriptions the sprites shaders are compiled against
-- (GRS-16): a per-vertex unit-quad corner and a per-instance rectangle,
-- texture-coordinate rectangle and texture handle in, and the texture table's
-- bindings and the draw's sampler index in the fragment stage. They are their
-- own module because a splice runs them.
module Hetoimasia.Sample.Sprites.ShaderInterfaces
  ( spritesVertexInterface
  , spritesFragmentInterface
  , samplerOffset
  ) where

import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
import Hetoimasia.GPU.Vulkan.Native.TextureTable (textureTableDescriptors)

-- | Binding 0, per vertex: the unit quad's corner as two floats. Binding 1,
-- per instance, 40 bytes a step: the rectangle in target pixels and the
-- texture-coordinate rectangle as four floats each, then the texture
-- handle's lookup index and generation as unsigned integers.
spritesVertexInterface ∷ ShaderInterface
spritesVertexInterface =
  (interfaceFor VertexInterface)
    { interfaceVertexInput =
        VertexInput
          [VertexBinding 0 8 PerVertex, VertexBinding 1 40 PerInstance]
          [ VertexAttribute 0 0 VertexFloat2 0
          , VertexAttribute 1 1 VertexFloat4 0
          , VertexAttribute 2 1 VertexFloat4 16
          , VertexAttribute 3 1 VertexUint 32
          , VertexAttribute 4 1 VertexUint 36
          ]
    }

-- | The texture table's bindings, and in the push constants the draw's
-- sampler index at 'samplerOffset'.
spritesFragmentInterface ∷ ShaderInterface
spritesFragmentInterface =
  (interfaceFor FragmentInterface)
    { interfacePushConstants = [PushMember samplerOffset 4]
    , interfaceDescriptors = textureTableDescriptors
    }

-- | Where the fragment stage reads the sampler index the draw selects.
samplerOffset ∷ Word32
samplerOffset = 0
