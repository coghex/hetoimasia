-- | Application materials (R2D-11) in the recorder: what the splice recorded and
-- checked, registration and the references it issues, the records and push blocks
-- of views and chunks as the recorder writes and pushes them, a material's
-- pipelines, what the recorder refuses, the holds a record's textures take, and a
-- deliberately misdeclared material in a separately compiled module.
--
-- __Where the expected values come from.__ Never from the code under test. The
-- facts a material was declared with are written here from its declaration, the
-- record bytes and bases are worked out by hand from the layout (a record is
-- @2 × handles + words@ words, tables back to back in the order the first run
-- that reads each appears), the commands are the ones the native layer was asked
-- to record, and the pipelines' shaders are compared with the SPIR-V the splice
-- compiled.
module Test.Render.TwoD.Vulkan.Materials (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder (floatLE, toLazyByteString, word32LE)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ImageFormat (..)
  , NativeCommand (..)
  , PipelineBlend (..)
  , PipelineDepth (..)
  , PipelineRequest (..)
  , PipelineShaders (..)
  , PushStage (..)
  , Refusal (..)
  , formatCode
  , validateRingSize
  , validateStorageWindow
  )
import qualified Hetoimasia.GPU.Vulkan.Native.Recording as Native
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShader (..), CheckedShaders (..), fingerprintPath)
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
  ( DescriptorCount (..)
  , DescriptorDeclaration (..)
  , DescriptorKind (..)
  , PushMember (..)
  , ShaderInterface (..)
  , storageTableDescriptors
  , textureTableDescriptors
  )
