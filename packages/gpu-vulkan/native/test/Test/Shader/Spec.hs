-- | VK-9's shader contract: what the embedded SPIR-V is, what a compile
-- registers, how a failure is reported, and which fingerprints are refused.
--
-- None of it needs a display, a device, a loader session or consent: the
-- compiler is a child process, and nothing here creates a Vulkan object. It
-- does need the provisioned toolchain, because the embedded shaders were
-- compiled by it and the runtime entry runs it; the suite is built and run by
-- @tools\/vulkan-proof\/run-shaders.sh@, which generates the fingerprint first.
module Test.Shader.Spec (spec) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (isInfixOf)
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain
  ( CompileRequest (..)
  , CompiledShader (..)
  , Fingerprint (..)
  , FingerprintInputs (..)
  , ShaderSite (..)
  , ShaderSource (..)
  , ShaderStage (..)
  , Toolchain
  , ToolchainFailure (..)
  , compileShader
  , fingerprintPath
  , generateFingerprint
  , loadToolchain
  , parseFingerprint
  , renderFingerprint
  , renderShaderFailure
  , renderToolchainFailure
  , toolchainFingerprint
  , vulkan13
  )
import Test.Shader.Constants (verificationMarker, verificationTagLocation)
import Test.Shader.Fragment (verificationFragment)
import Test.Shader.Vertex (verificationVertex)
import Test.Support.ExternalClient (Client (..), Mode (Typecheck), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Shaders" $ do
  describe "The embedded verification pair" $ do
    it "is SPIR-V 1.6, the version the vulkan1.3 target environment produces" $ do
      take 2 (spirvWords verificationVertex) `shouldBe` [spirvMagic, 0x00010600]
      take 2 (spirvWords verificationFragment) `shouldBe` [spirvMagic, 0x00010600]

    it "carries the interpolated Haskell constant into the compiled vertex module" $
      spirvWords verificationVertex `shouldContain` [verificationMarker]

    it "carries the interpolated layout location into the vertex module's interface" $
      locations verificationVertex `shouldBe` [fromIntegral verificationTagLocation]

    it "resolves the fragment shader's location through its transitive include" $
      -- The fragment's output is location 0; its input's location is defined
      -- only in the include of its include.
      locations verificationFragment `shouldMatchList` [0, fromIntegral verificationTagLocation]

  describe "The runtime compile entry" $ do
    it "compiles the fragment file to the bytes the splice embedded, reporting the source and both includes" $
      withToolchain $ \toolchain → do
        root ← getCurrentDirectory
        compileShader toolchain root (request Fragment (SourceFile "test/shaders/verification.frag")) >>= \case
          Left failure → expectationFailure (renderShaderFailure failure)
          Right compiled → do
            compiledSpirv compiled `shouldBe` verificationFragment
            compiledInputs compiled
              `shouldMatchList` [ "test/shaders/verification.frag"
                                , "test/shaders/include/verification_interface.glsl"
                                , "test/shaders/include/verification_layout.glsl"
                                ]
            compiledWarnings compiled `shouldBe` []

    it "names the module, the site, the stage and the compiler's message for a broken shader" $
      withToolchain $ \toolchain → do
        root ← getCurrentDirectory
        compileShader toolchain root (request Fragment (InlineSource brokenShader)) >>= \case
          Right _ → expectationFailure "a shader using an undeclared identifier compiled"
          Left failure → do
            let said = renderShaderFailure failure
            said `shouldContain` "the fragment shader spliced at test/Test/Shader/Runtime.hs:12:7"
            said `shouldContain` "in module Test.Shader.Runtime"
            said `shouldContain` "target vulkan1.3"
            said `shouldContain` "glslang"
            said `shouldContain` "'undeclaredColour' : undeclared identifier"

    it "refuses a shader whose include resolves outside the package root" $
      withToolchain $ \toolchain → do
        root ← getCurrentDirectory
        withSystemTempDirectory "hetoimasia-outside" $ \outside → do
          writeFile (outside </> "outside.glsl") "const float outside = 1.0;\n"
          let source =
                "#version 450\n\
                \#extension GL_GOOGLE_include_directive : require\n\
                \#include \"outside.glsl\"\n\
                \layout(location = 0) out vec4 colour;\n\
                \void main() { colour = vec4(outside); }\n"
          compileShader toolchain root (request Fragment (InlineSource source)) {requestIncludes = [outside]}
            >>= \case
              Right _ → expectationFailure "an include outside the package root was accepted"
              Left failure → renderShaderFailure failure `shouldContain` "outside the package root"

  describe "The toolchain fingerprint" $ do
    it "describes the provisioned wrapper, compiler and manifest as they are now" $
      withToolchain $ \toolchain → do
        let fingerprint = toolchainFingerprint toolchain
        fingerprintTarget fingerprint `shouldBe` "vulkan1.3"
        fingerprintFlags fingerprint `shouldBe` ["-V"]

    it "round-trips through its file, and a reader refuses a field it does not know" $ do
      let fingerprint = Fingerprint "vulkan1.3" ["-V"] "/w" "aa" "15.0.0" "/c" "bb" "/m" "cc"
      parseFingerprint (renderFingerprint fingerprint) `shouldBe` Right fingerprint
      parseFingerprint (renderFingerprint fingerprint <> "optimize yes\n") `shouldSatisfy` either ("unknown fields optimize" `isInfixOf`) (const False)

    it "refuses one generated against another prefix, naming the wrapper and manifest identity it expected" $ do
      loadToolchain "test/fixtures/foreign.fingerprint" >>= \case
        Right _ → expectationFailure "a fingerprint naming a nonexistent wrapper was trusted"
        Left failure → do
          let said = renderToolchainFailure failure
          said `shouldContain` "/nonexistent/foreign-prefix/vulkan/bin/glslangValidator"
          said `shouldContain` "expected identity 2222222222222222222222222222222222222222222222222222222222222222"
          said `shouldContain` "No other glslangValidator is used"

    it "refuses one whose recorded compiler identity was edited, rather than trusting it" $
      withToolchain $ \toolchain → withSystemTempDirectory "hetoimasia-fingerprint" $ \directory → do
        let edited = (toolchainFingerprint toolchain) {fingerprintVersion = "99.0.0"}
            path = directory </> "toolchain.fingerprint"
        writeFile path (renderFingerprint edited)
        loadToolchain path >>= \case
          Right _ → expectationFailure "a fingerprint recording another compiler version was trusted"
          Left failure → refusalReason failure `shouldContain` "glslang is now"

    it "refuses a missing fingerprint, naming where it looked" $
      loadToolchain "test/fixtures/absent.fingerprint" >>= \case
        Right _ → expectationFailure "a missing fingerprint was accepted"
        Left failure → refusalReason failure `shouldContain` "no shader toolchain fingerprint at test/fixtures/absent.fingerprint"

    it "is generated only from a wrapper the native manifest records, naming the manifest's identity" $
      withToolchain $ \toolchain → withSystemTempDirectory "hetoimasia-wrapper" $ \directory → do
        let impostor = directory </> "glslangValidator"
            manifest = fingerprintManifest (toolchainFingerprint toolchain)
            identity = fingerprintManifestSha256 (toolchainFingerprint toolchain)
        missing ← generateFingerprint (FingerprintInputs (Just impostor) (Just manifest))
        case missing of
          Right _ → expectationFailure "a fingerprint was generated for a wrapper that does not exist"
          Left failure → do
            let said = renderToolchainFailure failure
            said `shouldContain` ("no glslangValidator wrapper at " <> impostor)
            said `shouldContain` ("native manifest: " <> manifest <> " (expected identity " <> identity <> ")")
        writeFile impostor "#!/bin/sh\nexit 0\n"
        makeExecutable impostor
        substituted ← generateFingerprint (FingerprintInputs (Just impostor) (Just manifest))
        fmap refusalReason (either Just (const Nothing) substituted)
          `shouldSatisfy` maybe False (("records the wrapper " <> fingerprintWrapper (toolchainFingerprint toolchain)) `isInfixOf`)

  describe "A shader spliced outside this package" $
    it "fails that build, naming the module, the splice, the stage and the compiler's message" $
      withToolchain $ \_ → do
        fingerprint ← readFile fingerprintPath
        withStorePackageClient clientPackages "Broken.hs" brokenClient $ \compile → do
          -- Without a fingerprint of its own the splice refuses, saying where
          -- it looked; with a copy of this package's, it compiles and fails.
          unconfigured ← compile Typecheck
          unconfigured `rejectedBecause` "no shader toolchain fingerprint at shaders/toolchain.fingerprint"
          let copy = clientDirectory unconfigured </> fingerprintPath
          createDirectoryIfMissing True (takeDirectory copy)
          writeFile copy fingerprint
          broken ← compile Typecheck
          broken `rejectedBecause` "the fragment shader spliced at Broken.hs:9:"
          broken `rejectedBecause` "in module Broken (inline source, target vulkan1.3)"
          broken `rejectedBecause` "'undeclaredColour' : undeclared identifier"
  where
    request stage source =
      CompileRequest
        { requestSite = ShaderSite "Test.Shader.Runtime" "test/Test/Shader/Runtime.hs" 12 7
        , requestTarget = vulkan13
        , requestStage = stage
        , requestIncludes = []
        , requestSource = source
        }

-- | The package's own fingerprint, loaded and checked, or a failure saying
-- why the suite cannot run.
withToolchain ∷ (Toolchain → Expectation) → Expectation
withToolchain use =
  loadToolchain fingerprintPath >>= \case
    Left failure → expectationFailure (renderToolchainFailure failure)
    Right toolchain → use toolchain

brokenShader ∷ String
brokenShader =
  "#version 450\n\
  \layout(location = 0) out vec4 colour;\n\
  \void main() { colour = undeclaredColour; }\n"

-- | A client module whose one splice does not compile.
brokenClient ∷ String
brokenClient =
  unlines
    [ "{-# LANGUAGE TemplateHaskell #-}"
    , "module Broken (broken) where"
    , ""
    , "import Data.ByteString (ByteString)"
    , "import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShader)"
    , ""
    , "broken ∷ ByteString"
    , "broken ="
    , "  $(fragmentShader " <> show brokenShader <> ")"
    ]

clientPackages ∷ [String]
clientPackages = ["base", "bytestring", "hetoimasia-gpu-vulkan-native-0.1.0.0-inplace"]

makeExecutable ∷ FilePath → IO ()
makeExecutable path = do
  permissions ← getPermissions path
  setPermissions path (setOwnerExecutable True permissions)

spirvMagic ∷ Word32
spirvMagic = 0x07230203

-- | A module's words, in the byte order the compiler wrote: this host's, which
-- is little-endian on every platform this repository builds for.
spirvWords ∷ ByteString → [Word32]
spirvWords bytes
  | ByteString.null bytes = []
  | otherwise =
      let (word, rest) = ByteString.splitAt 4 bytes
       in foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack word) : spirvWords rest

-- | Every @Location@ an @OpDecorate@ assigns.
locations ∷ ByteString → [Word32]
locations bytes = go (drop 5 (spirvWords bytes))
  where
    go [] = []
    go (first : rest) =
      let count = fromIntegral (first `shiftR` 16)
          opcode = first .&. 0xFFFF
          operands = take (count - 1) rest
          found = case operands of
            [_, decoration, location] | opcode == opDecorate && decoration == decorationLocation → [location]
            _ → []
       in if count == 0 then [] else found <> go (drop (count - 1) rest)
    opDecorate = 71
    decorationLocation = 30
