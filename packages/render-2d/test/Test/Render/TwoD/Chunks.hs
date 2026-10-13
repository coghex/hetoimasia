-- | Retained chunks (R2D-10): building and routing them, referencing them from
-- layers, the merge order of a layer's content, culling by bounds, and the
-- encoding of what a backend uploads.
--
-- __Method.__ The examples state their expected outcomes in the test itself,
-- with tags in the material word naming each instance, so an order is read off
-- as a list of tags. The generated examples check an independent
-- characterisation of the merge order (one sequence number for each instance
-- in source order, then a plain sort) rather than rerunning the planner's own
-- composite key, and the culling property compares the answer with a brute
-- force of which pixel centres an instance covers, computed exactly.
--
-- __Kinds.__ A chunk is built for one of three kinds of layer; every claim about
-- a kind is made for all three.
module Test.Render.TwoD.Chunks (spec) where

import Data.Foldable (toList)
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust, mapMaybe)
import qualified Data.Set as Set
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Hetoimasia.Math.Affine2 (columns, fromColumns, toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef, chunkRefGeneration, chunkRefIndex)
import Hetoimasia.Render.TwoD.Culling (chunkCulled)
import Hetoimasia.Render.TwoD.DrawPlan
import Hetoimasia.Render.TwoD.Encoding (encodeChunkCutouts, encodeLayer, encodeLayerInDrawingOrder)
import Hetoimasia.Render.TwoD.Mapping
  ( ViewMapping
  , mappingPixelSnap
  , uiTransform
  , viewMapping
  , worldTransform
  )
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , Reason (..)
  , Refusal (..)
  , ValidLayer
  , validChunkRefs
  , validLayerChunks
  , validLayers
  , validateSnapshot
  , validateSnapshotWith
  )
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , Property
  , arbitrary
  , checkCoverage
  , choose
  , conjoin
  , counterexample
  , cover
  , elements
  , forAll
  , listOf
  , oneof
  , property
  , resize
  , (===)
  )
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Retained chunks" $ do
  referenceSpec
  buildingSpec
  boundsSpec
  validationSpec
  routingSpec
  mergeSpec
  cullingSpec
  encodingSpec
  layerSpec

-- * Builders

markedHandle, unmarkedHandle ∷ TextureHandle
markedHandle = textureHandle 1 1
unmarkedHandle = textureHandle 9 9

marks ∷ CutoutMarks
marks = cutoutMarks [markedHandle]

allKinds ∷ [ChunkKind]
allKinds = [minBound .. maxBound]

-- | A reference by index and generation.
ref ∷ Word32 → Word32 → ChunkRef
ref = chunkRef

-- | An instance in the cutout-eligible shape at this key, tagged in its
-- material word, which neither the plan nor the encoder reads.
cutoutAt ∷ Word32 → Word32 → Instance
cutoutAt key tag = plainInstance {instanceDepthKey = key, instanceParameter = tag}

-- | An instance that always takes the ordered path (the translucent override).
orderedAt ∷ Word32 → Word32 → Instance
orderedAt key tag = (cutoutAt key tag) {instanceTranslucent = True}

built ∷ ChunkKind → [Instance] → Chunk
built kind = either (error . ("the chunk was refused: " <>) . show) id . buildChunk marks kind DeriveBounds

-- | The layer of this kind listing these chunks beside these dynamic instances.
layerOf ∷ ChunkKind → [ChunkRef] → [Instance] → Layer
layerOf = \case
  ChunkWorldDepth → WorldLayerWith DepthEnabled
  ChunkWorldFlat → WorldLayerWith DepthDisabled
  ChunkUi → UiLayerWith

-- | The validated layer, against these chunks, and its plan with these marks.
planned ∷ CutoutMarks → [(ChunkRef, Chunk)] → Layer → (ValidLayer, PlannedLayer)
planned planMarks held layer =
  case validateSnapshotWith (chunksFrom held) (snapshotWithView (plainView [layer])) of
    Left refused → error ("the snapshot was refused: " <> show refused)
    Right valid → case (validLayers valid, planPasses (planSnapshot planMarks valid)) of
      ([validLayer], [PlannedPass {plannedViews = [PlannedView {plannedLayers = [plannedLayer]}]}]) → (validLayer, plannedLayer)
      _ → error "the snapshot did not plan to one layer"

-- | The tag of a source of a layer, given the chunks it lists in order.
tagOf ∷ [Chunk] → [Instance] → InstanceSource → Word32
tagOf listed dynamic = \case
  DynamicInstance index → instanceParameter (dynamic !! index)
  ChunkInstance position index → instanceParameter (chunkInstances (listed !! position) !! index)

-- | The tags of a plan's ring entries, in order.
ringTags ∷ [Chunk] → [Instance] → PlannedLayer → [Word32]
ringTags listed dynamic = map (tagOf listed dynamic) . drawingSources

runShape ∷ DrawRun → (DrawPath, RunSource, Int, Int)
runShape run = (runPath run, runSource run, runStart run, runCount run)

-- * References

referenceSpec ∷ Spec
referenceSpec = describe "a chunk reference" $ do
  it "is a value of an index and a generation, comparable and showable" $ do
    ref 1 1 `shouldBe` ref 1 1
    ref 1 1 `shouldSatisfy` (/= ref 1 2)
    ref 1 1 `shouldSatisfy` (< ref 1 2)
    show (ref 3 4) `shouldSatisfy` (not . null)
  it "is built and read through the backend-facing module alone" $ do
    chunkRefIndex (ref 7 9) `shouldBe` 7
    chunkRefGeneration (ref 7 9) `shouldBe` 9

-- * Building

buildingSpec ∷ Spec
buildingSpec = describe "building a chunk" $ do
  it "keeps the kind, the instances in build order, the textures they name and the bounds" $
    sequence_
      [ do
          let instances = [cutoutAt 4 0, orderedAt 2 1, (cutoutAt 9 2) {instanceTexture = unmarkedHandle}]
              chunk = built kind instances
          chunkKind chunk `shouldBe` kind
          chunkInstances chunk `shouldBe` instances
          chunkSize chunk `shouldBe` 3
          chunkInstanceAt chunk 1 `shouldBe` Just (instances !! 1)
          chunkInstanceAt chunk 3 `shouldBe` Nothing
          chunkInstanceAt chunk (-1) `shouldBe` Nothing
          chunkTextures chunk `shouldBe` Set.fromList [markedHandle, unmarkedHandle]
      | kind ← allKinds
      ]
  it "refuses every instance validation would refuse, naming its build position and every reason" $ do
    let bad = plainInstance {instanceDepthKey = 16777216, instanceClip = 3}
        nan = 0 / 0
        worse = plainInstance {instanceUv = UvRect nan 0 0 0}
    sequence_
      [ buildChunk marks kind DeriveBounds [plainInstance, bad, worse]
          `shouldBe` Left (ChunkInstanceInvalid 1 DepthKeyTooLarge :| [ChunkInstanceInvalid 1 ClipIndexUnknown, ChunkInstanceInvalid 2 UvNotFinite])
      | kind ← allKinds
      ]
  it "is deterministic: the same instances give the same chunk" $
    sequence_ [built kind [cutoutAt 3 0, orderedAt 1 1] `shouldBe` built kind [cutoutAt 3 0, orderedAt 1 1] | kind ← allKinds]

