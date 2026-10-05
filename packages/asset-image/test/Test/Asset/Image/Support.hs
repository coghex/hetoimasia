-- | Helpers the asset-image component specs share: reading fixtures, naming
-- the asset a decode is for, fully evaluating a result, and the independent
-- reference for premultiplication.
module Test.Asset.Image.Support
  ( Texel
  , fixtureBytes
  , fixtureAsset
  , decodeFixture
  , decodeFully
  , texels
  , referencePremultiplied
  , shouldBeWithinOne
  )
where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word8)
import Hetoimasia.Asset (Asset (..), AssetId (..), AssetRefusal, Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind)
import Hetoimasia.Asset.Image.Png (decodePng)
import System.FilePath ((</>))
import Test.Hspec (Expectation, expectationFailure)

-- | One texel as R, G, B, A.
type Texel = (Word8, Word8, Word8, Word8)

fixturePath ∷ FilePath → FilePath
fixturePath name = "test" </> "fixtures" </> name

-- | A committed fixture's bytes. @cabal test@ runs the suite in the package
-- directory.
fixtureBytes ∷ FilePath → IO ByteString
fixtureBytes = ByteString.readFile . fixturePath

-- | The asset a fixture is decoded as.
fixtureAsset ∷ FilePath → Asset
fixtureAsset name = Asset (AssetId (Text.pack name)) (FromFile (fixturePath name))

-- | Decode a fixture and evaluate the result completely, so that nothing
-- deferred inside it can fail after the outer result was inspected.
decodeFixture ∷ ImageKind → FilePath → IO (Either AssetRefusal DecodedImage)
decodeFixture kind name = fixtureBytes name >>= decodeFully kind (fixtureAsset name)

decodeFully ∷ ImageKind → Asset → ByteString → IO (Either AssetRefusal DecodedImage)
decodeFully kind asset bytes = evaluate (force (decodePng kind asset bytes))

-- | Level 0's texels, in order.
texels ∷ DecodedImage → [Texel]
texels image = case decodedLevels image of
  level : _ → quads (ByteString.unpack level)
  [] → []
  where
    quads (r : g : b : a : rest) = (r, g, b, a) : quads rest
    quads _ = []

-- | The exact value requirement 4 asks for, in code units, computed here
-- independently of the decoder: IEC 61966-2-1's transfer functions in
-- double precision, without the decoder's table or its rounding.
referencePremultiplied ∷ Word8 → Word8 → Double
referencePremultiplied alpha channel = 255 * encode (decode (fromIntegral channel / 255) * fromIntegral alpha / 255)
  where
    decode v = if v <= 0.04045 then v / 12.92 else ((v + 0.055) / 1.055) ** 2.4
    encode l = if l <= 0.0031308 then 12.92 * l else 1.055 * l ** (1 / 2.4) - 0.055

-- | A stored code value is within one code value of a reference.
shouldBeWithinOne ∷ Word8 → Double → Expectation
shouldBeWithinOne actual reference =
  unless (abs (fromIntegral actual - reference) <= 1) $
    expectationFailure (show actual <> " is not within one code value of the reference " <> show reference)