import Control.Concurrent.STM (atomically)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (LookupEntry (..), TableView (..), readTable, validateTableConfig)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex, textureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Material
import Hetoimasia.Render.TwoD.Material.Backend (materialRef, materialRefIdentity)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (Location (..), ValidSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout
import Hetoimasia.Render.TwoD.Vulkan.Chunks (buildRetainedChunkWith)
import Hetoimasia.Render.TwoD.Vulkan.Material
import Hetoimasia.Render.TwoD.Vulkan.Material.Sample (mixMaterial, tintOnlyMaterial, translucentMixMaterial)
import Hetoimasia.Render.TwoD.Vulkan.MaterialSources (declarationProblems, laidBytes, laidOffsets, layOut)
import Hetoimasia.Render.TwoD.Vulkan.Shaders (cutoutShaders, orderedShaders)
import Hetoimasia.Render.TwoD.Vulkan.Textures (MarkPolicy (..), registeredMarks, releaseTextureNow)
import Hetoimasia.Render.TwoD.Vulkan.Window
import System.Exit (ExitCode (ExitSuccess))
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Vulkan.Environment
import Test.Render.TwoD.Vulkan.Materials.Layouts (handlesOnlyMaterial, wordsOnlyMaterial)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Materials" $ do
  declarationSpec
  splicedSpec
  registrationSpec
  recordingSpec
  pipelineSpec
  refusalSpec
  publicationSpec
  externalSpec

-- ---------------------------------------------------------------------------
-- Fixtures

target16 ∷ TargetRef
target16 = targetRef 2 1

-- | A unit sprite of the default texture at this x and depth key.
unit ∷ MaterialRef → Word32 → Float → Word32 → Instance
unit material parameter x key =
  Instance
    { instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 x 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = textureHandle 1 1
    , instanceDepthKey = key
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceParameter = parameter
    , instanceMaterial = material
    }

-- | The 16 × 16 view over the plain camera holding this data and these layers.
viewHolding ∷ [(MaterialRef, MaterialData)] → [Layer] → View
viewHolding held layers =
  ViewWith (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] (Map.fromList held) layers

-- | Two floats, little-endian: the sample material's push block.
twoFloats ∷ Float → Float → ByteString
twoFloats a b = Lazy.toStrict (toLazyByteString (floatLE a <> floatLE b))

-- | A colour as four floats: the tint-only material's push block.
colour ∷ Float → Float → Float → Float → ByteString
colour r g b a = Lazy.toStrict (toLazyByteString (floatLE r <> floatLE g <> floatLE b <> floatLE a))

words' ∷ [Word32] → ByteString
words' = Lazy.toStrict . toLazyByteString . foldMap word32LE

-- | A record of these handles (index, generation) and words.
record ∷ [(Word32, Word32)] → [Word32] → MaterialRecord
record handles = MaterialRecord [textureHandle index generation | (index, generation) ← handles]

validated ∷ [(ChunkRef, Chunk)] → [Pass] → ValidSnapshot
validated held passes = case validateSnapshotWith (chunksFrom held) (Snapshot passes) of
  Right found → found
  Left refused → error ("the fixture was refused: " <> show refused)

onePass ∷ [(ChunkRef, Chunk)] → [View] → ValidSnapshot
onePass held views = validated held [Pass (OffscreenTarget target16) (ClearColour 0 0 0 1) views]

-- | A frame into the 16 × 16 target with a depth image, planned with these marks.
frameFor ∷ Rig → CutoutMarks → ImageFormat → ValidSnapshot → IO FrameInput
frameFor rig marks format snapshot = do
  image ← target rig format 16 16
  depth ← depthTarget rig Depth32Float 16 16
  pure
    ( FrameInput
        snapshot
        marks
        (\_ → Just (TargetBinding image (offscreenAttachment format 16 16) (Just (DepthBinding depth Depth32Float))))
        Nothing
        Nothing
        (const Nothing)
        Set.empty
    )

-- | A renderer over a ring of 64 KiB, a window of 4 KiB and a table of 16 slots.
rendererOver ∷ Rig → IO Render.Renderer
rendererOver rig = do
  renderer ←
    newRenderer
      rig
      Render.Configuration
        { Render.configurationRing = either (error . show) id (validateRingSize (64 * 1024))
        , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
        , Render.configurationRegionWindow = either (error . show) id (validateStorageWindow 4096)
        }
  resetJournal rig
  pure renderer

-- | A fresh rig and renderer, with the three sample materials registered.
data Fixtures = Fixtures
  { fixRig ∷ !Rig
  , fixRenderer ∷ !Render.Renderer
  , fixMix ∷ !MaterialRef
  , fixTranslucent ∷ !MaterialRef
  , fixTint ∷ !MaterialRef
  }

withFixtures ∷ (Fixtures → IO a) → IO a
withFixtures action = do
  rig ← newRig
  renderer ← rendererOver rig
  mix ← Render.registerMaterial renderer mixMaterial
  translucent ← Render.registerMaterial renderer translucentMixMaterial
  tint ← Render.registerMaterial renderer tintOnlyMaterial
  action (Fixtures rig renderer mix translucent tint)

-- | Prepare a frame and record it into a frame-less batch.
recorded ∷ Fixtures → FrameInput → IO (Either FrameRefusal ())
recorded fixtures input =
  Render.prepareSnapshot (builders (fixRig fixtures)) (fixRenderer fixtures) input >>= \case
    Left refusal → pure (Left refusal)
    Right recording → framelessOnce (fixRig fixtures) recording

-- | What the examples read of the commands.
data Seen
  = SeenPipeline
  | SeenTable
  | SeenStorage
  | SeenPush ![PushStage] !Word32 !ByteString
  | SeenBind !Word64
  | SeenDraw !Word32
  | SeenClear
  deriving (Eq, Show)

seen ∷ [NativeCommand] → [Seen]
seen = concatMap $ \case
  CommandBindPipeline _ → [SeenPipeline]
  CommandBindDescriptorSets {} → [SeenTable]
  CommandBindStorageSet {} → [SeenStorage]
  CommandPushConstants _ stages offset bytes → [SeenPush stages offset bytes]
  CommandBindVertexBuffer _ _ offset → [SeenBind offset]
  CommandDraw _ instances _ _ → [SeenDraw instances]
  CommandClearDepthRect {} → [SeenClear]
  _ → []

-- | The engine's block for a 16 × 16 UI layer at scale one.
enginePush ∷ ByteString
enginePush = packViewPush (ViewPush (fromColumns (V2 1 0) (V2 0 1) (V2 0 0)) (fromColumns (V2 1 (-0.0)) (V2 (-0.0) 1) (V2 0 0)) 0 (0, 0) (16, 16) 1 FilterNearest False)

both ∷ [PushStage]
both = [PushVertex, PushFragment]

-- | The material a pipeline was made for, by the shaders it was made with.
shaderLabels ∷ Fixtures → [(String, PipelineShaders)]
shaderLabels _ =
  [ ("default", shadersOf orderedShaders)
  , ("default cutout", shadersOf cutoutShaders)
  , ("mix", shadersOf (definedTranslucent mixMaterial))
  , ("translucent mix", shadersOf (definedTranslucent translucentMixMaterial))
  , ("tint", shadersOf (definedTranslucent tintOnlyMaterial))
  ]
    <> [("mix cutout", shadersOf cutout) | Just cutout ← [definedCutout mixMaterial]]
    <> [("tint cutout", shadersOf cutout) | Just cutout ← [definedCutout tintOnlyMaterial]]

shadersOf ∷ CheckedShaders → PipelineShaders
shadersOf (CheckedShaders vertex fragment) = PipelineShaders (checkedSpirv vertex) (checkedSpirv fragment)

-- | The label of the pipeline bound at each draw, with the instances it draws.
drawnWith ∷ Fixtures → [NativeCommand] → IO [(String, Word32)]
drawnWith fixtures commands = do
  made ← pipelineHandles (fixRig fixtures)
  let labelOf handle = do
        request ← lookup handle made
        case [name | (name, shaders) ← shaderLabels fixtures, shaders == requestShaders request] of
          name : _ → Just name
          [] → Nothing
      go _ [] = []
      go bound (command : rest) = case command of
        CommandBindPipeline handle → go (labelOf handle) rest
        CommandDraw _ instances _ _ → (maybe "?" id bound, instances) : go bound rest
        _ → go bound rest
  pure (go Nothing commands)

-- ---------------------------------------------------------------------------
-- Declarations

declarationSpec ∷ Spec
declarationSpec = describe "a material's declaration" $ do
  it "lays a push block out in std430 from the start of the application's block, each member at its alignment" $ do
    [(name, offset) | PushOffset name _ offset ← laidOffsets (layOut [PushField "a" PushFloat, PushField "b" PushVec2, PushField "c" PushVec4, PushField "d" PushUint])]
      `shouldBe` [("a", 0), ("b", 8), ("c", 16), ("d", 32)]
    laidBytes (layOut [PushField "a" PushFloat, PushField "b" PushVec2, PushField "c" PushVec4, PushField "d" PushUint]) `shouldBe` 36
    laidBytes (layOut []) `shouldBe` 0
    laidBytes (layOut [PushField "x" PushFloat, PushField "y" PushFloat]) `shouldBe` 8

  it "starts the application's block at 80 and lets it hold 48 bytes, which together with the engine's part fill the 128 every device holds" $ do
    applicationPushOffset `shouldBe` 80
    applicationPushLimit `shouldBe` 48
    maxPushBytes `shouldBe` 128
    applicationPushOffset + applicationPushLimit `shouldBe` maxPushBytes
    -- the engine's 76 bytes, then four of alignment
    fromIntegral pushBytes `shouldSatisfy` (<= applicationPushOffset)
    (applicationPushOffset `mod` 16) `shouldBe` 0

  it "refuses a push block beyond the limit, naming its size and the limit, and accepts one that fills it exactly" $ do
    let over = declaration {declaredPush = replicate 4 (PushField "x" PushVec4)}
    -- four members would all be named "x": the size is the problem named first.
    take 1 (declarationProblems over) `shouldSatisfy` all ("64 bytes, beyond the limit of 48 bytes" `isInfixOf`)
    let named n = PushField ("m" <> show (n ∷ Int)) PushVec4
        exact = declaration {declaredPush = map named [0 .. 2]}
    declarationProblems exact `shouldBe` []
    declarationProblems exact {declaredPush = map named [0 .. 3]} `shouldSatisfy` any ("64 bytes" `isInfixOf`)

  it "refuses a record beyond the limits, a member name the shader may not declare and one the engine's block already has" $ do
    declarationProblems declaration {declaredRecord = RecordLayout (maxRecordHandles + 1) 0} `shouldSatisfy` any ("handles" `isInfixOf`)
    declarationProblems declaration {declaredRecord = RecordLayout 0 (maxRecordWords + 1)} `shouldSatisfy` any ("words" `isInfixOf`)
    declarationProblems declaration {declaredRecord = RecordLayout maxRecordHandles maxRecordWords} `shouldBe` []
    forM_ ["", "1x", "a-b", "gl_x", "a__b", "naïve"] $ \name →
      declarationProblems declaration {declaredPush = [PushField name PushFloat]} `shouldSatisfy` any ("not a GLSL identifier" `isInfixOf`)
    forM_ ["viewLinear", "viewTranslation", "extent", "brightness", "filtering", "snap", "recordBase", "reserved"] $ \name →
      declarationProblems declaration {declaredPush = [PushField name PushFloat]} `shouldSatisfy` any ("the engine's own block" `isInfixOf`)
    declarationProblems declaration {declaredPush = [PushField "twice" PushFloat, PushField "twice" PushUint]} `shouldSatisfy` any ("more than once" `isInfixOf`)

  it "refuses a source that defines no function named material" $
    declarationProblems declaration {declaredSource = "float other() { return 1.0; }"} `shouldSatisfy` any ("material" `isInfixOf`)
  where
    declaration =
      MaterialDeclaration
        { declaredCutoutCapable = True
        , declaredRecord = RecordLayout 0 0
        , declaredPush = []
        , declaredSource = "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) { return texel; }"
        }

-- ---------------------------------------------------------------------------
-- What the splice recorded and checked

splicedSpec ∷ Spec
splicedSpec = describe "a spliced material" $ do
  it "records the facts it was declared with: cutout capability, record layout and push-block size" $ do
    definedFacts mixMaterial `shouldBe` MaterialFacts True (RecordLayout 1 1) 8
    definedFacts translucentMixMaterial `shouldBe` MaterialFacts False (RecordLayout 1 1) 8
    definedFacts tintOnlyMaterial `shouldBe` MaterialFacts True (RecordLayout 0 0) 16
    map definedPushBytes [mixMaterial, translucentMixMaterial, tintOnlyMaterial] `shouldBe` [8, 8, 16]

  it "records where each push member sits, from the start of the application's block" $ do
    [(name, offset) | PushOffset name _ offset ← definedPush mixMaterial] `shouldBe` [("strength", 0), ("bias", 4)]
    [(name, kind, offset) | PushOffset name kind offset ← definedPush tintOnlyMaterial] `shouldBe` [("colour", PushVec4, 0)]

  it "has a cutout variant exactly when the material is cutout-capable" $ do
    fmap (const ()) (definedCutout mixMaterial) `shouldBe` Just ()
    fmap (const ()) (definedCutout tintOnlyMaterial) `shouldBe` Just ()
    fmap (const ()) (definedCutout translucentMixMaterial) `shouldBe` Nothing

  it "declares one 128-byte push block in both stages of every variant: the engine's members, the material's own, the rest reserved" $ do
    let members shaders = case (checkedVertex shaders, checkedFragment shaders) of
          (CheckedShader _ vertex, CheckedShader _ fragment) → (interfacePushConstants vertex, interfacePushConstants fragment)
        variants = concat [definedTranslucent material : maybe [] pure (definedCutout material) | material ← [mixMaterial, translucentMixMaterial, tintOnlyMaterial]]
    forM_ variants $ \variant → do
      let (vertex, fragment) = members variant
      vertex `shouldBe` fragment
      [(offset, offset + size) | PushMember offset size ← take 10 vertex] `shouldBe` [(0, 16), (16, 24), (24, 32), (32, 36), (36, 40), (40, 44), (44, 48), (48, 64), (64, 72), (72, 76)]
      maximum [offset + size | PushMember offset size ← vertex] `shouldBe` 128
    -- The sample's two floats at 80 and 84, the rest from 88; the tint material's vec4 at 80, the rest from 96.
    [(offset, size) | PushMember offset size ← drop 10 (fst (members (definedTranslucent mixMaterial)))] `shouldBe` [(80, 4), (84, 4), (88, 40)]
    [(offset, size) | PushMember offset size ← drop 10 (fst (members (definedTranslucent tintOnlyMaterial)))] `shouldBe` [(80, 16), (96, 32)]
    -- The built-in shaders reserve all of it.
    [(offset, size) | PushMember offset size ← drop 10 (fst (members orderedShaders))] `shouldBe` [(80, 48)]

  it "reads the texture table and the storage region, whether or not the material has records" $ do
    let descriptors shaders = case checkedFragment shaders of CheckedShader _ fragment → interfaceDescriptors fragment
    descriptors (definedTranslucent mixMaterial) `shouldBe` textureTableDescriptors <> storageTableDescriptors
    descriptors (definedTranslucent translucentMixMaterial) `shouldBe` textureTableDescriptors <> storageTableDescriptors
    descriptors (definedTranslucent tintOnlyMaterial) `shouldBe` textureTableDescriptors <> storageTableDescriptors
    forM_ (maybe [] pure (definedCutout mixMaterial)) $ \cutout →
      descriptors cutout `shouldBe` textureTableDescriptors <> storageTableDescriptors
    storageTableDescriptors `shouldBe` [DescriptorDeclaration 2 0 StorageBuffer (DescriptorCount 1)]

  it "shares the vertex stage between a material's variants, and differs from the built-in one in the push block alone" $ do
    let vertexCode shaders = case checkedVertex shaders of CheckedShader code _ → code
    forM_ (maybe [] pure (definedCutout mixMaterial)) $ \cutout →
      vertexCode cutout `shouldBe` vertexCode (definedTranslucent mixMaterial)
    vertexCode (definedTranslucent mixMaterial) `shouldSatisfy` (/= vertexCode orderedShaders)

-- ---------------------------------------------------------------------------
-- Registration

registrationSpec ∷ Spec
registrationSpec = describe "registering a material" $ do
  it "splices a record of handles only, and one of words only, with each variant its facts call for" $ do
    definedFacts handlesOnlyMaterial `shouldBe` MaterialFacts True (RecordLayout 1 0) 0
    definedFacts wordsOnlyMaterial `shouldBe` MaterialFacts False (RecordLayout 0 1) 0
    (isJust (definedCutout handlesOnlyMaterial), isJust (definedCutout wordsOnlyMaterial)) `shouldBe` (True, False)
  it "issues a reference carrying exactly the facts the splice recorded" $
    withFixtures $ \fixtures → do
      map materialFacts [fixMix fixtures, fixTranslucent fixtures, fixTint fixtures]
        `shouldBe` [MaterialFacts True (RecordLayout 1 1) 8, MaterialFacts False (RecordLayout 1 1) 8, MaterialFacts True (RecordLayout 0 0) 16]
      map materialFacts [fixMix fixtures, fixTranslucent fixtures, fixTint fixtures]
        `shouldBe` map definedFacts [mixMaterial, translucentMixMaterial, tintOnlyMaterial]

  it "answers the reference already issued for a material registered again, and another for another material" $
    withFixtures $ \fixtures → do
      again ← Render.registerMaterial (fixRenderer fixtures) mixMaterial
      again `shouldBe` fixMix fixtures
      length (Set.fromList [fixMix fixtures, fixTranslucent fixtures, fixTint fixtures]) `shouldBe` 3

  it "issues identities that are never the default's, and that carry the session so another renderer's never match" $ do
    one ← withFixtures (\fixtures → pure (fixMix fixtures))
    two ← withFixtures (\fixtures → pure (fixMix fixtures))
    materialRefIdentity one `shouldSatisfy` (/= materialRefIdentity defaultMaterial)
    materialRefIdentity one `shouldSatisfy` (/= materialRefIdentity two)
    materialFacts one `shouldBe` materialFacts two
    one `shouldSatisfy` (/= two)

  it "looks a reference up by its identity, and the default is every renderer's" $
    withFixtures $ \fixtures → do
      issued ← Render.issuedMaterials (fixRenderer fixtures)
      issued (materialRefIdentity (fixMix fixtures)) `shouldBe` Just (fixMix fixtures)
      issued (materialRefIdentity defaultMaterial) `shouldBe` Just defaultMaterial
      issued 987654321 `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Recording

recordingSpec ∷ Spec
recordingSpec = describe "recording materials" $ do
  it "writes the view's records back to back in the order the runs first read them, and pushes each run's base and each material's push block" $
    withFixtures $ \fixtures → do
      let held =
            [ (fixMix fixtures, MaterialData [record [(10, 1)] [7], record [(11, 1)] [9]] (twoFloats 0.5 0.25))
            , (fixTranslucent fixtures, MaterialData [record [(12, 1)] [3]] (twoFloats 1 0))
            , (fixTint fixtures, MaterialData [] (colour 1 0.5 0.25 1))
            ]
          layer =
            UiLayer
              [ unit defaultMaterial 0 0 0
              , unit (fixMix fixtures) 1 1 1
              , unit (fixMix fixtures) 0 2 2
              , unit (fixTranslucent fixtures) 0 3 3
              , unit (fixTint fixtures) 0 4 4
              , unit defaultMaterial 0 5 5
              ]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldReturnRight` ()
      commands ← commandsRecorded (fixRig fixtures)
      -- The region: the clip region's one zero entry (four words), then the mix
      -- table (two records of three words) at word 4, the translucent mix's (one)
      -- at word 10.
      writes ← claimWrites (fixRig fixtures)
      take 1 writes `shouldBe` [(0, ByteString.replicate 16 0 <> words' [10, 1, 7, 11, 1, 9, 12, 1, 3])]
      -- 52 bytes are padded to the atom of 16, so the layer's region begins at 64.
      ringOffsets (fixRig fixtures) >>= (`shouldBe` [0, 64])
      seen commands
        `shouldBe` [ SeenPipeline
                   , SeenTable
                   , SeenStorage
                   , SeenPush both 0 enginePush
                   , -- the default material's run: no push block, no records
                     SeenBind 64
                   , SeenDraw 1
                   , -- the mix material's run: its table begins at word 4
                     SeenPipeline
                   , SeenPush both recordBaseOffset (words' [4])
                   , SeenPush both applicationPushOffset (twoFloats 0.5 0.25)
                   , SeenBind 128
                   , SeenDraw 2
                   , -- the translucent mix's run: its table begins at word 10
                     SeenPipeline
                   , SeenPush both recordBaseOffset (words' [10])
                   , SeenPush both applicationPushOffset (twoFloats 1 0)
                   , SeenBind 256
                   , SeenDraw 1
                   , -- the tint-only material: a push block and no records
                     SeenPipeline
                   , SeenPush both applicationPushOffset (colour 1 0.5 0.25 1)
                   , SeenBind 320
                   , SeenDraw 1
                   , SeenPipeline
                   , SeenBind 384
                   , SeenDraw 1
                   ]

  it "writes a chunk's own records beside the view's and pushes each chunk listing's base, writing a chunk listed twice once" $
    withFixtures $ \fixtures → do
      let a = chunkRef 1 1
          b = chunkRef 2 1
          chunkA = built [(fixMix fixtures, [record [(20, 1)] [21]])] [(unit (fixMix fixtures) 0 1 1)]
          chunkB = built [(fixMix fixtures, [record [(21, 1)] [22]])] [(unit (fixMix fixtures) 0 3 1)]
          held = [(fixMix fixtures, MaterialData [record [(30, 1)] [31]] (twoFloats 1 0))]
          layer = UiLayerWith [a, b, a] [unit (fixMix fixtures) 0 5 1]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [(a, chunkA), (b, chunkB)] [viewHolding held [layer]])
      recorded fixtures input `shouldReturnRight` ()
      commands ← commandsRecorded (fixRig fixtures)
      -- Tables in the order their first reader appears, after the clip region's
      -- four words: chunk a (word 4), chunk b (word 7), the view (word 10). The
      -- third listing reads a's table again.
      writes ← claimWrites (fixRig fixtures)
      take 1 writes `shouldBe` [(0, ByteString.replicate 16 0 <> words' [20, 1, 21, 21, 1, 22, 30, 1, 31])]
      -- At key 1 the order is the listings in turn, then the dynamic instance:
      -- four runs, each from its own source, though path and material are equal.
      -- Listing 0 reads the table at word 4; then listing 1's at 7, listing 2 (the
      -- same chunk) at 4 again, and the view's at 10.
      [bytes | SeenPush _ offset bytes ← seen commands, offset == recordBaseOffset] `shouldBe` [words' [4], words' [7], words' [4], words' [10]]
      length [() | SeenDraw 1 ← seen commands] `shouldBe` 4
      -- The material's push block is the view's, pushed once for all four runs.
      length [() | SeenPush _ offset _ ← seen commands, offset == applicationPushOffset] `shouldBe` 1

  it "keeps a run's instances in the drawing order the merge gave, whatever record source they come from" $
    withFixtures $ \fixtures → do
      let a = chunkRef 1 1
          chunkA = built [(fixMix fixtures, [record [(20, 1)] [21]])] [unit (fixMix fixtures) 0 1 3, unit (fixMix fixtures) 0 2 7]
          held = [(fixMix fixtures, MaterialData [record [(30, 1)] [31]] (twoFloats 1 0))]
          layer = UiLayerWith [a] [unit (fixMix fixtures) 0 4 5]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [(a, chunkA)] [viewHolding held [layer]])
      recorded fixtures input `shouldReturnRight` ()
      commands ← commandsRecorded (fixRig fixtures)
      -- Keys 3 (chunk), 5 (dynamic), 7 (chunk): three runs of one instance each,
      -- the chunk's table at word 4 and the view's at word 7.
      length [() | SeenDraw 1 ← seen commands] `shouldBe` 3
      [bytes | SeenPush _ offset bytes ← seen commands, offset == recordBaseOffset] `shouldBe` [words' [4], words' [7], words' [4]]

  it "pushes the material's push block once for a view however many layers use it, and again after each depth clear" $
    withFixtures $ \fixtures → do
      let held = [(fixMix fixtures, MaterialData [record [(10, 1)] [7]] (twoFloats 0.5 0.25))]
          ui = UiLayer [unit (fixMix fixtures) 0 0 0]
      uiInput ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [ui, ui]])
      recorded fixtures uiInput `shouldReturnRight` ()
      uiCommands ← commandsRecorded (fixRig fixtures)
      length [() | SeenPush _ offset _ ← seen uiCommands, offset == applicationPushOffset] `shouldBe` 1
      length [() | SeenDraw _ ← seen uiCommands] `shouldBe` 2
      resetJournal (fixRig fixtures)
      let deep = WorldLayer DepthEnabled [unit (fixMix fixtures) 0 0 0]
      depthInput ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [deep, deep]])
      recorded fixtures depthInput `shouldReturnRight` ()
      depthCommands ← commandsRecorded (fixRig fixtures)
      length [() | SeenClear ← seen depthCommands] `shouldBe` 2
      length [() | SeenPush _ offset _ ← seen depthCommands, offset == applicationPushOffset] `shouldBe` 2

  it "binds the storage table again after each depth clear, where the pass draws" $
    withFixtures $ \fixtures → do
      let deep = WorldLayer DepthEnabled [unit defaultMaterial 0 0 0]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding [] [deep, deep]])
      recorded fixtures input `shouldReturnRight` ()
      commands ← commandsRecorded (fixRig fixtures)
      length [() | SeenStorage ← seen commands] `shouldBe` 3
      length [() | SeenTable ← seen commands] `shouldBe` 3
  where
    built records instances = either (error . show) id (buildChunkWith noCutoutMarks ChunkUi DeriveBounds (Map.fromList records) instances)

