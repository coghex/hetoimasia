-- | The terrain evidence's independent judge and its record writer (TRA-8): every
-- pixel of a readback compared with what a viewer of the scene must see, worked
-- out by "Hetoimasia.Terrain.Render2D.Evidence" from half-spaces and lines of
-- sight, without the planner, its faces, its depth keys, its picking, the
-- material's model or the render-2d oracle.
--
-- The expectation is never derived from the observed image and nothing here
-- updates a golden image: a pixel is compared with the art's texel (through the
-- face's diagnostic tint, if the look tints) by the sRGB transfer function
-- written out below, within a tolerance declared here, before any pixel is read.
-- A pixel the expectation cannot decide (a line of sight along an edge, within
-- a hundredth of a pixel of one, or within a sixteenth of a texel's boundary) is
-- counted and listed as ambiguous, never compared and never passed.
--
-- State, ownership and lifetime: none; every function is pure.
module Test.GPU.Vulkan.Native.TerrainJudge
  ( Look (..)
  , lookTolerance
  , tintOf
  , Independent (..)
  , judgeIndependent
  , expectedByte
  , expectedRgba
  , Json (..)
  , renderJson
  ) where

import Data.List (intercalate)
import Data.Word (Word8)
import Numeric (showHex)
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Terrain.Render2D.Agreement (surfaceTint)
import Hetoimasia.Terrain.Render2D.Evidence

-- | How a fixture is drawn: the approved art alone, or with the technical
-- diagnostic tint of each face's plane (not artwork), which makes every face of
-- every shape visibly its own colour.
data Look = Plain | Tinted
  deriving stock (Eq, Show)

-- | The tolerance, in 8-bit steps per channel, a pixel is compared within,
-- declared before any pixel is read: the sRGB round trip of a texture sample
-- (decode on sampling, encode on writing) and, for a tinted look, one rounding of
-- the product in linear light.
lookTolerance ∷ Look → Int
lookTolerance = \case
  Plain → 2
  Tinted → 3

-- | The tint a hit is drawn with under a look.
tintOf ∷ Look → Char → (Word8, Word8, Word8)
tintOf Plain _ = (255, 255, 255)
tintOf Tinted surface = surfaceTint surface

-- | An 8-bit channel of an sRGB texel through a tint, as the target holds it:
-- decoded to linear light, multiplied by the tint and encoded again, by the
-- transfer function of IEC 61966-2-1.
expectedByte ∷ Word8 → Word8 → Word8
expectedByte texel tint = round (max 0 (min 255 (255 * encode (decode (fromIntegral texel / 255) * (fromIntegral tint / 255)))))
  where
    decode ∷ Double → Double
    decode c
      | c <= 0.04045 = c / 12.92
      | otherwise = ((c + 0.055) / 1.055) ** 2.4
    encode ∷ Double → Double
    encode l
      | l <= 0.0031308 = 12.92 * l
      | otherwise = 1.055 * l ** (1 / 2.4) - 0.055

-- | The colour the independent expectation gives a pixel under a look, or
-- 'Nothing' where it cannot decide.
expectedRgba ∷ Look → Expected → Maybe (Word8, Word8, Word8, Word8)
expectedRgba look = \case
  ExpectedClear → Just (0, 0, 0, 255)
  Ambiguous _ → Nothing
  ExpectedHit {expectedShown = Nothing} → Just (0, 0, 0, 255)
  ExpectedHit {expectedShown = Just (hit, (r, g, b, _))} →
    let (tr, tg, tb) = tintOf look (hitSurface hit)
     in Just (expectedByte r tr, expectedByte g tg, expectedByte b tb, 255)

-- | What judging every pixel against the independent expectation found.
data Independent = Independent
  { indCompared ∷ !Int
  , indAmbiguous ∷ !Int
  , indCovered ∷ !Int
  -- ^ Compared pixels a solid covers.
  , indReveals ∷ !Int
  -- ^ Of those, the pixels at which a solid behind the frontmost one is what is seen.
  , indMismatchCount ∷ !Int
  , indMismatches ∷ ![String]
  -- ^ The first few, each naming the pixel, what was expected and what was read.
  }

-- | Judge every pixel of a target against the independent expectation. The clear
-- colour of the passes here is opaque black.
judgeIndependent
  ∷ Look
  → (Int, Int)
  → ((Int, Int) → Expected)
  → (Int → Int → Maybe Rgba8)
  → Independent
judgeIndependent look (w, h) expectedAtPixel observed =
  foldr tally (Independent 0 0 0 0 0 []) [one (x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
  where
    tolerance = lookTolerance look
    tally verdict (Independent compared ambiguous covered reveals count shown) = case verdict of
      Left () → Independent compared (ambiguous + 1) covered reveals count shown
      Right (problem, isCovered, isReveal) →
        Independent
          (compared + 1)
          ambiguous
          (covered + fromEnum isCovered)
          (reveals + fromEnum isReveal)
          (count + length problem)
          (take 12 (problem <> shown))
    one pixel = case expectedAtPixel pixel of
      Ambiguous _ → Left ()
      ExpectedClear → Right (compareTo pixel (0, 0, 0, 255) "clear", False, False)
      ExpectedHit {expectedFront = front, expectedShown = shown} → case shown of
        Nothing → Right (compareTo pixel (0, 0, 0, 255) "clear (every texel on the line is transparent)", True, False)
        Just (hit, (r, g, b, _)) →
          let (tr, tg, tb) = tintOf look (hitSurface hit)
              expectedColour = (expectedByte r tr, expectedByte g tg, expectedByte b tb, 255)
           in Right (compareTo pixel expectedColour ("the texel of " <> show (hitCell hit) <> " " <> show (hitKind hit)), True, hitCell hit /= hitCell front || hitKind hit /= hitKind front)
    compareTo (x, y) (er, eg, eb, ea) what = case observed x y of
      Nothing → ["pixel " <> show (x, y) <> " was not read"]
      Just (Rgba8 r g b a)
        | all (\(e, o) → abs (fromIntegral e - fromIntegral o) <= tolerance) [(er, r), (eg, g), (eb, b), (ea, a)] → []
        | otherwise → ["pixel " <> show (x, y) <> ": expected " <> show (er, eg, eb, ea) <> " (" <> what <> "), read " <> show (r, g, b, a)]

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
