-- | The draw plan: routing, ordering, run splitting and the equal-key rules.
--
-- __What is under test.__ 'planSnapshot' turns a validated snapshot and each
-- texture's cutout mark into passes, views, layers and draw runs. The examples
-- state the expected outcomes in the test itself: the routing of every
-- combination of the conditions the specification names, the exact drawing
-- order and runs of interleaved inputs, and the two equal-key outcomes as
-- concrete fixtures. The generated examples check an independent
-- characterisation of the order (cutouts first, in submission order; the
-- ordered path in ascending key then submission order) rather than rerunning
-- the planner's own sort.
--
-- __Material.__ Until application materials exist every instance uses the
-- built-in default, which is cutout-capable; the routing matrix is therefore
-- over the other conditions, and cross-material cases wait for application
-- materials.
module Test.Render.TwoD.DrawPlan (spec) where

import Control.Exception (evaluate)
import Data.List (nub, sort)
import Data.Word (Word32)
import GHC.Exts.Heap (Box, allClosures, asBox, getBoxedClosureData)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan
import Hetoimasia.Render.TwoD.Settings (ViewSettings, defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..), validateSnapshot)
import System.Mem (performMajorGC)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , Property
  , arbitrary
  , choose
  , conjoin
  , counterexample
  , elements
  , forAll
  , frequency
  , listOf
  , property
  , resize
  , shuffle
  , sublistOf
  , (===)
  )
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Draw plan" $ do
  routingSpec
  orderingSpec
  equalKeySpec
  withoutDepthSpec
  runSpec
  structureSpec
  retentionSpec
  generatedSpec

-- * Builders

-- | The handle every plain instance carries, and the marks that name it.
markedHandle ∷ TextureHandle
markedHandle = textureHandle 1 1

marked ∷ CutoutMarks
marked = cutoutMarks [markedHandle]

-- | A valid snapshot's plan; a snapshot the caller knows is valid.
plannedWith ∷ CutoutMarks → Snapshot → DrawPlan
plannedWith marks snapshot =
  either (error . ("the snapshot was refused: " <>) . show) (planSnapshot marks) (validateSnapshot snapshot)

-- | The plan of one layer in the plain view.
layerPlan ∷ CutoutMarks → Layer → PlannedLayer
layerPlan marks layer =
  case plannedWith marks (snapshotWithView (plainView [layer])) of
    DrawPlan [PlannedPass {plannedViews = [PlannedView {plannedLayers = [planned]}]}] → planned
    other → error ("a snapshot of one layer planned to " <> show other)

depthLayer ∷ [Instance] → Layer
depthLayer = WorldLayer DepthEnabled

-- | A marked, opaque, plain instance at this depth key: it routes to cutout in
-- a depth-enabled world layer.
cutoutAt ∷ Word32 → Instance
cutoutAt key = plainInstance {instanceDepthKey = key}

-- | An instance carrying the translucent flag at this key: always ordered.
translucentAt ∷ Word32 → Instance
translucentAt key = plainInstance {instanceDepthKey = key, instanceTranslucent = True}

-- | An instance whose texture is unmarked at this key: ordered.
unmarkedAt ∷ Word32 → Instance
unmarkedAt key = plainInstance {instanceDepthKey = key, instanceTexture = textureHandle 9 9}

-- | Number the instances in submission order through the material word, which
-- the plan never reads, so a drawn instance can be named by its tag.
tagged ∷ [Instance] → [Instance]
tagged = zipWith (\n candidate → candidate {instanceMaterial = n}) [0 ..]

-- | The tags of the instances in the order the layer draws them.
drawnTags ∷ PlannedLayer → [Instance] → [Word32]
drawnTags planned instances = [instanceMaterial (instances !! index) | index ← drawingOrder planned]

runShapes ∷ PlannedLayer → [(DrawPath, Int, Int)]
runShapes planned = [(runPath run, runStart run, runCount run) | run ← plannedRuns planned]

-- * Routing

