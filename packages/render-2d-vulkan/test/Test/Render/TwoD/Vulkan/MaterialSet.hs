-- | The material check of a frame and of a publication ('unissuedMaterial'),
-- compared with the scan of every instance it replaced for retained content.
--
-- A chunk a layer lists is checked by the set of materials its build recorded,
-- and its instances are scanned only to find where a refused material is first
-- used. These examples hold that to the answer the full scan gives, for every
-- snapshot: the same refusal, the same first instance in snapshot order (a
-- layer's dynamic instances before its chunks, chunks in listed order, an
-- instance's build order within a chunk), the same location and references.
--
-- __Where the expected values come from.__ Never from the function under test.
-- The named examples carry answers worked out by hand from the snapshot's order
-- and the session's issued materials. The property's reference is the scan
-- written out here, over every instance of every layer and every chunk each layer
-- lists, with no use of a chunk's material set.
module Test.Render.TwoD.Vulkan.MaterialSet (spec) where

import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), Chunk, ChunkKind (..), buildChunk, chunkInstances, chunkMaterials, chunksFrom)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRef, RecordLayout (..), defaultMaterial)
import Hetoimasia.Render.TwoD.Material.Backend (materialRef, materialRefIdentity)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , ValidLayer
  , ValidSnapshot
  , validLayerChunks
  , validLayerContents
  , validLayerLocation
  , validLayers
  , validateSnapshotWith
  )
import Hetoimasia.Render.TwoD.Vulkan.Frame (FrameRefusal (..), unissuedMaterial)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe)
import Test.QuickCheck
  ( Gen
  , checkCoverage
  , choose
  , cover
  , elements
  , forAll
  , frequency
  , listOf
  , oneof
  , property
  , vectorOf
  , withNumTests
  )

spec ∷ Spec
spec = describe "The material check of retained content" $ do
  namedSpec
  propertySpec

-- ---------------------------------------------------------------------------
-- The session and the references

-- | A material of this identity declaring these facts.
reference ∷ Word64 → Bool → MaterialRef
reference identity cutout = materialRef identity (MaterialFacts cutout (RecordLayout 0 0) 0)

-- | The identity the built-in default is issued under.
defaultIdentity ∷ Word64
defaultIdentity = materialRefIdentity defaultMaterial

-- | What the session issued: for each of these identities, a reference with one
-- of the two facts it may declare, or nothing; the built-in default, as a
-- constant, to every session.
sessionOf ∷ [(Word64, Maybe Bool)] → Word64 → Maybe MaterialRef
sessionOf issuedFacts = \identity →
  if identity == defaultIdentity then Just defaultMaterial else Map.lookup identity table
  where
    table = Map.fromList [(at, reference at cutout) | (at, Just cutout) ← issuedFacts]

-- ---------------------------------------------------------------------------
-- Snapshots

-- | A unit sprite of this material at this x.
sprite ∷ MaterialRef → Float → Instance
sprite material x =
  Instance
    { instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 x 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = textureHandle 1 1
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceFrameTable = 0
    , instanceParameter = 0
    , instanceMaterial = material
    }

-- | A UI chunk of these instances, which share no record: the built-in default
-- or a material whose layout is empty.
chunkOf ∷ [Instance] → Chunk
chunkOf instances = either (error . ("the chunk was refused: " <>) . show) id (buildChunk noCutoutMarks ChunkUi DeriveBounds instances)

-- | A snapshot of one offscreen pass whose views hold these layers, each a UI
-- layer listing these chunks, by position in the table, and holding these
-- dynamic instances, over this table of chunks.
snapshotOf ∷ [Chunk] → [[([Int], [Instance])]] → ValidSnapshot
snapshotOf chunks views =
  case validateSnapshotWith (chunksFrom table) (Snapshot [Pass (OffscreenTarget (targetRef 2 1)) (ClearColour 0 0 0 1) (map viewOf views)]) of
    Right found → found
    Left refused → error ("the snapshot was refused: " <> show refused)
  where
    table = [(chunkRef (fromIntegral position) 1, chunk) | (position, chunk) ← zip [0 ∷ Int ..] chunks]
    viewOf layers = ViewWith (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] Map.empty [] 0 [UiLayerWith [fst (table !! position) | position ← listed] dynamic | (listed, dynamic) ← layers]

-- ---------------------------------------------------------------------------
-- The reference scan

