-- | The pinned Unicode behavior content identity rests on, checked against
-- reference data this repository did not compute.
--
-- Three independent sources. The Unicode Consortium's own
-- @NormalizationTest.txt@ and @CaseFolding.txt@, both for the version the build
-- pins ("Hetoimasia.Content.Internal.Identity.Unicode" states it), are kept
-- under @test/data@ with their provenance in the header; every row of the
-- first and every folding line of the second is checked, and every other scalar
-- value is checked to fold to itself. Hand-derived vectors, each worked out
-- from the standard's definitions in a comment, cover canonical caseless
-- matching (Unicode D145). And @text@'s UTF-8 decoder, a separate
-- implementation, is the oracle for the strict decoder over every short byte
-- string.
--
-- The examples reach the Unicode operations through the private library, because
-- the public boundary exposes identities, not the operations.
module Test.Content.Identity.Unicode (spec) where

import qualified Data.ByteString as BS
import Data.Char (chr, ord)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hetoimasia.Content.Internal.Identity.Unicode
import Numeric (readHex, showHex)
import Test.Content.Identity.Support (bytes, scalars)
import Test.Hspec

spec ∷ Spec
spec = do
  pinning
  normalization
  caseFolding
  caseless
  decoding

-- | A line of code points: space-separated hexadecimal.
codePoints ∷ String → T.Text
codePoints = T.pack . map (chr . hexValue) . words

-- | A hexadecimal number in a fixture.
hexValue ∷ String → Int
hexValue digits = case readHex digits of
  [(value, "")] → value
  _ → error ("bad hexadecimal number in a fixture: " <> digits)

-- | Show a text as code points, for a failure message.
hexOf ∷ T.Text → String
hexOf = unwords . map (\c → showHex (ord c) "") . T.unpack

-- | The data lines of a fixture, with its comment and blank lines dropped.
dataLines ∷ FilePath → IO ([String], [String])
dataLines path = do
  -- the headers carry a copyright sign, so decode explicitly rather than by locale
  contents ← T.unpack . TE.decodeUtf8 <$> BS.readFile path
  let all' = lines contents
  pure ([line | line ← all', "#" `isPrefixOf` line], [line | line ← all', not (null line), not ("#" `isPrefixOf` line)])

normalizationFixture, foldingFixture ∷ FilePath
normalizationFixture = "test/data/NormalizationTest-17.0.0.canonical.txt"
foldingFixture = "test/data/CaseFolding-17.0.0.cf.txt"

pinning ∷ Spec
pinning = describe "pinned data" $ do
  it "states the Unicode version of its tables" $
    unicodeDataVersion `shouldBe` "17.0.0"
  it "checks against reference files of that same version" $ do
    (normalizationHeader, _) ← dataLines normalizationFixture
    (foldingHeader, _) ← dataLines foldingFixture
    any ("version 17.0.0" `isInfixOf`) normalizationHeader `shouldBe` True
    any ("NormalizationTest-17.0.0.txt" `isInfixOf`) normalizationHeader `shouldBe` True
    any ("CaseFolding-17.0.0.txt" `isInfixOf`) foldingHeader `shouldBe` True
    any ("version 17.0.0" `isInfixOf`) foldingHeader `shouldBe` True

