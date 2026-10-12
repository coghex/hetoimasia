-- | The interface descriptions of the shaders
-- "Hetoimasia.GPU.Vulkan.Native.Recording.Shaders" compiles with checked
-- splices (GRS-16). They are their own module because a splice runs them.
module Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces
  ( quadVertexInterface
  , quadFragmentInterface
  , tableVertexInterface
  , tableFragmentInterface
  , tableSamplerOffset
  , tableInstanceVertexInterface
  , tableInstanceFragmentInterface
  , tableInstanceStride
  , storageTableVertexInterface
  , storageTableFragmentInterface
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

-- | One binding of 'tableInstanceStride' bytes a step per instance, and no
-- per-vertex input — the rectangle's corners are the shader's own. In each
-- instance, from the binding's start: the rectangle in clip space as four
-- floats (left, top, right, bottom) at location 0; the texture handle's
-- lookup index at location 1 and its generation at location 2; and the
-- sampler index at location 3, each a 32-bit unsigned integer.
tableInstanceVertexInterface ∷ ShaderInterface
tableInstanceVertexInterface =
  (interfaceFor VertexInterface)
    { interfaceVertexInput =
        VertexInput
          [VertexBinding 0 tableInstanceStride PerInstance]
          [ VertexAttribute 0 0 VertexFloat4 0
          , VertexAttribute 1 0 VertexUint 16
          , VertexAttribute 2 0 VertexUint 20
          , VertexAttribute 3 0 VertexUint 24
          ]
    }

-- | The texture table's bindings (GRS-7) and no push constants: the handle
-- and the sampler index arrive from the vertex stage.
tableInstanceFragmentInterface ∷ ShaderInterface
tableInstanceFragmentInterface = (interfaceFor FragmentInterface) {interfaceDescriptors = textureTableDescriptors}

-- | The bytes of one instance 'tableInstanceVertexInterface' reads: four
-- floats and three unsigned integers.
tableInstanceStride ∷ Word32
tableInstanceStride = 28

-- | No vertex input — the shader makes its own vertices — and the storage
-- table's binding (R2D-15): the rectangle it draws is read from the table the
-- batch bound at set 2.
storageTableVertexInterface ∷ ShaderInterface
storageTableVertexInterface = (interfaceFor VertexInterface) {interfaceDescriptors = storageTableDescriptors}

-- | The storage table's binding and no push constants: the colour it shows is
-- read from the table the batch bound at set 2.
storageTableFragmentInterface ∷ ShaderInterface
storageTableFragmentInterface = (interfaceFor FragmentInterface) {interfaceDescriptors = storageTableDescriptors}
