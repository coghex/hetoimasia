-- | Application materials (R2D-11): the reference and the facts it carries,
-- routing and runs by material, the records and push blocks a view holds and the
-- refusals about them, the records a chunk carries, and the record encoding.
--
-- __Method.__ References are built through the backend-facing constructor with
-- given facts, as a backend or a test standing in for one builds them: a
-- cutout-capable material and one that is not, several record layouts and
-- several push-block sizes. Orders are read off as tags in the instances'
-- parameter words, as the chunk specs read them.
module Test.Render.TwoD.Materials (spec) where

import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32, Word64, Word8)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, encodeLayerInDrawingOrder, encodeRecords)
import Hetoimasia.Render.TwoD.Material
import Hetoimasia.Render.TwoD.Material.Backend (defaultMaterialIdentity, materialRef, materialRefIdentity)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , Reason (..)
  , Refusal (..)
  , validLayers
  , validateSnapshotWith
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Support

-- * References and records to build

-- | A reference with this identity and these facts.
refWith ∷ Word64 → Bool → (Word32, Word32) → Word32 → MaterialRef
refWith identity cutout (handles, wordCount) pushBytes =
  materialRef identity (MaterialFacts cutout (RecordLayout handles wordCount) pushBytes)

-- | Cutout-capable, no record, no push block: an application material that
-- needs nothing from its view.
plainMaterial ∷ MaterialRef
plainMaterial = refWith 1 True (0, 0) 0

-- | Not cutout-capable.
translucentMaterial ∷ MaterialRef
translucentMaterial = refWith 2 False (0, 0) 0

-- | Another cutout-capable material that needs nothing from its view.
otherMaterial ∷ MaterialRef
otherMaterial = refWith 6 True (0, 0) 0

-- | One handle and one word in a record, a push block of 16 bytes.
mixMaterial ∷ MaterialRef
mixMaterial = refWith 3 True (1, 1) 16

-- | Two handles and no word in a record, no push block.
twoHandles ∷ MaterialRef
twoHandles = refWith 4 True (2, 0) 0

-- | No record, a push block of 4 bytes.
pushOnly ∷ MaterialRef
pushOnly = refWith 5 False (0, 0) 4

-- | A record of these full handles and words.
recordOf ∷ [(Word32, Word32)] → [Word32] → MaterialRecord
recordOf handles = MaterialRecord [textureHandle index generation | (index, generation) ← handles]

-- | A record of the layout of 'mixMaterial', tagged by its word.
mixRecord ∷ Word32 → MaterialRecord
mixRecord tag = recordOf [(10 + tag, 1)] [tag]

-- | A push block of this many bytes.
block ∷ Int → ByteString.ByteString
block size = ByteString.replicate size 0xAB

-- | An instance of this material and parameter word, in the cutout-eligible shape.
using ∷ MaterialRef → Word32 → Instance
using material parameter = plainInstance {instanceMaterial = material, instanceParameter = parameter}

marks ∷ CutoutMarks
marks = cutoutMarks [instanceTexture plainInstance]

-- | A view of the plain camera and viewport holding this data for these materials.
viewHolding ∷ [(MaterialRef, MaterialData)] → [Layer] → View
viewHolding held layers = (plainView layers) {viewMaterials = Map.fromList held}

snapshotOf ∷ View → Snapshot
snapshotOf = snapshotWithView

refusalsAgainst ∷ [(ChunkRef, Chunk)] → View → [Refusal]
refusalsAgainst held view = either (foldr (:) []) (const []) (validateSnapshotWith (chunksFrom held) (snapshotOf view))

-- | The plan of the one layer of a view, with the chunks it lists resolved.
planOf ∷ [(ChunkRef, Chunk)] → View → PlannedLayer
planOf held view = case validateSnapshotWith (chunksFrom held) (snapshotOf view) of
  Left refused → error ("the snapshot was refused: " <> show refused)
  Right valid → case planPasses (planSnapshot marks valid) of
    [PlannedPass {plannedViews = [PlannedView {plannedLayers = [layer]}]}] → layer
    _ → error "the snapshot did not plan to one layer"

