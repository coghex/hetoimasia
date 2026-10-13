-- | Clip tables (R2D-12): the resolver, its determinism and its totality, and how
-- a clip index meets the draw plan and the encoder.
--
-- __What is under test.__ 'resolveClips' intersects each entry with its parent
-- chain. The examples state the expected rectangles in the test itself: a
-- single entry, a nested pair, a chain three deep, an empty intersection, edges
-- that only touch, a zero extent, descendants of an empty entry, a chain that
-- shortens a rectangle, finite coordinates whose sum overflows a float, and
-- inputs validation would refuse. The generated examples check an independent
-- characterisation of the resolver (a point is inside a resolved entry exactly
-- when it is inside every rectangle of its chain) on a grid of values every
-- float holds exactly, rather than rerunning the resolver's own arithmetic.
--
-- __Plan and encoding.__ A clip index never splits a run or moves an instance:
-- the plan of instances with clip indices equals the plan of the same
-- instances with none, and the plan carries the view's resolved table. An
-- accepted clip index reaches the encoded flags word unchanged.
module Test.Render.TwoD.Clip (spec) where

import qualified Data.ByteString as ByteString
import Data.Word (Word16)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Clip
import Hetoimasia.Render.TwoD.DrawPlan
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, instanceStride)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (validLayers, validateSnapshot)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, conjoin, counterexample, forAll, oneof, (===))
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Clip tables" $ do
  resolveSpec
  totalSpec
  generatedSpec
  planSpec
  encodingSpec

-- | An entry at this origin with this extent and parent.
entry ∷ (Float, Float) → (Float, Float) → Maybe Int → ClipEntry
entry (x, y) (width, height) = ClipEntry (ClipRect (V2 x y) (V2 width height))