shouldReturnRight ∷ (Show a, Eq a) ⇒ IO (Either FrameRefusal a) → a → IO ()
shouldReturnRight action expected = action >>= \answer → answer `shouldBe` Right expected

-- ---------------------------------------------------------------------------
-- Pipelines

pipelineSpec ∷ Spec
pipelineSpec = describe "a material's pipelines" $ do
  it "are built per colour format and kind on first use, from the variant the kind draws, and never again" $
    withFixtures $ \fixtures → do
      let art = textureHandle 1 1
          held = [(fixMix fixtures, MaterialData [record [(10, 1)] [7]] (twoFloats 1 0))]
          layer = WorldLayer DepthEnabled [(unit (fixMix fixtures) 0 0 1) {instanceTexture = art}, (unit (fixMix fixtures) 0 1 2) {instanceTexture = textureHandle 2 1}]
          snapshot = onePass [] [viewHolding held [layer]]
      input ← frameFor (fixRig fixtures) (cutoutMarks [art]) Rgba8Linear snapshot
      recorded fixtures input `shouldReturnRight` ()
      made ← pipelinesMade (fixRig fixtures)
      let labels = shaderLabels fixtures
          label request = [name | (name, shaders) ← labels, shaders == requestShaders request]
      [(label request, requestBlend request, requestDepth request) | request ← made]
        `shouldBe` [ (["mix cutout"], BlendNone, Just (PipelineDepth Depth32Float True True Native.CompareLessOrEqual))
                   , (["mix"], BlendPremultipliedAlpha, Just (PipelineDepth Depth32Float True False Native.CompareLessOrEqual))
                   ]
      commands ← commandsRecorded (fixRig fixtures)
      drawnWith fixtures commands >>= (`shouldBe` [("mix cutout", 1), ("mix", 1)])
      -- A second frame into the same format makes none; another format makes its own.
      input' ← frameFor (fixRig fixtures) (cutoutMarks [art]) Rgba8Linear snapshot
      recorded fixtures input' `shouldReturnRight` ()
      length <$> pipelinesMade (fixRig fixtures) >>= (`shouldBe` 2)
      srgb ← frameFor (fixRig fixtures) (cutoutMarks [art]) Rgba8Srgb snapshot
      recorded fixtures srgb `shouldReturnRight` ()
      made' ← pipelinesMade (fixRig fixtures)
      length made' `shouldBe` 4
      drop 2 (map requestColorFormat made') `shouldBe` [formatCode Rgba8Srgb, formatCode Rgba8Srgb]

  it "are made over the one layout the built-in shaders use, so binding another material's never disturbs what is bound" $
    withFixtures $ \fixtures → do
      let art = textureHandle 1 1
          held = [(fixMix fixtures, MaterialData [record [(10, 1)] [7]] (twoFloats 1 0)), (fixTint fixtures, MaterialData [] (colour 1 1 1 1))]
          layer = WorldLayer DepthEnabled [unit defaultMaterial 0 0 1, unit (fixMix fixtures) 0 1 2, unit (fixTint fixtures) 0 2 3]
      input ← frameFor (fixRig fixtures) (cutoutMarks [art]) Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldReturnRight` ()
      made ← pipelinesMade (fixRig fixtures)
      length made `shouldBe` 3
      length (Set.fromList (map requestLayout made)) `shouldBe` 1
      layouts ← layoutsMade (fixRig fixtures)
      map snd layouts `shouldBe` [[Native.PushConstantRange both 0 128]]

  it "builds no cutout pipeline for a material that is not cutout-capable, whatever its texture and tint say" $
    withFixtures $ \fixtures → do
      let art = textureHandle 1 1
          held = [(fixTranslucent fixtures, MaterialData [record [(10, 1)] [7]] (twoFloats 1 0))]
          layer = WorldLayer DepthEnabled [unit (fixTranslucent fixtures) 0 0 1]
      input ← frameFor (fixRig fixtures) (cutoutMarks [art]) Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldReturnRight` ()
      made ← pipelinesMade (fixRig fixtures)
      map requestBlend made `shouldBe` [BlendPremultipliedAlpha]
      commandsRecorded (fixRig fixtures) >>= drawnWith fixtures >>= (`shouldBe` [("translucent mix", 1)])

  it "refuses a cutout pipeline for a material that has no cutout variant, and one for a reference it did not issue" $
    withFixtures $ \fixtures → do
      let format = formatCode Rgba8Linear
          forged = materialRef 77 (MaterialFacts True (RecordLayout 0 0) 0)
      Render.pipelineForMaterial (builders (fixRig fixtures)) (fixRenderer fixtures) (fixTranslucent fixtures) Render.CutoutPipeline format
        >>= (`shouldSatisfy` isIllegal)
      Render.pipelineForMaterial (builders (fixRig fixtures)) (fixRenderer fixtures) forged Render.OrderedTestedPipeline format
        >>= (`shouldSatisfy` isIllegal)
      Render.pipelineForMaterial (builders (fixRig fixtures)) (fixRenderer fixtures) (fixMix fixtures) Render.CutoutPipeline format
        >>= (`shouldSatisfy` either (const False) (const True))
  where
    isIllegal = \case
      Left (RefusedIllegal _) → True
      _ → False

-- ---------------------------------------------------------------------------
-- Refusals

refusalSpec ∷ Spec
refusalSpec = describe "what the recorder refuses before it records anything" $ do
  let nothingRecorded fixtures = do
        commandsRecorded (fixRig fixtures) >>= (`shouldBe` [])
        ringOffsets (fixRig fixtures) >>= (`shouldBe` [])
        pipelinesMade (fixRig fixtures) >>= (`shouldBe` [])
  it "names a reference the session did not issue, where it is used" $
    withFixtures $ \fixtures → do
      let forged = materialRef 77 (MaterialFacts True (RecordLayout 0 0) 0)
          layer = UiLayer [unit defaultMaterial 0 0 0, unit forged 0 1 1]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding [] [layer]])
      recorded fixtures input `shouldBe'` Left (MaterialNotIssued (AtInstance 0 0 0 1) forged)
      nothingRecorded fixtures

  it "names a reference another renderer issued, though the facts agree" $ do
    elsewhere ← withFixtures (\fixtures → pure (fixMix fixtures))
    withFixtures $ \fixtures → do
      let layer = UiLayer [unit elsewhere 0 0 0]
          held = [(elsewhere, MaterialData [record [(10, 1)] [7]] (twoFloats 1 0))]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldBe'` Left (MaterialNotIssued (AtInstance 0 0 0 0) elsewhere)
      nothingRecorded fixtures

  it "names a reference that carries an issued material's identity and other facts" $
    withFixtures $ \fixtures → do
      let lying = materialRef (materialRefIdentity (fixMix fixtures)) (MaterialFacts True (RecordLayout 0 0) 0)
          layer = UiLayer [unit lying 0 0 0]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding [] [layer]])
      recorded fixtures input `shouldBe'` Left (MaterialFactsDisagree (AtInstance 0 0 0 0) lying (fixMix fixtures))
      nothingRecorded fixtures

  it "names a reference with the default's identity and other facts" $
    withFixtures $ \fixtures → do
      let lying = materialRef (materialRefIdentity defaultMaterial) (MaterialFacts False (RecordLayout 0 0) 0)
          layer = UiLayer [unit lying 0 0 0]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding [] [layer]])
      recorded fixtures input `shouldBe'` Left (MaterialFactsDisagree (AtInstance 0 0 0 0) lying defaultMaterial)

  it "names the instance of a chunk a layer lists that names a material the session did not issue" $
    withFixtures $ \fixtures → do
      let forged = materialRef 77 (MaterialFacts True (RecordLayout 0 0) 0)
          reference = chunkRef 1 1
          chunk = either (error . show) id (buildChunk noCutoutMarks ChunkUi DeriveBounds [unit defaultMaterial 0 0 0, unit forged 0 1 1])
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [(reference, chunk)] [viewHolding [] [UiLayerWith [reference] []]])
      recorded fixtures input `shouldBe'` Left (MaterialNotIssued (AtChunkInstance 0 0 0 0 1) forged)
      nothingRecorded fixtures

  it "refuses a frame whose records are larger than the storage window, naming both sizes" $
    withFixtures $ \fixtures → do
      -- 400 records of a handle and a word are 4800 bytes, and the clip region's
      -- 16 come first; the window is 4096.
      let records = [record [(10, 1)] [n] | n ← [0 .. 399]]
          held = [(fixMix fixtures, MaterialData records (twoFloats 1 0))]
          layer = UiLayer [unit (fixMix fixtures) 399 0 0]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldBe'` Left (RecordsTooLarge 4816 4096)
      nothingRecorded fixtures

  it "accepts a frame whose records fill the window exactly" $
    withFixtures $ \fixtures → do
      -- 340 records are 4080 bytes, which with the clip region's 16 fill the window.
      let records = [record [(10, 1)] [n] | n ← [0 .. 339]]
          held = [(fixMix fixtures, MaterialData records (twoFloats 1 0))]
          layer = UiLayer [unit (fixMix fixtures) 339 0 0]
      input ← frameFor (fixRig fixtures) noCutoutMarks Rgba8Linear (onePass [] [viewHolding held [layer]])
      recorded fixtures input `shouldBe'` Right ()
  where
    shouldBe' action expected = action >>= (`shouldBe` expected)