built ∷ ChunkKind → [(MaterialRef, [MaterialRecord])] → [Instance] → Chunk
built kind records = either (error . ("the chunk was refused: " <>) . show) id . buildChunkWith marks kind DeriveBounds (Map.fromList records)

-- | The material and parameter word of each of a plan's runs' paths, in order,
-- with the record source and the count.
shape ∷ PlannedLayer → [(DrawPath, MaterialRef, RecordSource, Int)]
shape layer = [(runPath run, runMaterial run, runRecords run, runCount run) | run ← plannedRuns layer]

spec ∷ Spec
spec = describe "Application materials" $ do
  referenceSpec
  routingSpec
  runsSpec
  recordSourceSpec
  viewSpec
  chunkSpec
  encodingSpec

-- * The reference

referenceSpec ∷ Spec
referenceSpec = describe "a material reference" $ do
  it "has the default material's constant facts: cutout-capable, an empty record, no push block" $ do
    materialCutoutCapable defaultMaterial `shouldBe` True
    materialRecordLayout defaultMaterial `shouldBe` RecordLayout 0 0
    materialPushBytes defaultMaterial `shouldBe` 0
    materialFacts defaultMaterial `shouldBe` MaterialFacts True (RecordLayout 0 0) 0
    materialRefIdentity defaultMaterial `shouldBe` defaultMaterialIdentity
  it "is the default material that an instance names unless it says otherwise" $
    instanceMaterial plainInstance `shouldBe` defaultMaterial
  it "carries exactly the facts it was built with, and reads them back" $ do
    materialCutoutCapable mixMaterial `shouldBe` True
    materialCutoutCapable translucentMaterial `shouldBe` False
    materialRecordLayout mixMaterial `shouldBe` RecordLayout 1 1
    materialRecordLayout twoHandles `shouldBe` RecordLayout 2 0
    materialPushBytes mixMaterial `shouldBe` 16
    materialPushBytes pushOnly `shouldBe` 4
    materialRefIdentity mixMaterial `shouldBe` 3
  it "is equal to another reference only when the identity and every fact agree" $ do
    mixMaterial `shouldBe` refWith 3 True (1, 1) 16
    mixMaterial `shouldSatisfy` (/= refWith 3 False (1, 1) 16)
    mixMaterial `shouldSatisfy` (/= refWith 3 True (1, 2) 16)
    mixMaterial `shouldSatisfy` (/= refWith 3 True (1, 1) 20)
    mixMaterial `shouldSatisfy` (/= refWith 9 True (1, 1) 16)
  it "is comparable, ordered and showable" $ do
    compare defaultMaterial plainMaterial `shouldBe` LT
    Set.size (Set.fromList [defaultMaterial, plainMaterial, mixMaterial, mixMaterial]) `shouldBe` 3
    show mixMaterial `shouldSatisfy` (not . null)
  it "measures a record in bytes: eight for a handle, four for a word" $ do
    recordLayoutBytes (RecordLayout 0 0) `shouldBe` 0
    recordLayoutBytes (RecordLayout 1 1) `shouldBe` 12
    recordLayoutBytes (RecordLayout 2 3) `shouldBe` 28
    recordLayoutIsEmpty (RecordLayout 0 0) `shouldBe` True
    recordLayoutIsEmpty (RecordLayout 0 1) `shouldBe` False
    recordLayoutIsEmpty (RecordLayout 1 0) `shouldBe` False

-- * Routing