resolveSpec ∷ Spec
resolveSpec = describe "resolving" $ do
  it "resolves a table of no entries to none" $
    resolveClips [] `shouldBe` []

  it "resolves an entry with no parent to its own rectangle" $
    resolveClips [entry (10, 20) (30, 40) Nothing] `shouldBe` [ResolvedClip 10 20 40 60]

  it "intersects a nested pair, in table order" $
    resolveClips
      [ entry (0, 0) (100, 100) Nothing
      , entry (50, 50) (100, 100) (Just 0)
      ]
      `shouldBe` [ResolvedClip 0 0 100 100, ResolvedClip 50 50 100 100]

  it "keeps the child's own edges where they lie inside the parent" $
    resolveClips
      [ entry (0, 0) (100, 100) Nothing
      , entry (10, 20) (30, 40) (Just 0)
      ]
      `shouldBe` [ResolvedClip 0 0 100 100, ResolvedClip 10 20 40 60]

  it "intersects a chain three deep with every ancestor" $
    resolveClips
      [ entry (0, 0) (100, 100) Nothing
      , entry (20, 0) (100, 60) (Just 0)
      , entry (0, 30) (60, 100) (Just 1)
      , entry (25, 35) (200, 200) (Just 2)
      ]
      `shouldBe` [ ResolvedClip 0 0 100 100
                 , ResolvedClip 20 0 100 60
                 , ResolvedClip 20 30 60 60
                 , ResolvedClip 25 35 60 60
                 ]

  it "lets two children of one parent each intersect it alone" $
    resolveClips
      [ entry (0, 0) (10, 10) Nothing
      , entry (5, 5) (10, 10) (Just 0)
      , entry (-5, -5) (10, 10) (Just 0)
      ]
      `shouldBe` [ResolvedClip 0 0 10 10, ResolvedClip 5 5 10 10, ResolvedClip 0 0 5 5]

  it "keeps an empty intersection as the empty rectangle" $ do
    resolveClips [entry (0, 0) (10, 10) Nothing, entry (20, 20) (5, 5) (Just 0)]
      `shouldBe` [ResolvedClip 0 0 10 10, emptyClip]
    clipIsEmpty emptyClip `shouldBe` True

  it "treats edges that only touch as an empty intersection (the right and bottom edges are outside)" $ do
    resolveClips [entry (0, 0) (10, 10) Nothing, entry (10, 0) (10, 10) (Just 0)]
      `shouldBe` [ResolvedClip 0 0 10 10, emptyClip]
    resolveClips [entry (0, 0) (10, 10) Nothing, entry (0, 10) (10, 10) (Just 0)]
      `shouldBe` [ResolvedClip 0 0 10 10, emptyClip]

  it "treats a zero width or height as empty, which clips everything" $ do
    resolveClips [entry (5, 5) (0, 10) Nothing] `shouldBe` [emptyClip]
    resolveClips [entry (5, 5) (10, 0) Nothing] `shouldBe` [emptyClip]
    resolveClips [entry (0, 0) (0, 0) Nothing] `shouldBe` [emptyClip]

  it "keeps every descendant of an empty entry empty, however its own rectangle lies" $
    resolveClips
      [ entry (0, 0) (10, 10) Nothing
      , entry (20, 20) (5, 5) (Just 0)
      , entry (-1000, -1000) (5000, 5000) (Just 1)
      , entry (0, 0) (10, 10) (Just 2)
      ]
      `shouldBe` [ResolvedClip 0 0 10 10, emptyClip, emptyClip, emptyClip]

  it "keeps a descendant of a zero-extent entry empty" $
    resolveClips [entry (3, 3) (0, 0) Nothing, entry (0, 0) (100, 100) (Just 0)]
      `shouldBe` [emptyClip, emptyClip]

  it "resolves a wide child inside a narrow parent to the parent's rectangle" $
    resolveClips [entry (2, 3) (4, 5) Nothing, entry (-100, -100) (1000, 1000) (Just 0)]
      `shouldBe` [ResolvedClip 2 3 6 8, ResolvedClip 2 3 6 8]

  it "sums an origin and an extent exactly and rounds once" $ do
    let exactSum = toRational (0.1 ∷ Float) + toRational (0.2 ∷ Float)
    resolveClips [entry (0.1, 0.1) (0.2, 0.2) Nothing]
      `shouldBe` [ResolvedClip 0.1 0.1 (fromRational exactSum) (fromRational exactSum)]

  it "clamps a right edge that overflows a float to the largest finite float, so no field is infinite" $
    resolveClips [entry (big, big) (largest, largest) Nothing]
      `shouldBe` [ResolvedClip big big largest largest]

  it "resolves a region the floats cannot tell from nothing as empty" $
    resolveClips [entry (largest, largest) (largest, largest) Nothing] `shouldBe` [emptyClip]

  it "intersects finite coordinates whose sum would overflow with a parent that keeps them finite" $
    resolveClips
      [ entry (-big, -big) (2 * big, 2 * big) Nothing
      , entry (0, 0) (largest, largest) (Just 0)
      ]
      `shouldBe` [ResolvedClip (-big) (-big) big big, ResolvedClip 0 0 big big]

  it "holds a point on the left or top edge and none on the right or bottom edge" $ do
    let clip = ResolvedClip 2 3 6 8
    map (clipContains clip . uncurry V2) [(2, 3), (5.9999995, 7.9999995), (6, 4), (4, 8), (1.9999999, 5), (4, 2.9999998)]
      `shouldBe` [True, True, False, False, False, False]
    clipContains emptyClip (V2 0 0) `shouldBe` False
  where
    big = encodeFloat 1 125 ∷ Float
    largest = 3.4028235e38 ∷ Float

totalSpec ∷ Spec
totalSpec = describe "resolving anything" $ do
  it "ignores a parent that is not an earlier entry" $
    resolveClips
      [ entry (0, 0) (10, 10) (Just 0)
      , entry (1, 1) (10, 10) (Just 5)
      , entry (2, 2) (10, 10) (Just (-1))
      , entry (3, 3) (10, 10) (Just 4)
      , entry (4, 4) (10, 10) Nothing
      ]
      `shouldBe` [ ResolvedClip 0 0 10 10
                 , ResolvedClip 1 1 11 11
                 , ResolvedClip 2 2 12 12
                 , ResolvedClip 3 3 13 13
                 , ResolvedClip 4 4 14 14
                 ]

  it "resolves a rectangle that is not finite, or has a negative extent, as empty" $
    resolveClips
      [ entry (0 / 0, 0) (1, 1) Nothing
      , entry (0, 0) (1 / 0, 1) Nothing
      , entry (0, 0) (-1, 1) Nothing
      , entry (0, 0) (1, -1) Nothing
      , entry (0, 0) (-1 / 0, 1) Nothing
      ]
      `shouldBe` replicate 5 emptyClip

  it "gives every entry a resolved rectangle with finite fields" $
    all finiteClip (resolveClips (map (\x → entry (x, x) (x, x) Nothing) [-3.4028235e38, -1, 0, 1, 3.4028235e38]))
      `shouldBe` True

  it "numbers the answer like the table" $
    length (resolveClips (replicate 7 (entry (0, 0) (1, 1) Nothing))) `shouldBe` 7

  it "selects entry k - 1 for a clip index k, and none for 0" $
    map clipEntryOfIndex [0, 1, 2, 65535] `shouldBe` [Nothing, Just 0, Just 1, Just 65534]