-- | NormalizationTest.txt invariants for the canonical forms, for every row of
-- every part: with the columns source, NFC and NFD, NFC maps all three to the
-- second and NFD maps all three to the third.
normalization ∷ Spec
normalization = describe "normalization against NormalizationTest-17.0.0" $ do
  rows ← runIO $ do
    (_, body) ← dataLines normalizationFixture
    pure (parts body)
  it "has every part, in the file's order" $
    map fst rows `shouldBe` ["@Part0", "@Part1", "@Part2", "@Part3", "@Part4", "@Part5"]
  mapM_
    ( \(part, triples) → do
        it ("maps every row of " <> part <> " to its NFC and NFD") $ do
          let failures =
                [ (hexOf source, hexOf expectedNfc, hexOf expectedNfd)
                | (source, expectedNfc, expectedNfd) ← triples
                , not
                    ( all (\t → nfc t == expectedNfc) [source, expectedNfc, expectedNfd]
                        && all (\t → nfd t == expectedNfd) [source, expectedNfc, expectedNfd]
                    )
                ]
          take 5 failures `shouldBe` []
        it ("has rows in " <> part) $ length triples `shouldSatisfy` (> 0)
    )
    rows
  it "reads the whole file: more than 20,000 rows" $
    sum (map (length . snd) rows) `shouldSatisfy` (> 20000)
  where
    parts body = go body
      where
        go [] = []
        go (marker : rest)
          | "@Part" `isPrefixOf` marker =
              let (mine, others) = break ("@Part" `isPrefixOf`) rest
               in (marker, map triple mine) : go others
          | otherwise = go rest
    triple line = case splitOn ';' line of
      [a, b, c] → (codePoints a, codePoints b, codePoints c)
      _ → error ("bad fixture row: " <> line)

splitOn ∷ Char → String → [String]
splitOn separator text = case break (== separator) text of
  (field, []) → [field]
  (field, _ : remainder) → field : splitOn separator remainder

-- | CaseFolding.txt, statuses C and F: the default full case folding.
caseFolding ∷ Spec
caseFolding = describe "case folding against CaseFolding-17.0.0" $ do
  table ← runIO $ do
    (_, body) ← dataLines foldingFixture
    pure (Map.fromList (map entry body))
  it "has the common and full foldings" $ Map.size table `shouldSatisfy` (> 1500)
  it "folds every listed code point to its listed mapping and every other scalar value to itself" $ do
    let failures =
          [ (showHex (ord c) "", hexOf found, hexOf expected)
          | c ← scalars
          , let expected = Map.findWithDefault (T.singleton c) c table
                found = caseFold (T.singleton c)
          , found /= expected
          ]
    take 5 failures `shouldBe` []
  it "never applies the Turkic T mappings" $ do
    caseFold (T.singleton 'I') `shouldBe` T.singleton 'i'
    caseFold (T.singleton '\x130') `shouldBe` T.pack "i\x307"
    caseFold (T.singleton '\x131') `shouldBe` T.singleton '\x131'
  it "folds the multi-code-point cases" $ do
    caseFold (T.singleton '\xdf') `shouldBe` T.pack "ss"
    caseFold (T.singleton '\x1e9e') `shouldBe` T.pack "ss"
    caseFold (T.singleton '\xfb03') `shouldBe` T.pack "ffi"
    caseFold (T.singleton '\x390') `shouldBe` T.pack "\x3b9\x308\x301"
  where
    entry line = case splitOn ';' line of
      [code, _status, mapping, _] → (chr (hexValue code), codePoints mapping)
      _ → error ("bad fixture row: " <> line)