routingSpec ∷ Spec
routingSpec = describe "routing by the material's capability" $ do
  let depthLayer = WorldLayer DepthEnabled
      pathsOf instances = [runPath run | run ← plannedRuns (planOf [] (plainView [depthLayer instances]))]
  it "sends a cutout-capable application material's marked, opaque instance to the cutout path" $
    pathsOf [using plainMaterial 0] `shouldBe` [Cutout]
  it "sends an instance of a material that is not cutout-capable to the ordered path, though everything else qualifies" $
    pathsOf [using translucentMaterial 0] `shouldBe` [Ordered]
  it "routes each instance by its own material's capability in one layer: the two cutout materials' runs, then the ordered one" $
    pathsOf [using translucentMaterial 0, using plainMaterial 0, plainInstance] `shouldBe` [Cutout, Cutout, Ordered]
  it "routes by the capability of the reference, not by its identity" $ do
    pathsOf [using (refWith 1 False (0, 0) 0) 0] `shouldBe` [Ordered]
    pathsOf [using (refWith 1 True (0, 0) 0) 0] `shouldBe` [Cutout]
  it "keeps a material that is cutout-capable on the ordered path where the layer has no depth, in a UI layer, and when the tint is translucent" $ do
    [runPath run | run ← plannedRuns (planOf [] (plainView [WorldLayer DepthDisabled [using plainMaterial 0]]))] `shouldBe` [Ordered]
    [runPath run | run ← plannedRuns (planOf [] (plainView [UiLayer [using plainMaterial 0]]))] `shouldBe` [Ordered]
    pathsOf [(using plainMaterial 0) {instanceTint = Tint 255 255 255 254}] `shouldBe` [Ordered]
  it "routes a chunk's instances by their materials when it is built" $ do
    let chunk = built ChunkWorldDepth [] [using plainMaterial 0, using translucentMaterial 0, plainInstance]
    chunkCutoutPositions chunk `shouldBe` [2, 0]
    chunkOrderedPositions chunk `shouldBe` [1]

-- * Runs

runsSpec ∷ Spec
runsSpec = describe "runs by material" $ do
  let depthLayer = WorldLayer DepthEnabled
      cutoutRuns layer = [(runMaterial run, runCount run) | run ← plannedRuns layer, runPath run == Cutout]
  it "splits the cutout runs by material and orders them by the reference" $ do
    let layer = planOf [] (plainView [depthLayer [using otherMaterial 0, plainInstance, using plainMaterial 0, using otherMaterial 0, plainInstance, using plainMaterial 0]])
    cutoutRuns layer
      `shouldBe` [(defaultMaterial, 2), (plainMaterial, 2), (otherMaterial, 2)]
  it "draws a material's cutouts in submission order inside its run" $ do
    let instances = [(using plainMaterial 5) {instanceDepthKey = 3}, plainInstance {instanceDepthKey = 1}, (using plainMaterial 6) {instanceDepthKey = 2}]
        layer = planOf [] (plainView [depthLayer instances])
    drawingOrder layer `shouldBe` [1, 0, 2]
  it "splits an ordered run where the material changes, and only there" $ do
    let instances = [using translucentMaterial 0, using translucentMaterial 1, using pushOnly 0, using translucentMaterial 2, plainInstance {instanceTranslucent = True}]
        keyed = zipWith (\key candidate → candidate {instanceDepthKey = key}) [0 ..] instances
        layer = planOf [] (viewHolding [(pushOnly, MaterialData [] (block 4))] [UiLayer keyed])
    [(runMaterial run, runCount run) | run ← plannedRuns layer]
      `shouldBe` [(translucentMaterial, 2), (pushOnly, 1), (translucentMaterial, 1), (defaultMaterial, 1)]
  it "does not split a run on the parameter word, which travels in the instance" $ do
    let layer = planOf [] (plainView [UiLayer [using translucentMaterial n | n ← [0 .. 9]]])
    [(runMaterial run, runCount run) | run ← plannedRuns layer] `shouldBe` [(translucentMaterial, 10)]
  it "holds at most two runs for a layer of the default material alone" $ do
    let layer = planOf [] (plainView [depthLayer [plainInstance, plainInstance {instanceTranslucent = True}, plainInstance]])
    length (plannedRuns layer) `shouldBe` 2

-- * Record sources

