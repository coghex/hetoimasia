-- | GRS-16's shader-interface contract: the pure reader over committed SPIR-V
-- fixtures, checked shaders that match their descriptions, the unchecked
-- splices' interface-free rule, and each kind of mismatch failing a client's
-- build with a message naming it.
--
-- The reader examples need nothing but the fixtures. The checked shaders were
-- compiled with this suite, and the client examples compile clients against
-- the built package with the provisioned toolchain, as the shader suite's
-- broken-client example does.
module Test.Shader.InterfaceSpec (spec) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.Word (Word32)
import Data.List (isInfixOf)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
import Hetoimasia.GPU.Vulkan.Native.Shader.Reflect
import Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain (fingerprintPath)
import Test.Shader.Checked (matchingFragment, matchingVertex)
import Test.Shader.Fragment (verificationFragment)
import Test.Shader.Interfaces (checkedFragmentInterface, checkedVertexInterface)
import Test.Shader.Vertex (verificationVertex)
import Test.Support.ExternalClient (Client (..), Mode (Typecheck), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Shader interfaces" $ do
  describe "The reader" $ do
    it "reads a vertex shader's push-constant members — a matrix, a vector and an array — and its inputs, but no built-in or varying" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/interface.vert.spv"
      reflect bytes
        `shouldBe` Right
          Reflection
            { reflectionStage = ReflectedVertex
            , reflectionPushMembers = Just [(0, 64), (64, 16), (80, 12)]
            , reflectionInputs =
                [ (0, VectorType (FloatScalar 32) 2)
                , (1, ScalarType (UnsignedScalar 32))
                , (2, VectorType (FloatScalar 32) 4)
                ]
            , reflectionDescriptors = []
            }

    it "reads every descriptor kind, a fixed array's count and a runtime-sized array, and no fragment input" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      reflect bytes
        `shouldBe` Right
          Reflection
            { reflectionStage = ReflectedFragment
            , reflectionPushMembers = Nothing
            , reflectionInputs = []
            , reflectionDescriptors =
                [ ReflectedDescriptor 0 0 ReflectedCombinedImageSampler (ReflectedFixed 1)
                , ReflectedDescriptor 0 1 ReflectedSampledImage (ReflectedFixed 4)
                , ReflectedDescriptor 0 2 ReflectedSampler (ReflectedFixed 1)
                , ReflectedDescriptor 0 3 ReflectedStorageImage (ReflectedFixed 1)
                , ReflectedDescriptor 1 0 ReflectedUniformBuffer (ReflectedFixed 1)
                , ReflectedDescriptor 1 1 ReflectedStorageBuffer (ReflectedFixed 1)
                , ReflectedDescriptor 2 0 ReflectedSampledImage ReflectedRuntime
                ]
            }

    it "refuses an interface construct it does not support rather than reading it as empty or matching" $ do
      nested ← ByteString.readFile "test/fixtures/spirv/nested.frag.spv"
      matrix ← ByteString.readFile "test/fixtures/spirv/matrix.vert.spv"
      reflect nested `shouldSatisfy` failedWith "push-constant member 0 is a nested struct"
      reflect matrix `shouldSatisfy` failedWith "is neither a scalar nor a vector"

    it "refuses an input attachment rather than reading it as a storage image" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/subpass.frag.spv"
      reflect bytes `shouldSatisfy` failedWith "is an input attachment, which the reader does not support"

    it "refuses a push-constant member whose extent is beyond what 32 bits can hold, rather than wrapping it" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/overflow.frag.spv"
      reflect bytes `shouldSatisfy` failedWith "push-constant member 0 reaches byte 4294967300, beyond what 32 bits can hold"

    it "refuses an interface naming an id the module defines no variable for, rather than reading it as empty" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      -- Every variable's definition removed, its entry point's references kept.
      reflect (without (\instruction → opcodeOf instruction == 59) bytes) `shouldSatisfy` failedWith "which the module defines no variable for"

    it "refuses a buffer whose struct is undefined or not a Block, and a combined image sampler over an undefined image" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      let decorating which instruction = case wordsOf instruction of
            first : _ : decorated : _ → first .&. 0xFFFF == 71 && decorated == which
            _ → False
      -- Every Block (2) decoration removed: the uniform block is refused.
      reflect (without (decorating 2) bytes) `shouldSatisfy` failedWith "whose struct is not a Block"
      -- Every struct definition removed: the buffers' pointers reach types no
      -- longer defined.
      reflect (without (\instruction → opcodeOf instruction == 30) bytes) `shouldSatisfy` failedWith "which the module does not declare"
      -- Every image type removed: the first descriptor, a combined image
      -- sampler, reaches one no longer defined.
      reflect (without (\instruction → opcodeOf instruction == 25) bytes) `shouldSatisfy` failedWith "which the module does not declare"

    it "refuses any type an interface variable reaches that the module does not define: a buffer member's runtime array, an image's sampled type" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      -- Every runtime-array type removed: the storage buffer's member, and
      -- the table's, now name types no longer defined.
      reflect (without (\instruction → opcodeOf instruction == 29) bytes) `shouldSatisfy` failedWith "which the module does not declare"
      -- Every image's sampled type replaced by an id the module never defines.
      reflect (rewriting (\instruction → if opcodeOf instruction == 25 then replaceWord 2 0xFFFFF instruction else instruction) bytes)
        `shouldSatisfy` failedWith "reaches an image whose sampled type (id 1048575) the module does not declare"

    it "refuses a vertex input that starts past its location's first component" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/component.vert.spv"
      reflect bytes `shouldSatisfy` failedWith "the vertex input at location 0 starts at component 1, which the reader does not support"

    it "refuses a descriptor variable lacking its DescriptorSet and Binding, rather than dropping it" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      -- Every DescriptorSet (34) and Binding (33) decoration removed.
      let decorates which instruction = case wordsOf instruction of
            first : _ : decorated : _ → first .&. 0xFFFF == 71 && decorated `elem` which
            _ → False
      reflect (without (decorates [33, 34]) bytes) `shouldSatisfy` failedWith "has neither a DescriptorSet nor a Binding"
      reflect (without (decorates [33]) bytes) `shouldSatisfy` failedWith "has a DescriptorSet or a Binding but not both"

    it "refuses a module that is not well-formed SPIR-V" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/interface.vert.spv"
      reflect (ByteString.take 12 bytes) `shouldSatisfy` failedWith "shorter than its header"
      reflect (ByteString.replicate 20 0) `shouldSatisfy` failedWith "magic number"
      reflect (ByteString.take (ByteString.length bytes - 1) bytes) `shouldSatisfy` failedWith "not a whole number of words"
      -- The header, and the first word of the first instruction, a capability
      -- two words long.
      reflect (ByteString.take 24 bytes) `shouldSatisfy` failedWith "ends inside an instruction"

    it "finds no interface in the interface-free verification pair, whose built-in and varyings it does not report" $ do
      fmap foundInterface (reflect verificationVertex) `shouldBe` Right []
      fmap foundInterface (reflect verificationFragment) `shouldBe` Right []

  describe "Checked shaders" $ do
    it "carry their descriptions beside SPIR-V that matches them, in the source and file forms" $ do
      checkedInterface matchingVertex `shouldBe` checkedVertexInterface
      checkedInterface matchingFragment `shouldBe` checkedFragmentInterface
      fmap (compareInterface checkedVertexInterface) (reflect (checkedSpirv matchingVertex)) `shouldBe` Right []
      fmap (compareInterface checkedFragmentInterface) (reflect (checkedSpirv matchingFragment)) `shouldBe` Right []

    it "compare in both directions, naming each mismatch" $ do
      bytes ← ByteString.readFile "test/fixtures/spirv/descriptors.frag.spv"
      let declared =
            (interfaceFor FragmentInterface)
              { interfacePushConstants = [PushMember 0 16]
              , interfaceDescriptors =
                  [ DescriptorDeclaration 0 0 SampledImage (DescriptorCount 1)
                  , DescriptorDeclaration 0 1 SampledImage (DescriptorCount 2)
                  , DescriptorDeclaration 2 0 SampledImage (DescriptorCount 8)
                  , DescriptorDeclaration 3 0 Sampler (DescriptorCount 1)
                  ]
              }
      fmap (map renderMismatch . compareInterface declared) (reflect bytes)
        `shouldBe` Right
          [ "the push-constant block is declared but absent from the shader"
          , "descriptor set 3, binding 0 is declared but absent from the shader"
          , "descriptor set 0, binding 2 (Sampler) is present in the shader but undeclared"
          , "descriptor set 0, binding 3 (StorageImage) is present in the shader but undeclared"
          , "descriptor set 1, binding 0 (UniformBuffer) is present in the shader but undeclared"
          , "descriptor set 1, binding 1 (StorageBuffer) is present in the shader but undeclared"
          , "descriptor set 0, binding 0 is declared with type SampledImage, but the shader's is CombinedImageSampler"
          , "descriptor set 0, binding 1 is declared with count 2, but the shader's is 4"
          , "descriptor set 2, binding 0 is declared with count 8, but the shader's is runtime-sized"
          ]

  describe "A client's build" $ do
    let mismatch name description glsl' expected =
          it name $ withClient (checkedClient description glsl') $ \built → do
            built `rejectedBecause` "the fragment shader spliced at Client.hs:"
            built `rejectedBecause` "in module Client does not match its interface description"
            built `rejectedBecause` expected
        tintBlock = "layout(push_constant) uniform Pushed { vec4 first; vec4 second; } pushed;\nlayout(location = 0) out vec4 colour;\nvoid main() { colour = pushed.first + pushed.second; }"
        sampled binding count =
          "layout(set = "
            <> fst binding
            <> ", binding = "
            <> snd binding
            <> ") uniform sampler2D images["
            <> count
            <> "];\nlayout(location = 0) out vec4 colour;\nvoid main() { colour = texture(images[0], vec2(0.0)); }"
    mismatch
      "fails on a push-constant member's offset"
      "(interfaceFor FragmentInterface) { interfacePushConstants = [PushMember 0 16, PushMember 8 16] }"
      tintBlock
      "push-constant member 1 is declared at offset 8 with size 16, but the shader has offset 16 and size 16"
    mismatch
      "fails on a push-constant member's size"
      "(interfaceFor FragmentInterface) { interfacePushConstants = [PushMember 0 16, PushMember 16 8] }"
      tintBlock
      "push-constant member 1 is declared at offset 16 with size 8, but the shader has offset 16 and size 16"
    mismatch
      "fails on a descriptor's set"
      "(interfaceFor FragmentInterface) { interfaceDescriptors = [DescriptorDeclaration 0 0 CombinedImageSampler (DescriptorCount 2)] }"
      (sampled ("1", "0") "2")
      "descriptor set 1, binding 0 (CombinedImageSampler) is present in the shader but undeclared"
    mismatch
      "fails on a descriptor's binding number"
      "(interfaceFor FragmentInterface) { interfaceDescriptors = [DescriptorDeclaration 0 1 CombinedImageSampler (DescriptorCount 2)] }"
      (sampled ("0", "2") "2")
      "descriptor set 0, binding 2 (CombinedImageSampler) is present in the shader but undeclared"
    mismatch
      "fails on a descriptor's type"
      "(interfaceFor FragmentInterface) { interfaceDescriptors = [DescriptorDeclaration 0 0 SampledImage (DescriptorCount 2)] }"
      (sampled ("0", "0") "2")
      "descriptor set 0, binding 0 is declared with type SampledImage, but the shader's is CombinedImageSampler"
    mismatch
      "fails on a descriptor's count"
      "(interfaceFor FragmentInterface) { interfaceDescriptors = [DescriptorDeclaration 0 0 CombinedImageSampler (DescriptorCount 3)] }"
      (sampled ("0", "0") "2")
      "descriptor set 0, binding 0 is declared with count 3, but the shader's is 2"
    mismatch
      "fails on something declared but absent from the shader"
      "(interfaceFor FragmentInterface) { interfacePushConstants = [PushMember 0 16] }"
      "layout(location = 0) out vec4 colour;\nvoid main() { colour = vec4(1.0); }"
      "the push-constant block is declared but absent from the shader"
    mismatch
      "fails on something present in the shader but undeclared"
      "interfaceFor FragmentInterface"
      tintBlock
      "a push-constant block of 2 members is present in the shader but undeclared"

    it "fails on a vertex input's location" $
      withClient (checkedVertexClient "VertexAttribute 0 0 VertexFloat2 0" "layout(location = 1) in vec2 position;") $ \built → do
        built `rejectedBecause` "the vertex shader spliced at Client.hs:"
        built `rejectedBecause` "vertex input location 0 is declared but absent from the shader"
        built `rejectedBecause` "vertex input location 1 (32-bit float vector of 2) is present in the shader but undeclared"

    it "fails on a vertex input's format" $
      withClient (checkedVertexClient "VertexAttribute 0 0 VertexFloat3 0" "layout(location = 0) in vec2 position;") $ \built →
        built `rejectedBecause` "vertex input location 0 is declared with format VertexFloat3, but the shader reads it as a 32-bit float vector of 2"

    it "fails an unchecked splice over a shader that declares an interface, naming what it found" $
      withClient (uncheckedClient tintBlock) $ \built → do
        built `rejectedBecause` "the fragment shader spliced at Client.hs:"
        built `rejectedBecause` "declares an interface, which only a checked splice may compile"
        built `rejectedBecause` "a push-constant block of 2 members"
  where
    failedWith fragment = either (fragment `isInfixOf`) (const False)

-- | A module with every instruction the predicate selects removed, its header
-- and every other instruction kept.
without ∷ (ByteString.ByteString → Bool) → ByteString.ByteString → ByteString.ByteString
without removed bytes = ByteString.concat (header : [instruction | instruction ← instructions body, not (removed instruction)])
  where
    (header, body) = ByteString.splitAt 20 bytes
    instructions rest
      | ByteString.null rest = []
      | otherwise =
          let count = fromIntegral (firstWord rest `shiftR` 16) * 4
              (instruction, remaining) = ByteString.splitAt count rest
           in instruction : instructions remaining

-- | A module with every instruction passed through the function, its header
-- kept.
rewriting ∷ (ByteString.ByteString → ByteString.ByteString) → ByteString.ByteString → ByteString.ByteString
rewriting change bytes = ByteString.concat (header : map change (split body))
  where
    (header, body) = ByteString.splitAt 20 bytes
    split rest
      | ByteString.null rest = []
      | otherwise =
          let (instruction, remaining) = ByteString.splitAt (fromIntegral (firstWord rest `shiftR` 16) * 4) rest
           in instruction : split remaining

-- | An instruction with its word at this index — the opcode word is 0 —
-- replaced, in this host's byte order.
replaceWord ∷ Int → Word32 → ByteString.ByteString → ByteString.ByteString
replaceWord index value instruction =
  ByteString.take (index * 4) instruction
    <> ByteString.pack [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]
    <> ByteString.drop ((index + 1) * 4) instruction

-- | An instruction's words, in this host's byte order, and its opcode.
wordsOf ∷ ByteString.ByteString → [Word32]
wordsOf chunk
  | ByteString.null chunk = []
  | otherwise =
      let (word, rest) = ByteString.splitAt 4 chunk
       in foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack word) : wordsOf rest

opcodeOf ∷ ByteString.ByteString → Word32
opcodeOf instruction = firstWord instruction .&. 0xFFFF

firstWord ∷ ByteString.ByteString → Word32
firstWord chunk = case wordsOf (ByteString.take 4 chunk) of
  word : _ → word
  [] → 0

-- | Compile one client against the built package with a copy of this
-- package's fingerprint, and hand its outcome to the example. The first
-- compile only learns the client's directory: without a fingerprint its
-- splice refuses at once.
withClient ∷ String → (Client → Expectation) → Expectation
withClient source use = do
  fingerprint ← readFile fingerprintPath
  withStorePackageClient clientPackages "Client.hs" source $ \compile → do
    unconfigured ← compile Typecheck
    let copy = clientDirectory unconfigured </> fingerprintPath
    createDirectoryIfMissing True (takeDirectory copy)
    writeFile copy fingerprint
    compile Typecheck >>= use

clientPackages ∷ [String]
clientPackages = ["base", "bytestring", "hetoimasia-gpu-vulkan-native-0.1.0.0-inplace"]

clientHeader ∷ [String]
clientHeader =
  [ "{-# LANGUAGE TemplateHaskell #-}"
  , "module Client (shader) where"
  , ""
  , "import Hetoimasia.GPU.Vulkan.Native.Shader"
  , "import Hetoimasia.GPU.Vulkan.Native.Shader.Interface"
  , ""
  ]

-- | A client checking a fragment shader against a description written in the
-- splice's own argument.
checkedClient ∷ String → String → String
checkedClient description body =
  unlines
    ( clientHeader
        <> [ "shader :: CheckedShader"
           , "shader = $(checkedFragmentShader (" <> description <> ") " <> show ("#version 450\n" <> body <> "\n") <> ")"
           ]
    )

-- | A client checking a vertex shader with one input against a description
-- declaring one attribute.
checkedVertexClient ∷ String → String → String
checkedVertexClient attribute input =
  unlines
    ( clientHeader
        <> [ "shader :: CheckedShader"
           , "shader = $(checkedVertexShader ((interfaceFor VertexInterface) { interfaceVertexInput = VertexInput [VertexBinding 0 8 PerVertex] [" <> attribute <> "] }) "
               <> show ("#version 450\n" <> input <> "\nvoid main() { gl_Position = vec4(position.xy, 0.0, 1.0); }\n")
               <> ")"
           ]
    )

-- | A client compiling a fragment shader with the unchecked splice.
uncheckedClient ∷ String → String
uncheckedClient body =
  unlines
    ( clientHeader
        <> [ "import Data.ByteString (ByteString)"
           , ""
           , "shader :: ByteString"
           , "shader = $(fragmentShader " <> show ("#version 450\n" <> body <> "\n") <> ")"
           ]
    )
