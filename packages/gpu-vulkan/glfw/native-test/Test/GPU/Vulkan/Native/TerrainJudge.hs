-- | The terrain evidence's independent judge and its record writer (TRA-17): every pixel of a
-- readback compared with what a viewer of the scene must see, worked out by
-- "Hetoimasia.Terrain.Render2D.Evidence" from hand-stated geometry, the independently decoded
-- source images and the specified lighting and depth equations, without the planner, its keys, the
-- picker, the atlas adaptation, the material's model or the render-2d oracle.
--
-- The expectation is never derived from the observed image and nothing here updates a golden
-- image: a pixel is compared with the hand-computed linear colour encoded to 8-bit sRGB by the
-- transfer function of IEC 61966-2-1, within a tolerance declared here before any pixel is read. A
-- pixel the expectation cannot decide (within a sixteenth of a texel boundary) is counted and
-- listed as ambiguous, never compared and never passed.
--
-- State, ownership and lifetime: none; every function is pure.
module Test.GPU.Vulkan.Native.TerrainJudge
  ( tolerance
  , Independent (..)
  , judgeIndependent
  , splitPasses
  , observedFrom
  , completeReadback
  , expectedRgba
  , Json (..)
  , renderJson
  ) where

import Data.Array (Array, bounds, listArray, (!))
import Data.List (intercalate)
import Data.Word (Word8)
import Numeric (showHex)
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Test.GPU.Vulkan.Native.OrderedPath (ProbeResult (..))
import Hetoimasia.Terrain.Render2D.Evidence

-- | The tolerance, in 8-bit steps per channel, a pixel is compared within, declared before any
-- pixel is read: the sRGB round trip of a texture sample (decode on sampling, encode on writing),
-- one rounding of the lit, darkened and hazed product in linear light, and the 32-bit evaluation of
-- the shader's arithmetic against the expectation's 64-bit.
tolerance ∷ Int
tolerance = 3

-- | The colour the independent expectation gives a pixel, or 'Nothing' where it cannot decide.
expectedRgba ∷ Expected → Maybe (Word8, Word8, Word8, Word8)
expectedRgba = \case
  ExpectedClear → Just (0, 0, 0, 255)
  Ambiguous _ → Nothing
  ExpectedHit {expectedLinear = linear} → let (r, g, b) = shadedByte linear in Just (r, g, b, 255)

-- | What judging every pixel against the independent expectation found.
data Independent = Independent
  { indCompared ∷ !Int
  , indAmbiguous ∷ !Int
  , indCovered ∷ !Int
  -- ^ Compared pixels a quad covers.
  , indReveals ∷ !Int
  -- ^ Of those, the pixels at which a nearer quad's transparent texel shows what lies behind.
  , indOverlaps ∷ !Int
  -- ^ Of those, the pixels at which the front hides another opaque texel behind it.
  , indMismatchCount ∷ !Int
  , indMismatches ∷ ![String]
  -- ^ The first few, each naming the pixel, what was expected and what was read.
  }

-- | Judge every pixel of a target against the independent expectation. The clear colour of the
-- passes here is opaque black.
judgeIndependent ∷ (Int, Int) → ((Int, Int) → Expected) → (Int → Int → Maybe Rgba8) → Independent
judgeIndependent (w, h) expectedAtPixel observed =
  foldr tally (Independent 0 0 0 0 0 0 []) [one (x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
  where
    tally verdict (Independent compared ambiguous covered reveals overlaps count shown) = case verdict of
      Left () → Independent compared (ambiguous + 1) covered reveals overlaps count shown
      Right (problem, isCovered, isReveal, isOverlap) →
        Independent
          (compared + 1)
          ambiguous
          (covered + fromEnum isCovered)
          (reveals + fromEnum isReveal)
          (overlaps + fromEnum isOverlap)
          (count + length problem)
          (take 12 (problem <> shown))
    one pixel = case expectedAtPixel pixel of
      Ambiguous _ → Left ()
      ExpectedClear → Right (compareTo pixel (0, 0, 0, 255) "clear", False, False, False)
      hit@ExpectedHit {expectedFront = front, expectedSkipped = skipped, expectedBehind = behind} → case expectedRgba hit of
        Nothing → Left ()
        Just colour → Right (compareTo pixel colour ("the texel of " <> show (hqCell front) <> " " <> show (hqRole front)), True, not (null skipped), not (null behind))
    compareTo (x, y) (er, eg, eb, ea) what = case observed x y of
      Nothing → ["pixel " <> show (x, y) <> " was not read"]
      Just (Rgba8 r g b a)
        | all (\(e, o) → abs (fromIntegral e - fromIntegral o) <= tolerance) [(er, r), (eg, g), (eb, b), (ea, a)] → []
        | otherwise → ["pixel " <> show (x, y) <> ": expected " <> show (er, eg, eb, ea) <> " (" <> what <> "), read " <> show (r, g, b, a)]

-- | The oracle's probes of a fixture, which run pass by pass and row by row, split by pass.
splitPasses ∷ [(Int, Int)] → [ProbeResult] → [[ProbeResult]]
splitPasses extents probes = case extents of
  [] → []
  (w, h) : rest →
    let (these, others) = splitAt (w * h) probes
     in these : splitPasses rest others

-- | The readback's pixel at (x, y) of a target @width@ wide, from the oracle's probes of its pass,
-- which run row by row; 'Nothing' for a pixel the probes do not hold (a readback that failed
-- leaves none), never an exception.
observedFrom ∷ Int → [ProbeResult] → Int → Int → Maybe Rgba8
observedFrom width probes = \x y →
  let index = y * width + x
   in if x < 0 || y < 0 || x >= width || index > snd (bounds table) then Nothing else table ! index
  where
    table = listArray (0, length probes - 1) (map probeObserved probes) ∷ Array Int (Maybe Rgba8)

-- | Whether the probes hold every pixel of every target: a render, completion or readback that
-- failed returns a result with too few, and nothing is judged then.
completeReadback ∷ [(Int, Int)] → [ProbeResult] → Bool
completeReadback extents probes = length probes == sum [w * h | (w, h) ← extents]

-- ---------------------------------------------------------------------------
-- A small JSON writer for the fixture record

data Json
  = JNull
  | JBool !Bool
  | JNumber !String
  | JString !String
  | JArray ![Json]
  | JObject ![(String, Json)]

renderJson ∷ Json → String
renderJson = \case
  JNull → "null"
  JBool value → if value then "true" else "false"
  JNumber value → value
  JString value → "\"" <> concatMap escape value <> "\""
  JArray items → "[" <> intercalate ", " (map renderJson items) <> "]"
  JObject fields → "{" <> intercalate ", " [renderJson (JString key) <> ": " <> renderJson value | (key, value) ← fields] <> "}"
  where
    escape = \case
      '"' → "\\\""
      '\\' → "\\\\"
      '\n' → "\\n"
      '\r' → "\\r"
      '\t' → "\\t"
      c
        | c < ' ' → let digits = showHex (fromEnum c) "" in "\\u" <> replicate (4 - length digits) '0' <> digits
        | otherwise → [c]
