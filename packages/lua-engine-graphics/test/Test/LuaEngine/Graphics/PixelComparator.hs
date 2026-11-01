{-# LANGUAGE OverloadedStrings #-}

-- | The device-free half of the `Lua offscreen pixels` subgroup (LFE-24): the committed technical fixtures, the
-- hand-stated expectations, and the comparator that judges a readback against them. No device, display or GLFW
-- session is created; the readbacks here are synthetic and say so.
--
-- It shows three things the real-device cases then rely on:
--
-- * The committed PNG files are the fixtures the suites state: their SHA-256 are the listed ones, and the production
--   decoder reads them back to exactly the texel tables stated here (premultiplied as a colour image is).
-- * The hand-stated expectations are consistent with the render-2d oracle over the same specification: the numbers
--   worked out by hand are numbers the oracle independently expects (or, where it declines to determine a pixel, are
--   not required of it and are said so).
-- * The comparator rejects what it must: a channel beyond tolerance, a short readback, an image with no determinate
--   pixel, and the representative defects (a flipped Y or X, a reversed list order, linear sampling, straight rather
--   than premultiplied alpha, a byte 128 taken as linear light), each as a readback a defective renderer or translator
--   would have produced.
module Test.LuaEngine.Graphics.PixelComparator (spec) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (FromMemory))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (ColourImage))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Oracle
  ( Expectation (..)
  , Oracle
  , Probe (..)
  , expect
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..), Pass (..), Snapshot (..), Target (..))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validSnapshot, validateSnapshot)
import Test.Hspec
import Test.LuaEngine.Graphics.Pixels

spec ∷ Spec
spec = describe "Lua offscreen pixels comparator" $ do
  fixtureSpec
  agreementSpec
  comparatorSpec
  retargetSpec

-- The committed files ---------------------------------------------------------------------------------------------------

fixtureSpec ∷ Spec
fixtureSpec = describe "the committed technical fixtures" $ do
  it "are the files this suite states: each one's SHA-256 is the listed one, and the production decoder reads exactly the stated texel table" $
    mapM_ checkCommitted committedFixtures
  it "include the shipped lua-quad texture, whose SHA-256 is the generator's published one and whose decoded texels are the stated table" $ do
    path ← findUpwards "samples/lua-quad/content/images/quad.png"
    bytes ← ByteString.readFile path
    sha256Text bytes `shouldBe` fixtureSha256 quadFixture
    decoded bytes >>= (`shouldBe` fixtureDecoded quadFixture)
  it "have the sizes the cases rely on, and only the grid is opaque everywhere with twelve distinct colours" $ do
    [(fixtureWidth f, fixtureHeight f) | f ← committedFixtures] `shouldBe` [(4, 3), (2, 2), (2, 2), (2, 2), (2, 2)]
    let texels = [fixtureTexel gridFixture x y | y ← [0 .. 2], x ← [0 .. 3]]
    length (Map.fromList [(t, ()) | t ← texels]) `shouldBe` 12
    all (\(_, _, _, a) → a == 255) texels `shouldBe` True
    decodedBinaryAlpha (fixtureDecoded redFixture) `shouldBe` False
    decodedBinaryAlpha (fixtureDecoded blueFixture) `shouldBe` False
    decodedBinaryAlpha (fixtureDecoded gridFixture) `shouldBe` True
  where
    checkCommitted fixture = do
      path ← findUpwards ("packages/lua-engine-graphics/test-common/fixtures/pixels/" <> drop (length ("images/" ∷ String)) (fixtureFile fixture))
      bytes ← ByteString.readFile path
      sha256Text bytes `shouldBe` fixtureSha256 fixture
      decoded bytes >>= (`shouldBe` fixtureDecoded fixture)
    decoded bytes = case decodePng ColourImage (Asset (AssetId "fixture") (FromMemory "a committed technical fixture")) bytes of
      Left refusal → expectationFailure ("the decoder refused a committed fixture: " <> show refusal) >> pure (fixtureDecoded gridFixture)
      Right image → pure image {decodedLevels = take 1 (decodedLevels image)}

-- The hand-stated numbers against the oracle ------------------------------------------------------------------------------