-- * Bounds

-- | A transform of these columns.
placed ∷ (Float, Float) → (Float, Float) → (Float, Float) → Instance
placed (a, b) (c, d) (tx, ty) = plainInstance {instanceTransform = fromColumns (V2 a b) (V2 c d) (V2 tx ty)}

boundsOf ∷ [Instance] → Bounds
boundsOf = either (error . show) chunkBounds . buildChunk marks ChunkUi DeriveBounds

-- | The exact rectangle of the four corners of the unit square, computed corner
-- by corner, as an independent characterisation of the derivation.
cornerRectangle ∷ [Instance] → (Rational, Rational, Rational, Rational)
cornerRectangle instances = (minimum xs, minimum ys, maximum xs, maximum ys)
  where
    corners = [(x, y) | candidate ← instances, let (V2 a b, V2 c d, V2 tx ty) = columns (instanceTransform candidate), (x0, y0) ← [(0, 0), (1, 0), (0, 1), (1, 1)], let x = toRational a * x0 + toRational c * y0 + toRational tx, let y = toRational b * x0 + toRational d * y0 + toRational ty]
    xs = map fst corners
    ys = map snd corners

nextUpF, nextDownF ∷ Float → Float
nextUpF value
  | value == 0 = castWord32ToFloat 1
  | value > 0 = castWord32ToFloat (castFloatToWord32 value + 1)
  | otherwise = castWord32ToFloat (castFloatToWord32 value - 1)
nextDownF = negate . nextUpF . negate

boundsSpec ∷ Spec
boundsSpec = describe "a chunk's bounds" $ do
  it "are derived exactly for axis-aligned instances" $
    boundsOf [placed (64, 0) (0, 32) (10, 20), placed (8, 0) (0, 8) (-5, 100)]
      `shouldBe` Bounds (V2 (-5) 20) (V2 74 108)
  it "are derived over all four corners for a rotated, sheared or mirrored instance" $ do
    -- A mirrored axis: the unit square spans x in [tx - 4, tx] and y in [ty, ty + 2].
    boundsOf [placed (-4, 0) (0, 2) (10, 10)] `shouldBe` Bounds (V2 6 10) (V2 10 12)
    -- A quarter turn: x' = -y, y' = x.
    boundsOf [placed (0, 3) (-3, 0) (0, 0)] `shouldBe` Bounds (V2 (-3) 0) (V2 0 3)
    -- A shear: the corners at (1, 1) leave the unit square's box.
    boundsOf [placed (1, 0) (1, 1) (0, 0)] `shouldBe` Bounds (V2 0 0) (V2 2 1)
  it "are rounded outward to 32-bit floats when the geometry is not representable" $ do
    let tenth = 0.1 ∷ Float
        Bounds (V2 x0 _) (V2 x1 _) = boundsOf [placed (tenth, 0) (0, 1) (tenth, 0)]
    toRational x0 `shouldSatisfy` (<= toRational tenth)
    toRational x1 `shouldSatisfy` (>= toRational tenth + toRational tenth)
    -- Tight: no more than a float step beyond the exact value.
    toRational (nextUpF x0) `shouldSatisfy` (> toRational tenth)
    toRational (nextDownF x1) `shouldSatisfy` (< toRational tenth + toRational tenth)
  it "enclose every instance, within one float step, for generated instances" $
    forAll (resize 6 (nonEmptyOf validInstance)) $ \instances →
      let (lowX, lowY, highX, highY) = cornerRectangle instances
          Bounds (V2 x0 y0) (V2 x1 y1) = boundsOf instances
       in conjoin
            [ counterexample "encloses" (toRational x0 <= lowX && toRational y0 <= lowY && toRational x1 >= highX && toRational y1 >= highY)
            , counterexample "tight" (toRational (nextUpF x0) > lowX && toRational (nextUpF y0) > lowY && toRational (nextDownF x1) < highX && toRational (nextDownF y1) < highY)
            ]
  it "accepts supplied bounds that are exactly tight, and bounds larger than needed" $
    sequence_
      [ do
          let instances = [placed (8, 0) (0, 8) (1, 2)]
              tight = Bounds (V2 1 2) (V2 9 10)
          fmap chunkBounds (buildChunk marks kind (SuppliedBounds tight) instances) `shouldBe` Right tight
          fmap chunkBounds (buildChunk marks kind (SuppliedBounds (Bounds (V2 (-1000) (-1000)) (V2 1000 1000))) instances)
            `shouldBe` Right (Bounds (V2 (-1000) (-1000)) (V2 1000 1000))
      | kind ← allKinds
      ]
  it "refuses supplied bounds that miss any edge by one float step" $ do
    let instances = [placed (8, 0) (0, 8) (1, 2)]
        refuse bounds = buildChunk marks ChunkUi (SuppliedBounds bounds) instances `shouldBe` Left (ChunkBoundsInsufficient :| [])
    refuse (Bounds (V2 (nextUpF 1) 2) (V2 9 10))
    refuse (Bounds (V2 1 (nextUpF 2)) (V2 9 10))
    refuse (Bounds (V2 1 2) (V2 (nextDownF 9) 10))
    refuse (Bounds (V2 1 2) (V2 9 (nextDownF 10)))
  it "refuses supplied bounds that are not finite, inverted or malformed" $ do
    let nan = 0 / 0
        inf = 1 / 0
        instances = [placed (8, 0) (0, 8) (1, 2)]
        outcome bounds = buildChunk marks ChunkUi (SuppliedBounds bounds) instances
    outcome (Bounds (V2 nan 2) (V2 9 10)) `shouldBe` Left (ChunkBoundsNotFinite :| [])
    outcome (Bounds (V2 1 2) (V2 inf 10)) `shouldBe` Left (ChunkBoundsNotFinite :| [])
    outcome (Bounds (V2 (-inf) 2) (V2 9 10)) `shouldBe` Left (ChunkBoundsNotFinite :| [])
    outcome (Bounds (V2 9 2) (V2 1 10)) `shouldBe` Left (ChunkBoundsInverted :| [])
    outcome (Bounds (V2 1 10) (V2 9 2)) `shouldBe` Left (ChunkBoundsInverted :| [])
  it "have no geometry to derive from a chunk with no instance, and take supplied bounds" $ do
    buildChunk marks ChunkUi DeriveBounds [] `shouldBe` Left (ChunkBoundsUnderivable :| [])
    fmap chunkBounds (buildChunk marks ChunkUi (SuppliedBounds (Bounds (V2 0 0) (V2 1 1))) []) `shouldBe` Right (Bounds (V2 0 0) (V2 1 1))
  it "cannot be derived when the geometry leaves the 32-bit float range" $
    buildChunk marks ChunkUi DeriveBounds [placed (3.0e38, 0) (0, 1) (3.0e38, 0)] `shouldBe` Left (ChunkBoundsNotRepresentable :| [])
  it "are checked as well as the instances, and every reason is reported" $
    buildChunk marks ChunkUi (SuppliedBounds (Bounds (V2 9 2) (V2 1 10))) [plainInstance {instanceDepthKey = 16777216}]
      `shouldBe` Left (ChunkInstanceInvalid 0 DepthKeyTooLarge :| [ChunkBoundsInverted])