-- | Unicode D145: two strings match caselessly exactly when
-- @NFD (toCasefold (NFD x))@ agree. Each expected key below is worked out from
-- UnicodeData.txt and CaseFolding.txt by hand, not computed.
caseless ∷ Spec
caseless = describe "canonical caseless matching (D145)" $ do
  let key = caselessKey . T.pack
      keyIs name input expected = it name (hexOf (key input) `shouldBe` expected)
      matches name left right = it name (key left `shouldBe` key right)
      differs name left right = it name (key left `shouldNotBe` key right)
  keyIs "folds sharp s to ss (CaseFolding: 00DF; F; 0073 0073)" "\xdf" "73 73"
  keyIs "folds capital sharp s to ss (1E9E; F; 0073 0073)" "\x1e9e" "73 73"
  keyIs "folds the ffi ligature to three letters (FB03; F; 0066 0066 0069)" "\xfb03" "66 66 69"
  keyIs "folds dotted capital I to i and a combining dot (0130; F; 0069 0307)" "\x130" "69 307"
  keyIs "leaves dotless i alone, as no C or F line names it" "\x131" "131"
  keyIs "folds the Kelvin sign through NFD to k (212A decomposes to K; K folds to k)" "\x212a" "6b"
  keyIs "folds the angstrom sign through NFD to a ring above (212B -> 00C5 -> 0041 030A -> 0061 030A)" "\x212b" "61 30a"
  keyIs "folds the iota-with-dialytika-and-tonos triple fold (0390; F; 03B9 0308 0301)" "\x390" "3b9 308 301"
  keyIs "folds long s with dot above through both steps (1E9B -> 017F 0307; 017F; C; 0073)" "\x1e9b" "73 307"
  keyIs "folds a Greek letter with ypogegrammeni to its expanded form (1F80 -> 03B1 0313 0345; 0345; C; 03B9)" "\x1f80" "3b1 313 3b9"
  keyIs "folds final sigma to sigma (03C2; C; 03C3)" "\x3c2" "3c3"
  matches "matches sharp s with ss and SS" "\xdf" "SS"
  matches "matches ss with Ss" "ss" "Ss"
  matches "matches a ligature with its letters, in any case" "\xfb03" "FFI"
  matches "matches Kelvin with k and K" "\x212a" "k"
  matches "matches the angstrom sign with a composed and a decomposed A ring" "\x212b" "a\x30a"
  matches "matches ΑΣ with ας (final sigma)" "\x391\x3a3" "\x3b1\x3c2"
  matches "matches the two spellings of the triple fold" "\x390" "\x1fd3"
  matches "matches long s with dot above to s with dot above" "\x1e9b" "\x1e61"
  matches "matches a caron j in composed and decomposed form" "\x1f0" "j\x30c"
  matches "matches canonically reordered combining marks" "A\x323\x307" "a\x307\x323"
  matches "matches ASCII in any case" "Hero.PNG" "hero.png"
  differs "keeps dotless i apart from i, as the Turkic mappings are not applied" "\x131" "i"
  differs "keeps dotted capital I apart from plain i" "\x130" "i"
  differs "keeps different letters apart" "a" "b"
  differs "keeps a combining mark apart from its absence" "e\x301" "e"
  it "bounds the derived key: no scalar value's key exceeds the documented expansion" $ do
    let longest = maximum [T.length (caselessKey (T.singleton c)) | c ← scalars]
    longest `shouldSatisfy` (<= maxCaselessExpansion)
    -- the figure is tight for the pipeline, not an arbitrary round number
    longest `shouldBe` maxCaselessExpansion

-- | The strict decoder agrees with @text@'s on well-formedness for every short
-- byte string, and decodes to the same characters.
decoding ∷ Spec
decoding = describe "strict UTF-8 decoding against text's decoder" $ do
  let agrees input = case (decodeUtf8 input, TE.decodeUtf8' input) of
        (Right decoded, Right text) → map snd decoded == T.unpack text
        (Left _, Left _) → True
        _ → False
      disagreements inputs = [BS.unpack input | input ← inputs, not (agrees input)]
      boundary = [0x00, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xed, 0xf0, 0xf4, 0xf5, 0xff]
  it "agrees on every one-byte string" $
    take 3 (disagreements [bytes [a] | a ← [0 .. 255]]) `shouldBe` []
  it "agrees on every two-byte string" $
    take 3 (disagreements [bytes [a, b] | a ← [0 .. 255], b ← [0 .. 255]]) `shouldBe` []
  it "agrees on every three-byte string whose lead starts a three-byte form" $
    take 3 (disagreements [bytes [a, b, c] | a ← [0xe0 .. 0xef], b ← [0 .. 255], c ← [0 .. 255]]) `shouldBe` []
  it "agrees on four-byte strings over the boundary bytes and every final byte" $
    take 3 (disagreements [bytes [a, b, c, d] | a ← [0xef .. 0xf5], b ← boundary, c ← boundary, d ← [0 .. 255]]) `shouldBe` []
  it "agrees on every scalar value's encoding, and decodes it back with its offset" $ do
    let failures = [c | c ← scalars, decodeUtf8 (TE.encodeUtf8 (T.singleton c)) /= Right [(0, c)]]
    take 5 failures `shouldBe` []
  it "reports the offset of the first ill-formed sequence, not the last" $
    decodeUtf8 (bytes [0x61, 0xc3, 0xa9, 0xff, 0xff]) `shouldBe` Left 3