routingSpec ∷ Spec
routingSpec = describe "routing" $ do
  it "sends an instance to the cutout path only when all five conditions hold, over every combination" $
    sequence_
      [ routedTo spaceLayer markedTexture alpha translucent additive `shouldBe` expected
      | (spaceLayer, depthOn) ← spaces
      , markedTexture ← [False, True]
      , alpha ← [255, 254, 128, 1, 0]
      , translucent ← [False, True]
      , additive ← [False, True]
      , let expected
              | depthOn && markedTexture && alpha == 255 && not translucent && not additive = Cutout
              | otherwise = Ordered
      ]
  it "routes the cutout-eligible instance to a single cutout run in a depth-enabled world layer" $ do
    let planned = layerPlan marked (depthLayer [cutoutAt 3])
    runShapes planned `shouldBe` [(Cutout, 0, 1)]
    runMaterial <$> plannedRuns planned `shouldBe` [DefaultMaterial]
  it "takes the ordered path for an unmarked texture and for an unknown handle" $ do
    runShapes (layerPlan noCutoutMarks (depthLayer [cutoutAt 1])) `shouldBe` [(Ordered, 0, 1)]
    runShapes (layerPlan marked (depthLayer [unmarkedAt 1])) `shouldBe` [(Ordered, 0, 1)]
  it "keeps a mark to its generation: the same lookup index with another generation is unmarked" $ do
    let marks = cutoutMarks [textureHandle 7 2]
        with generation = plainInstance {instanceTexture = textureHandle 7 generation}
        planned = layerPlan marks (depthLayer (tagged [with 1, with 2, with 3, with 0, with 2]))
    runShapes planned `shouldBe` [(Cutout, 0, 2), (Ordered, 2, 3)]
    drawingOrder planned `shouldBe` [1, 4, 0, 2, 3]
  it "takes the ordered path whatever the mark when the mark set is empty" $
    runShapes (layerPlan noCutoutMarks (depthLayer (replicate 4 plainInstance))) `shouldBe` [(Ordered, 0, 4)]
  it "marks a handle by its complete value: index and generation both" $ do
    let marks = cutoutMarks [textureHandle 3 3]
    mapM_ (\(handle, expected) → isMarkedCutout marks handle `shouldBe` expected)
      [(textureHandle 3 3, True), (textureHandle 3 4, False), (textureHandle 4 3, False), (textureHandle 0 0, False)]
  where
    spaces = [(WorldLayer DepthEnabled, True), (WorldLayer DepthDisabled, False), (UiLayer, False)]
    routedTo build markedTexture alpha translucent additive =
      let candidate =
            plainInstance
              { instanceTexture = if markedTexture then markedHandle else textureHandle 2 2
              , instanceTint = Tint 255 255 255 alpha
              , instanceTranslucent = translucent
              , instanceAdditive = additive
              }
       in case runShapes (layerPlan marked (build [candidate])) of
            [(path, 0, 1)] → path
            other → error ("one instance planned to " <> show other)

-- * Ordering

orderingSpec ∷ Spec
orderingSpec = describe "ordering" $ do
  it "draws cutouts first in submission order, then the ordered instances by ascending key and submission" $ do
    -- Submission order, with the key and the reason each is cutout or ordered:
    --  0 cutout key 5; 1 translucent key 3; 2 cutout key 1; 3 alpha 128 key 9;
    --  4 additive key 3; 5 cutout key 5; 6 unmarked key 0.
    let instances =
          tagged
            [ cutoutAt 5
            , translucentAt 3
            , cutoutAt 1
            , plainInstance {instanceDepthKey = 9, instanceTint = Tint 255 255 255 128}
            , plainInstance {instanceDepthKey = 3, instanceAdditive = True}
            , cutoutAt 5
            , unmarkedAt 0
            ]
        planned = layerPlan marked (depthLayer instances)
    drawingOrder planned `shouldBe` [0, 2, 5, 6, 1, 4, 3]
    runShapes planned `shouldBe` [(Cutout, 0, 3), (Ordered, 3, 4)]
    drawnTags planned instances `shouldBe` [0, 2, 5, 6, 1, 4, 3]
  it "does not sort cutouts by key: the depth buffer decides, so submission order stands" $ do
    let instances = tagged [cutoutAt 20, cutoutAt 10, cutoutAt 30]
    drawingOrder (layerPlan marked (depthLayer instances)) `shouldBe` [0, 1, 2]
  it "sorts the ordered instances back to front: a larger key, being nearer, draws later" $ do
    let instances = tagged [translucentAt 9, translucentAt 2, translucentAt 5]
    drawingOrder (layerPlan marked (depthLayer instances)) `shouldBe` [1, 2, 0]
  it "gives a lone ordered instance among cutouts the last run, however small its key" $ do
    let instances = tagged [translucentAt 0, cutoutAt 100, cutoutAt 50]
        planned = layerPlan marked (depthLayer instances)
    drawingOrder planned `shouldBe` [1, 2, 0]
    runShapes planned `shouldBe` [(Cutout, 0, 2), (Ordered, 2, 1)]
  it "plans the same layer to the same plan every time" $ do
    let layer = depthLayer (tagged [translucentAt 4, cutoutAt 1, translucentAt 4, cutoutAt 9])
    layerPlan marked layer `shouldBe` layerPlan marked layer