-- | Every specification the cases state, in the order the cases run.
allSpecs ∷ [CaseSpec]
allSpecs =
  [ initialSpec
  , gridSpec
  , orderedSpec
  , orderedReversedSpec
  , greyClearSpec
  , greySpriteSpec
  , placementSpec
  , gridAtScale 2 (128, 96) (64, 48) "grid at scale 2"
  , gridAtScale 1 (80, 60) (80, 60) "grid on a larger target"
  , gridAtScale 1 (40, 30) (40, 30) "grid on a smaller target"
  , emptySpec
  , copyBeforeSpec
  , copyAfterSpec
  , refusalSpec
  , quadSpec
  ]

oracleOf ∷ CaseSpec → Oracle
oracleOf spec' = case validateSnapshot (specSnapshot spec') of
  Left refused → error ("the specification's own snapshot was refused: " <> show refused)
  Right valid → specOracle spec' (specMetrics spec') valid (fmap fixtureDecoded . specTextures spec') (marksOf spec')

-- | The cutout marks the registry's default would give: a texture whose alpha is binary is a cutout.
marksOf ∷ CaseSpec → CutoutMarks
marksOf _ = noCutoutMarks

agreementSpec ∷ Spec
agreementSpec = describe "the hand-stated expectations" $ do
  mapM_ one allSpecs
  it "state at least one position per case, with no duplicate position inside a case" $
    mapM_ (\s → (length (specNamed s) > 0, length (positions s) == length (Map.fromList [(p, ()) | p ← positions s])) `shouldBe` (True, True)) allSpecs
  where
    positions s = [(namedX n, namedY n) | n ← specNamed s]
    one s = it ("agree with the oracle over the same specification: " <> Text.unpack (specLabel s)) $
      agreesWith (oracleOf s) (specNamed s) `shouldBe` []

-- The comparator ----------------------------------------------------------------------------------------------------------

-- | The readback a correct renderer would have produced: the oracle's own value where it determines one.
perfect ∷ CaseSpec → Readback
perfect s = Readback w h (ByteString.pack (concat [pixel x y | y ← [0 .. h - 1], x ← [0 .. w - 1]]))
  where
    (w, h) = specFramebuffer s
    oracle = oracleOf s
    pixel x y = case expect oracle (Probe 0 x y) of
      Expected (Rgba8 r g b a) _ → [r, g, b, a]
      _ → [255, 0, 255, 255]

flipY, flipX ∷ Readback → Readback
flipY (Readback w h bytes) = Readback w h (ByteString.concat (reverse [ByteString.take (w * 4) (ByteString.drop (y * w * 4) bytes) | y ← [0 .. h - 1]]))
flipX (Readback w h bytes) = Readback w h (ByteString.concat [ByteString.concat (reverse [ByteString.take 4 (ByteString.drop ((y * w + x) * 4) bytes) | x ← [0 .. w - 1]]) | y ← [0 .. h - 1]])

-- | Add this many to a channel of one pixel.
nudged ∷ Int → Int → Int → Int → Readback → Readback
nudged x y channel by (Readback w h bytes) = Readback w h (ByteString.pack (zipWith bump [0 ..] (ByteString.unpack bytes)))
  where
    target = (y * w + x) * 4 + channel
    bump i value = if i == target then fromIntegral (fromIntegral value + by ∷ Int) else value

judged ∷ CaseSpec → Readback → Judgement
judged s = judgeWhole (oracleOf s)

