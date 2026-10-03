{-# LANGUAGE DeriveLift #-}

-- | Shader interface descriptions (GRS-16, D-19): what a shader declares it
-- reads from the host, written in Haskell beside its GLSL, and checked
-- against its compiled SPIR-V while the package builds.
--
-- A 'ShaderInterface' names its stage and everything the host must supply:
--
-- * its push-constant block, as each member's offset and size in bytes, in
--   declaration order — empty when it declares no block;
-- * for a vertex shader, its vertex input as the pipeline binds it: the
--   'VertexInput' of "Hetoimasia.GPU.Vulkan.Native.Recording", whose bindings
--   carry what SPIR-V cannot say — whether a binding advances per vertex or
--   per instance, its stride, and each attribute's binding, byte offset and
--   storage format — and whose attributes' locations and formats are checked
--   against the shader's own inputs;
-- * its descriptor bindings: each one's set, binding, kind and count, a fixed
--   count or a runtime-sized array.
--
-- 'compareInterface' compares a description with what
-- "Hetoimasia.GPU.Vulkan.Native.Shader.Reflect" read from the SPIR-V, in both
-- directions: something declared but absent from the shader, something
-- present in the shader but undeclared, and a stage, offset, size, format,
-- kind or count that disagrees are each a 'Mismatch'. The checked splices of
-- "Hetoimasia.GPU.Vulkan.Native.Shader" fail the build on any of them, and a
-- shader that passes is a 'CheckedShader': its SPIR-V with its description,
-- which a pipeline takes its push-constant ranges and vertex input from.
--
-- A description is a Haskell value a splice runs, so it is defined in another
-- module, or written whole in the splice's argument, as for any splice.
module Hetoimasia.GPU.Vulkan.Native.Shader.Interface
  ( -- * Descriptions
    InterfaceStage (..)
  , ShaderInterface (..)
  , interfaceFor
  , PushMember (..)
  , DescriptorKind (..)
  , DescriptorCount (..)
  , DescriptorDeclaration (..)
  , textureTableDescriptors

    -- * Vertex input, as a pipeline binds it
  , VertexInput (..)
  , VertexBinding (..)
  , VertexAttribute (..)
  , InputRate (..)
  , VertexFormat (..)
  , noVertexInput

    -- * Checked shaders
  , CheckedShader (..)
  , CheckedShaders (..)

    -- * Comparing a description with a shader
  , Mismatch (..)
  , compareInterface
  , renderMismatch
  , foundInterface
  ) where

import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Word (Word32)
import Language.Haskell.TH.Syntax (Lift)

import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( InputRate (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexFormat (..)
  , VertexInput (..)
  , noVertexInput
  )
import Hetoimasia.GPU.Vulkan.Native.Shader.Reflect
  ( ReflectedCount (..)
  , ReflectedDescriptor (..)
  , ReflectedKind (..)
  , ReflectedStage (..)
  , ReflectedType (..)
  , Reflection (..)
  , ScalarKind (..)
  , renderReflectedType
  )

-- | The stage a description is for.
data InterfaceStage = VertexInterface | FragmentInterface
  deriving (Eq, Ord, Show, Enum, Bounded, Lift)

-- | A shader's external interface, as the host declares it.
data ShaderInterface = ShaderInterface
  { interfaceStage ∷ !InterfaceStage
  , interfacePushConstants ∷ ![PushMember]
    -- ^ Its push-constant block's members, in declaration order; empty for a
    -- shader with no block.
  , interfaceVertexInput ∷ !VertexInput
    -- ^ A vertex shader's input as the pipeline binds it; 'noVertexInput' for
    -- one with none, and for a fragment shader.
  , interfaceDescriptors ∷ ![DescriptorDeclaration]
  }
  deriving (Eq, Show, Lift)

-- | A description of a shader of this stage that declares nothing.
interfaceFor ∷ InterfaceStage → ShaderInterface
interfaceFor stage = ShaderInterface stage [] noVertexInput []

-- | One push-constant block member: its offset and its size, in bytes.
data PushMember = PushMember
  { pushMemberOffset ∷ !Word32
  , pushMemberSize ∷ !Word32
  }
  deriving (Eq, Ord, Show, Lift)

-- | What kind of descriptor a binding is.
data DescriptorKind
  = CombinedImageSampler
  | SampledImage
  | StorageImage
  | Sampler
  | UniformBuffer
  | StorageBuffer
  deriving (Eq, Ord, Show, Enum, Bounded, Lift)

-- | How many descriptors a binding is: a fixed count, compared exactly, or a
-- runtime-sized array, whose capacity is the layout's and whose filled count
-- is the allocation's — neither of which a shader states.
data DescriptorCount = DescriptorCount !Word32 | RuntimeSized
  deriving (Eq, Ord, Show, Lift)

data DescriptorDeclaration = DescriptorDeclaration
  { descriptorSet ∷ !Word32
  , descriptorBinding ∷ !Word32
  , descriptorKind ∷ !DescriptorKind
  , descriptorCount ∷ !DescriptorCount
  }
  deriving (Eq, Ord, Show, Lift)

-- | The texture table's bindings (GRS-7; resource services design D-22,
-- D-31, D-35), as a shader that reads the table declares them: set 0's four
-- samplers at binding 0 and its runtime-sized sampled-image array at binding
-- 1, and set 1's lookup buffer at binding 0. A stage declares those it reads;
-- a pipeline layout holding the table admits no other binding.
textureTableDescriptors ∷ [DescriptorDeclaration]
textureTableDescriptors =
  [ DescriptorDeclaration 0 0 Sampler (DescriptorCount 4)
  , DescriptorDeclaration 0 1 SampledImage RuntimeSized
  , DescriptorDeclaration 1 0 StorageBuffer (DescriptorCount 1)
  ]

-- | A shader whose interface was checked against its description while the
-- package built: its SPIR-V, and that description. The checked splices make
-- them; one made by hand asserts a description nothing checked.
data CheckedShader = CheckedShader
  { checkedSpirv ∷ !ByteString
  , checkedInterface ∷ !ShaderInterface
  }
  deriving (Eq, Show)

-- | The two checked stages of a graphics pipeline.
data CheckedShaders = CheckedShaders
  { checkedVertex ∷ !CheckedShader
  , checkedFragment ∷ !CheckedShader
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Comparison

-- | One way a description and a shader disagree.
data Mismatch
  = StageMismatch !InterfaceStage !ReflectedStage
  | PushDeclaredAbsent
  | PushPresentUndeclared ![(Word32, Word32)]
  | PushMemberCount !Int !Int
    -- ^ How many members the description declares, and the shader has.
  | PushMemberMismatch !Int !PushMember !(Word32, Word32)
    -- ^ A member's index, as declared, and as the shader has it.
  | FragmentVertexInput
    -- ^ A fragment description declaring vertex input.
  | InputDeclaredAbsent !Word32
  | InputPresentUndeclared !Word32 !ReflectedType
  | InputFormatMismatch !Word32 !VertexFormat !ReflectedType
  | DescriptorDeclaredAbsent !Word32 !Word32
  | DescriptorPresentUndeclared !Word32 !Word32 !ReflectedKind
  | DescriptorKindMismatch !Word32 !Word32 !DescriptorKind !ReflectedKind
  | DescriptorCountMismatch !Word32 !Word32 !DescriptorCount !ReflectedCount
  deriving (Eq, Show)

-- | Every way the description and what the shader's SPIR-V says disagree,
-- in both directions; none means they match.
compareInterface ∷ ShaderInterface → Reflection → [Mismatch]
compareInterface interface found =
  stage <> push <> inputs <> descriptors
  where
    stage = case (interfaceStage interface, reflectionStage found) of
      (VertexInterface, ReflectedVertex) → []
      (FragmentInterface, ReflectedFragment) → []
      (declared, other) → [StageMismatch declared other]
    push = case (interfacePushConstants interface, reflectionPushMembers found) of
      ([], Nothing) → []
      (_ : _, Nothing) → [PushDeclaredAbsent]
      ([], Just members) → [PushPresentUndeclared members]
      (declared, Just members)
        | length declared /= length members → [PushMemberCount (length declared) (length members)]
        | otherwise →
            [ PushMemberMismatch index member present
            | (index, member, present) ← zip3 [0 ..] declared members
            , (pushMemberOffset member, pushMemberSize member) /= present
            ]
    attributes = inputAttributes (interfaceVertexInput interface)
    inputs = case interfaceStage interface of
      FragmentInterface → [FragmentVertexInput | not (null attributes)]
      VertexInterface →
        [InputDeclaredAbsent (attributeLocation attribute) | attribute ← attributes, attributeLocation attribute `notElem` map fst (reflectionInputs found)]
          <> [ InputPresentUndeclared location kind
             | (location, kind) ← reflectionInputs found
             , location `notElem` map attributeLocation attributes
             ]
          <> [ InputFormatMismatch location (attributeFormat attribute) kind
             | attribute ← attributes
             , (location, kind) ← reflectionInputs found
             , location == attributeLocation attribute
             , not (formatFits (attributeFormat attribute) kind)
             ]
    declaredDescriptors = interfaceDescriptors interface
    key descriptor = (descriptorSet descriptor, descriptorBinding descriptor)
    reflectedKey reflected' = (reflectedSet reflected', reflectedBinding reflected')
    descriptors =
      [ uncurry DescriptorDeclaredAbsent (key declared)
      | declared ← sort declaredDescriptors
      , key declared `notElem` map reflectedKey (reflectionDescriptors found)
      ]
        <> [ DescriptorPresentUndeclared (reflectedSet reflected') (reflectedBinding reflected') (reflectedKind reflected')
           | reflected' ← reflectionDescriptors found
           , reflectedKey reflected' `notElem` map key declaredDescriptors
           ]
        <> concat
          [ [DescriptorKindMismatch set binding (descriptorKind declared) (reflectedKind reflected') | not (kindFits (descriptorKind declared) (reflectedKind reflected'))]
              <> [DescriptorCountMismatch set binding (descriptorCount declared) (reflectedCount reflected') | not (countFits (descriptorCount declared) (reflectedCount reflected'))]
          | declared ← sort declaredDescriptors
          , reflected' ← reflectionDescriptors found
          , key declared == reflectedKey reflected'
          , let (set, binding) = key declared
          ]

-- | Whether a vertex format is read as this shader type: one to four 32-bit
-- floats for the float formats, a 32-bit unsigned integer for the unsigned
-- one, and four floats for four normalized bytes.
formatFits ∷ VertexFormat → ReflectedType → Bool
formatFits format kind = case (format, kind) of
  (VertexFloat, ScalarType (FloatScalar 32)) → True
  (VertexFloat2, VectorType (FloatScalar 32) 2) → True
  (VertexFloat3, VectorType (FloatScalar 32) 3) → True
  (VertexFloat4, VectorType (FloatScalar 32) 4) → True
  (VertexUint, ScalarType (UnsignedScalar 32)) → True
  (VertexRgba8Unorm, VectorType (FloatScalar 32) 4) → True
  _ → False

kindFits ∷ DescriptorKind → ReflectedKind → Bool
kindFits declared found = case (declared, found) of
  (CombinedImageSampler, ReflectedCombinedImageSampler) → True
  (SampledImage, ReflectedSampledImage) → True
  (StorageImage, ReflectedStorageImage) → True
  (Sampler, ReflectedSampler) → True
  (UniformBuffer, ReflectedUniformBuffer) → True
  (StorageBuffer, ReflectedStorageBuffer) → True
  _ → False

countFits ∷ DescriptorCount → ReflectedCount → Bool
countFits declared found = case (declared, found) of
  (DescriptorCount count, ReflectedFixed present) → count == present
  (RuntimeSized, ReflectedRuntime) → True
  _ → False

-- | A mismatch as a build failure names it.
renderMismatch ∷ Mismatch → String
renderMismatch = \case
  StageMismatch declared found → "the description is for the " <> stageName declared <> " stage, but the shader is " <> reflectedStageName found
  PushDeclaredAbsent → "the push-constant block is declared but absent from the shader"
  PushPresentUndeclared members → "a push-constant block of " <> show (length members) <> " members is present in the shader but undeclared"
  PushMemberCount declared found → "the push-constant block is declared with " <> show declared <> " members, but the shader's has " <> show found
  PushMemberMismatch index member (offset, size) →
    "push-constant member "
      <> show index
      <> " is declared at offset "
      <> show (pushMemberOffset member)
      <> " with size "
      <> show (pushMemberSize member)
      <> ", but the shader has offset "
      <> show offset
      <> " and size "
      <> show size
  FragmentVertexInput → "the fragment description declares vertex input, which only a vertex shader reads"
  InputDeclaredAbsent location → "vertex input location " <> show location <> " is declared but absent from the shader"
  InputPresentUndeclared location kind → "vertex input location " <> show location <> " (" <> renderReflectedType kind <> ") is present in the shader but undeclared"
  InputFormatMismatch location format kind →
    "vertex input location " <> show location <> " is declared with format " <> show format <> ", but the shader reads it as a " <> renderReflectedType kind
  DescriptorDeclaredAbsent set binding → "descriptor set " <> show set <> ", binding " <> show binding <> " is declared but absent from the shader"
  DescriptorPresentUndeclared set binding kind →
    "descriptor set " <> show set <> ", binding " <> show binding <> " (" <> reflectedKindName kind <> ") is present in the shader but undeclared"
  DescriptorKindMismatch set binding declared found →
    "descriptor set " <> show set <> ", binding " <> show binding <> " is declared with type " <> show declared <> ", but the shader's is " <> reflectedKindName found
  DescriptorCountMismatch set binding declared found →
    "descriptor set " <> show set <> ", binding " <> show binding <> " is declared with count " <> countName declared <> ", but the shader's is " <> reflectedCountName found
  where
    stageName = \case
      VertexInterface → "vertex"
      FragmentInterface → "fragment"
    reflectedStageName = \case
      ReflectedVertex → "a vertex shader"
      ReflectedFragment → "a fragment shader"
      ReflectedOther model → "of execution model " <> show model
    reflectedKindName = \case
      ReflectedCombinedImageSampler → "CombinedImageSampler"
      ReflectedSampledImage → "SampledImage"
      ReflectedStorageImage → "StorageImage"
      ReflectedSampler → "Sampler"
      ReflectedUniformBuffer → "UniformBuffer"
      ReflectedStorageBuffer → "StorageBuffer"
    countName = \case
      DescriptorCount count → show count
      RuntimeSized → "runtime-sized"
    reflectedCountName = \case
      ReflectedFixed count → show count
      ReflectedRuntime → "runtime-sized"

-- | What an unchecked splice found that only a checked one may compile: the
-- shader's push-constant block, its vertex inputs, and its descriptor
-- bindings, each named; none for an interface-free shader.
foundInterface ∷ Reflection → [String]
foundInterface found =
  maybe [] (\members → ["a push-constant block of " <> show (length members) <> " members"]) (reflectionPushMembers found)
    <> ["vertex input location " <> show location <> " (" <> renderReflectedType kind <> ")" | (location, kind) ← reflectionInputs found]
    <> ["descriptor set " <> show (reflectedSet each) <> ", binding " <> show (reflectedBinding each) | each ← reflectionDescriptors found]