-- | The first instance of the snapshot naming a material the session did not
-- issue, or naming one with other facts, found by looking at every instance of
-- every layer and of every chunk each layer lists, in snapshot order.
scanned ∷ (Word64 → Maybe MaterialRef) → ValidSnapshot → Maybe FrameRefusal
scanned issued = listToMaybe . concatMap layerRefusals . validLayers
  where
    layerRefusals ∷ ValidLayer → [FrameRefusal]
    layerRefusals layer =
      [ refusal
      | (index, candidate) ← zip [0 ..] (layerInstances (validLayerContents layer))
      , Just refusal ← [judge (instanceAt layer index) (instanceMaterial candidate)]
      ]
        <> [ refusal
           | (position, (_, built)) ← zip [0 ..] (validLayerChunks layer)
           , (index, candidate) ← zip [0 ..] (chunkInstances built)
           , Just refusal ← [judge (chunkInstanceAt layer position index) (instanceMaterial candidate)]
           ]
    instanceAt layer index = case validLayerLocation layer of
      AtLayer pass view held → AtInstance pass view held index
      other → other
    chunkInstanceAt layer position index = case validLayerLocation layer of
      AtLayer pass view held → AtChunkInstance pass view held position index
      other → other
    judge location material
      | material == defaultMaterial = Nothing
      | otherwise = case issued (materialRefIdentity material) of
          Nothing → Just (MaterialNotIssued location material)
          Just held
            | held == material → Nothing
            | otherwise → Just (MaterialFactsDisagree location material held)

-- ---------------------------------------------------------------------------
-- Named examples

-- | A session that issued 1 and 2 as cutout-capable and 3 not, and nothing else.
named ∷ Word64 → Maybe MaterialRef
named = sessionOf [(1, Just True), (2, Just True), (3, Just False)]

good1, good2, good3, never9, never8, lying2 ∷ MaterialRef
good1 = reference 1 True
good2 = reference 2 True
good3 = reference 3 False
never9 = reference 9 True
never8 = reference 8 True
lying2 = reference 2 False

-- | The check's answer for the snapshot, and the scan's, are both this.
answers ∷ ValidSnapshot → Maybe FrameRefusal → Expectation
answers snapshot expected = (unissuedMaterial named snapshot, scanned named snapshot) `shouldBe` (expected, expected)

namedSpec ∷ Spec
namedSpec = describe "answers worked out from the snapshot's order" $ do
  it "accepts a snapshot whose chunks use only issued materials, listed twice, empty or outside the view" $ do
    let chunk = chunkOf [sprite good1 0, sprite good2 1, sprite good3 2, sprite defaultMaterial 3, sprite good1 900]
        snapshot = snapshotOf [chunk, chunkOf [sprite good2 4000]] [[([0, 0, 1], [sprite good1 0]), ([], [sprite good3 0]), ([1], [])]]
    snapshot `answers` Nothing

  it "names the first instance of a refused chunk in its build order, not the first instance of the first refused material in the set's order" $ do
    -- The chunk's set holds 8 and 9, and 8 sorts first; the instance that comes
    -- first uses 9.
    let chunk = chunkOf [sprite good1 0, sprite never9 1, sprite never8 2, sprite never9 3]
        snapshot = snapshotOf [chunk] [[([0], [])]]
    snapshot `answers` Just (MaterialNotIssued (AtChunkInstance 0 0 0 0 1) never9)

  it "names an issued identity declared with other facts, with the issued reference, where it is first used in a chunk" $ do
    let chunk = chunkOf [sprite good1 0, sprite lying2 1, sprite good2 2]
        snapshot = snapshotOf [chunk] [[([0], [])]]
    snapshot `answers` Just (MaterialFactsDisagree (AtChunkInstance 0 0 0 0 1) lying2 good2)

  it "names a reference with the default's identity and other facts, in a chunk" $ do
    let lyingDefault = reference defaultIdentity False
        chunk = chunkOf [sprite defaultMaterial 0, sprite lyingDefault 1]
        snapshot = snapshotOf [chunk] [[([0], [])]]
    snapshot `answers` Just (MaterialFactsDisagree (AtChunkInstance 0 0 0 0 1) lyingDefault defaultMaterial)

  it "names a layer's dynamic instance before a refused chunk it lists" $ do
    let chunk = chunkOf [sprite never9 0]
        snapshot = snapshotOf [chunk] [[([0], [sprite good1 0, sprite never8 1])]]
    snapshot `answers` Just (MaterialNotIssued (AtInstance 0 0 0 1) never8)

  it "names an earlier layer's refused chunk before a later layer's refused dynamic instance, and the chunk listed first of those a layer lists" $ do
    let ok = chunkOf [sprite good1 0]
        bad = chunkOf [sprite good2 0, sprite never9 1]
        worse = chunkOf [sprite never8 0]
        snapshot = snapshotOf [ok, bad, worse] [[([0, 1, 2], []), ([], [sprite never8 0])]]
    snapshot `answers` Just (MaterialNotIssued (AtChunkInstance 0 0 0 1 1) never9)

  it "names the second view's layer when the first view's chunks are all issued, and counts a repeated listing's position" $ do
    let ok = chunkOf [sprite good1 0]
        bad = chunkOf [sprite never9 0]
        snapshot = snapshotOf [ok, bad] [[([0], [])], [([0, 0, 1], [])]]
    snapshot `answers` Just (MaterialNotIssued (AtChunkInstance 0 1 0 2 0) never9)

-- ---------------------------------------------------------------------------
-- The property

-- | The references a generated snapshot may use: the default, a reference with
-- the default's identity and other facts, and, for each of five identities, both
-- facts it may declare.
universe ∷ [MaterialRef]
universe = defaultMaterial : reference defaultIdentity False : [reference identity cutout | identity ← [1 .. 5], cutout ← [False, True]]