recordSourceSpec ∷ Spec
recordSourceSpec = describe "runs and their record sources" $ do
  let listed kind records = built kind records
      a = chunkRef 1 1
      b = chunkRef 2 1
      -- The same material and parameter index in both chunks and the view, with
      -- different contents in each.
      chunkA = listed ChunkUi [(mixMaterial, [mixRecord 1])] [(using mixMaterial 0) {instanceDepthKey = 1}]
      chunkB = listed ChunkUi [(mixMaterial, [mixRecord 2])] [(using mixMaterial 0) {instanceDepthKey = 1}]
      dynamic = (using mixMaterial 0) {instanceDepthKey = 1}
      mixData = MaterialData [mixRecord 3] (block 16)
      view layers = viewHolding [(mixMaterial, mixData)] layers
  it "splits the ordered run between the view's records and each chunk's, though path and material match" $ do
    let layer = planOf [(a, chunkA), (b, chunkB)] (view [UiLayerWith [a, b] [dynamic]])
    shape layer
      `shouldBe` [ (Ordered, mixMaterial, ChunkRecords 0, 1)
                 , (Ordered, mixMaterial, ChunkRecords 1, 1)
                 , (Ordered, mixMaterial, ViewRecords, 1)
                 ]
  it "keeps the drawing order the merge gives, splitting between sources without reordering" $ do
    let layer = planOf [(a, chunkA), (b, chunkB)] (view [UiLayerWith [a, b] [dynamic]])
        defaulted = planOf [(a, built ChunkUi [] [plainInstance {instanceDepthKey = 1}]), (b, built ChunkUi [] [plainInstance {instanceDepthKey = 1}])] (plainView [UiLayerWith [a, b] [plainInstance {instanceDepthKey = 1}]])
    drawingSources layer `shouldBe` drawingSources defaulted
    drawingSources layer `shouldBe` [ChunkInstance 0 0, ChunkInstance 1 0, DynamicInstance 0]
  it "does not split a run of a material that has no records, whatever its source" $ do
    let chunkP = listed ChunkUi [] [(using translucentMaterial 0) {instanceDepthKey = 1}]
        chunkQ = listed ChunkUi [] [(using translucentMaterial 0) {instanceDepthKey = 1}]
        layer = planOf [(a, chunkP), (b, chunkQ)] (plainView [UiLayerWith [a, b] [(using translucentMaterial 0) {instanceDepthKey = 1}]])
    shape layer `shouldBe` [(Ordered, translucentMaterial, NoRecords, 3)]
  it "names no records for the default material" $ do
    let chunkD = listed ChunkUi [] [plainInstance]
        layer = planOf [(a, chunkD)] (plainView [UiLayerWith [a] [plainInstance]])
    map (\(_, _, source, _) → source) (shape layer) `shouldBe` [NoRecords]
  it "splits a chunk's cutout runs from the view's and gives each its source" $ do
    let chunkC = listed ChunkWorldDepth [(mixMaterial, [mixRecord 1, mixRecord 2])] [using mixMaterial 1, using mixMaterial 0]
        layer = planOf [(a, chunkC)] (view [WorldLayerWith DepthEnabled [a] [using mixMaterial 0]])
    shape layer
      `shouldBe` [ (Cutout, mixMaterial, ChunkRecords 0, 2)
                 , (Cutout, mixMaterial, ViewRecords, 1)
                 ]
  it "puts a chunk listed twice at each listing's own source" $ do
    let chunkD = listed ChunkUi [(mixMaterial, [mixRecord 1])] [(using mixMaterial 0) {instanceDepthKey = 1}]
        layer = planOf [(a, chunkD)] (view [UiLayerWith [a, a] []])
    [source | (_, _, source, _) ← shape layer] `shouldBe` [ChunkRecords 0, ChunkRecords 1]

-- * A view's data