-- * Validation

validationSpec ∷ Spec
validationSpec = describe "referencing chunks from layers" $ do
  let held kind = chunksFrom [(ref 1 1, built kind [cutoutAt 0 0])]
      snapshotOf layer = snapshotWithView (plainView [layer])
  it "accepts a chunk in a layer of its own kind, for each kind" $
    sequence_
      [ validateSnapshotWith (held kind) (snapshotOf (layerOf kind [ref 1 1] [plainInstance])) `shouldSatisfy` isRight'
      | kind ← allKinds
      ]
  it "refuses a chunk of each other kind in each kind of layer, naming the layer and the chunk" $
    sequence_
      [ validateSnapshotWith (held chunkK) (snapshotOf (layerOf layerK [ref 1 1] []))
          `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 1 1)) ChunkKindMismatch :| [])
      | chunkK ← allKinds
      , layerK ← allKinds
      , chunkK /= layerK
      ]
  it "names the pass, view, layer and position of a deeply nested chunk" $ do
    let good = ref 1 1
        bad = ref 2 1
        chunks = chunksFrom [(good, built ChunkUi [orderedAt 0 0]), (bad, built ChunkWorldDepth [cutoutAt 0 0])]
        snapshot =
          Snapshot
            [ plainPass (offscreen 0) [plainView []]
            , windowPass
                [ plainView []
                , plainView [UiLayer [], UiLayer [], UiLayerWith [good, bad, good] []]
                ]
            ]
    validateSnapshotWith chunks snapshot `shouldBe` Left (Refusal (AtChunk 1 1 2 1 bad) ChunkKindMismatch :| [])
  it "refuses a reference that resolves to nothing: never issued, or of another generation" $
    sequence_
      [ do
          validateSnapshotWith (held kind) (snapshotOf (layerOf kind [ref 5 1] []))
            `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 5 1)) ChunkUnresolved :| [])
          -- Index 1 is held, at generation 1: a stale or future generation finds nothing.
          validateSnapshotWith (held kind) (snapshotOf (layerOf kind [ref 1 2] []))
            `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 1 2)) ChunkUnresolved :| [])
          validateSnapshotWith (held kind) (snapshotOf (layerOf kind [ref 1 0] []))
            `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 1 0)) ChunkUnresolved :| [])
      | kind ← allKinds
      ]
  it "never lets a stale reference reach rebuilt content: the new generation resolves, the old does not" $ do
    let rebuilt = chunksFrom [(ref 1 2, built ChunkUi [orderedAt 0 77])]
    validateSnapshotWith rebuilt (snapshotOf (UiLayerWith [ref 1 1] [])) `shouldSatisfy` isLeft'
    case validateSnapshotWith rebuilt (snapshotOf (UiLayerWith [ref 1 2] [])) of
      Right valid → map (map instanceParameter . chunkInstances . snd) (concatMap validLayerChunks (validLayers valid)) `shouldBe` [[77]]
      Left refused → fail ("refused: " <> show refused)
  it "refuses any listed chunk when the snapshot is validated against none" $
    sequence_
      [ validateSnapshot (snapshotOf (layerOf kind [ref 1 1] [])) `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 1 1)) ChunkUnresolved :| [])
      | kind ← allKinds
      ]
  it "reports a chunk's refusals before its layer's instances, and every one of them" $ do
    let nan = 0 / 0
        snapshot = snapshotOf (UiLayerWith [ref 8 1, ref 1 1] [plainInstance {instanceUv = UvRect nan 0 0 0}])
        chunks = chunksFrom [(ref 1 1, built ChunkWorldFlat [cutoutAt 0 0])]
    validateSnapshotWith chunks snapshot
      `shouldBe` Left
        ( Refusal (AtChunk 0 0 0 0 (ref 8 1)) ChunkUnresolved
            :| [Refusal (AtChunk 0 0 0 1 (ref 1 1)) ChunkKindMismatch, Refusal (AtInstance 0 0 0 0) UvNotFinite]
        )
  it "checks the references of a layer in a zero-size viewport as it checks any other" $
    validateSnapshotWith (held ChunkUi) (snapshotWithView (View plainCamera (Viewport (V2 0 0) (V2 0 0)) defaultViewSettings [] [UiLayerWith [ref 6 1] []]))
      `shouldBe` Left (Refusal (AtChunk 0 0 0 0 (ref 6 1)) ChunkUnresolved :| [])
  it "keeps what each listing resolved to, a chunk listed twice appearing twice, and names each chunk once" $ do
    let a = built ChunkUi [orderedAt 1 10]
        b = built ChunkUi [orderedAt 2 20]
        chunks = chunksFrom [(ref 1 1, a), (ref 2 1, b)]
        layer = UiLayerWith [ref 1 1, ref 2 1, ref 1 1] []
    case validateSnapshotWith chunks (snapshotOf layer) of
      Right valid → do
        concatMap validLayerChunks (validLayers valid) `shouldBe` [(ref 1 1, a), (ref 2 1, b), (ref 1 1, a)]
        validChunkRefs valid `shouldBe` [ref 1 1, ref 2 1]
      Left refused → fail ("refused: " <> show refused)

isRight', isLeft' ∷ Either a b → Bool
isRight' = either (const False) (const True)
isLeft' = not . isRight'

-- * Routing at build

routingSpec ∷ Spec
routingSpec = describe "routing at build" $ do
  let instances =
        [ cutoutAt 5 0 -- eligible
        , (cutoutAt 3 1) {instanceTranslucent = True}
        , (cutoutAt 3 2) {instanceAdditive = True}
        , (cutoutAt 8 3) {instanceTint = Tint 255 255 255 254}
        , (cutoutAt 1 4) {instanceTexture = unmarkedHandle}
        , cutoutAt 5 5 -- eligible
        ]
  it "puts anything on the cutout path only in a world-with-depth chunk, and only what meets every condition" $ do
    chunkCutoutPositions (built ChunkWorldDepth instances) `shouldBe` [0, 5]
    chunkOrderedPositions (built ChunkWorldDepth instances) `shouldBe` [4, 1, 2, 3]
  it "puts every instance of a world chunk without depth and of a UI chunk on the ordered path, by key and then build order" $
    sequence_
      [ do
          chunkCutoutPositions chunk `shouldBe` []
          chunkOrderedPositions chunk `shouldBe` [4, 1, 2, 0, 5, 3]
      | kind ← [ChunkWorldFlat, ChunkUi]
      , let chunk = built kind instances
      ]
  it "fixes the routing when the chunk is built: the marks it is planned with later do not change it" $ do
    let chunk = built ChunkWorldDepth [cutoutAt 5 0]
        (_, plan) = planned noCutoutMarks [(ref 1 1, chunk)] (layerOf ChunkWorldDepth [ref 1 1] [])
    map runShape (plannedRuns plan) `shouldBe` [(Cutout, ChunkRun 0, 0, 1)]
    -- And a chunk built before its texture was marked stays on the ordered path.
    let unmarkedAtBuild = either (error . show) id (buildChunk noCutoutMarks ChunkWorldDepth DeriveBounds [cutoutAt 5 0])
        (_, laterPlan) = planned marks [(ref 1 1, unmarkedAtBuild)] (layerOf ChunkWorldDepth [ref 1 1] [])
    map runShape (plannedRuns laterPlan) `shouldBe` [(Ordered, RingRun, 0, 1)]
  it "routes the same as the plan does for the same instances submitted dynamically" $
    forAll (resize 8 (nonEmptyOf routedInstance)) $ \generated →
      let chunk = built ChunkWorldDepth generated
          (_, plan) = planned marks [] (WorldLayer DepthEnabled generated)
          dynamicCutouts = concat [runIndices plan run | run ← plannedRuns plan, runPath run == Cutout]
       in sort dynamicCutouts === sort (chunkCutoutPositions chunk)

nonEmptyOf ∷ Gen a → Gen [a]
nonEmptyOf gen = (:) <$> gen <*> listOf gen

-- | An instance whose routing conditions vary.
routedInstance ∷ Gen Instance
routedInstance = do
  key ← choose (0, 4)
  handle ← elements [markedHandle, unmarkedHandle]
  alpha ← elements [255, 255, 255, 254, 0]
  translucent ← elements [False, False, False, True]
  additive ← elements [False, False, False, True]
  pure plainInstance {instanceDepthKey = key, instanceTexture = handle, instanceTint = Tint 255 255 255 alpha, instanceTranslucent = translucent, instanceAdditive = additive}

-- * The merge order

mergeSpec ∷ Spec
mergeSpec = describe "the merge order of a layer's content" $ do
  it "merges the ordered instances of chunks and the dynamic ones by key, then chunks in listed order, build order, then dynamic submission order" $
    sequence_
      [ do
          let first = built kind [orderedAt 5 100, orderedAt 3 101, orderedAt 5 102]
              second = built kind [orderedAt 3 200, orderedAt 5 201]
              dynamic = [orderedAt 3 1, orderedAt 5 2, orderedAt 4 3]
              layer = layerOf kind [ref 1 1, ref 2 1] dynamic
              (_, plan) = planned marks [(ref 1 1, first), (ref 2 1, second)] layer
          ringTags [first, second] dynamic plan `shouldBe` [101, 200, 1, 3, 100, 102, 201, 2]
          map runShape (plannedRuns plan) `shouldBe` [(Ordered, RingRun, 0, 8)]
      | kind ← allKinds
      ]
  it "takes the order of the listing, not of the references: the same chunks listed the other way merge the other way" $ do
    let first = built ChunkUi [orderedAt 5 100]
        second = built ChunkUi [orderedAt 5 200]
        held = [(ref 1 1, first), (ref 2 1, second)]
        order refs listed = ringTags listed [] (snd (planned marks held (UiLayerWith refs [])))
    order [ref 1 1, ref 2 1] [first, second] `shouldBe` [100, 200]
    order [ref 2 1, ref 1 1] [second, first] `shouldBe` [200, 100]
  it "draws a chunk listed twice at both places, each in its own turn" $ do
    let a = built ChunkUi [orderedAt 5 100, orderedAt 6 101]
        b = built ChunkUi [orderedAt 5 200]
        held = [(ref 1 1, a), (ref 2 1, b)]
        plan = snd (planned marks held (UiLayerWith [ref 1 1, ref 2 1, ref 1 1] []))
    ringTags [a, b, a] [] plan `shouldBe` [100, 200, 100, 101, 101]
    drawingSources plan `shouldBe` [ChunkInstance 0 0, ChunkInstance 1 0, ChunkInstance 2 0, ChunkInstance 0 1, ChunkInstance 2 1]
  it "draws the cutouts first as runs: each chunk's from its own buffer in listed order, then the dynamic ones from the ring, then the ordered instances" $ do
    let first = built ChunkWorldDepth [cutoutAt 7 100, cutoutAt 7 101, orderedAt 7 110]
        second = built ChunkWorldDepth [cutoutAt 7 200, orderedAt 6 210]
        dynamic = [cutoutAt 7 1, orderedAt 7 2]
        layer = WorldLayerWith DepthEnabled [ref 1 1, ref 2 1] dynamic
        (_, plan) = planned marks [(ref 1 1, first), (ref 2 1, second)] layer
    map runShape (plannedRuns plan)
      `shouldBe` [ (Cutout, ChunkRun 0, 0, 2)
                 , (Cutout, ChunkRun 1, 0, 1)
                 , (Cutout, RingRun, 0, 1)
                 , (Ordered, RingRun, 1, 3)
                 ]
    -- The ring holds the dynamic cutout, then the merged ordered instances; the
    -- chunks' cutouts are not rewritten.
    ringTags [first, second] dynamic plan `shouldBe` [1, 210, 110, 2]
    drawingSources plan `shouldBe` [DynamicInstance 0, ChunkInstance 1 1, ChunkInstance 0 2, DynamicInstance 1]
  it "lets an ordered instance at an equal key draw after, and so over, a cutout, and a later cutout win an equal-depth tie" $ do
    let first = built ChunkWorldDepth [cutoutAt 7 100, orderedAt 7 110]
        dynamic = [cutoutAt 7 1]
        (_, plan) = planned marks [(ref 1 1, first)] (WorldLayerWith DepthEnabled [ref 1 1] dynamic)
    -- Runs draw in this order, the later of two cutouts at one key winning the
    -- tie (the recorder tests less-or-equal), and the ordered run last.
    map (\run → (runPath run, runSource run)) (plannedRuns plan) `shouldBe` [(Cutout, ChunkRun 0), (Cutout, RingRun), (Ordered, RingRun)]
  it "plans a chunk-free layer exactly as before: one ring, the permutation, no chunk run" $ do
    let dynamic = [cutoutAt 9 0, orderedAt 2 1, cutoutAt 3 2]
        (_, plan) = planned marks [] (WorldLayer DepthEnabled dynamic)
    drawingOrder plan `shouldBe` [0, 2, 1]
    map runShape (plannedRuns plan) `shouldBe` [(Cutout, RingRun, 0, 2), (Ordered, RingRun, 2, 1)]
    plannedCulled plan `shouldBe` []
  it "plans nothing from a chunk in a zero-size viewport" $ do
    let chunk = built ChunkUi [orderedAt 1 1]
        snapshot = snapshotWithView (View plainCamera (Viewport (V2 0 0) (V2 0 100)) defaultViewSettings [] [UiLayerWith [ref 1 1] [orderedAt 2 2]])
    case validateSnapshotWith (chunksFrom [(ref 1 1, chunk)]) snapshot of
      Right valid → case planPasses (planSnapshot marks valid) of
        [PlannedPass {plannedViews = [PlannedView {plannedLayers = [plan]}]}] → do
          drawingSources plan `shouldBe` []
          plannedRuns plan `shouldBe` []
        other → fail ("planned to " <> show other)
      Left refused → fail ("refused: " <> show refused)
  prop "is total and repeatable, and matches an independent characterisation, for generated chunks and dynamic instances" $
    checkCoverage $
      forAll layerCase $ \(kind, listing, listedChunks, dynamic) →
      let held = [(ref (fromIntegral i) 1, chunk) | (i, chunk) ← zip [0 ∷ Int ..] listedChunks]
          refs = [ref (fromIntegral i) 1 | i ← listing]
          listed = [listedChunks !! i | i ← listing]
          layer = layerOf kind refs dynamic
          (_, plan) = planned marks held layer
          (_, again) = planned marks held layer
       in cover 30 (not (null listing)) "the layer lists chunks" $
            cover 10 (kind == ChunkWorldDepth && any (not . null . chunkCutoutPositions) listed) "a depth chunk has cutouts" $
              conjoin
                [ counterexample "repeatable" (plan === again)
                , counterexample "the ring and the runs" (characterised kind listed dynamic plan)
                , counterexample "culls nothing" (plannedCulled plan === [])
                ]
  where
    layerCase = do
      kind ← elements allKinds
      chunks ← resize 3 (listOf (chunkOf kind))
      listing ← if null chunks then pure [] else resize 5 (listOf (choose (0, length chunks - 1)))
      dynamic ← resize 6 (listOf taggedInstance)
      pure (kind, listing, chunks, dynamic)
    chunkOf kind = built kind <$> resize 5 (nonEmptyOf taggedInstance)
    taggedInstance = routedInstance

-- | Whether the plan of a layer is what an independent derivation says: the
-- instances numbered in source order (listed chunks in order and build order,
-- then dynamic), the cutouts sorted by number, the ordered by key and number,
-- and the runs.
characterised ∷ ChunkKind → [Chunk] → [Instance] → PlannedLayer → Property
characterised kind listed dynamic plan =
  conjoin
    [ counterexample "the ring is the dynamic cutouts, then the ordered instances by key and source order" (drawingSources plan === expectedRing)
    , counterexample "the runs" (map runShape (plannedRuns plan) === expectedRuns)
    ]
  where
    sources =
      [(ChunkInstance position index, candidate) | (position, chunk) ← zip [0 ..] listed, (index, candidate) ← zip [0 ..] (chunkInstances chunk)]
        <> [(DynamicInstance index, candidate) | (index, candidate) ← zip [0 ..] dynamic]
    numbered = zip [0 ∷ Int ..] sources
    -- The routing, stated again: a chunk's was decided at build, a dynamic
    -- instance's by the layer.
    depth = kind == ChunkWorldDepth
    cutsOut candidate =
      depth
        && instanceTexture candidate == markedHandle
        && instanceTint candidate == Tint 255 255 255 255
        && not (instanceTranslucent candidate)
        && not (instanceAdditive candidate)
    isCutout (_, (_, candidate)) = cutsOut candidate
    cutouts = filter isCutout numbered
    ordered = filter (not . isCutout) numbered
    dynamicCutouts = [source | (_, (source@(DynamicInstance _), _)) ← cutouts]
    orderedSources = [source | (_, (source, _)) ← sortOn (\(number, (_, candidate)) → (instanceDepthKey candidate, number)) ordered]
    expectedRing = dynamicCutouts <> orderedSources
    chunkRuns =
      [ (Cutout, ChunkRun position, 0, count)
      | (position, chunk) ← zip [0 ..] listed
      , let count = length [() | candidate ← chunkInstances chunk, cutsOut candidate]
      , count > 0
      ]
    ringCutoutRun = [(Cutout, RingRun, 0, length dynamicCutouts) | not (null dynamicCutouts)]
    orderedRun = [(Ordered, RingRun, length dynamicCutouts, length orderedSources) | not (null orderedSources)]
    expectedRuns = chunkRuns <> ringCutoutRun <> orderedRun

-- * Culling

-- | A view over a 640 × 480 target with this camera, viewport and settings,
-- and its mapping.
mappingOf ∷ TargetMetrics → Camera → Viewport → ViewSettings → ViewMapping
mappingOf metrics camera viewport settings =
  maybe (error "the view has no mapping") id (viewMapping metrics (View camera viewport settings [] []))

plainMapping ∷ ViewMapping
plainMapping = mappingOf (offscreenMetrics (PixelExtent 640 480)) plainCamera plainViewport defaultViewSettings

extent640 ∷ (Word32, Word32)
extent640 = (640, 480)

-- | Whether a world-with-depth chunk of these bounds is skipped in the plain view,
-- where world point (x, y) lies at target (320 + x, 240 + y).
culledAt ∷ (Float, Float) → (Float, Float) → Bool
culledAt (x0, y0) (x1, y1) = chunkCulled plainMapping extent640 plainViewport ChunkWorldDepth (Bounds (V2 x0 y0) (V2 x1 y1)) 0

cullingSpec ∷ Spec
cullingSpec = describe "culling" $ do
  it "keeps a chunk inside the view, straddling an edge and covering the view, and skips one wholly outside it, on every side" $ do
    culledAt (-10, -10) (10, 10) `shouldBe` False
    -- World x = 320 is target x = 640, the right edge.
    culledAt (300, 0) (340, 10) `shouldBe` False
    culledAt (-340, 0) (-300, 10) `shouldBe` False
    culledAt (-1000, -1000) (1000, 1000) `shouldBe` False
    culledAt (400, 0) (500, 10) `shouldBe` True
    culledAt (-500, 0) (-400, 10) `shouldBe` True
    culledAt (0, 300) (10, 400) `shouldBe` True
    culledAt (0, -400) (10, -300) `shouldBe` True
  it "keeps a chunk whose edge touches the view, and skips one a pixel and more beyond it" $ do
    -- Target x = 640 is the right edge: the chunk's left edge at 640 touches it.
    culledAt (320, 0) (330, 10) `shouldBe` False
    culledAt (321, 0) (330, 10) `shouldBe` True
    culledAt (-330, 0) (-320, 10) `shouldBe` False
    culledAt (-330, 0) (-321, 10) `shouldBe` True
    culledAt (0, 240) (10, 250) `shouldBe` False
    culledAt (0, 241) (10, 250) `shouldBe` True
  it "keeps a chunk a sixteenth of a pixel beyond the view, which pixel coverage may still reach, and skips one clearly beyond it" $ do
    culledAt (320.03125, 0) (330, 10) `shouldBe` False
    culledAt (320.25, 0) (330, 10) `shouldBe` True
  it "keeps a chunk half a pixel further out when the view snaps, which rounds an instance's origin by up to that" $ do
    let snapping = mappingOf (offscreenMetrics (PixelExtent 640 480)) plainCamera plainViewport defaultViewSettings {settingPixelSnap = True}
        culledSnapped bounds = chunkCulled snapping extent640 plainViewport ChunkWorldDepth bounds 0
    mappingPixelSnap snapping `shouldBe` True
    -- Left of the view, 0.3 beyond its edge: skipped unsnapped, kept snapped.
    culledAt (-330.3, 0) (-320.3, 10) `shouldBe` True
    culledSnapped (Bounds (V2 (-330.3) 0) (V2 (-320.3) 10)) `shouldBe` False
    -- Still skipped once it is clearly beyond the snap.
    culledSnapped (Bounds (V2 (-331) 0) (V2 (-321)  10)) `shouldBe` True
  it "follows a rotated camera: a quarter turn moves what lay to the right of the view above it" $ do
    let quarter = pi / 2 ∷ Float
        turned = mappingOf (offscreenMetrics (PixelExtent 640 480)) plainCamera {cameraRotation = Just quarter} plainViewport defaultViewSettings
        skipped bounds = chunkCulled turned extent640 plainViewport ChunkWorldDepth bounds 0
    -- World +X is then above the centre: x in [300, 360] is at target y near 240 - x, far above the view.
    skipped (Bounds (V2 300 0) (V2 360 10)) `shouldBe` True
    -- World +Y is then right of the centre, still inside at y in [100, 110].
    skipped (Bounds (V2 0 100) (V2 10 110)) `shouldBe` False
    -- Unrotated, the first is in view and the second is too, so the rotation decided the first.
    culledAt (300, 0) (360, 10) `shouldBe` False
  it "applies the UI scale and the content scale to a UI chunk" $ do
    let metrics = TargetMetrics (PixelExtent 640 480) (PixelExtent 640 480) 1.5 1.5
        viewport = Viewport (V2 320 0) (V2 320 480)
        mapping scale = mappingOf metrics plainCamera viewport defaultViewSettings {settingUiScale = scale}
        skipped scale = chunkCulled (mapping scale) extent640 viewport ChunkUi (Bounds (V2 0 0) (V2 100 50)) 0
    -- The viewport's origin is 320, and a UI point maps to origin + point × scale × content scale.
    -- Scale 2 × 1.5 = 3: the chunk spans target x in [320, 620], so it is in view.
    skipped 2 `shouldBe` False
    -- Scale 0.5 × 1.5 = 0.75: the chunk spans [320, 395], in view too.
    skipped 0.5 `shouldBe` False
    -- A viewport over the left 300 pixels: the chunk [110, 200] spans [330, 600] at
    -- a scale of 3, wholly beyond it, and [165, 300] at a scale of 1.5, within it.
    let left = Viewport (V2 0 0) (V2 300 480)
        leftMapping scale = mappingOf metrics plainCamera left defaultViewSettings {settingUiScale = scale}
        skippedLeft scale = chunkCulled (leftMapping scale) extent640 left ChunkUi (Bounds (V2 110 0) (V2 200 50)) 0
    skippedLeft 2 `shouldBe` True
    skippedLeft 1 `shouldBe` False
  it "treats a viewport beyond the target as the part of it within the target" $ do
    let viewport = Viewport (V2 600 0) (V2 400 480)
        mapping = mappingOf (offscreenMetrics (PixelExtent 640 480)) plainCamera viewport defaultViewSettings
    -- Target x in [650, 700] is within the viewport but beyond the 640-pixel target.
    chunkCulled mapping extent640 viewport ChunkWorldFlat (Bounds (V2 330 0) (V2 380 10)) 0 `shouldBe` True
  it "skips a chunk in one view and keeps it in another, planning each as such" $ do
    let chunk = built ChunkWorldDepth [cutoutAt 1 1, orderedAt 2 2]
        held = chunksFrom [(ref 1 1, chunk)]
        layer = WorldLayerWith DepthEnabled [ref 1 1] [orderedAt 3 3]
        views =
          [ View plainCamera plainViewport defaultViewSettings [] [layer]
          , View plainCamera {cameraPosition = V2 5000 0} plainViewport defaultViewSettings [] [layer]
          ]
        snapshot = Snapshot [windowPass views]
        metrics = offscreenMetrics (PixelExtent 640 480)
        culler _ viewIndex _ kind bounds placement =
          chunkCulled (mappingOf metrics (viewCamera (views !! viewIndex)) plainViewport defaultViewSettings) extent640 plainViewport kind bounds placement
    case validateSnapshotWith held snapshot of
      Left refused → fail ("refused: " <> show refused)
      Right valid → case planPasses (planSnapshotCulled culler marks valid) of
        [PlannedPass {plannedViews = [PlannedView {plannedLayers = [near]}, PlannedView {plannedLayers = [far]}]}] → do
          plannedCulled near `shouldBe` []
          map runShape (plannedRuns near) `shouldBe` [(Cutout, ChunkRun 0, 0, 1), (Ordered, RingRun, 0, 2)]
          plannedCulled far `shouldBe` [0]
          -- Without the chunk, exactly the plan of the layer without it.
          map runShape (plannedRuns far) `shouldBe` [(Ordered, RingRun, 0, 1)]
          drawingSources far `shouldBe` [DynamicInstance 0]
        other → fail ("planned to " <> show other)
  it "keeps a chunk whose placement cancels large terms, the 32-bit arithmetic rounding at their size (a camera 8 million units away)" $ do
    -- With the camera at x = 8,000,000 and a zoom of 5.3, an 8 × 1 instance at x = 8,000,001.5 lies at
    -- target x of about 13.5, but each product the shader forms is about 4 × 10⁷, where a 32-bit
    -- float steps by 4: evaluated in single precision its x endpoints fall at 12 and 56, so column 12
    -- of a viewport 13 pixels wide is covered. The culler may not discard it.
    let metrics = offscreenMetrics (PixelExtent 32 32)
        viewport = Viewport (V2 0 0) (V2 13 32)
        mapping = mappingOf metrics (Camera (V2 8000000 16) 5.3 Nothing) viewport defaultViewSettings
        chunk = either (error . show) id (buildChunk marks ChunkWorldFlat DeriveBounds [placed (8, 0) (0, 1) (8000001.5, 16)])
    chunkCulled mapping (32, 32) viewport ChunkWorldFlat (chunkBounds chunk) (chunkPlacementMagnitude chunk) `shouldBe` False
  prop "never skips a chunk whose 32-bit placement reaches the view, however large the terms that cancel" $
    checkCoverage $
      forAll cancellingCase $ \(camera, viewport, instances) →
        let metrics = offscreenMetrics (PixelExtent 32 32)
         in case viewMapping metrics (View camera viewport defaultViewSettings [] []) of
              Nothing → property True
              Just mapping →
                let chunk = either (error . show) id (buildChunk marks ChunkWorldFlat DeriveBounds instances)
                    reached = any (floatPlacementReaches mapping viewport) instances
                    skipped = chunkCulled mapping (32, 32) viewport ChunkWorldFlat (chunkBounds chunk) (chunkPlacementMagnitude chunk)
                 in cover 15 reached "the single-precision placement reaches the view" $
                      cover 10 (not reached && skipped) "it does not and the chunk is skipped" $
                        counterexample "the single-precision placement reaches the view but the chunk was skipped" (not (reached && skipped))
  prop "never skips a chunk with an instance that covers a pixel centre of the view, whatever the camera, scales and snap" $
    checkCoverage $
      forAll cullingCase $ \(extent, kind, camera, viewport, settings, instances) →
      let metrics = TargetMetrics (PixelExtent (fromIntegral (fst extent)) (fromIntegral (snd extent))) (PixelExtent (fromIntegral (fst extent)) (fromIntegral (snd extent))) 1 1
       in case viewMapping metrics (View camera viewport settings [] []) of
            Nothing → property True
            Just mapping →
              let chunk = built' kind instances
                  covered = [() | candidate ← instances, coversACentre mapping kind extent viewport candidate]
                  skipped = chunkCulled mapping extent viewport kind (chunkBounds chunk) (chunkPlacementMagnitude chunk)
               in cover 20 (not (null covered)) "an instance covers a pixel centre" $
                    cover 10 (null covered && skipped) "nothing is covered and the chunk is skipped" $
                      counterexample
                        ("an instance covers a pixel centre of the view but the chunk was skipped: " <> show (mappingPixelSnap mapping))
                        (null covered || not skipped)
  where
    built' kind = either (error . show) id . buildChunk marks kind DeriveBounds

-- | A small target, a view over part of it, and instances placed in and around
-- it.
cullingCase ∷ Gen ((Word32, Word32), ChunkKind, Camera, Viewport, ViewSettings, [Instance])
cullingCase = do
  width ← choose (4, 12)
  height ← choose (4, 12)
  kind ← elements allKinds
  position ← V2 <$> choose (-6, 6) <*> choose (-6, 6)
  zoom ← elements [0.5, 1, 2, 3.25]
  rotated ← oneof [pure Nothing, Just <$> choose (-3.2, 3.2)]
  viewportOrigin ← V2 <$> choose (-1, 4) <*> choose (-1, 4)
  viewportExtent ← V2 <$> choose (3, 12) <*> choose (3, 12)
  snap ← arbitrary
  scale ← elements [0.5, 1, 1.75, 4]
  instances ← resize 4 (listOf1 small)
  pure ((width, height), kind, Camera position zoom rotated, Viewport viewportOrigin viewportExtent, defaultViewSettings {settingPixelSnap = snap, settingUiScale = scale}, instances)
  where
    listOf1 gen = (:) <$> gen <*> listOf gen
    coefficient = elements [-8, -4, -2, -1.5, -0.5, 0, 0.25, 1, 1.5, 2, 3, 6]
    small = do
      a ← coefficient
      b ← coefficient
      c ← coefficient
      d ← coefficient
      tx ← choose (-8, 12)
      ty ← choose (-8, 12)
      pure (placed (a, b) (c, d) (tx, ty))

-- | Whether the instance, drawn in this view, covers the centre of some pixel of
-- the target that the view draws to: a brute force in exact arithmetic of the
-- shader's placement. The quad is the unit square under the instance's
-- transform, in the layer's space, then under the layer's transform to target
-- pixels, moved rigidly by @floor(o + ½) − o@ when the view snaps, @o@ being
-- the mapped origin. A centre on an edge counts.
coversACentre ∷ ViewMapping → ChunkKind → (Word32, Word32) → Viewport → Instance → Bool
coversACentre mapping kind (width, height) (Viewport (V2 ox oy) (V2 vw vh)) candidate =
  any covers [(fromIntegral i + 1 / 2, fromIntegral j + 1 / 2) | i ← [0 .. width - 1], j ← [0 .. height - 1], inside (fromIntegral i + 1 / 2) (fromIntegral j + 1 / 2)]
  where
    r = toRational
    inside x y = x >= r ox && x < r ox + r vw && y >= r oy && y < r oy + r vh
    layerTransform = case kind of
      ChunkUi → uiTransform mapping
      _ → worldTransform mapping
    (la, lb, lc, ld, ltx, lty) = case map r (toColumnMajor layerTransform) of
      [p, q, u, v, x, y] → (p, q, u, v, x, y)
      _ → error "an affine transform has six coefficients"
    toTarget (x, y) = (la * x + lc * y + ltx, lb * x + ld * y + lty)
    (V2 ia ib, V2 ic id', V2 itx ity) = columns (instanceTransform candidate)
    (a, b, c, d, tx, ty) = (r ia, r ib, r ic, r id', r itx, r ity)
    (originX, originY) = toTarget (tx, ty)
    snapped = mappingPixelSnap mapping
    shiftX = if snapped then fromIntegral (floor (originX + 1 / 2) ∷ Integer) - originX else 0
    shiftY = if snapped then fromIntegral (floor (originY + 1 / 2) ∷ Integer) - originY else 0
    -- Target position of local (u, v): the instance's placement, the layer's
    -- transform, the shift.
    atLocal (u, v) = let (x, y) = toTarget (a * u + c * v + tx, b * u + d * v + ty) in (x + shiftX, y + shiftY)
    (p00x, p00y) = atLocal (0, 0)
    (p10x, p10y) = atLocal (1, 0)
    (p01x, p01y) = atLocal (0, 1)
    -- Solve centre = p00 + u (p10 - p00) + v (p01 - p00).
    ex = p10x - p00x
    ey = p10y - p00y
    fx = p01x - p00x
    fy = p01y - p00y
    determinant = ex * fy - ey * fx
    covers (cx, cy)
      | determinant == 0 = False
      | otherwise =
          let dx = cx - p00x
              dy = cy - p00y
              u = (dx * fy - dy * fx) / determinant
              v = (ex * dy - ey * dx) / determinant
           in u >= 0 && u <= 1 && v >= 0 && v <= 1

-- | A camera far from the origin and instances near it, so that the terms of the
-- placement are large and nearly cancel.
cancellingCase ∷ Gen (Camera, Viewport, [Instance])
cancellingCase = do
  camX ← elements [0, 1.0e5, 1.0e6, 8.0e6, -8.0e6, 3.0e7]
  camY ← elements [0, 1.0e6, -4.0e6]
  zoom ← elements [0.5, 1, 2, 5.3, 8]
  width ← choose (4, 32)
  height ← choose (4, 32)
  offsets ← resize 4 (nonEmptyOf ((,) <$> choose (-20, 40) <*> choose (-20, 40)))
  size ← choose (1, 10)
  let instances = [placed (size, 0) (0, 1) (fromIntegral (round' camX + x ∷ Integer) + 0.5, fromIntegral (round' camY + y ∷ Integer)) | (x, y) ← offsets]
  pure (Camera (V2 camX camY) zoom Nothing, Viewport (V2 0 0) (V2 width height), instances)
  where
    round' ∷ Float → Integer
    round' = round

-- | Whether the instance, placed by the shader's own 32-bit arithmetic, one multiply
-- and one add at a time, has a corner within the part of the target the view draws
-- to (taken as a rectangle, as culling takes it).
floatPlacementReaches ∷ ViewMapping → Viewport → Instance → Bool
floatPlacementReaches mapping (Viewport (V2 ox oy) (V2 w h)) candidate =
  minimum xs <= right && maximum xs >= left && minimum ys <= bottom && maximum ys >= top
  where
    (V2 ia ib, V2 ic id' , V2 itx ity) = columns (instanceTransform candidate)
    (V2 va vb, V2 vc vd, V2 vtx vty) = columns (worldTransform mapping)
    corners = [(u, v) | u ← [0, 1], v ← [0, 1 ∷ Float]]
    placedAt (u, v) =
      let wx = (ia * u + ic * v) + itx
          wy = (ib * u + id' * v) + ity
       in ((va * wx + vc * wy) + vtx, (vb * wx + vd * wy) + vty)
    mapped = map placedAt corners
    xs = map fst mapped
    ys = map snd mapped
    left = max 0 ox
    top = max 0 oy
    right = min 32 (ox + w)
    bottom = min 32 (oy + h)

-- * Encoding

encodingSpec ∷ Spec
encodingSpec = describe "encoding what a backend uploads and what it writes" $ do
  it "encodes a chunk's cutout instances as the dynamic encoding of those instances, in the order the buffer holds them" $ do
    let chunk = built ChunkWorldDepth [orderedAt 1 0, cutoutAt 5 1, orderedAt 2 2, cutoutAt 3 3]
        cutouts = [instance' | position ← chunkCutoutPositions chunk, Just instance' ← [chunkInstanceAt chunk position]]
    map instanceParameter cutouts `shouldBe` [1, 3]
    encodeChunkCutouts chunk `shouldBe` encodeLayer (singleLayer (WorldLayer DepthEnabled cutouts))
  it "encodes no cutout bytes for a chunk with none, whatever its kind" $
    sequence_ [encodeChunkCutouts (built kind [orderedAt 1 0]) `shouldBe` mempty | kind ← allKinds]
  it "writes a layer's ring entries as the dynamic encoding of those instances in the merged order" $ do
    let first = built ChunkWorldDepth [cutoutAt 7 100, orderedAt 5 101, orderedAt 2 102]
        second = built ChunkWorldDepth [orderedAt 5 200, cutoutAt 7 201]
        dynamic = [orderedAt 5 1, cutoutAt 7 2, orderedAt 2 3]
        layer = WorldLayerWith DepthEnabled [ref 1 1, ref 2 1] dynamic
        (valid, plan) = planned marks [(ref 1 1, first), (ref 2 1, second)] layer
        expectedTags = ringTags [first, second] dynamic plan
        byTag = [(instanceParameter candidate, candidate) | candidate ← chunkInstances first <> chunkInstances second <> dynamic]
        expected = [candidate | tag ← expectedTags, Just candidate ← [lookup tag byTag]]
    expectedTags `shouldBe` [2, 102, 3, 101, 200, 1]
    encodeLayerInDrawingOrder plan valid `shouldBe` Just (encodeLayer (singleLayer (WorldLayer DepthEnabled expected)))
  it "encodes a layer that lists no chunk as it always did" $ do
    let dynamic = [cutoutAt 9 0, orderedAt 2 1, cutoutAt 3 2]
        (valid, plan) = planned marks [] (WorldLayer DepthEnabled dynamic)
    encodeLayerInDrawingOrder plan valid `shouldBe` Just (encodeLayer (singleLayer (WorldLayer DepthEnabled [dynamic !! 0, dynamic !! 2, dynamic !! 1])))
  it "refuses a plan that names a chunk the layer does not list" $ do
    let chunk = built ChunkUi [orderedAt 1 1]
        (_, plan) = planned marks [(ref 1 1, chunk)] (UiLayerWith [ref 1 1] [])
        (otherValid, _) = planned marks [] (UiLayer [orderedAt 1 1])
    encodeLayerInDrawingOrder plan otherValid `shouldBe` Nothing

-- * Layers

layerSpec ∷ Spec
layerSpec = describe "a layer that lists chunks" $ do
  it "is the layer that lists none when it lists none, as a constructor and as a pattern" $ do
    WorldLayer DepthEnabled [plainInstance] `shouldBe` WorldLayerWith DepthEnabled [] [plainInstance]
    UiLayer [plainInstance] `shouldBe` UiLayerWith [] [plainInstance]
    case WorldLayerWith DepthDisabled [] [plainInstance] of
      WorldLayer depth instances → (depth, instances) `shouldBe` (DepthDisabled, [plainInstance])
      _ → fail "the chunk-free layer did not match"
    (case UiLayerWith [ref 1 1] [] of UiLayer _ → True; _ → False) `shouldBe` False
  it "reports its chunks in order and its dynamic instances without theirs" $ do
    let layer = WorldLayerWith DepthEnabled [ref 2 1, ref 1 1] [plainInstance]
    layerChunks layer `shouldBe` [ref 2 1, ref 1 1]
    layerInstances layer `shouldBe` [plainInstance]
    layerChunks (UiLayer [plainInstance]) `shouldBe` []
  it "names the kind of chunk it takes" $ do
    layerChunkKind (WorldLayer DepthEnabled []) `shouldBe` ChunkWorldDepth
    layerChunkKind (WorldLayer DepthDisabled []) `shouldBe` ChunkWorldFlat
    layerChunkKind (UiLayer []) `shouldBe` ChunkUi
  it "resolves the chunks of a resolver by exact reference, and lists them" $ do
    let a = built ChunkUi [orderedAt 1 1]
        chunks = chunksFrom [(ref 3 1, a), (ref 1 2, a)]
    lookupChunk chunks (ref 3 1) `shouldBe` Just a
    lookupChunk chunks (ref 3 2) `shouldBe` Nothing
    lookupChunk noChunks (ref 3 1) `shouldBe` Nothing
    chunkRefsOf chunks `shouldBe` [ref 1 2, ref 3 1]
    nub (toList (chunkRefsOf chunks)) `shouldBe` chunkRefsOf chunks
    isJust (lookupChunk chunks (ref 1 2)) `shouldBe` True
    mapMaybe (lookupChunk chunks) [ref 1 2, ref 9 9, ref 3 1] `shouldBe` [a, a]