finiteClip ∷ ResolvedClip → Bool
finiteClip (ResolvedClip a b c d) = all (\value → not (isNaN value || isInfinite value)) [a, b, c, d]

generatedSpec ∷ Spec
generatedSpec = describe "over generated tables" $ do
  prop "resolves the same table to the same answer" $
    forAll gridTable $ \table → resolveClips table === resolveClips table

  prop "answers one finite rectangle per entry" $
    forAll gridTable $ \table →
      let resolved = resolveClips table
       in conjoin [length resolved === length table, counterexample "a resolved field was not finite" (all finiteClip resolved)]

  prop "holds a point exactly when every rectangle of its chain holds it" $
    forAll gridTable $ \table →
      forAll gridPoint $ \(px, py) →
        let resolved = resolveClips table
         in and
              [ clipContains (resolved !! index) (V2 px py) == all (inRect px py) (chainOf table index)
              | index ← [0 .. length table - 1]
              ]

  prop "never widens an entry past its parent's resolved rectangle" $
    forAll gridTable $ \table →
      let resolved = resolveClips table
       in and
            [ clipIsEmpty child || (resolvedLeft child >= resolvedLeft parent && resolvedTop child >= resolvedTop parent && resolvedRight child <= resolvedRight parent && resolvedBottom child <= resolvedBottom parent)
            | (index, ClipEntry {clipParent = Just p}) ← zip [0 ..] table
            , p >= 0 && p < index
            , let child = resolved !! index
            , let parent = resolved !! p
            ]

  prop "keeps an empty entry's descendants empty" $
    forAll gridTable $ \table →
      let resolved = resolveClips table
       in and
            [ clipIsEmpty (resolved !! index)
            | (index, ClipEntry {clipParent = Just p}) ← zip [0 ..] table
            , p >= 0 && p < index
            , clipIsEmpty (resolved !! p)
            ]

  prop "does not depend on the entries that come after it" $
    forAll gridTable $ \table →
      forAll (choose (0, length table)) $ \keep →
        take keep (resolveClips table) === resolveClips (take keep table)

-- | Whether a point is inside a rectangle of the table, exactly, half-open.
inRect ∷ Float → Float → ClipRect → Bool
inRect px py (ClipRect (V2 x y) (V2 width height)) =
  width >= 0 && height >= 0 && x' <= px' && px' < x' + w' && y' <= py' && py' < y' + h'
  where
    x' = toRational x
    y' = toRational y
    w' = toRational width
    h' = toRational height
    px' = toRational px
    py' = toRational py

-- | The rectangles of an entry's chain: its own, then each ancestor's.
chainOf ∷ [ClipEntry] → Int → [ClipRect]
chainOf table index = case table !! index of
  ClipEntry rect (Just p) | p >= 0 && p < index → rect : chainOf table p
  ClipEntry rect _ → [rect]

-- | A table of up to six entries on a grid of quarters, each with no parent or
-- an earlier entry, so every float and every sum below is exact.
gridTable ∷ Gen [ClipEntry]
gridTable = do
  count ← choose (0, 6)
  mapM one [0 .. count - 1]
  where
    one index = ClipEntry <$> (ClipRect <$> (V2 <$> quarter (-8) 8 <*> quarter (-8) 8) <*> (V2 <$> quarter 0 8 <*> quarter 0 8)) <*> parent index
    parent index
      | index == 0 = pure Nothing
      | otherwise = oneof [pure Nothing, Just <$> choose (0, index - 1)]
    quarter low high = (/ 4) . fromIntegral <$> choose (low * 4 ∷ Int, high * 4)