-- ---------------------------------------------------------------------------
-- Publication and holds

publicationSpec ∷ Spec
publicationSpec = describe "publishing and holding materials' records" $ do
  it "refuses a snapshot naming a material the renderer did not issue, naming the instance, and publishes one it did" $
    withEnv [1] $ \env → do
      issued ← Render.registerMaterial (envRenderer env) mixMaterial
      art ← registered env 1 True DefaultMark
      let forged = materialRef 77 (MaterialFacts True (RecordLayout 0 0) 0)
          snapshotOf material held = windowWith [(issued, held)] [instanceOf material art]
          good = MaterialData [record [(10, 1)] [7]] (twoFloats 1 0)
      publish2DSnapshot (envAdapter env) 1 (snapshotOf forged good)
        >>= (`shouldBe` Left (MaterialNotIssuedInSnapshot (MaterialNotIssued (AtInstance 0 0 0 0) forged)))
      publish2DSnapshot (envAdapter env) 1 (snapshotOf issued good) >>= (`shouldBe` Right 1)

  it "holds a texture only a record names, with the revision that adopts it, and releases it only after that revision" $
    withEnv [1] $ \env → do
      issued ← Render.registerMaterial (envRenderer env) mixMaterial
      art ← registered env 1 True DefaultMark
      second ← registered env 2 True DefaultMark
      let (index, generation) = (handleIndex second, handleGeneration second)
          held = MaterialData [record [(index, generation)] [7]] (twoFloats 1 0)
      revision ← publish2DSnapshot (envAdapter env) 1 (windowWith [(issued, held)] [instanceOf issued art]) >>= either (fail . show) pure
      adopt env 1 revision
      (,) <$> textureHolds (envAdapter env) art <*> textureHolds (envAdapter env) second >>= (`shouldBe` (1, 1))
      -- Its release is requested and the barrier met, but the adopted revision's record still shows it.
      release2DTexture (envAdapter env) second >>= (`shouldBe` Right ())
      _ ← runQueued env
      resolves env second >>= (`shouldBe` True)
      -- A snapshot without it is adopted and the first released.
      without ← publishOk env 1 []
      adopt env 1 without
      releaseRevision env 1 revision
      _ ← runQueued env
      resolves env second >>= (`shouldBe` False)
      textureHolds (envAdapter env) second >>= (`shouldBe` 0)

  it "refuses a snapshot whose record names a texture whose release was requested, naming it, as it refuses an instance's" $
    withEnv [1] $ \env → do
      issued ← Render.registerMaterial (envRenderer env) mixMaterial
      art ← registered env 1 True DefaultMark
      gone ← registered env 2 True DefaultMark
      release2DTexture (envAdapter env) gone >>= (`shouldBe` Right ())
      let held = MaterialData [record [(handleIndex gone, handleGeneration gone)] [7]] (twoFloats 1 0)
      publish2DSnapshot (envAdapter env) 1 (windowWith [(issued, held)] [instanceOf issued art]) >>= (`shouldBe` Left (TextureReleasedInSnapshot gone))
      -- Without the record's handle the snapshot publishes.
      publish2DSnapshot (envAdapter env) 1 (windowWith [(issued, MaterialData [record [(handleIndex art, handleGeneration art)] [7]] (twoFloats 1 0))] [instanceOf issued art]) >>= (`shouldBe` Right 1)

  it "keeps a record's texture while a batch that recorded it is incomplete, and releases it once the batch completes" $
    withEnv [1] $ \env → do
      issued ← Render.registerMaterial (envRenderer env) mixMaterial
      art ← registered env 1 True DefaultMark
      second ← registered env 2 True DefaultMark
      let held = [(issued, MaterialData [record [(handleIndex second, handleGeneration second)] [7]] (twoFloats 1 0))]
          snapshot = onePass [] [viewHolding held [UiLayer [(unit issued 0 0 0) {instanceTexture = art}]]]
      image ← target (envRig env) Rgba8Linear 16 16
      depth ← depthTarget (envRig env) Depth32Float 16 16
      let input =
            FrameInput
              snapshot
              noCutoutMarks
              (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear 16 16) (Just (DepthBinding depth Depth32Float))))
              Nothing
              Nothing
              (const Nothing)
              Set.empty
      slot ← slotOf env second
      Render.prepareSnapshot (builders (envRig env)) (envRenderer env) input >>= \case
        Left refusal → expectationFailure (show refusal)
        Right recording →
          framelessOnce (envRig env) $ \recorder → do
            recording recorder >>= (`shouldBe` Right ())
            -- The batch has recorded and not completed: it holds a table version that maps the slot.
            releaseTextureNow (builders (envRig env)) (envTextures env) second >>= (`shouldBe` Right ())
            resolves env second >>= (`shouldBe` False)
            mappedSlots env >>= (`shouldSatisfy` Set.member slot)
      -- Submitted, not completed: the batch's version still maps it, and the slot is not free to reuse.
      mappedSlots env >>= (`shouldSatisfy` Set.member slot)
      settleUploads (envRig env)
      refreshTable (envRig env)
      mappedSlots env >>= (`shouldSatisfy` (not . Set.member slot))

  it "holds the textures a chunk's records name with the chunk, which releases with the chunk's own rules" $
    withEnv [1] $ \env → do
      issued ← Render.registerMaterial (envRenderer env) mixMaterial
      art ← registered env 1 True DefaultMark
      named ← registered env 2 True DefaultMark
      marks ← registeredMarks (envTextures env)
      reference ←
        buildRetainedChunkWith
          (builders (envRig env))
          (envRetained env)
          marks
          ChunkUi
          DeriveBounds
          (Map.fromList [(issued, [record [(handleIndex named, handleGeneration named)] [7]])])
          [instanceOf issued art]
          >>= either (fail . show) pure
      let listing = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [viewHolding [(issued, MaterialData [] (twoFloats 1 0))] [UiLayerWith [reference] []]]]
      revision ← publish2DSnapshot (envAdapter env) 1 listing >>= either (fail . show) pure
      adopt env 1 revision
      (,,) <$> textureHolds (envAdapter env) art <*> textureHolds (envAdapter env) named <*> chunkHolds (envAdapter env) reference
        >>= (`shouldBe` (1, 1, 1))
      releaseRevision env 1 revision
      (,,) <$> textureHolds (envAdapter env) art <*> textureHolds (envAdapter env) named <*> chunkHolds (envAdapter env) reference
        >>= (`shouldBe` (0, 0, 0))
  where
    instanceOf material texture = (unit material 0 0 0) {instanceTexture = texture}
    windowWith held instances = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [viewHolding held [UiLayer instances]]]

