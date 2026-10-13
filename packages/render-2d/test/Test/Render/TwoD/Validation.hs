-- | Snapshot validation: every refusal with its location, the boundaries of
-- every range, the window-pass rules, the retention of every reason across
-- locations, and determinism.
--
-- __Method.__ A table of candidates, each a plain valid snapshot with exactly
-- one component changed, states the refusals it must produce as an exact list,
-- location included; one example then checks that the table reaches every
-- 'Reason'. A metamorphic property corrupts one instance of a generated valid
-- snapshot and expects exactly that refusal. Totality and determinism are
-- checked on snapshots generated from the wild float generator, which reaches
-- NaN and both infinities.
module Test.Render.TwoD.Validation (spec) where

import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Word (Word32)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Settings
  ( TextureFilter (..)
  , ViewSettings (..)
  , ZoomMode (..)
  , brightnessRange
  , defaultViewSettings
  , uiScaleRange
  )
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, counterexample, elements, forAll, oneof, property, (.&&.))
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Validation" $ do
  acceptedSpec
  refusalSpec
  boundarySpec
  windowPassSpec
  retentionSpec
  generatedSpec

nan, inf ∷ Float
nan = 0 / 0
inf = 1 / 0

atInstance ∷ Reason → [Refusal]
atInstance reason = [Refusal (AtInstance 0 0 0 0) reason]

atView ∷ Reason → [Refusal]
atView reason = [Refusal (AtView 0 0) reason]

atPass ∷ Reason → [Refusal]
atPass reason = [Refusal (AtPass 0) reason]

-- | A view with the plain camera and viewport and these settings.
withSettings ∷ ViewSettings → Snapshot
withSettings settings = snapshotWithView (View plainCamera plainViewport settings [])

withCamera ∷ Camera → Snapshot
withCamera camera = snapshotWithView (View camera plainViewport defaultViewSettings [])

withViewport ∷ Viewport → Snapshot
withViewport viewport = snapshotWithView (View plainCamera viewport defaultViewSettings [])

withClear ∷ ClearColour → Snapshot
withClear clear = snapshotWithPass (Pass WindowTarget clear [])

withKey ∷ Word32 → Snapshot
withKey key = snapshotWithInstance plainInstance {instanceDepthKey = key}

acceptedSpec ∷ Spec
acceptedSpec = describe "an accepted snapshot" $ do
  it "is unchanged by validation, with every layer in its place" $ do
    let first = UiLayer [plainInstance, plainInstance {instanceDepthKey = 5}]
        second = WorldLayer DepthDisabled [plainInstance {instanceParameter = 9}]
        snapshot =
          Snapshot
            [ plainPass (offscreen 3) [plainView [first], plainView [second, first]]
            , windowPass [plainView [second]]
            ]
    case validateSnapshot snapshot of
      Left refused → fail ("refused: " <> show refused)
      Right valid → do
        validSnapshot valid `shouldBe` snapshot
        map validLayerLocation (validLayers valid)
          `shouldBe` [AtLayer 0 0 0, AtLayer 0 1 0, AtLayer 0 1 1, AtLayer 1 0 0]
        map validLayerContents (validLayers valid) `shouldBe` [first, second, first, second]

  it "may hold no pass, no view, no layer and no instance" $ do
    refusalsOf (Snapshot []) `shouldBe` []
    refusalsOf (snapshotWithPass (windowPass [])) `shouldBe` []
    refusalsOf (snapshotWithView (plainView [])) `shouldBe` []
    refusalsOf (snapshotWithView (plainView [UiLayer []])) `shouldBe` []

  it "may hold only offscreen passes, for window-free rendering and evidence" $
    refusalsOf (Snapshot [plainPass (offscreen 0) [plainView []], plainPass (offscreen 1) [plainView []]])
      `shouldBe` []

  it "accepts a zero-size viewport, which draws nothing" $ do
    refusalsOf (withViewport (Viewport (V2 10 20) (V2 0 0))) `shouldBe` []
    refusalsOf (withViewport (Viewport (V2 10 20) (V2 0 480))) `shouldBe` []
    refusalsOf (withViewport (Viewport (V2 10 20) (V2 640 0))) `shouldBe` []

  it "accepts every default setting, every filter and both zoom modes" $ do
    refusalsOf (withSettings defaultViewSettings) `shouldBe` []
    mapM_
      (\filtering → refusalsOf (withSettings defaultViewSettings {settingFilter = filtering}) `shouldBe` [])
      [minBound .. maxBound]
    refusalsOf (withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight 12.5}) `shouldBe` []
    refusalsOf (withSettings defaultViewSettings {settingPixelSnap = True}) `shouldBe` []

  it "holds the defaults the contract states" $ do
    settingUiScale defaultViewSettings `shouldBe` 1.0
    settingPixelSnap defaultViewSettings `shouldBe` False
    settingFilter defaultViewSettings `shouldBe` FilterNearest
    settingBrightness defaultViewSettings `shouldBe` 1.0
    settingZoomMode defaultViewSettings `shouldBe` PixelsPerUnit
    uiScaleRange `shouldBe` (0.5, 4.0)
    brightnessRange `shouldBe` (0.5, 3.0)