-- * Equal keys

equalKeySpec ∷ Spec
equalKeySpec = describe "equal depth keys" $ do
  it "orders equal-key cutouts by submission, so the later draw wins" $ do
    -- Two cutouts at key 10, A submitted first: A draws first, B last and wins.
    let instances = tagged [cutoutAt 10, cutoutAt 10]
        planned = layerPlan marked (depthLayer instances)
    drawnTags planned instances `shouldBe` [0, 1]
    -- Submitted the other way round, the roles swap with the submission.
    let reversed = tagged [cutoutAt 10, cutoutAt 10, cutoutAt 10]
    drawingOrder (layerPlan marked (depthLayer reversed)) `shouldBe` [0, 1, 2]
  it "draws an ordered-path instance after a cutout at the same key, so it draws over it" $ do
    -- The translucent instance is submitted first, and still draws last.
    let translucentFirst = tagged [translucentAt 7, cutoutAt 7]
        planned = layerPlan marked (depthLayer translucentFirst)
    drawnTags planned translucentFirst `shouldBe` [1, 0]
    runShapes planned `shouldBe` [(Cutout, 0, 1), (Ordered, 1, 1)]
    -- Submitted last, it also draws last.
    let translucentLast = tagged [cutoutAt 7, translucentAt 7]
    drawnTags (layerPlan marked (depthLayer translucentLast)) translucentLast `shouldBe` [0, 1]
  it "draws an ordered-path instance after every cutout, whatever its key" $ do
    let instances = tagged [translucentAt 0, cutoutAt 5, cutoutAt 5, cutoutAt 0]
    drawnTags (layerPlan marked (depthLayer instances)) instances `shouldBe` [1, 2, 3, 0]
  it "keeps equal-key ordered instances in submission order" $ do
    let instances = tagged [translucentAt 4, translucentAt 4, translucentAt 4]
    drawingOrder (layerPlan marked (depthLayer instances)) `shouldBe` [0, 1, 2]

-- * Layers without depth