viewSpec ∷ Spec
viewSpec = describe "the material data a view holds" $ do
  let refuse location reason = [Refusal location reason]
      layerOf instances = [UiLayer instances]
      withData held instances = refusalsAgainst [] (viewHolding held (layerOf instances))
      mixData records size = MaterialData records (block size)
  it "needs nothing for the default material: no record, no push block, any parameter word" $
    refusalsAgainst [] (plainView (layerOf [plainInstance {instanceParameter = 0xFFFFFFFF}])) `shouldBe` []
  it "needs nothing for a material whose record is empty and whose push block is empty, and passes its parameter word through" $
    withData [] [using plainMaterial 0xFFFFFFFF, using translucentMaterial 123456] `shouldBe` []
  it "accepts a parameter word that indexes one of the records" $
    withData [(mixMaterial, mixData [mixRecord 0, mixRecord 1] 16)] [using mixMaterial 0, using mixMaterial 1] `shouldBe` []
  it "refuses a parameter word beyond the records, naming the instance" $
    withData [(mixMaterial, mixData [mixRecord 0, mixRecord 1] 16)] [using mixMaterial 0, using mixMaterial 2]
      `shouldBe` refuse (AtInstance 0 0 0 1) ParameterBeyondRecords
  it "refuses any parameter word for a material that has a record layout and no records in the view" $
    withData [] [using twoHandles 0] `shouldBe` refuse (AtInstance 0 0 0 0) ParameterBeyondRecords
  it "refuses a parameter word that is not below the number of records, at its edge" $ do
    withData [(mixMaterial, mixData [mixRecord 0] 16)] [using mixMaterial 0xFFFFFFFF] `shouldBe` refuse (AtInstance 0 0 0 0) ParameterBeyondRecords
    withData [(mixMaterial, mixData [mixRecord 0] 16)] [using mixMaterial 1] `shouldBe` refuse (AtInstance 0 0 0 0) ParameterBeyondRecords
  it "refuses a record whose handles or words are not the layout the material declares, naming it" $ do
    withData [(mixMaterial, mixData [mixRecord 0, recordOf [] [1], recordOf [(1, 1), (2, 1)] [1], recordOf [(1, 1)] [], recordOf [(1, 1)] [1, 2]] 16)] []
      `shouldBe` [Refusal (AtRecord 0 0 mixMaterial index) RecordLayoutMismatch | index ← [1, 2, 3, 4]]
  it "refuses a record of the wrong layout even where no instance uses it" $
    withData [(twoHandles, mixData [recordOf [(1, 1)] []] 0)] []
      `shouldBe` refuse (AtRecord 0 0 twoHandles 0) RecordLayoutMismatch
  it "refuses a push block whose size is not the one the material declares" $ do
    withData [(mixMaterial, mixData [mixRecord 0] 12)] [using mixMaterial 0] `shouldBe` refuse (AtPushBlock 0 0 mixMaterial) PushBlockSizeMismatch
    withData [(mixMaterial, mixData [mixRecord 0] 20)] [using mixMaterial 0] `shouldBe` refuse (AtPushBlock 0 0 mixMaterial) PushBlockSizeMismatch
    withData [(plainMaterial, mixData [] 4)] [using plainMaterial 0] `shouldBe` refuse (AtPushBlock 0 0 plainMaterial) PushBlockSizeMismatch
  it "refuses a missing push block for a material the view uses and that declares one" $ do
    withData [(mixMaterial, MaterialData [mixRecord 0] ByteString.empty)] [using mixMaterial 0] `shouldBe` refuse (AtPushBlock 0 0 mixMaterial) PushBlockSizeMismatch
    withData [] [using pushOnly 0] `shouldBe` refuse (AtPushBlock 0 0 pushOnly) PushBlockMissing
    withData [] [using pushOnly 0, using pushOnly 1] `shouldBe` refuse (AtPushBlock 0 0 pushOnly) PushBlockMissing
  it "accepts a push block of the declared size for several sizes" $ do
    withData [(pushOnly, mixData [] 4)] [using pushOnly 0] `shouldBe` []
    withData [(mixMaterial, mixData [mixRecord 0] 16)] [using mixMaterial 0] `shouldBe` []
    withData [(refWith 7 True (0, 0) 64, mixData [] 64)] [using (refWith 7 True (0, 0) 64) 0] `shouldBe` []
  it "does not ask for a push block of a material the view does not use" $
    withData [] [plainInstance] `shouldBe` []
  it "names where each refusal was found, in the order of the view's checks" $ do
    let bad = mixData [mixRecord 0, recordOf [] []] 8
    withData [(mixMaterial, bad)] [using mixMaterial 5]
      `shouldBe` [ Refusal (AtRecord 0 0 mixMaterial 1) RecordLayoutMismatch
                 , Refusal (AtPushBlock 0 0 mixMaterial) PushBlockSizeMismatch
                 , Refusal (AtInstance 0 0 0 0) ParameterBeyondRecords
                 ]
  it "keeps its checks inside a zero-size viewport" $ do
    let zero = (viewHolding [(mixMaterial, mixData [mixRecord 0] 12)] (layerOf [using mixMaterial 4])) {viewViewport = Viewport (V2 0 0) (V2 0 0)}
    refusalsAgainst [] zero
      `shouldBe` [ Refusal (AtPushBlock 0 0 mixMaterial) PushBlockSizeMismatch
                 , Refusal (AtInstance 0 0 0 0) ParameterBeyondRecords
                 ]
  it "checks the data of every view, naming the view" $ do
    let good = viewHolding [(mixMaterial, mixData [mixRecord 0] 16)] (layerOf [using mixMaterial 0])
        bad = viewHolding [] (layerOf [using mixMaterial 0])
    refusalsAgainst [] bad `shouldBe` [Refusal (AtPushBlock 0 0 mixMaterial) PushBlockMissing, Refusal (AtInstance 0 0 0 0) ParameterBeyondRecords]
    either (foldr (:) []) (const []) (validateSnapshotWith noChunks (Snapshot [windowPass [good, bad]]))
      `shouldBe` [Refusal (AtPushBlock 0 1 mixMaterial) PushBlockMissing, Refusal (AtInstance 0 1 0 0) ParameterBeyondRecords]
  it "asks a view for the push block of a material a chunk it lists uses" $ do
    let chunk = built ChunkUi [] [using pushOnly 0]
        reference = chunkRef 1 1
    refusalsAgainst [(reference, chunk)] (plainView [UiLayerWith [reference] []]) `shouldBe` refuse (AtPushBlock 0 0 pushOnly) PushBlockMissing
    refusalsAgainst [(reference, chunk)] (viewHolding [(pushOnly, mixData [] 4)] [UiLayerWith [reference] []]) `shouldBe` []
  it "does not ask for a push block of a chunk the view does not list" $
    refusalsAgainst [(chunkRef 1 1, built ChunkUi [] [using pushOnly 0])] (plainView [UiLayer []]) `shouldBe` []
  it "keeps the view a plain value: the constructor without data builds one with none" $ do
    viewMaterials (plainView []) `shouldBe` Map.empty
    case plainView [UiLayer []] of
      View _ _ _ _ layers → length layers `shouldBe` 1
      ViewWith {} → expectationFailure "the view holds data for a material, though it was built with none"
    case viewHolding [(mixMaterial, noMaterialData)] [] of
      View {} → expectationFailure "a view holding data for a material matches the pattern for one that holds none"
      ViewWith {} → pure ()
  it "is exercised for each new reason" $
    sequence_
      [ reason `shouldSatisfy` (`elem` [ParameterBeyondRecords, RecordLayoutMismatch, PushBlockSizeMismatch, PushBlockMissing])
      | reason ← [ParameterBeyondRecords, RecordLayoutMismatch, PushBlockSizeMismatch, PushBlockMissing]
      ]