-- | A point on a grid of eighths covering the table's range.
gridPoint ∷ Gen (Float, Float)
gridPoint = (,) <$> eighth <*> eighth
  where
    eighth = (/ 8) . fromIntegral <$> choose (-80 ∷ Int, 160)

planSpec ∷ Spec
planSpec = describe "in the draw plan" $ do
  it "carries the view's clip table, resolved, one rectangle per entry" $ do
    let table = [entry (0, 0) (100, 100) Nothing, entry (50, 0) (100, 100) (Just 0)]
        view = View plainCamera plainViewport defaultViewSettings table [UiLayer [plainInstance {instanceClip = 2}]]
    case validateSnapshot (Snapshot [windowPass [view]]) of
      Left refused → expectationFailure (show refused)
      Right valid → case planPasses (planSnapshot noCutoutMarks valid) of
        [PlannedPass {plannedViews = [planned]}] → plannedClips planned `shouldBe` resolveClips table
        other → expectationFailure (show other)

  it "plans a view with no table with an empty resolved table" $
    case validateSnapshot (Snapshot [windowPass [plainView []]]) of
      Left refused → expectationFailure (show refused)
      Right valid → map (map plannedClips . plannedViews) (planPasses (planSnapshot noCutoutMarks valid)) `shouldBe` [[[]]]

  it "keeps instances of different clip indices in one run, in the order they would have had" $ do
    let indices = [0, 1, 2, 1, 0, 2, 3, 0]
        table = [entry (0, 0) (10, 10) Nothing, entry (1, 1) (10, 10) (Just 0), entry (2, 2) (10, 10) (Just 1)]
        instancesWith clips = [plainInstance {instanceDepthKey = key, instanceClip = clip} | (key, clip) ← zip [3, 1, 4, 1, 5, 9, 2, 6] clips]
        planOf clips layerOf = case validateSnapshot (Snapshot [windowPass [View plainCamera plainViewport defaultViewSettings table [layerOf (instancesWith clips)]]]) of
          Left refused → error (show refused)
          Right valid → case planPasses (planSnapshot noCutoutMarks valid) of
            [PlannedPass {plannedViews = [PlannedView {plannedLayers = [layer]}]}] → layer
            other → error (show other)
    mapM_
      ( \layerOf → do
          let clipped' = planOf indices layerOf
              plain = planOf (map (const 0) indices) layerOf
          drawingOrder clipped' `shouldBe` drawingOrder plain
          plannedRuns clipped' `shouldBe` plannedRuns plain
          length (plannedRuns clipped') `shouldBe` 1
      )
      [UiLayer, WorldLayer DepthDisabled, WorldLayer DepthEnabled]

encodingSpec ∷ Spec
encodingSpec = describe "in the encoded instances" $ do
  it "writes every accepted clip index unchanged into bits 16 to 31 of the flags word" $ do
    let table = [entry (0, 0) (1, 1) Nothing, entry (0, 0) (1, 1) (Just 0), entry (0, 0) (1, 1) Nothing]
        indices = [0, 1, 2, 3, 3, 0, 2, 1] ∷ [Word16]
        layer = UiLayer [plainInstance {instanceClip = clip} | clip ← indices]
        snapshot = Snapshot [windowPass [View plainCamera plainViewport defaultViewSettings table [layer]]]
    case validateSnapshot snapshot of
      Left refused → expectationFailure (show refused)
      Right valid → do
        let encoded = encodeLayer (singleLayerOf valid)
            flagsAt n = ByteString.unpack (ByteString.take 4 (ByteString.drop (n * instanceStride + 56) encoded))
            clipOf n = case flagsAt n of
              [_, _, low, high] → fromIntegral low + 256 * fromIntegral high ∷ Word16
              _ → maxBound
        map clipOf [0 .. length indices - 1] `shouldBe` indices
        ByteString.length encoded `shouldBe` length indices * instanceStride
  where
    singleLayerOf valid = case validLayers valid of
      first : _ → first
      [] → error "no layer"