-- | Each candidate, built by changing one component of a valid snapshot, and
-- the exact refusals it must produce.
refusals ∷ [(String, Snapshot, [Refusal])]
refusals =
  [ ("a window pass followed by another pass", Snapshot [windowPass [], plainPass (offscreen 0) []], atPass WindowPassNotLast)
  , ("two window passes", Snapshot [windowPass [], windowPass []], [Refusal (AtPass 0) WindowPassNotLast, Refusal (AtPass 1) MultipleWindowPasses])
  , ("a clear colour component below 0", withClear (ClearColour (-1.0e-6) 0 0 1), atPass ClearColourInvalid)
  , ("a clear colour component above 1", withClear (ClearColour 0 0 0 1.0000001), atPass ClearColourInvalid)
  , ("a NaN clear colour component", withClear (ClearColour 0 nan 0 1), atPass ClearColourInvalid)
  , ("an infinite clear colour component", withClear (ClearColour 0 0 inf 1), atPass ClearColourInvalid)
  , ("a NaN camera position", withCamera plainCamera {cameraPosition = V2 nan 0}, atView CameraPositionNotFinite)
  , ("an infinite camera position", withCamera plainCamera {cameraPosition = V2 0 (-inf)}, atView CameraPositionNotFinite)
  , ("a zero camera zoom", withCamera plainCamera {cameraZoom = 0}, atView CameraZoomInvalid)
  , ("a negative camera zoom", withCamera plainCamera {cameraZoom = -2}, atView CameraZoomInvalid)
  , ("a NaN camera zoom", withCamera plainCamera {cameraZoom = nan}, atView CameraZoomInvalid)
  , ("an infinite camera zoom", withCamera plainCamera {cameraZoom = inf}, atView CameraZoomInvalid)
  , ("a NaN camera rotation", withCamera plainCamera {cameraRotation = Just nan}, atView CameraRotationNotFinite)
  , ("an infinite camera rotation", withCamera plainCamera {cameraRotation = Just inf}, atView CameraRotationNotFinite)
  , ("a NaN viewport origin", withViewport (Viewport (V2 nan 0) (V2 1 1)), atView ViewportNotFinite)
  , ("an infinite viewport extent", withViewport (Viewport (V2 0 0) (V2 inf 1)), atView ViewportNotFinite)
  , ("a negative infinite viewport extent", withViewport (Viewport (V2 0 0) (V2 (-inf) 1)), [Refusal (AtView 0 0) ViewportNotFinite, Refusal (AtView 0 0) ViewportExtentNegative])
  , ("a NaN origin beside a finite negative extent", withViewport (Viewport (V2 nan 0) (V2 (-1) 1)), [Refusal (AtView 0 0) ViewportNotFinite, Refusal (AtView 0 0) ViewportExtentNegative])
  , ("an infinite extent beside a finite negative extent", withViewport (Viewport (V2 0 0) (V2 inf (-1))), [Refusal (AtView 0 0) ViewportNotFinite, Refusal (AtView 0 0) ViewportExtentNegative])
  , ("a negative viewport width", withViewport (Viewport (V2 0 0) (V2 (-1) 1)), atView ViewportExtentNegative)
  , ("a negative viewport height", withViewport (Viewport (V2 0 0) (V2 1 (-1.0e-30))), atView ViewportExtentNegative)
  , ("a UI scale below its range", withSettings defaultViewSettings {settingUiScale = 0.25}, atView UiScaleOutOfRange)
  , ("a UI scale above its range", withSettings defaultViewSettings {settingUiScale = 4.5}, atView UiScaleOutOfRange)
  , ("a NaN UI scale", withSettings defaultViewSettings {settingUiScale = nan}, atView UiScaleOutOfRange)
  , ("an infinite UI scale", withSettings defaultViewSettings {settingUiScale = inf}, atView UiScaleOutOfRange)
  , ("a brightness below its range", withSettings defaultViewSettings {settingBrightness = 0.25}, atView BrightnessOutOfRange)
  , ("a brightness above its range", withSettings defaultViewSettings {settingBrightness = 3.5}, atView BrightnessOutOfRange)
  , ("a NaN brightness", withSettings defaultViewSettings {settingBrightness = nan}, atView BrightnessOutOfRange)
  , ("an infinite brightness", withSettings defaultViewSettings {settingBrightness = -inf}, atView BrightnessOutOfRange)
  , ("a zero fixed half-height", withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight 0}, atView HalfHeightInvalid)
  , ("a negative fixed half-height", withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight (-3)}, atView HalfHeightInvalid)
  , ("a NaN fixed half-height", withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight nan}, atView HalfHeightInvalid)
  , ("an infinite fixed half-height", withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight inf}, atView HalfHeightInvalid)
  , ("a NaN transform coefficient", snapshotWithInstance plainInstance {instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 nan 0)}, atInstance TransformNotFinite)
  , ("an infinite transform coefficient", snapshotWithInstance plainInstance {instanceTransform = fromColumns (V2 inf 0) (V2 0 1) (V2 0 0)}, atInstance TransformNotFinite)
  , ("a NaN UV value", snapshotWithInstance plainInstance {instanceUv = UvRect 0 0 nan 1}, atInstance UvNotFinite)
  , ("an infinite UV value", snapshotWithInstance plainInstance {instanceUv = UvRect 0 (-inf) 1 1}, atInstance UvNotFinite)
  , ("a depth key of 2^24", withKey 16777216, atInstance DepthKeyTooLarge)
  , ("a depth key of 2^32 - 1", withKey maxBound, atInstance DepthKeyTooLarge)
  , ("a clip index of 1", snapshotWithInstance plainInstance {instanceClip = 1}, atInstance ClipIndexNotZero)
  , ("a clip index of 65535", snapshotWithInstance plainInstance {instanceClip = maxBound}, atInstance ClipIndexNotZero)
  ]