-- * A chunk's records

chunkSpec ∷ Spec
chunkSpec = describe "the records a chunk carries" $ do
  let records = [(mixMaterial, [mixRecord 0, mixRecord 1])]
  it "keeps its records, its materials and the handles its records hold" $
    sequence_
      [ do
          let chunk = built kind records [using mixMaterial 1, plainInstance]
          chunkRecords chunk `shouldBe` Map.fromList records
          chunkMaterials chunk `shouldBe` Set.fromList [mixMaterial, defaultMaterial]
          chunkTextures chunk `shouldBe` Set.fromList [instanceTexture plainInstance, textureHandle 10 1, textureHandle 11 1]
      | kind ← [minBound .. maxBound]
      ]
  it "builds a chunk with no records as buildChunk does" $
    sequence_ [buildChunkWith marks kind DeriveBounds Map.empty [plainInstance] `shouldBe` buildChunk marks kind DeriveBounds [plainInstance] | kind ← [minBound .. maxBound]]
  it "refuses a parameter word beyond the chunk's records, naming the instance" $
    buildChunkWith marks ChunkUi DeriveBounds (Map.fromList records) [using mixMaterial 0, using mixMaterial 2, using mixMaterial 7]
      `shouldBe` Left (ChunkParameterBeyondRecords 1 :| [ChunkParameterBeyondRecords 2])
  it "refuses an instance of a material with records when the chunk holds none for it" $
    buildChunkWith marks ChunkUi DeriveBounds Map.empty [using mixMaterial 0] `shouldBe` Left (ChunkParameterBeyondRecords 0 :| [])
  it "refuses a record of the wrong layout, naming the material and the record" $
    buildChunkWith marks ChunkUi DeriveBounds (Map.fromList [(mixMaterial, [mixRecord 0, recordOf [] [1]]), (twoHandles, [recordOf [(1, 1), (2, 2)] [], recordOf [(1, 1)] []])]) [using mixMaterial 0]
      `shouldBe` Left (ChunkRecordMismatch mixMaterial 1 :| [ChunkRecordMismatch twoHandles 1])
  it "reports instance refusals first, then record ones, then the bounds'" $ do
    let bad = (using mixMaterial 3) {instanceDepthKey = 16777216}
    buildChunkWith marks ChunkUi (SuppliedBounds (Bounds (V2 5 5) (V2 6 6))) (Map.fromList [(mixMaterial, [recordOf [] []])]) [bad]
      `shouldBe` Left (ChunkInstanceInvalid 0 DepthKeyTooLarge :| [ChunkRecordMismatch mixMaterial 0, ChunkParameterBeyondRecords 0, ChunkBoundsInsufficient])
  it "does not index records for a material whose layout is empty" $
    buildChunkWith marks ChunkUi DeriveBounds Map.empty [using plainMaterial 99, using translucentMaterial 4] `shouldSatisfy` either (const False) (const True)
  it "lists a chunk with different records for the same parameter index, each at its own source" $ do
    let one = built ChunkUi [(mixMaterial, [mixRecord 1])] [using mixMaterial 0]
        other = built ChunkUi [(mixMaterial, [mixRecord 2])] [using mixMaterial 0]
        a = chunkRef 1 1
        b = chunkRef 2 1
    one `shouldSatisfy` (/= other)
    chunkRecords one `shouldSatisfy` (/= chunkRecords other)
    refusalsAgainst [(a, one), (b, other)] (viewHolding [(mixMaterial, MaterialData [] (block 16))] [UiLayerWith [a, b] []]) `shouldBe` []

