{-# LANGUAGE OverloadedRecordDot #-}

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
import Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan (colorBlendAttachment, depthAttachmentInfo, nativeDepthState)
import Data.Bits ((.|.))
import Vulkan.Core10 (BlendFactor (..), BlendOp (..), ColorComponentFlagBits (..), CompareOp (..), PipelineColorBlendAttachmentState (..), PipelineDepthStencilStateCreateInfo (..))
import qualified Vulkan.Core10 as Core10
import Vulkan.Core13 (RenderingAttachmentInfo (..))
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

  it "declares premultiplied-alpha blending to the native layer only for a pipeline that asks for it, and none by default (GRS-8)" $ do
    rig ← newRig
    let checked = shaders (vertexWith tint) (fragmentWith tint)
    layout ← createPipelineLayoutFor (rigRecording rig) checked >>= either (fail . show) pure
    plain ← createCheckedPipeline (rigRecording rig) layout checked 37 >>= either (fail . show) pure
    blended ← createBlendedCheckedPipeline (rigRecording rig) layout checked 37 BlendPremultipliedAlpha >>= either (fail . show) pure
    unblended ← createBlendedCheckedPipeline (rigRecording rig) layout checked 37 BlendNone >>= either (fail . show) pure
    calls ← recordingCalls (rigRecordingStandIn rig)
    let made = [handle | CreatedPipeline handle _ _ ← calls]
    length made `shouldBe` 3
    [(handle, blend) | DeclaredBlend handle blend ← calls] `shouldBe` [(made !! 1, BlendPremultipliedAlpha)]
    (plain, blended, unblended) `seq` clean rig

  it "builds the colour attachment's blend state for each declared blend: every channel written, and blending only as declared" $ do
    let channels = COLOR_COMPONENT_R_BIT .|. COLOR_COMPONENT_G_BIT .|. COLOR_COMPONENT_B_BIT .|. COLOR_COMPONENT_A_BIT
        none = colorBlendAttachment BlendNone
        premultiplied = colorBlendAttachment BlendPremultipliedAlpha
    (blendEnable none, colorWriteMask none) `shouldBe` (False, channels)
    ( blendEnable premultiplied
      , srcColorBlendFactor premultiplied
      , dstColorBlendFactor premultiplied
      , colorBlendOp premultiplied
      , srcAlphaBlendFactor premultiplied
      , dstAlphaBlendFactor premultiplied
      , alphaBlendOp premultiplied
      , colorWriteMask premultiplied
      )
      `shouldBe` (True, BLEND_FACTOR_ONE, BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, BLEND_OP_ADD, BLEND_FACTOR_ONE, BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, BLEND_OP_ADD, channels)

  it "declares a checked pipeline's depth to the native layer only when it asks for it, and checks its layout and shaders as it checks any (GRS-10)" $ do
    rig ← newRig
    let checked = shaders (vertexWith tint) (fragmentWith tint)
        reversed = PipelineDepth Depth32Float True False CompareGreaterOrEqual
    layout ← createPipelineLayoutFor (rigRecording rig) checked >>= either (fail . show) pure
    other ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
    plain ← createCheckedPipeline (rigRecording rig) layout checked 37 >>= either (fail . show) pure
    tested ← createDepthCheckedPipeline (rigRecording rig) layout checked 37 BlendNone (depthTested Depth32Float) >>= either (fail . show) pure
    blended ← createDepthCheckedPipeline (rigRecording rig) layout checked 37 BlendPremultipliedAlpha reversed >>= either (fail . show) pure
    calls ← recordingCalls (rigRecordingStandIn rig)
    let made = [handle | CreatedPipeline handle _ _ ← calls]
    length made `shouldBe` 3
    [(handle, depth) | DeclaredDepth handle depth ← calls] `shouldBe` [(made !! 1, depthTested Depth32Float), (made !! 2, reversed)]
    [(handle, blend) | DeclaredBlend handle blend ← calls] `shouldBe` [(made !! 2, BlendPremultipliedAlpha)]
    -- The shaders and the layout are checked first, and a refusal makes no
    -- native call.
    before ← nativeCalls rig
    refused ← createDepthCheckedPipeline (rigRecording rig) other checked 37 BlendNone (depthTested Depth32Float)
    fmap (const ()) refused `shouldBe` Left (RefusedIncompatible "a pipeline layout whose push-constant ranges are not the ones its checked shaders declare")
    unsupported ← createDepthCheckedPipeline (rigRecording rig) layout checked 37 BlendNone (PipelineDepth Depth32Float False True CompareLess)
    fmap (const ()) unsupported `shouldBe` Left (RefusedIllegal "a pipeline that writes depth without testing it")
    nativeCalls rig `shouldReturn` before
    (plain, tested, blended) `seq` clean rig

  it "builds the native depth state and depth attachment from what is declared: the test, the write, the comparison, a view cleared and stored in the depth-attachment layout, and no bounds and no stencil (GRS-10)" $ do
    let state = nativeDepthState (depthTested Depth32Float)
    (depthTestEnable state, depthWriteEnable state, depthCompareOp state) `shouldBe` (True, True, COMPARE_OP_LESS_OR_EQUAL)
    (depthBoundsTestEnable state, stencilTestEnable state) `shouldBe` (False, False)
    let reversed = nativeDepthState (PipelineDepth Depth32Float True False CompareGreaterOrEqual)
    (depthTestEnable reversed, depthWriteEnable reversed, depthCompareOp reversed) `shouldBe` (True, False, COMPARE_OP_GREATER_OR_EQUAL)
    -- Each comparison is the Vulkan operation of the same name.
    map (depthCompareOp . nativeDepthState . PipelineDepth Depth16 True True) [minBound .. maxBound]
      `shouldBe` [ COMPARE_OP_NEVER
                 , COMPARE_OP_LESS
                 , COMPARE_OP_EQUAL
                 , COMPARE_OP_LESS_OR_EQUAL
                 , COMPARE_OP_GREATER
                 , COMPARE_OP_NOT_EQUAL
                 , COMPARE_OP_GREATER_OR_EQUAL
                 , COMPARE_OP_ALWAYS
                 ]
    let info = depthAttachmentInfo (DepthClear 77 0.5)
    (info.imageView, info.imageLayout) `shouldBe` (Core10.ImageView 77, Core10.IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL)
    (info.loadOp, info.storeOp) `shouldBe` (Core10.ATTACHMENT_LOAD_OP_CLEAR, Core10.ATTACHMENT_STORE_OP_STORE)
    case info.clearValue of
      Core10.DepthStencil (Core10.ClearDepthStencilValue depth stencil) → (depth, stencil) `shouldBe` (0.5, 0)
      other → fail ("the attachment clears to " <> show other)

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
                 , Left (RefusedUnsupported "a shader declaring descriptor bindings, which only a pipeline layout holding the texture table declares")
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