withoutDepthSpec ∷ Spec
withoutDepthSpec = describe "layers without depth and UI layers" $ do
  let allLayers instances =
        [ ("a UI layer", UiLayer instances)
        , ("a world layer with depth disabled", WorldLayer DepthDisabled instances)
        ]
  it "draw wholly in the ordered path, whatever the marks" $
    sequence_
      [ runShapes (layerPlan marked layer) `shouldBe` [(Ordered, 0, 3)]
      | (_, layer) ← allLayers [cutoutAt 1, cutoutAt 1, cutoutAt 1]
      ]
  it "sort by ascending depth key, then submission order" $
    sequence_
      [ do
          let planned = layerPlan marked layer
          drawingOrder planned `shouldBe` [2, 0, 3, 1, 4]
          runShapes planned `shouldBe` [(Ordered, 0, 5)]
      | (_, layer) ← allLayers (map cutoutAt [5, 9, 1, 5, 9])
      ]
  it "draw a larger key over an instance submitted later with a smaller key" $
    sequence_
      [ do
          let instances = tagged [cutoutAt 9, cutoutAt 2]
          -- Tag 0 has the larger key and was submitted first: it draws last.
          drawnTags (layerPlan marked (build instances)) instances `shouldBe` [1, 0]
      | build ← [UiLayer, WorldLayer DepthDisabled]
      ]
  it "keep submission order at equal keys: plain painter's order" $
    sequence_
      [ do
          let instances = tagged [cutoutAt 4, cutoutAt 4, cutoutAt 4]
          drawnTags (layerPlan marked (build instances)) instances `shouldBe` [0, 1, 2]
      | build ← [UiLayer, WorldLayer DepthDisabled]
      ]
  it "clear depth only when they are world layers with depth enabled" $ do
    plannedClearsDepth (layerPlan marked (WorldLayer DepthEnabled [])) `shouldBe` True
    plannedClearsDepth (layerPlan marked (WorldLayer DepthDisabled [cutoutAt 1])) `shouldBe` False
    plannedClearsDepth (layerPlan marked (UiLayer [cutoutAt 1])) `shouldBe` False
  it "mark a depth-enabled layer as clearing depth whether it holds cutouts, only ordered instances or nothing" $
    sequence_
      [ plannedClearsDepth (layerPlan marked (depthLayer instances)) `shouldBe` True
      | instances ← [[cutoutAt 1], [translucentAt 1], [], [cutoutAt 1, translucentAt 1]]
      ]
  it "record each layer's space" $ do
    plannedSpace (layerPlan marked (WorldLayer DepthEnabled [])) `shouldBe` WorldSpace DepthEnabled
    plannedSpace (layerPlan marked (WorldLayer DepthDisabled [])) `shouldBe` WorldSpace DepthDisabled
    plannedSpace (layerPlan marked (UiLayer [])) `shouldBe` UiSpace

-- * Runs

runSpec ∷ Spec
runSpec = describe "runs" $ do
  it "hold nothing for a layer with no instances" $ do
    let planned = layerPlan marked (depthLayer [])
    plannedRuns planned `shouldBe` []
    drawingOrder planned `shouldBe` []
  it "hold nothing in a zero-size viewport, whatever the layers hold" $
    sequence_
      [ do
          let view = View plainCamera viewport defaultViewSettings [depthLayer [cutoutAt 1, translucentAt 2], UiLayer [plainInstance]]
              plan = plannedWith marked (snapshotWithView view)
              layers = [planned | pass ← planPasses plan, planView ← plannedViews pass, planned ← plannedLayers planView]
          length layers `shouldBe` 2
          mapM_ (\planned → plannedRuns planned `shouldBe` []) layers
          mapM_ (\planned → drawingOrder planned `shouldBe` []) layers
      | viewport ←
          [ Viewport (V2 5 5) (V2 0 0)
          , Viewport (V2 5 5) (V2 0 100)
          , Viewport (V2 5 5) (V2 100 0)
          ]
      ]
  it "start at zero and meet end to end, and split only where the path changes" $ do
    let planned = layerPlan marked (depthLayer (tagged [cutoutAt 1, translucentAt 1, cutoutAt 2, translucentAt 2]))
    runShapes planned `shouldBe` [(Cutout, 0, 2), (Ordered, 2, 2)]
  it "are not split by sampler, tint colour, depth key, transform, UV or material parameter word" $ do
    let varied =
          [ plainInstance {instanceSampler = SamplerNearest, instanceDepthKey = 9}
          , plainInstance {instanceSampler = SamplerLinear, instanceTint = Tint 1 2 3 255, instanceMaterial = 77}
          , plainInstance {instanceUv = UvRect 0.25 0.25 0.5 0.5, instanceDepthKey = 0}
          , plainInstance {instanceSampler = SamplerDefault, instanceTint = Tint 255 0 0 255, instanceMaterial = 4}
          ]
    runShapes (layerPlan marked (depthLayer varied)) `shouldBe` [(Cutout, 0, 4)]
  it "are not split by tint alpha or the flags among the ordered instances" $ do
    let varied =
          [ translucentAt 1
          , plainInstance {instanceAdditive = True, instanceDepthKey = 2}
          , plainInstance {instanceTint = Tint 9 9 9 10, instanceDepthKey = 3, instanceSampler = SamplerLinear}
          , plainInstance {instanceTranslucent = True, instanceAdditive = True, instanceMaterial = 5}
          ]
    runShapes (layerPlan marked (depthLayer varied)) `shouldBe` [(Ordered, 0, 4)]
  it "give a run's indices as the slice of the drawing order it names" $ do
    let planned = layerPlan marked (depthLayer (tagged [translucentAt 3, cutoutAt 0, cutoutAt 1, translucentAt 1]))
    map (runIndices planned) (plannedRuns planned) `shouldBe` [[1, 2], [3, 0]]
  it "name the built-in default material until application materials exist" $
    map runMaterial (plannedRuns (layerPlan marked (depthLayer [cutoutAt 1, translucentAt 1]))) `shouldBe` [DefaultMaterial, DefaultMaterial]
  it "treat the built-in default material as cutout-capable" $
    materialCutoutCapable DefaultMaterial `shouldBe` True