-- * The encoding

encodingSpec ∷ Spec
encodingSpec = describe "encoding records" $ do
  let bytes ∷ [Word8] → ByteString.ByteString
      bytes = ByteString.pack
      littleEndian ∷ Word32 → [Word8]
      littleEndian n = [fromIntegral (n `div` (256 ^ k)) | k ← [0 .. 3 ∷ Int]]
  it "writes a record as each handle's lookup index and generation, then its words, little-endian" $
    encodeRecords (RecordLayout 1 2) [recordOf [(0x01020304, 0x0A0B0C0D)] [7, 0xDEADBEEF]]
      `shouldBe` bytes ([0x04, 0x03, 0x02, 0x01, 0x0D, 0x0C, 0x0B, 0x0A] <> [7, 0, 0, 0] <> [0xEF, 0xBE, 0xAD, 0xDE])
  it "writes record after record with no padding, so record k starts at k times the record's size" $ do
    let records = [recordOf [(n, n + 100)] [n * 2] | n ← [1 .. 5]]
        encoded = encodeRecords (RecordLayout 1 1) records
    ByteString.length encoded `shouldBe` 5 * fromIntegral (recordLayoutBytes (RecordLayout 1 1))
    sequence_
      [ ByteString.take 12 (ByteString.drop (12 * k) encoded) `shouldBe` bytes (littleEndian n <> littleEndian (n + 100) <> littleEndian (n * 2))
      | (k, n) ← zip [0 ..] [1 .. 5]
      ]
  it "writes several handles in order and no words, or words and no handle" $ do
    encodeRecords (RecordLayout 2 0) [recordOf [(1, 2), (3, 4)] []] `shouldBe` bytes (concatMap littleEndian [1, 2, 3, 4])
    encodeRecords (RecordLayout 0 3) [recordOf [] [9, 8, 7]] `shouldBe` bytes (concatMap littleEndian [9, 8, 7])
  it "writes no byte for no record and for a layout that holds nothing" $ do
    encodeRecords (RecordLayout 1 1) [] `shouldBe` ByteString.empty
    encodeRecords (RecordLayout 0 0) [recordOf [] [], recordOf [] []] `shouldBe` ByteString.empty
  it "is total: a record cut short is padded with zero words and one that is longer is cut off at the layout" $ do
    encodeRecords (RecordLayout 1 2) [recordOf [] [5]] `shouldBe` bytes (concatMap littleEndian [0, 0, 5, 0])
    encodeRecords (RecordLayout 1 1) [recordOf [(1, 2), (3, 4)] [5, 6]] `shouldBe` bytes (concatMap littleEndian [1, 2, 5])
  it "leaves the 64-byte instance encoding as it was: the material is never encoded" $ do
    let withMaterial = [using mixMaterial 3, using twoHandles 4, using translucentMaterial 5]
        withDefault = [plainInstance {instanceParameter = n} | n ← [3, 4, 5]]
        held = [(mixMaterial, MaterialData (map mixRecord [0 .. 5]) (block 16)), (twoHandles, MaterialData (replicate 5 (recordOf [(1, 1), (2, 2)] [])) ByteString.empty)]
        layerBytes instances = case validateSnapshotWith noChunks (snapshotOf (viewHolding held [UiLayer instances])) of
          Right valid | [layer] ← validLayers valid → encodeLayer layer
          other → error ("the layer was not validated: " <> either show (const "more than one layer") other)
    layerBytes withMaterial `shouldBe` layerBytes withDefault
    ByteString.length (layerBytes withMaterial) `shouldBe` 3 * 64
  it "encodes a planned layer's instances in drawing order the same whichever material they name" $ do
    let instances = [(using translucentMaterial n) {instanceDepthKey = 3 - n, instanceTranslucent = True} | n ← [0 .. 2]]
        plain' = [plainInstance {instanceParameter = n, instanceDepthKey = 3 - n, instanceTranslucent = True} | n ← [0 .. 2]]
        encodedIn layers = case validateSnapshotWith noChunks (snapshotOf (plainView layers)) of
          Right valid → case (validLayers valid, planPasses (planSnapshot marks valid)) of
            ([layer], [PlannedPass {plannedViews = [PlannedView {plannedLayers = [planned]}]}]) → encodeLayerInDrawingOrder planned layer
            _ → Nothing
          Left _ → Nothing
    encodedIn [UiLayer instances] `shouldBe` encodedIn [UiLayer plain']
    fmap ByteString.length (encodedIn [UiLayer instances]) `shouldBe` Just 192