-- | The table slot a registered handle maps to.
slotOf ∷ Env → Api.TextureHandle → IO Word32
slotOf env handle =
  atomically (readTable (rigRecording (envRig env))) >>= \case
    Just view | Just entry ← Map.lookup (handleIndex handle) (tableViewMapping view) → pure (entrySlot entry)
    _ → fail "the handle is not mapped"

-- | The slots a live table version maps: the current one and every one a batch holds.
mappedSlots ∷ Env → IO (Set.Set Word32)
mappedSlots env = maybe Set.empty tableViewMapped <$> atomically (readTable (rigRecording (envRig env)))

-- ---------------------------------------------------------------------------
-- A deliberately misdeclared material, in a module of its own

externalSpec ∷ Spec
externalSpec = describe "a material in a separately compiled module" $ do
  it "compiles when it is declared correctly" $
    withClient (correct (unlines ["    vec4 second = sampleTexture(record.handles[0], uv);", "    return mix(texel, second, pushed.amount);"])) $ \built →
      case clientStatus built of
        ExitSuccess → pure ()
        other → expectationFailure ("the correct material must compile, but the compiler exited with " <> show other <> ":\n" <> clientOutput built)

  it "fails to compile when its push block is beyond the limit, naming the size and the limit" $
    withClient (clientWith "RecordLayout 0 0" "[PushField \"a\" PushVec4, PushField \"b\" PushVec4, PushField \"c\" PushVec4, PushField \"d\" PushVec4, PushField \"e\" PushVec4, PushField \"f\" PushVec4]" "return texel;") $ \built → do
      built `rejectedBecause` "the material's declaration is refused"
      built `rejectedBecause` "the push block would be 96 bytes, beyond the limit of 48 bytes"

  it "fails to compile when its shader reads a record member beyond the layout it declares" $
    withClient (correct (unlines ["    float beyond = float(record.words[2]);", "    return texel * beyond;"])) $ \built → do
      built `rejectedBecause` "did not compile: glslang"
      built `rejectedBecause` "array index out of range '2'"

  it "fails to compile when its shader declares a resource its interface does not, naming it" $
    withClient (clientWithPrelude "layout(set = 0, binding = 2) uniform sampler2D extra;" "RecordLayout 0 0" "[]" "return texture(extra, uv);") $ \built → do
      built `rejectedBecause` "does not match its interface description"
      built `rejectedBecause` "descriptor set 0, binding 2"

  it "fails to compile when its function does not have the fixed signature" $
    withClient (clientWithSource "vec4 material(vec4 texel) { return texel; }" "RecordLayout 0 0" "[]") $ \built → do
      built `rejectedBecause` "did not compile: glslang"
      built `rejectedBecause` "'material' : no matching overloaded function found"

  it "fails to compile when it names a push member the engine's block already declares" $
    withClient (clientWith "RecordLayout 0 0" "[PushField \"brightness\" PushFloat]" "return texel;") $ \built →
      built `rejectedBecause` "the engine's own block"
  where
    -- Compile one client against the built packages with a copy of this
    -- package's fingerprint: the first compile only learns the client's
    -- directory, since without a fingerprint its splice refuses at once.
    withClient source use = do
      fingerprint ← readFile fingerprintPath
      withStorePackageClient clientPackages "Client.hs" source $ \compile → do
        unconfigured ← compile Typecheck
        let copy = clientDirectory unconfigured </> fingerprintPath
        createDirectoryIfMissing True (takeDirectory copy)
        writeFile copy fingerprint
        compile Typecheck >>= use
    clientPackages = ["base", "template-haskell", "hetoimasia-render-2d", "hetoimasia-render-2d-vulkan"]
    correct ∷ String → String
    correct body = clientWith "RecordLayout 1 1" "[PushField \"amount\" PushFloat]" body
    clientWith ∷ String → String → String → String
    clientWith record' push body = clientWithSource (signature body) record' push
    clientWithPrelude ∷ String → String → String → String → String
    clientWithPrelude extra record' push body = clientWithSource (extra <> "\n" <> signature body) record' push
    signature ∷ String → String
    signature body = "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {\n" <> body <> "\n}"
    clientWithSource ∷ String → String → String → String
    clientWithSource source record' push =
      unlines
        [ "{-# LANGUAGE TemplateHaskell #-}"
        , "module Client (material) where"
        , ""
        , "import Hetoimasia.Render.TwoD.Vulkan.Material"
        , ""
        , "material :: DefinedMaterial"
        , "material = $(defineMaterial MaterialDeclaration"
        , "  { declaredCutoutCapable = True"
        , "  , declaredRecord = " <> record'
        , "  , declaredPush = " <> push
        , "  , declaredSource = " <> show source
        , "  })"
        ]