-- * Structure

structureSpec ∷ Spec
structureSpec = describe "structure" $ do
  it "keeps passes, views and layers in order with their targets, clears, cameras, viewports and settings" $ do
    let cameraA = Camera (V2 1 2) 2 Nothing
        cameraB = Camera (V2 (-3) 4) 0.5 (Just 0.25)
        viewportA = Viewport (V2 0 0) (V2 320 240)
        viewportB = Viewport (V2 320 0) (V2 320 240)
        viewA = View cameraA viewportA defaultViewSettings [depthLayer [cutoutAt 2, translucentAt 1], UiLayer [cutoutAt 3, cutoutAt 1]]
        viewB = View cameraB viewportB defaultViewSettings [WorldLayer DepthDisabled [cutoutAt 5], depthLayer []]
        viewC = View cameraA viewportB defaultViewSettings []
        clearA = ClearColour 0.1 0.2 0.3 1
        clearB = ClearColour 0 0 0 0
        snapshot =
          Snapshot
            [ Pass (offscreen 0) clearA [viewA, viewB]
            , Pass (offscreen 1) clearB [viewC]
            , Pass WindowTarget clearB [viewB, viewA]
            ]
        DrawPlan passes = plannedWith marked snapshot
    map plannedTarget passes `shouldBe` [offscreen 0, offscreen 1, WindowTarget]
    map plannedClear passes `shouldBe` [clearA, clearB, clearB]
    map (map plannedCamera . plannedViews) passes `shouldBe` [[cameraA, cameraB], [cameraA], [cameraB, cameraA]]
    map (map plannedViewport . plannedViews) passes `shouldBe` [[viewportA, viewportB], [viewportB], [viewportB, viewportA]]
    map (map plannedSettings . plannedViews) passes
      `shouldBe` [ [defaultViewSettings, defaultViewSettings]
                 , [defaultViewSettings]
                 , [defaultViewSettings, defaultViewSettings]
                 ]
    map (map (map plannedLocation . plannedLayers) . plannedViews) passes
      `shouldBe` [ [[AtLayer 0 0 0, AtLayer 0 0 1], [AtLayer 0 1 0, AtLayer 0 1 1]]
                 , [[]]
                 , [[AtLayer 2 0 0, AtLayer 2 0 1], [AtLayer 2 1 0, AtLayer 2 1 1]]
                 ]
    map (map (map plannedSpace . plannedLayers) . plannedViews) passes
      `shouldBe` [ [[WorldSpace DepthEnabled, UiSpace], [WorldSpace DepthDisabled, WorldSpace DepthEnabled]]
                 , [[]]
                 , [[WorldSpace DepthDisabled, WorldSpace DepthEnabled], [WorldSpace DepthEnabled, UiSpace]]
                 ]
    map (map (map plannedClearsDepth . plannedLayers) . plannedViews) passes
      `shouldBe` [ [[True, False], [False, True]]
                 , [[]]
                 , [[False, True], [True, False]]
                 ]
    -- The first view's first layer: a cutout then a translucent instance.
    case passes of
      PlannedPass {plannedViews = PlannedView {plannedLayers = firstLayer : _} : _} : _ → do
        drawingOrder firstLayer `shouldBe` [0, 1]
        runShapes firstLayer `shouldBe` [(Cutout, 0, 1), (Ordered, 1, 1)]
      _ → fail "the first layer was missing"
    -- The UI layer beside it sorts by key: key 1 before key 3.
    case passes of
      PlannedPass {plannedViews = PlannedView {plannedLayers = _ : uiLayer : _} : _} : _ → do
        drawingOrder uiLayer `shouldBe` [1, 0]
        runShapes uiLayer `shouldBe` [(Ordered, 0, 2)]
      _ → fail "the UI layer was missing"
  it "plans a snapshot of no passes to no passes" $
    plannedWith marked (Snapshot []) `shouldBe` DrawPlan []