refusalSpec ∷ Spec
refusalSpec = describe "a refused snapshot" $ do
  mapM_
    (\(name, candidate, expected) → it ("names " <> name <> " and where it was found") $ refusalsOf candidate `shouldBe` expected)
    refusals

  -- The two reasons about retained chunks are about what a snapshot lists, not
  -- about its own values; "Test.Render.TwoD.Chunks" exercises them. The four
  -- about application materials are about the data a view holds for them;
  -- "Test.Render.TwoD.Materials" exercises them.
  it "is exercised for every reason the module can give but the chunk and the material ones" $
    sort (nub [refusalReason refusal | (_, _, expected) ← refusals, refusal ← expected])
      `shouldBe` [reason | reason ← [minBound .. maxBound], reason `notElem` [ChunkUnresolved, ChunkKindMismatch, ParameterBeyondRecords, RecordLayoutMismatch, PushBlockSizeMismatch, PushBlockMissing]]

  it "ignores a fixed half-height outside the fixed half-height mode" $
    refusalsOf (withSettings defaultViewSettings {settingZoomMode = PixelsPerUnit}) `shouldBe` []

  it "names the pass, view, layer and instance of a deeply nested fault" $ do
    let bad = plainInstance {instanceDepthKey = 16777216}
        snapshot =
          Snapshot
            [ plainPass (offscreen 0) [plainView []]
            , windowPass
                [ plainView []
                , plainView
                    [ UiLayer [plainInstance]
                    , WorldLayer DepthEnabled [plainInstance, plainInstance, bad]
                    ]
                ]
            ]
    refusalsOf snapshot `shouldBe` [Refusal (AtInstance 1 1 1 2) DepthKeyTooLarge]

