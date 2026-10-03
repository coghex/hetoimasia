-- | Pipelines from checked shaders (GRS-16) over the recording's stand-in
-- native layer: a layout with exactly the push-constant ranges the shaders'
-- descriptions need — one stage's, the other's, or both stages' alike — a
-- pipeline taking its vertex input from the vertex description, and every
-- disagreement refused before any native call, on creation and replacement
-- alike: stages whose blocks differ, a shader declaring descriptor bindings, a
-- stage given the other stage's shader, and a supplied layout declaring other
-- ranges.
--
-- The shaders' bytes are stand-ins: the descriptions are what is asserted.
-- Nothing here creates a Vulkan object.
module Test.GPU.Vulkan.Native.Checked (spec) where

import qualified Data.ByteString as ByteString
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (DescriptorCount (..), DescriptorDeclaration (..), DescriptorKind (..), InterfaceStage (..), PushMember (..), ShaderInterface (..), interfaceFor)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), recordingCalls)

spec ∷ Spec
spec = describe "Pipelines from checked shaders" $ do
  it "needs one range per stage that declares a block, one range for both stages declaring the same block, and none for neither" $ do
    checkedRanges (shaders (vertexWith tint) fragmentPlain) `shouldBe` Right [PushConstantRange [PushVertex] 0 16]
    checkedRanges (shaders vertexPlain (fragmentWith tint)) `shouldBe` Right [PushConstantRange [PushFragment] 0 16]
    checkedRanges (shaders (vertexWith tint) (fragmentWith tint)) `shouldBe` Right [PushConstantRange [PushVertex, PushFragment] 0 16]
    checkedRanges (shaders vertexPlain fragmentPlain) `shouldBe` Right []
    checkedRanges (shaders (vertexWith [PushMember 16 16, PushMember 32 4]) fragmentPlain) `shouldBe` Right [PushConstantRange [PushVertex] 16 20]
    -- An extent beyond what 32 bits can hold is refused, never wrapped.
    checkedRanges (shaders (vertexWith [PushMember 4294967292 8]) fragmentPlain) `shouldBe` Left (RefusedOutOfBounds 4294967300 4294967295)

  it "makes the layout the descriptions need, and a pipeline whose vertex input is the vertex description's" $ do
    rig ← newRig
    let checked = shaders (vertexWith tint) (fragmentWith tint)
    layout ← createPipelineLayoutFor (rigRecording rig) checked >>= either (fail . show) pure
    _ ← createCheckedPipeline (rigRecording rig) layout checked 37 >>= either (fail . show) pure
    calls ← recordingCalls (rigRecordingStandIn rig)
    [ranges | DeclaredRanges _ ranges ← calls] `shouldBe` [[PushConstantRange [PushVertex, PushFragment] 0 16]]
    [input | DeclaredInput _ input ← calls] `shouldBe` [quadInput]
    length [() | CreatedPipeline {} ← calls] `shouldBe` 1
    clean rig

  it "refuses disagreeing stages, descriptor bindings, a misassigned stage and a layout with other ranges, making no native call" $ do
    rig ← newRig
    let checked = shaders (vertexWith tint) fragmentPlain
    layout ← createPipelineLayoutFor (rigRecording rig) checked >>= either (fail . show) pure
    other ← createPipelineLayoutWith (rigRecording rig) [PushConstantRange [PushVertex, PushFragment] 0 16] >>= either (fail . show) pure
    before ← nativeCalls rig
    answers ←
      sequence
        [ createPipelineLayoutFor (rigRecording rig) (shaders (vertexWith tint) (fragmentWith [PushMember 0 8])) >>= pure . fmap (const ())
        , createCheckedPipeline (rigRecording rig) layout (shaders (vertexWith tint) (fragmentWith [PushMember 0 8])) 37 >>= pure . fmap (const ())
        , createCheckedPipeline (rigRecording rig) layout (shaders (vertexWith tint) fragmentSampling) 37 >>= pure . fmap (const ())
        , createCheckedPipeline (rigRecording rig) layout (shaders (fragmentWith tint) fragmentPlain) 37 >>= pure . fmap (const ())
        , createCheckedPipeline (rigRecording rig) other checked 37 >>= pure . fmap (const ())
        ]
    answers
      `shouldBe` [ Left (RefusedIncompatible "vertex and fragment stages whose push-constant blocks disagree")
                 , Left (RefusedIncompatible "vertex and fragment stages whose push-constant blocks disagree")
                 , Left (RefusedUnsupported "a shader declaring descriptor bindings, which no pipeline layout declares yet")
                 , Left (RefusedIncompatible "a vertex stage whose shader is not a vertex shader's")
                 , Left (RefusedIncompatible "a pipeline layout whose push-constant ranges are not the ones its checked shaders declare")
                 ]
    nativeCalls rig `shouldReturn` before
    clean rig

  it "keeps the descriptions authoritative through a replacement, refusing a layout with other ranges before any native call" $ do
    rig ← newRig
    let checked = shaders (vertexWith tint) fragmentPlain
    layout ← createPipelineLayoutFor (rigRecording rig) checked >>= either (fail . show) pure
    other ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
    pipeline ← createCheckedPipeline (rigRecording rig) layout checked 37 >>= either (fail . show) pure
    before ← nativeCalls rig
    refused ← replaceCheckedPipeline (rigRecording rig) pipeline other checked 37
    fmap (const ()) refused `shouldBe` Left (RefusedIncompatible "a pipeline layout whose push-constant ranges are not the ones its checked shaders declare")
    nativeCalls rig `shouldReturn` before
    replaced ← replaceCheckedPipeline (rigRecording rig) pipeline layout checked 37
    fmap (const ()) replaced `shouldBe` Right ()
    calls ← recordingCalls (rigRecordingStandIn rig)
    length [input | DeclaredInput _ input ← calls, input == quadInput] `shouldBe` 2
    clean rig
  where
    tint = [PushMember 0 16]

-- | A vertex description reading 'quadInput', with these push-constant
-- members.
vertexWith ∷ [PushMember] → ShaderInterface
vertexWith members = (interfaceFor VertexInterface) {interfacePushConstants = members, interfaceVertexInput = quadInput}

vertexPlain ∷ ShaderInterface
vertexPlain = vertexWith []

fragmentWith ∷ [PushMember] → ShaderInterface
fragmentWith members = (interfaceFor FragmentInterface) {interfacePushConstants = members}

fragmentPlain ∷ ShaderInterface
fragmentPlain = fragmentWith []

fragmentSampling ∷ ShaderInterface
fragmentSampling = fragmentPlain {interfaceDescriptors = [DescriptorDeclaration 0 0 CombinedImageSampler (DescriptorCount 1)]}

shaders ∷ ShaderInterface → ShaderInterface → CheckedShaders
shaders vertex fragment =
  CheckedShaders (CheckedShader (ByteString.pack [1, 2, 3, 4]) vertex) (CheckedShader (ByteString.pack [5, 6, 7, 8]) fragment)

quadInput ∷ VertexInput
quadInput =
  VertexInput
    [VertexBinding 0 8 PerVertex, VertexBinding 1 8 PerInstance]
    [VertexAttribute 0 0 VertexFloat2 0, VertexAttribute 1 1 VertexFloat2 0]

-- | How many layouts and pipelines the stand-in has been asked to create.
nativeCalls ∷ Rig → IO Int
nativeCalls rig = (\calls → length [() | call ← calls, created call]) <$> recordingCalls (rigRecordingStandIn rig)
  where
    created = \case
      CreatedLayout _ → True
      CreatedPipeline {} → True
      _ → False