-- * Retention

-- | A planned layer keeps the permutation and its few runs, and nothing else
-- per instance: after the layer is evaluated, the number of heap closures
-- reachable from it does not depend on how many instances it orders. A lazy
-- field still holding the list the order was built from would reach one closure
-- or more for every instance.
retentionSpec ∷ Spec
retentionSpec = describe "retention" $ do
  it "reaches the same heap from a layer of 4000 instances as from one of 200" $ do
    small ← reachableFromLayer 200
    large ← reachableFromLayer 4000
    large `shouldBe` small
  it "reaches a small heap: the permutation, the runs and the layer's few fields" $ do
    reachable ← reachableFromLayer 4000
    (reachable < 100) `shouldBe` True
  where
    reachableFromLayer count = do
      let instances =
            [ if even index then cutoutAt (fromIntegral (index `mod` 7)) else translucentAt (fromIntegral (index `mod` 5))
            | index ← [0 .. count - 1 ∷ Int]
            ]
      planned ← evaluate (layerPlan marked (depthLayer instances))
      performMajorGC
      closureCount (asBox planned)

-- | The closures reachable from a value, counted along every path. The values
-- measured here are trees and small shared constants, with no cycle.
closureCount ∷ Box → IO Int
closureCount box = do
  closure ← getBoxedClosureData box
  below ← mapM closureCount (allClosures closure)
  pure (1 + sum below)

-- * Generated

generatedSpec ∷ Spec
generatedSpec = describe "over generated snapshots" $ do
  prop "plans the same snapshot and marks to the same plan every time" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      plannedWith marks snapshot === plannedWith marks snapshot
  prop "gives each layer in a non-zero viewport a permutation of its submission indices" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      forLayers marks snapshot $ \viewport layer planned →
        whenNonZero viewport $
          sort (drawingOrder planned) === [0 .. length (layerInstances layer) - 1]
  prop "partitions the permutation into non-empty runs without gaps or overlap, split exactly where path or material changes" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      forLayers marks snapshot $ \viewport layer planned →
        whenNonZero viewport $
          runsPartition (length (layerInstances layer)) (plannedRuns planned)
  prop "routes by the five conditions, draws cutouts first in submission order, then ordered instances by ascending key and submission" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      forLayers marks snapshot $ \viewport layer planned →
        whenNonZero viewport $
          orderingHolds marks layer planned
  prop "holds no order and no runs in a zero-size viewport" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      forLayers marks snapshot $ \viewport _ planned →
        if nonZero viewport
          then property True
          else (drawingOrder planned, plannedRuns planned) === ([], [])
  prop "keeps the snapshot's structure, locations and per-layer depth-clear marks" $
    forAll routedSnapshotGen $ \(marks, snapshot) →
      structureOf (plannedWith marks snapshot) === expectedStructure snapshot
  prop "keeps shuffled equal-key inputs in their new submission order, on each path" $
    forAll routedMarks $ \marks →
      forAll (resize 12 (listOf routedInstanceGen)) $ \instances →
        forAll (shuffle (tagged instances)) $ \shuffled →
          let planned = layerPlan marks (depthLayer shuffled)
              drawn = [shuffled !! index | index ← drawingOrder planned]
              tag = instanceMaterial
              cutoutTags xs = [tag candidate | candidate ← xs, expectedPath marks True candidate == Cutout]
              orderedTagsAt key xs =
                [ tag candidate
                | candidate ← xs
                , expectedPath marks True candidate == Ordered
                , instanceDepthKey candidate == key
                ]
           in conjoin
                ( (cutoutTags drawn === cutoutTags shuffled)
                    : [orderedTagsAt key drawn === orderedTagsAt key shuffled | key ← nub (map instanceDepthKey shuffled)]
                )
  it "plans a large layer to a permutation with its two runs" $ do
    let count = 6000
        instances =
          [ if even index
              then cutoutAt (fromIntegral (index `mod` 97))
              else translucentAt (fromIntegral (index `mod` 89))
          | index ← [0 .. count - 1 ∷ Int]
          ]
        planned = layerPlan marked (depthLayer instances)
    sort (drawingOrder planned) `shouldBe` [0 .. count - 1]
    runShapes planned `shouldBe` [(Cutout, 0, count `div` 2), (Ordered, count `div` 2, count `div` 2)]