boundarySpec ∷ Spec
boundarySpec = describe "the boundary of every range" $ do
  it "accepts depth keys up to 2^24 - 1 and refuses 2^24 and above" $ do
    refusalsOf (withKey 0) `shouldBe` []
    refusalsOf (withKey 16777215) `shouldBe` []
    refusalsOf (withKey 16777216) `shouldBe` atInstance DepthKeyTooLarge
    refusalsOf (withKey 16777217) `shouldBe` atInstance DepthKeyTooLarge
    refusalsOf (withKey 4294967295) `shouldBe` atInstance DepthKeyTooLarge

  it "accepts UI scales 0.5 and 4.0 and refuses the Floats on either side of them" $ do
    let ui scale = refusalsOf (withSettings defaultViewSettings {settingUiScale = scale})
    ui 0.5 `shouldBe` []
    ui 4.0 `shouldBe` []
    ui 0.49999997 `shouldBe` atView UiScaleOutOfRange
    ui 4.0000005 `shouldBe` atView UiScaleOutOfRange
    ui 1.0 `shouldBe` []

  it "accepts brightness 0.5 and 3.0 and refuses the Floats on either side of them" $ do
    let bright level = refusalsOf (withSettings defaultViewSettings {settingBrightness = level})
    bright 0.5 `shouldBe` []
    bright 3.0 `shouldBe` []
    bright 0.49999997 `shouldBe` atView BrightnessOutOfRange
    bright 3.0000002 `shouldBe` atView BrightnessOutOfRange

  it "accepts clear components 0 and 1 and refuses the Floats on either side of them" $ do
    refusalsOf (withClear (ClearColour 0 1 0 1)) `shouldBe` []
    refusalsOf (withClear (ClearColour (-1.0e-45) 1 0 1)) `shouldBe` atPass ClearColourInvalid
    refusalsOf (withClear (ClearColour 0 1.0000001 0 1)) `shouldBe` atPass ClearColourInvalid

  it "refuses a clear component at each of the four positions" $
    mapM_
      (\clear → refusalsOf (withClear clear) `shouldBe` atPass ClearColourInvalid)
      [ClearColour nan 0 0 0, ClearColour 0 nan 0 0, ClearColour 0 0 nan 0, ClearColour 0 0 0 nan]

  it "accepts the smallest positive camera zoom and fixed half-height" $ do
    refusalsOf (withCamera plainCamera {cameraZoom = 1.0e-45}) `shouldBe` []
    refusalsOf (withSettings defaultViewSettings {settingZoomMode = FixedHalfHeight 1.0e-45}) `shouldBe` []

  it "accepts a rotation of any finite size" $
    refusalsOf (withCamera plainCamera {cameraRotation = Just 3.4028235e38}) `shouldBe` []

windowPassSpec ∷ Spec
windowPassSpec = describe "the window pass" $ do
  it "may be the only pass, or last after offscreen passes" $ do
    refusalsOf (Snapshot [windowPass []]) `shouldBe` []
    refusalsOf (Snapshot [plainPass (offscreen 0) [], plainPass (offscreen 1) [], windowPass []]) `shouldBe` []

  it "is refused when another pass follows it" $ do
    refusalsOf (Snapshot [windowPass [], plainPass (offscreen 0) []]) `shouldBe` [Refusal (AtPass 0) WindowPassNotLast]
    refusalsOf (Snapshot [plainPass (offscreen 0) [], windowPass [], plainPass (offscreen 1) []])
      `shouldBe` [Refusal (AtPass 1) WindowPassNotLast]

  it "is refused when a second one appears, whether or not offscreen passes sit between" $ do
    refusalsOf (Snapshot [windowPass [], windowPass []])
      `shouldBe` [Refusal (AtPass 0) WindowPassNotLast, Refusal (AtPass 1) MultipleWindowPasses]
    refusalsOf (Snapshot [plainPass (offscreen 0) [], windowPass [], plainPass (offscreen 1) [], windowPass []])
      `shouldBe` [Refusal (AtPass 1) WindowPassNotLast, Refusal (AtPass 3) MultipleWindowPasses]

  it "names every extra window pass of three" $
    refusalsOf (Snapshot [windowPass [], windowPass [], windowPass []])
      `shouldBe` [ Refusal (AtPass 0) WindowPassNotLast
                 , Refusal (AtPass 1) MultipleWindowPasses
                 , Refusal (AtPass 1) WindowPassNotLast
                 , Refusal (AtPass 2) MultipleWindowPasses
                 ]