-- | What the session issued of each of the five identities.
sessionGen ∷ Gen [(Word64, Maybe Bool)]
sessionGen = mapM (\identity → (,) identity <$> elements [Nothing, Just False, Just True]) [1 .. 5]

-- | A material for one instance: mostly one the session issued, as often as the
-- snapshot's chosen weight says any reference at all.
materialGen ∷ [(Word64, Maybe Bool)] → Int → Gen MaterialRef
materialGen issuedFacts badness =
  frequency
    [ (10, elements (defaultMaterial : [reference identity cutout | (identity, Just cutout) ← issuedFacts]))
    , (badness, elements universe)
    ]

-- | A chunk of one to six instances of generated materials, some far outside the
-- 16 × 16 view.
chunkGen ∷ Gen MaterialRef → Gen Chunk
chunkGen material = do
  count ← choose (1, 6)
  materials ← vectorOf count material
  positions ← vectorOf count (elements [0, 3, 700, 5000])
  pure (chunkOf (zipWith sprite materials positions))

-- | One to three views of one to three layers, each listing up to four chunks
-- (a position may repeat) and holding up to three dynamic instances.
viewsGen ∷ Gen MaterialRef → Int → Gen [[([Int], [Instance])]]
viewsGen material chunkCount = do
  views ← choose (1, 3)
  vectorOf views $ do
    layers ← choose (1, 3)
    vectorOf layers $ do
      listed ← if chunkCount == 0 then pure [] else listOf (choose (0, chunkCount - 1))
      dynamic ← do
        count ← choose (0, 3)
        materials ← vectorOf count material
        pure (zipWith sprite materials [0 ..])
      pure (take 4 listed, dynamic)

snapshotGen ∷ Gen ([(Word64, Maybe Bool)], ValidSnapshot)
snapshotGen = do
  issuedFacts ← sessionGen
  -- How willing this snapshot is to name a material that may not be issued: none
  -- at all, now and then, or often.
  badness ← elements [0, 1, 1, 2, 4]
  let material = materialGen issuedFacts badness
  chunks ← do
    count ← oneof [pure 0, choose (1, 4)]
    vectorOf count (chunkGen material)
  views ← viewsGen material (length chunks)
  pure (issuedFacts, snapshotOf chunks views)

propertySpec ∷ Spec
propertySpec = describe "against a scan of every instance" $
  it "answers as the scan does, for generated snapshots whose chunks mix issued, unissued and fact-disagreeing materials" $
    property $
      withNumTests 3000 $
        forAll snapshotGen $ \(issuedFacts, snapshot) →
          let issued = sessionOf issuedFacts
              answer = unissuedMaterial issued snapshot
              expected = scanned issued snapshot
              layers = validLayers snapshot
              -- What the generated cases must keep exercising, or the property
              -- would pass on a generator that stopped reaching them.
              listings = [map fst (validLayerChunks layer) | layer ← layers]
              refusedInChunk = case answer of
                Just (MaterialNotIssued (AtChunkInstance {}) _) → True
                Just (MaterialFactsDisagree (AtChunkInstance {}) _ _) → True
                _ → False
              refusedDynamic = case answer of
                Just (MaterialNotIssued (AtInstance {}) _) → True
                Just (MaterialFactsDisagree (AtInstance {}) _ _) → True
                _ → False
              bothInvalid = or [any badChunk chunks' && any (not . ok issued . instanceMaterial) (layerInstances (validLayerContents layer)) | layer ← layers, let chunks' = map snd (validLayerChunks layer)]
              badChunk chunk = any (not . ok issued) (Set.toList (chunkMaterials chunk))
              setOrderDiffers = or [not (null invalid) && firstInstance /= Just (Set.findMin (Set.fromList invalid)) | layer ← layers, (_, chunk) ← validLayerChunks layer, let invalid = [material | material ← Set.toList (chunkMaterials chunk), not (ok issued material)], let firstInstance = listToMaybe [instanceMaterial candidate | candidate ← chunkInstances chunk, not (ok issued (instanceMaterial candidate))]]
           in checkCoverage
                . cover 5 (answer == Nothing) "accepted"
                . cover 5 refusedInChunk "refused in a chunk's instance"
                . cover 5 refusedDynamic "refused in a dynamic instance"
                . cover 5 (maybe False isUnissued answer) "a material the session did not issue"
                . cover 5 (maybe False isDisagreeing answer) "a material with other facts"
                . cover 5 bothInvalid "a dynamic instance and a chunk both refused"
                . cover 2 setOrderDiffers "a chunk whose first refused instance is not its smallest refused material"
                . cover 5 (any hasRepeat listings) "a chunk listed twice in one layer"
                . cover 5 (any null listings) "a layer listing no chunk"
                $ answer == expected
  where
    ok issued material = material == defaultMaterial || (issued (materialRefIdentity material) == Just material)
    isUnissued = \case MaterialNotIssued {} → True; _ → False
    isDisagreeing = \case MaterialFactsDisagree {} → True; _ → False
    hasRepeat listing = length listing /= length (nub listing)