-- | Whether the viewport has a non-zero extent in both directions.
nonZero ∷ Viewport → Bool
nonZero (Viewport _ (V2 width height)) = width /= 0 && height /= 0

whenNonZero ∷ Viewport → Property → Property
whenNonZero viewport check = if nonZero viewport then check else property True

-- | The path the specification gives an instance in a layer, stated here
-- independently of the planner. Material capability is constant until
-- application materials exist.
expectedPath ∷ CutoutMarks → Bool → Instance → DrawPath
expectedPath marks depthOn candidate
  | depthOn
      && isMarkedCutout marks (instanceTexture candidate)
      && alpha == 255
      && not (instanceTranslucent candidate)
      && not (instanceAdditive candidate) =
      Cutout
  | otherwise = Ordered
  where
    Tint _ _ _ alpha = instanceTint candidate

-- | Every layer of the plan with its viewport and the layer it came from.
layersOf ∷ CutoutMarks → Snapshot → [(Viewport, Layer, PlannedLayer)]
layersOf marks snapshot =
  [ (viewViewport view, layer, planned)
  | (pass, plannedPass) ← zip (snapshotPasses snapshot) (planPasses (plannedWith marks snapshot))
  , (view, plannedView) ← zip (passViews pass) (plannedViews plannedPass)
  , (layer, planned) ← zip (viewLayers view) (plannedLayers plannedView)
  ]

forLayers ∷ CutoutMarks → Snapshot → (Viewport → Layer → PlannedLayer → Property) → Property
forLayers marks snapshot check =
  conjoin [check viewport layer planned | (viewport, layer, planned) ← layersOf marks snapshot]

-- | The runs start at zero, meet end to end, are never empty, cover the layer's
-- instances exactly, and differ from their neighbours in path or material, so
-- the grouping is maximal.
runsPartition ∷ Int → [DrawRun] → Property
runsPartition count runs =
  conjoin
    [ counterexample "the runs start at zero and meet end to end" (map runStart runs === init (scanl (+) 0 (map runCount runs)))
    , counterexample "every run holds an instance" (all ((>= 1) . runCount) runs === True)
    , counterexample "the runs cover every instance" (sum (map runCount runs) === count)
    , counterexample "neighbouring runs differ in path or material" $
        and [(runPath a, runMaterial a) /= (runPath b, runMaterial b) | (a, b) ← zip runs (drop 1 runs)] === True
    ]

-- | The drawing order is the cutouts in submission order and then the ordered
-- instances by ascending key and submission, every run holds the path its
-- instances take, and the cutouts are exactly those meeting the five conditions.
orderingHolds ∷ CutoutMarks → Layer → PlannedLayer → Property
orderingHolds marks layer planned =
  conjoin
    [ counterexample "the cutout path comes first" (paths === sort paths)
    , counterexample "cutouts keep submission order" (cutouts === sort cutouts)
    , counterexample "ordered instances ascend by key and then submission" (ordered === sort ordered)
    , counterexample "every run holds only its own path" $
        and [all ((== runPath run) . expected) (runIndices planned run) | run ← plannedRuns planned] === True
    ]
  where
    instances = layerInstances layer
    depthOn = plannedSpace planned == WorldSpace DepthEnabled
    expected index = expectedPath marks depthOn (instances !! index)
    order = drawingOrder planned
    paths = map expected order
    cutouts = [index | index ← order, expected index == Cutout]
    ordered = [(instanceDepthKey (instances !! index), index) | index ← order, expected index == Ordered]

-- | What a plan keeps of the snapshot, as plain data.
type Structure = [(Target, ClearColour, [(Camera, Viewport, ViewSettings, [(Location, LayerSpace, Bool, Int)])])]