comparatorSpec ∷ Spec
comparatorSpec = describe "the comparator" $ do
  it "accepts the readback a correct renderer produces: every determinate pixel matches, none is unevaluable, and the named positions all hold" $
    mapM_
      ( \s → do
          let readback = perfect s
              verdict = judged s readback
          judgedFailed verdict `shouldBe` []
          judgedUnevaluable verdict `shouldBe` []
          judgedDeterminate verdict `shouldSatisfy` (> 0)
          judgementOk verdict `shouldBe` True
          checkNamed readback (specNamed s) `shouldBe` []
      )
      allSpecs
  it "reports the pixels the oracle declines to determine, by reason, and counts them for no success" $ do
    let verdict = judged gridSpec (perfect gridSpec)
    judgedDeterminate verdict + sum (map snd (judgedIndeterminate verdict)) `shouldBe` 64 * 48
  it "rejects a channel beyond the oracle's tolerance, in any of the four channels, and accepts one within it" $ do
    let base = perfect gridSpec
        -- (20, 20, 40, 255) is the clear colour: the pixel (0, 0) is determinate and exact
        within' = nudged 0 0 0 1 base
        beyond channel = nudged 0 0 channel 2 base
    judgementOk (judged gridSpec within') `shouldBe` True
    mapM_ (\channel → judgementOk (judged gridSpec (beyond channel)) `shouldBe` False) [0, 1, 2]
    judgementOk (judged gridSpec (nudged 0 0 3 (-2) base)) `shouldBe` False
    (map mismatchName (checkNamed (beyond 0) [Named "clear" 0 0 (20, 20, 40, 255) 1])) `shouldBe` ["clear"]
  it "rejects a readback of the wrong size, and an image the oracle determines nothing of" $ do
    let Readback w h bytes = perfect gridSpec
    judgementOk (judged gridSpec (Readback w h (ByteString.take 100 bytes))) `shouldBe` False
    judgementOk (judged gridSpec (Readback (w + 1) h bytes)) `shouldBe` False
    judgementOk (Judgement 0 [] [("NearQuadEdge", 3)] []) `shouldBe` False
    judgementOk (Judgement 5 [] [] ["a probe"]) `shouldBe` False
    checkNamed (Readback 2 2 (ByteString.replicate 16 0)) [Named "outside" 5 5 (0, 0, 0, 0) 0] `shouldSatisfy` (not . null)
  it "rejects a Y flip, an X flip and a rotation of the grid, in the whole image and at the named positions" $ do
    let readback = perfect gridSpec
    mapM_
      ( \defective → do
          judgementOk (judged gridSpec defective) `shouldBe` False
          checkNamed defective (specNamed gridSpec) `shouldSatisfy` (not . null)
      )
      [flipY readback, flipX readback, flipY (flipX readback)]
  it "rejects the other list order: the reversed overlap is not the overlap, in the whole image and at the named positions" $ do
    let reversedReadback = perfect orderedReversedSpec
    judgementOk (judged orderedSpec reversedReadback) `shouldBe` False
    checkNamed reversedReadback (specNamed orderedSpec) `shouldSatisfy` (not . null)
    judgementOk (judged orderedReversedSpec (perfect orderedSpec)) `shouldBe` False
    checkNamed (perfect orderedSpec) (specNamed orderedReversedSpec) `shouldSatisfy` (not . null)
  it "rejects linear sampling: a nearest-filtered grid has no colour between two neighbouring texels' own at a boundary" $ do
    let linear = interpolated gridSpec (perfect gridSpec)
    judgementOk (judged gridSpec linear) `shouldBe` False
    checkNamed linear (specNamed gridSpec) `shouldSatisfy` (not . null)
  it "rejects a straight-alpha blend: the same sprites blended without premultiplying read differently" $ do
    let straight = straightAlphaOrdered
    judgementOk (judged orderedSpec straight) `shouldBe` False
    checkNamed straight (specNamed orderedSpec) `shouldSatisfy` (not . null)
  it "rejects a byte 128 taken as linear light, for a clear and for a texel" $ do
    let wrongClear = filled greyClearSpec (188, 188, 188, 255)
    judgementOk (judged greyClearSpec wrongClear) `shouldBe` False
    checkNamed wrongClear (specNamed greyClearSpec) `shouldSatisfy` (not . null)
    let wrongTexel = recolour greySpriteSpec (128, 128, 128, 255) (188, 188, 188, 255)
    judgementOk (judged greySpriteSpec wrongTexel) `shouldBe` False
    checkNamed wrongTexel (specNamed greySpriteSpec) `shouldSatisfy` (not . null)
  it "rejects a transparent output: an opaque clear that reads back with alpha below 255" $ do
    let transparent = filled emptySpec (40, 80, 120, 200)
    judgementOk (judged emptySpec transparent) `shouldBe` False
    checkNamed transparent (specNamed emptySpec) `shouldSatisfy` (not . null)
  it "rejects a placement that was snapped, clipped by recentring or stretched, at the named positions" $ do
    let snappedDown = recolourAt placementSpec 24 7 (210, 40, 170, 255)
    checkNamed snappedDown (specNamed placementSpec) `shouldSatisfy` (not . null)
    let recentred = flipY (perfect placementSpec)
    checkNamed recentred (specNamed placementSpec) `shouldSatisfy` (not . null)

filled ∷ CaseSpec → Texel → Readback
filled s (r, g, b, a) =
  let (w, h) = specFramebuffer s
   in Readback w h (ByteString.concat (replicate (w * h) (ByteString.pack [r, g, b, a])))

recolour ∷ CaseSpec → Texel → Texel → Readback
recolour s from to =
  let Readback w h bytes = perfect s
      pixels = [ByteString.take 4 (ByteString.drop (4 * i) bytes) | i ← [0 .. w * h - 1]]
      pack (r, g, b, a) = ByteString.pack [r, g, b, a]
   in Readback w h (ByteString.concat [if p == pack from then pack to else p | p ← pixels])

recolourAt ∷ CaseSpec → Int → Int → Texel → Readback
recolourAt s x y (r, g, b, a) =
  let Readback w h bytes = perfect s
      at = (y * w + x) * 4
   in Readback w h (ByteString.take at bytes <> ByteString.pack [r, g, b, a] <> ByteString.drop (at + 4) bytes)

-- | The readback a bilinear sampler would produce for the grid scene: each pixel the mean of the correct pixel and its
-- left and right neighbours inside the image. It differs from the nearest readback only beside a texel boundary.
interpolated ∷ CaseSpec → Readback → Readback
interpolated _ (Readback w h bytes) = Readback w h (ByteString.pack (concat [blend x y | y ← [0 .. h - 1], x ← [0 .. w - 1]]))
  where
    pixel x y = [fromIntegral (ByteString.index bytes ((y * w + max 0 (min (w - 1) x)) * 4 + c)) ∷ Int | c ← [0 .. 3]]
    blend x y = [fromIntegral (sum (map (!! c) [pixel (x - 4) y, pixel x y, pixel x y, pixel (x + 4) y]) `div` 4) | c ← [0 .. 3]]

-- | The ordered scene blended as a straight-alpha renderer would: the sprites' colour channels not premultiplied, so a
-- single layer over black reads 255 x 0.7529 in light but 255 as a colour before blending. The values are those a
-- renderer that took the premultiplied path with straight texels draws: the sprite colour at full strength.
straightAlphaOrdered ∷ Readback
straightAlphaOrdered =
  let Readback w h bytes = perfect orderedSpec
      pixels = [ByteString.take 4 (ByteString.drop (4 * i) bytes) | i ← [0 .. w * h - 1]]
      full p
        | p == ByteString.pack [225, 0, 0, 255] = ByteString.pack [255, 0, 0, 255]
        | p == ByteString.pack [0, 0, 225, 255] = ByteString.pack [0, 0, 255, 255]
        | p == ByteString.pack [119, 0, 225, 255] = ByteString.pack [64, 0, 255, 255]
        | otherwise = p
   in Readback w h (ByteString.concat (map full pixels))

-- The target substitution -------------------------------------------------------------------------------------------------

retargetSpec ∷ Spec
retargetSpec = describe "the retargeted copy of a published scene" $ do
  it "differs from the published window pass in its target alone: read back through validSnapshot, every other value is equal" $ do
    let published = specSnapshot gridSpec
        reference = targetRef 7 1
        copy = retargeted reference published
    snapshotPasses published `shouldSatisfy` all ((== WindowTarget) . passTarget)
    snapshotPasses copy `shouldSatisfy` all ((== OffscreenTarget reference) . passTarget)
    sameExceptTarget published copy `shouldBe` True
    validated copy >>= \valid → do
      sameExceptTarget published (validSnapshot valid) `shouldBe` True
      map passTarget (snapshotPasses (validSnapshot valid)) `shouldBe` [OffscreenTarget reference]
  it "is not accepted when the copy changed anything else: a clear colour, a view or a pass count" $ do
    let published = specSnapshot gridSpec
        copy = retargeted (targetRef 7 1) published
        changedClear = Snapshot [p {passClear = ClearColour 0.5 0.5 0.5 1} | p ← snapshotPasses copy]
        changedViews = Snapshot [p {passViews = []} | p ← snapshotPasses copy]
    sameExceptTarget published changedClear `shouldBe` False
    sameExceptTarget published changedViews `shouldBe` False
    sameExceptTarget published (Snapshot (snapshotPasses copy <> snapshotPasses copy)) `shouldBe` False
  it "reports a translation that is not the specification's, ignoring only which texture each sprite names" $ do
    let wanted = specSnapshot orderedSpec
        reversed = specSnapshot orderedReversedSpec
    translationDiffs wanted wanted `shouldBe` []
    translationDiffs reversed wanted `shouldSatisfy` (not . null)
    translationDiffs (specSnapshot gridSpec) wanted `shouldSatisfy` (not . null)
  where
    validated copy = case validateSnapshot copy of
      Left refused → expectationFailure ("the copy was refused: " <> show refused) >> error "unreachable"
      Right valid → pure valid