retentionSpec ∷ Spec
retentionSpec = describe "every reason is retained" $ do
  it "reports faults at different locations together, in snapshot order, with their indices" $ do
    let zeroViewport = Viewport (V2 0 0) (V2 0 0)
        badInstance =
          plainInstance
            { instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 nan 0)
            , instanceUv = UvRect 0 0 inf 1
            , instanceClip = 7
            }
        snapshot =
          Snapshot
            [ Pass
                WindowTarget
                (ClearColour nan 0 0 1)
                [ -- Invalid data inside a zero-size viewport is refused like any other.
                  View
                    plainCamera {cameraPosition = V2 nan 0}
                    zeroViewport
                    defaultViewSettings
                    [UiLayer [plainInstance {instanceDepthKey = 16777216}, badInstance]]
                , View
                    plainCamera {cameraZoom = 0, cameraRotation = Just inf}
                    plainViewport
                    defaultViewSettings {settingUiScale = 5, settingBrightness = nan, settingZoomMode = FixedHalfHeight (-1)}
                    [WorldLayer DepthDisabled [plainInstance, plainInstance, plainInstance {instanceDepthKey = maxBound}]]
                ]
            , windowPass [plainView []]
            ]
        expected =
          [ Refusal (AtPass 0) WindowPassNotLast
          , Refusal (AtPass 0) ClearColourInvalid
          , Refusal (AtView 0 0) CameraPositionNotFinite
          , Refusal (AtInstance 0 0 0 0) DepthKeyTooLarge
          , Refusal (AtInstance 0 0 0 1) TransformNotFinite
          , Refusal (AtInstance 0 0 0 1) UvNotFinite
          , Refusal (AtInstance 0 0 0 1) ClipIndexNotZero
          , Refusal (AtView 0 1) CameraZoomInvalid
          , Refusal (AtView 0 1) CameraRotationNotFinite
          , Refusal (AtView 0 1) UiScaleOutOfRange
          , Refusal (AtView 0 1) BrightnessOutOfRange
          , Refusal (AtView 0 1) HalfHeightInvalid
          , Refusal (AtInstance 0 1 0 2) DepthKeyTooLarge
          , Refusal (AtPass 1) MultipleWindowPasses
          ]
    refusalsOf snapshot `shouldBe` expected
    -- Asking again gives the same answer in the same order.
    refusalsOf snapshot `shouldBe` expected

  it "reports the same fault at the same index in two views of the same pass" $
    refusalsOf
      ( snapshotWithPass
          (windowPass [plainView [], plainView [UiLayer [plainInstance {instanceClip = 1}]], plainView [UiLayer [plainInstance {instanceClip = 1}]]])
      )
      `shouldBe` [Refusal (AtInstance 0 1 0 0) ClipIndexNotZero, Refusal (AtInstance 0 2 0 0) ClipIndexNotZero]

  it "reports a refused instance in a layer other than the first" $
    refusalsOf
      ( snapshotWithView
          (plainView [UiLayer [], WorldLayer DepthEnabled [plainInstance {instanceUv = UvRect nan nan nan nan}]])
      )
      `shouldBe` [Refusal (AtInstance 0 0 1 0) UvNotFinite]

generatedSpec ∷ Spec
generatedSpec = describe "over generated snapshots" $ do
  prop "accepts a generated valid snapshot and leaves it unchanged" $
    forAll validSnapshotGen $ \snapshot → case validateSnapshot snapshot of
      Left refused → counterexample (show refused) False
      Right valid → property (validSnapshot valid == snapshot)

  prop "gives every layer of an accepted snapshot its location, in order" $
    forAll validSnapshotGen $ \snapshot → case validateSnapshot snapshot of
      Left refused → counterexample (show refused) False
      Right valid →
        property
          ( map validLayerLocation (validLayers valid)
              == [ AtLayer passIndex viewIndex layerIndex
                 | (passIndex, pass) ← zip [0 ..] (snapshotPasses snapshot)
                 , (viewIndex, view) ← zip [0 ..] (passViews pass)
                 , (layerIndex, _) ← zip [0 ..] (viewLayers view)
                 ]
          )

  prop "refuses exactly the one instance fault injected into a generated valid snapshot" $
    forAll validSnapshotGen $ \snapshot → forAll (injection snapshot) $ \injected → case injected of
      Nothing → property True
      Just (corrupted, location, reason) →
        counterexample (show corrupted) (refusalsOf corrupted == [Refusal location reason])

  prop "answers every wild candidate, the same way twice, accepting only what it holds unchanged" $
    forAll wildSnapshot $ \snapshot →
      let first = validateSnapshot snapshot
          second = validateSnapshot snapshot
       in property (first == second)
            .&&. case first of
              Left refused → property (not (null (toList refused)))
              Right valid → property (validSnapshot valid == snapshot)