structureOf ∷ DrawPlan → Structure
structureOf (DrawPlan passes) =
  [ ( plannedTarget pass
    , plannedClear pass
    , [ ( plannedCamera view
        , plannedViewport view
        , plannedSettings view
        , [ (plannedLocation layer, plannedSpace layer, plannedClearsDepth layer, length (drawingOrder layer))
          | layer ← plannedLayers view
          ]
        )
      | view ← plannedViews pass
      ]
    )
  | pass ← passes
  ]

-- | The same, read straight off the snapshot.
expectedStructure ∷ Snapshot → Structure
expectedStructure (Snapshot passes) =
  [ ( passTarget pass
    , passClear pass
    , [ ( viewCamera view
        , viewViewport view
        , viewSettings view
        , [ (AtLayer passIndex viewIndex layerIndex, space layer, clears layer, count view layer)
          | (layerIndex, layer) ← zip [0 ..] (viewLayers view)
          ]
        )
      | (viewIndex, view) ← zip [0 ..] (passViews pass)
      ]
    )
  | (passIndex, pass) ← zip [0 ..] passes
  ]
  where
    space (WorldLayerWith depth _ _) = WorldSpace depth
    space (UiLayerWith _ _) = UiSpace
    clears (WorldLayerWith depth _ _) = depth == DepthEnabled
    clears (UiLayerWith _ _) = False
    count view layer = if nonZero (viewViewport view) then length (layerInstances layer) else 0

-- * Generators

-- | A few handles, so marks and instances meet often: two generations of one
-- lookup index among them.
routedHandles ∷ [TextureHandle]
routedHandles = [textureHandle 1 1, textureHandle 1 2, textureHandle 2 1, textureHandle 3 3]

-- | A random set of marked handles.
routedMarks ∷ Gen CutoutMarks
routedMarks = cutoutMarks <$> sublistOf routedHandles

-- | An instance whose routing conditions are each often, not always, met, with
-- few depth keys so equal keys are common.
routedInstanceGen ∷ Gen Instance
routedInstanceGen = do
  texture ← elements routedHandles
  key ← frequency [(6, choose (0, 3)), (1, elements [0, depthKeyLimit - 1])]
  alpha ← frequency [(5, pure 255), (1, choose (0, 254))]
  translucent ← frequency [(5, pure False), (1, pure True)]
  additive ← frequency [(5, pure False), (1, pure True)]
  sampler ← elements [minBound .. maxBound]
  material ← arbitrary
  pure
    plainInstance
      { instanceTexture = texture
      , instanceDepthKey = key
      , instanceTint = Tint 255 255 255 alpha
      , instanceTranslucent = translucent
      , instanceAdditive = additive
      , instanceSampler = sampler
      , instanceMaterial = material
      }

routedLayerGen ∷ Gen Layer
routedLayerGen = do
  instances ← resize 8 (listOf routedInstanceGen)
  frequency
    [ (3, pure (WorldLayer DepthEnabled instances))
    , (1, pure (WorldLayer DepthDisabled instances))
    , (1, pure (UiLayer instances))
    ]

-- | Marks and a valid snapshot of up to three offscreen passes and possibly a
-- window pass, each with up to three views of up to three layers, some views
-- with a zero-size viewport.
routedSnapshotGen ∷ Gen (CutoutMarks, Snapshot)
routedSnapshotGen = do
  marks ← routedMarks
  count ← choose (0, 3)
  withWindow ← elements [False, True]
  offscreenPasses ← mapM (pass . offscreen) [0 .. count - 1]
  windowPasses ← if withWindow then (: []) <$> pass WindowTarget else pure []
  pure (marks, Snapshot (offscreenPasses <> windowPasses))
  where
    pass target = plainPass target <$> resize 3 (listOf view)
    view = do
      extent ← frequency [(4, pure (V2 640 480)), (1, pure (V2 0 0)), (1, pure (V2 0 50)), (1, pure (V2 50 0))]
      layers ← resize 3 (listOf routedLayerGen)
      pure (View plainCamera (Viewport (V2 0 0) extent) defaultViewSettings layers)