-- | A snapshot of wild values in the places validation inspects.
wildSnapshot ∷ Gen Snapshot
wildSnapshot = do
  passes ← mapM (const wildPass) [1 .. (3 ∷ Int)]
  pure (Snapshot passes)
  where
    wildPass = do
      target ← elements [WindowTarget, offscreen 0]
      clear ← ClearColour <$> wildFloat <*> wildFloat <*> wildFloat <*> wildFloat
      views ← mapM (const wildView) [1 .. (2 ∷ Int)]
      pure (Pass target clear views)
    wildView = do
      camera ← Camera <$> (V2 <$> wildFloat <*> wildFloat) <*> wildFloat <*> oneof [pure Nothing, Just <$> wildFloat]
      viewport ← Viewport <$> (V2 <$> wildFloat <*> wildFloat) <*> (V2 <$> wildFloat <*> wildFloat)
      settings ← ViewSettings <$> wildFloat <*> pure False <*> pure FilterNearest <*> wildFloat <*> oneof [pure PixelsPerUnit, FixedHalfHeight <$> wildFloat]
      layers ← mapM (const wildLayer) [1 .. (2 ∷ Int)]
      pure (View camera viewport settings layers)
    wildLayer = do
      instances ← mapM (const wildInstance) [1 .. (2 ∷ Int)]
      oneof [pure (UiLayer instances), pure (WorldLayer DepthEnabled instances)]
    wildInstance = do
      transform ← fromColumns <$> wildV2 <*> wildV2 <*> wildV2
      rectangle ← UvRect <$> wildFloat <*> wildFloat <*> wildFloat <*> wildFloat
      key ← oneof [choose (0, 16777215), choose (16777216, maxBound)]
      clip ← oneof [pure 0, choose (1, maxBound)]
      pure plainInstance {instanceTransform = transform, instanceUv = rectangle, instanceDepthKey = key, instanceClip = clip}
    wildV2 = V2 <$> wildFloat <*> wildFloat

-- | Corrupt one instance of the snapshot, if it has any, and say which refusal
-- the corruption must give and where.
injection ∷ Snapshot → Gen (Maybe (Snapshot, Location, Reason))
injection snapshot = case instanceLocations of
  [] → pure Nothing
  places → do
    (passIndex, viewIndex, layerIndex, index) ← elements places
    (corrupt, reason) ← elements corruptions
    let location = AtInstance passIndex viewIndex layerIndex index
    pure (Just (replaceInstance (passIndex, viewIndex, layerIndex, index) corrupt snapshot, location, reason))
  where
    instanceLocations =
      [ (passIndex, viewIndex, layerIndex, index)
      | (passIndex, pass) ← zip [0 ..] (snapshotPasses snapshot)
      , (viewIndex, view) ← zip [0 ..] (passViews pass)
      , (layerIndex, layer) ← zip [0 ..] (viewLayers view)
      , (index, _) ← zip [0 ..] (layerInstances layer)
      ]
    corruptions =
      [ (\i → i {instanceDepthKey = depthKeyLimit}, DepthKeyTooLarge)
      , (\i → i {instanceDepthKey = maxBound}, DepthKeyTooLarge)
      , (\i → i {instanceClip = 1}, ClipIndexNotZero)
      , (\i → i {instanceUv = UvRect nan 0 0 0}, UvNotFinite)
      , (\i → i {instanceTransform = fromColumns (V2 0 0) (V2 0 0) (V2 inf 0)}, TransformNotFinite)
      ]

replaceInstance ∷ (Int, Int, Int, Int) → (Instance → Instance) → Snapshot → Snapshot
replaceInstance (passAt, viewAt, layerAt, instanceAt) change (Snapshot passes) =
  Snapshot (at passAt (\pass → pass {passViews = at viewAt (\view → view {viewLayers = at layerAt layerChange (viewLayers view)}) (passViews pass)}) passes)
  where
    layerChange (WorldLayerWith depth chunks instances) = WorldLayerWith depth chunks (at instanceAt change instances)
    layerChange (UiLayerWith chunks instances) = UiLayerWith chunks (at instanceAt change instances)
    at n f items = [if i == n then f item else item | (i, item) ← zip [0 ..] items]
