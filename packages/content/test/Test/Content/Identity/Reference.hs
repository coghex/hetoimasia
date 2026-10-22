-- | The literal root-relative grammar and the NFC identity it yields, through
-- the public identity boundary: every refusal, every ill-formed UTF-8 form,
-- the control-character boundary, literal spaces and non-ASCII names, composed
-- and decomposed equality, exact case, idempotence, and the byte and segment
-- bounds at and one beyond each edge, raw and normalized.
module Test.Content.Identity.Reference (spec) where

import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hetoimasia.Content.Identity
import Test.Content.Identity.Support
import Test.Hspec

spec ∷ Spec
spec = do
  grammar
  invalidUtf8
  controls
  literals
  normalization
  exactCase
  bounds
  precedence
  textReferences

-- | What the grammar refuses, one case each, with where it is refused.
grammar ∷ Spec
grammar = describe "grammar" $ do
  it "refuses the empty reference" $
    refusedReason "" `shouldBe` Left EmptyReference

  it "refuses leading, trailing and repeated slashes" $ do
    refusedReason "/a" `shouldBe` Left LeadingSlash
    refusedReason "/" `shouldBe` Left LeadingSlash
    refusedReason "a/" `shouldBe` Left TrailingSlash
    refusedReason "a//b" `shouldBe` Left (RepeatedSlash 1)
    refusedReason "a/b//c" `shouldBe` Left (RepeatedSlash 2)

  it "refuses dot and dot-dot segments wherever they sit" $ do
    refusedReason "." `shouldBe` Left (BadSegment 0 SegmentDot)
    refusedReason ".." `shouldBe` Left (BadSegment 0 SegmentDotDot)
    refusedReason "a/./b" `shouldBe` Left (BadSegment 1 SegmentDot)
    refusedReason "a/b/.." `shouldBe` Left (BadSegment 2 SegmentDotDot)
    refusedReason "../a" `shouldBe` Left (BadSegment 0 SegmentDotDot)

  it "accepts dots that are not whole segments" $ do
    mapM_
      (\reference → refusedReason reference `shouldBe` Right reference)
      ["...", "a.", ".a", "a.b.c", "..a", "a..", ".hidden", "a/.../b"]

  it "refuses backslashes and colons, naming the offset" $ do
    refusedReason "a\\b" `shouldBe` Left (BadSegment 0 (SegmentForbidden Backslash 1 0x5c))
    refusedReason "ok/\\" `shouldBe` Left (BadSegment 1 (SegmentForbidden Backslash 0 0x5c))
    refusedReason "a:b" `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 1 0x3a))
    refusedReason "C:" `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 1 0x3a))

  it "refuses drive, network, URL and absolute spellings without interpreting them" $ do
    refusedReason "C:\\x" `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 1 0x3a))
    refusedReason "\\\\server\\share" `shouldBe` Left (BadSegment 0 (SegmentForbidden Backslash 0 0x5c))
    refusedReason "//server/share" `shouldBe` Left LeadingSlash
    -- the shape of the slashes is judged before the content of any segment
    refusedReason "file:///etc/passwd" `shouldBe` Left (RepeatedSlash 1)
    refusedReason "http://example.com/a" `shouldBe` Left (RepeatedSlash 1)
    refusedReason "file:x" `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 4 0x3a))
    refusedReason "mailto:a@b" `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 6 0x3a))
    refusedReason "/etc/passwd" `shouldBe` Left LeadingSlash

  it "refuses NUL, reporting it as NUL" $ do
    refusedReason "a\0b" `shouldBe` Left (BadSegment 0 (SegmentForbidden Nul 1 0))
    refusedReason "\0" `shouldBe` Left (BadSegment 0 (SegmentForbidden Nul 0 0))
    refusedReason "x/\0" `shouldBe` Left (BadSegment 1 (SegmentForbidden Nul 0 0))

-- | Every form RFC 3629 and Unicode well-formedness reject, each refused as
-- malformed and never decoded into the character it imitates or replaced.
invalidUtf8 ∷ Spec
invalidUtf8 = describe "invalid UTF-8" $ do
  let malformedAt offset = Left (BadSegment 0 (SegmentMalformedUtf8 offset))
  it "refuses overlong encodings, never decoding them as the character they imitate" $ do
    -- '/' (2F), '.' (2E), '\' (5C), ':' (3A) and NUL, each in an overlong form
    refusedReason (bytes [0xc0, 0xaf]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xe0, 0x80, 0xaf]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xe0, 0x80, 0xae]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xc0, 0xae]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xc1, 0x9c]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xc0, 0xba]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xc0, 0x80]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xf0, 0x80, 0x80, 0xaf]) `shouldBe` malformedAt 0
    -- a path made of an overlong dot and a name is one malformed segment, not "../x"
    refusedReason (bytes [0xc0, 0xae, 0xc0, 0xae]) `shouldBe` malformedAt 0
  it "refuses encoded surrogates" $ do
    refusedReason (bytes [0xed, 0xa0, 0x80]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xed, 0xbf, 0xbf]) `shouldBe` malformedAt 0
  it "refuses code points above U+10FFFF" $ do
    refusedReason (bytes [0xf4, 0x90, 0x80, 0x80]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xf5, 0x80, 0x80, 0x80]) `shouldBe` malformedAt 0
  it "refuses truncated sequences, at the offset where the sequence starts" $ do
    refusedReason (bytes [0xc3]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xe2, 0x82]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xf0, 0x9f, 0x98]) `shouldBe` malformedAt 0
    refusedReason (bytes [0x61, 0x62, 0xe2, 0x82]) `shouldBe` malformedAt 2
    refusedReason (bytes [0xc3, 0x61]) `shouldBe` malformedAt 0
  it "refuses stray continuation bytes and invalid lead bytes" $ do
    refusedReason (bytes [0x80]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xbf]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xc1, 0xbf]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xfe]) `shouldBe` malformedAt 0
    refusedReason (bytes [0xff]) `shouldBe` malformedAt 0
    refusedReason (bytes [0x61, 0xff, 0x62]) `shouldBe` malformedAt 1
  it "reports the segment that is malformed, not the first" $
    refusedReason (BS.concat ["ok/", bytes [0xff]]) `shouldBe` Left (BadSegment 1 (SegmentMalformedUtf8 0))
  it "does not decode with replacement, so a malformed reference never equals its replaced spelling" $ do
    refusedReason (bytes [0x61, 0xff, 0x62]) `shouldNotBe` refusedReason (utf8 "a\xfffd" <> "b")
    refusedReason (utf8 "a\xfffd" <> "b") `shouldBe` Right (utf8 "a\xfffd" <> "b")
  it "accepts the extreme well-formed encodings" $ do
    refusedReason (bytes [0xc2, 0xa0]) `shouldBe` Right (bytes [0xc2, 0xa0])
    refusedReason (bytes [0xdf, 0xbf]) `shouldBe` Right (bytes [0xdf, 0xbf])
    refusedReason (bytes [0xe0, 0xa0, 0x80]) `shouldBe` Right (bytes [0xe0, 0xa0, 0x80])
    refusedReason (bytes [0xed, 0x9f, 0xbf]) `shouldBe` Right (bytes [0xed, 0x9f, 0xbf])
    refusedReason (bytes [0xee, 0x80, 0x80]) `shouldBe` Right (bytes [0xee, 0x80, 0x80])
    refusedReason (bytes [0xf0, 0x90, 0x80, 0x80]) `shouldBe` Right (bytes [0xf0, 0x90, 0x80, 0x80])
    refusedReason (bytes [0xf4, 0x8f, 0xbf, 0xbf]) `shouldBe` Right (bytes [0xf4, 0x8f, 0xbf, 0xbf])

-- | 'Control' is General_Category Cc and nothing else.
controls ∷ Spec
controls = describe "control characters" $ do
  it "refuses every C0 control and DEL, and every C1 control" $ do
    let refused code = case refusedReason (utf8 ['a', toEnum code, 'b']) of
          Left (BadSegment 0 (SegmentForbidden Control 1 found)) → found == code
          _ → False
    [code | code ← [0x01 .. 0x1f] <> [0x7f .. 0x9f], not (refused code)] `shouldBe` []
  it "refuses the boundaries U+001F, U+007F, U+0080 and U+009F by name" $ do
    refusedReason (utf8 "a\x1f") `shouldBe` Left (BadSegment 0 (SegmentForbidden Control 1 0x1f))
    refusedReason (utf8 "a\x7f") `shouldBe` Left (BadSegment 0 (SegmentForbidden Control 1 0x7f))
    refusedReason (utf8 "a\x80") `shouldBe` Left (BadSegment 0 (SegmentForbidden Control 1 0x80))
    refusedReason (utf8 "a\x9f") `shouldBe` Left (BadSegment 0 (SegmentForbidden Control 1 0x9f))
  it "accepts the neighbours U+0020 and U+00A0" $ do
    refusedReason (utf8 "a b") `shouldBe` Right (utf8 "a b")
    refusedReason (utf8 "a\xa0\&b") `shouldBe` Right (utf8 "a\xa0\&b")
  it "does not refuse format characters, line and paragraph separators or noncharacters" $
    mapM_
      (\code → let reference = utf8 ['a', toEnum code, 'b'] in refusedReason reference `shouldBe` Right reference)
      [ 0x200b -- ZERO WIDTH SPACE
      , 0x200e -- LEFT-TO-RIGHT MARK
      , 0x202e -- RIGHT-TO-LEFT OVERRIDE
      , 0x2028 -- LINE SEPARATOR
      , 0x2029 -- PARAGRAPH SEPARATOR
      , 0xfeff -- ZERO WIDTH NO-BREAK SPACE
      , 0xfffe -- noncharacter
      , 0xffff -- noncharacter
      , 0x10ffff -- noncharacter
      ]
  it "does not strip a leading U+FEFF" $ do
    let reference = utf8 "\xfeff\&a/b"
    refusedReason reference `shouldBe` Right reference
    refusedReason reference `shouldNotBe` refusedReason "a/b"

-- | Spaces and punctuation stay literal; nothing is trimmed, expanded or
-- completed.
literals ∷ Spec
literals = describe "literals" $ do
  it "keeps spaces, leading and trailing, exactly" $ do
    refusedReason " a" `shouldBe` Right " a"
    refusedReason "a " `shouldBe` Right "a "
    refusedReason " " `shouldBe` Right " "
    refusedReason "a b/ c /d" `shouldBe` Right "a b/ c /d"
  it "keeps tilde, dollar, percent, hash, question and brackets literal" $
    mapM_
      (\reference → refusedReason reference `shouldBe` Right reference)
      ["~", "~/x", "$HOME/x", "${HOME}/x", "%TEMP%/x", "a#b", "a?b=c", "[x]/(y)", "a;b", "a,b", "a&b", "'q'", "\"q\""]
  it "adds no extension and searches no alternate entry" $ do
    refusedReason "lua/util" `shouldBe` Right "lua/util"
    refusedReason "lua" `shouldBe` Right "lua"
    refusedReason "lua/" `shouldBe` Left TrailingSlash
  it "accepts non-ASCII names of every encoded width" $
    mapM_
      (\reference → refusedReason reference `shouldBe` Right reference)
      [ utf8 "\xe9\&t\xe9/\x65e5\x672c\x8a9e.lua"
      , utf8 "\x1f600/\x1d11e"
      , utf8 "\x3b1\x3b2\x3b3 \x3b4"
      , bytes [0xf0, 0x9f, 0x92, 0xa9]
      ]
  it "is bytes in, bytes out for NFC input: the identity is the reference itself" $
    pathOf (utf8 "caf\xe9/menu") >>= (`shouldBe` utf8 "caf\xe9/menu")
  it "never resolves relative to an importing script: the identity does not depend on the root" $ do
    keyOf rootA "x/y" `shouldNotBe` keyOf rootB "x/y"
    contentKeyPath (keyOf rootA "x/y") `shouldBe` contentKeyPath (keyOf rootB "x/y")
  it "splits the identity into its segments" $
    fmap (logicalPathSegments . contentKeyPath) (parseReference m1 rootA "a/b/c")
      `shouldBe` Right ("a" :| ["b", "c"])

-- | Composed and decomposed spellings share one identity in file and
-- directory positions, and the identity is idempotent.
normalization ∷ Spec
normalization = describe "NFC identity" $ do
  let composed = utf8 "caf\xe9"
      decomposed = utf8 "cafe\x301"
  it "gives composed and decomposed spellings the same identity" $ do
    pathOf composed `shouldReturn` composed
    pathOf decomposed `shouldReturn` composed
    keyOf rootA decomposed `shouldBe` keyOf rootA composed
  it "does so for directory segments as well as the final one" $ do
    pathOf (utf8 "d\xe9/x.lua") `shouldReturn` utf8 "d\xe9/x.lua"
    pathOf (utf8 "de\x301/x.lua") `shouldReturn` utf8 "d\xe9/x.lua"
    pathOf (utf8 "a/de\x301/ce\x301") `shouldReturn` utf8 "a/d\xe9/c\xe9"
  it "reorders canonically equivalent combining marks" $ do
    -- U+0323 (class 220) sorts before U+0307 (class 230) in either spelling,
    -- and a + U+0323 composes to U+1EA1, which U+0307 does not extend
    dotBelowFirst ← pathOf (utf8 "a\x323\x307")
    dotAboveFirst ← pathOf (utf8 "a\x307\x323")
    dotBelowFirst `shouldBe` utf8 "\x1ea1\x307"
    dotAboveFirst `shouldBe` dotBelowFirst
  it "composes Hangul syllables and decomposed jamo alike" $
    pathOf (utf8 "\x1112\x1161\x11ab") `shouldReturn` utf8 "\xd55c"
  it "applies composition exclusions: U+0958 is not recomposed" $
    pathOf (utf8 "\x958") `shouldReturn` utf8 "\x915\x93c"
  it "maps canonical singletons to their targets, including into ASCII" $ do
    pathOf (utf8 "\x212a") `shouldReturn` "K"
    pathOf (utf8 "\x37e") `shouldReturn` ";"
    pathOf (utf8 "\x212b") `shouldReturn` utf8 "\xc5"
    keyOf rootA (utf8 "\x212a\&elvin") `shouldBe` keyOf rootA "Kelvin"
  it "is idempotent: the identity of an identity is itself" $
    mapM_
      ( \reference → do
          once ← pathOf reference
          twice ← pathOf once
          twice `shouldBe` once
      )
      [ composed
      , decomposed
      , utf8 "a\x323\x307/\x1112\x1161\x11ab/\x958"
      , utf8 "\x212a/\x37e/\x212b"
      , utf8 "\x1fed\x1fef"
      , "plain/ascii.lua"
      ]
  it "does not apply compatibility normalization: ligatures and fullwidth forms stay" $ do
    pathOf (utf8 "\xfb01") `shouldReturn` utf8 "\xfb01"
    pathOf (utf8 "\xff21") `shouldReturn` utf8 "\xff21"
    pathOf (utf8 "\x2460") `shouldReturn` utf8 "\x2460"
  it "keeps every scalar value's identity within the grammar, and idempotent" $ do
    -- an independent statement of the grammar, applied to the returned identity
    let violations =
          [ (code, found)
          | char ← scalars
          , let code = ord char
          , Right identity ← [refusedReason (TE.encodeUtf8 (T.singleton char))]
          , let text = TE.decodeUtf8 identity
          , found ← identityViolations text <> [again | again ← ["not idempotent"], refusedReason identity /= Right identity]
          ]
    violations `shouldBe` []
  where
    identityViolations text =
      [ "empty" | T.null text ]
        <> [ "dot segment" | text == "." || text == ".." ]
        <> [ "forbidden character U+" <> show (ord c) | c ← T.unpack text, c == '\\' || c == ':' || c == '/' || ord c <= 0x1f || (ord c >= 0x7f && ord c <= 0x9f) ]

-- | Case is significant everywhere in the identity.
exactCase ∷ Spec
exactCase = describe "exact case" $ do
  it "keeps images/Hero.png distinct from images/hero.png" $ do
    keyOf rootA "images/Hero.png" `shouldNotBe` keyOf rootA "images/hero.png"
    pathOf "images/Hero.png" `shouldReturn` "images/Hero.png"
    pathOf "images/hero.png" `shouldReturn` "images/hero.png"
  it "does not fold case in the identity, for ASCII, one-to-many folds or final sigma" $ do
    keyOf rootA (utf8 "\xdf") `shouldNotBe` keyOf rootA "ss"
    keyOf rootA (utf8 "\xdf") `shouldNotBe` keyOf rootA "SS"
    keyOf rootA (utf8 "\xc9") `shouldNotBe` keyOf rootA (utf8 "\xe9")
    keyOf rootA (utf8 "\x3a3") `shouldNotBe` keyOf rootA (utf8 "\x3c3")
    keyOf rootA (utf8 "\x3c2") `shouldNotBe` keyOf rootA (utf8 "\x3c3")
    keyOf rootA (utf8 "\x130") `shouldNotBe` keyOf rootA "i"
  it "makes a different spelling in the same position a different identity, not a malformed one" $
    refusedReason "Lua/Util.lua" `shouldBe` Right "Lua/Util.lua"

-- | Raw and NFC bounds, at the edge and one beyond, in bytes.
bounds ∷ Spec
bounds = describe "bounds" $ do
  describe "whole path" $ do
    it "accepts exactly 1,024 bytes and refuses 1,025, counting separators" $ do
      BS.length (exactly 255 1024) `shouldBe` 1024
      refusedReason (exactly 255 1024) `shouldBe` Right (exactly 255 1024)
      refusedReason (exactly 255 1025) `shouldBe` Left (ReferenceTooLong 1025 1024)
    it "counts the separators: four 255-byte segments and their slashes are 1,023 bytes" $
      refusedReason (BS.intercalate "/" (replicate 4 (BS.replicate 255 0x61))) `shouldBe` Right (BS.intercalate "/" (replicate 4 (BS.replicate 255 0x61)))
    it "counts bytes, not characters: 512 two-byte characters are 1,024 bytes" $ do
      -- one 1,024-byte segment passes the path bound and is refused by the segment bound
      refusedReason (utf8 (replicate 512 '\xe9')) `shouldBe` Left (BadSegment 0 (SegmentTooLong 1024 255))
      refusedReason (utf8 (replicate 513 '\xe9')) `shouldBe` Left (ReferenceTooLong 1026 1024)
      -- four 254-byte segments of 127 characters each and their separators are 1,019 bytes
      let reference = BS.intercalate "/" (replicate 4 (utf8 (replicate 127 '\xe9')))
      BS.length reference `shouldBe` 1019
      refusedReason reference `shouldBe` Right reference
  describe "one segment" $ do
    it "accepts 255 bytes and refuses 256" $ do
      refusedReason (BS.replicate 255 0x61) `shouldBe` Right (BS.replicate 255 0x61)
      refusedReason (BS.replicate 256 0x61) `shouldBe` Left (BadSegment 0 (SegmentTooLong 256 255))
    it "names the segment that is too long" $
      refusedReason ("ok/" <> BS.replicate 256 0x61) `shouldBe` Left (BadSegment 1 (SegmentTooLong 256 255))
    it "counts bytes for two-, three- and four-byte characters" $ do
      let width code characters = utf8 (replicate characters code)
      -- 127 two-byte characters and one ASCII byte are 255 bytes
      refusedReason (width '\xe9' 127 <> "a") `shouldBe` Right (width '\xe9' 127 <> "a")
      refusedReason (width '\xe9' 128) `shouldBe` Left (BadSegment 0 (SegmentTooLong 256 255))
      -- 85 three-byte characters are 255 bytes; 86 are 258
      refusedReason (width '\x20ac' 85) `shouldBe` Right (width '\x20ac' 85)
      refusedReason (width '\x20ac' 86) `shouldBe` Left (BadSegment 0 (SegmentTooLong 258 255))
      -- 63 four-byte characters and three ASCII bytes are 255 bytes
      refusedReason (width '\x1f600' 63 <> "abc") `shouldBe` Right (width '\x1f600' 63 <> "abc")
      refusedReason (width '\x1f600' 64) `shouldBe` Left (BadSegment 0 (SegmentTooLong 256 255))
  describe "segment count" $ do
    it "accepts 32 segments and refuses 33" $ do
      let segments n = BS.intercalate "/" (replicate n "a")
      refusedReason (segments 32) `shouldBe` Right (segments 32)
      refusedReason (segments 33) `shouldBe` Left (TooManySegments 33 32)
    it "counts from the separators before splitting, so a shape error beyond the limit is a count error" $
      refusedReason (BS.replicate 40 0x2f) `shouldBe` Left (TooManySegments 41 32)
  describe "normalization that shrinks" $ do
    it "does not excuse an over-limit original: the raw bound is checked first" $ do
      -- e + U+0301 is 3 bytes and NFC is 2; with a 2-byte segment limit the original is refused
      accepted (limits 16 2 4 4) (utf8 "e\x301") `shouldBe` Left (BadSegment 0 (SegmentTooLong 3 2))
      accepted (limits 16 3 4 4) (utf8 "e\x301") `shouldBe` Right (utf8 "\xe9")
    it "accepts a 255-byte original whose NFC form is shorter" $ do
      let original = utf8 (concat (replicate 85 "e\x301"))
      BS.length original `shouldBe` 255
      fmap BS.length (refusedReason original) `shouldBe` Right 170
    it "refuses a 256-byte original whose NFC form would fit" $ do
      let original = utf8 (concat (replicate 85 "e\x301")) <> "a"
      refusedReason original `shouldBe` Left (BadSegment 0 (SegmentTooLong 256 255))
    it "does not let a path of shrinking segments past the raw whole-path bound" $ do
      -- three 3-byte originals and two slashes are 11 bytes; their NFC forms are 8
      let original = utf8 "e\x301/e\x301/e\x301"
      accepted (limits 10 3 4 4) original `shouldBe` Left (ReferenceTooLong 11 10)
      accepted (limits 11 3 4 4) original `shouldBe` Right (utf8 "\xe9/\xe9/\xe9")
  describe "normalization that expands" $ do
    it "refuses a segment whose NFC form exceeds the segment limit although the original fits" $ do
      -- U+0958 is 3 bytes and NFC is U+0915 U+093C, 6 bytes
      accepted (limits 64 5 4 4) (utf8 "\x958") `shouldBe` Left (BadSegment 0 (SegmentNormalizedTooLong 6 5))
      accepted (limits 64 6 4 4) (utf8 "\x958") `shouldBe` Right (utf8 "\x915\x93c")
    it "refuses a path whose NFC form exceeds the path limit although the original fits" $ do
      -- two 3-byte originals and a slash are 7 bytes; the NFC forms and the slash are 13
      accepted (limits 8 6 4 4) (utf8 "\x958/\x958") `shouldBe` Left (NormalizedTooLong 13 8)
      accepted (limits 13 6 4 4) (utf8 "\x958/\x958") `shouldBe` Right (utf8 "\x915\x93c/\x915\x93c")
    it "applies the expansion at the M1 numbers: 85 U+0958 are 255 bytes and 510 after NFC" $ do
      let original = utf8 (replicate 85 '\x958')
      BS.length original `shouldBe` 255
      refusedReason original `shouldBe` Left (BadSegment 0 (SegmentNormalizedTooLong 510 255))
  describe "narrow injected limits" $ do
    it "applies the segment count of a smaller profile" $ do
      accepted (limits 64 8 2 4) "a/b" `shouldBe` Right "a/b"
      accepted (limits 64 8 2 4) "a/b/c" `shouldBe` Left (TooManySegments 3 2)
    it "applies the path bound of a smaller profile" $ do
      accepted (limits 5 5 4 4) "ab/cd" `shouldBe` Right "ab/cd"
      accepted (limits 5 5 4 4) "ab/cde" `shouldBe` Left (ReferenceTooLong 6 5)
    it "applies the segment bound of a smaller profile" $ do
      accepted (limits 64 3 4 4) "abc" `shouldBe` Right "abc"
      accepted (limits 64 3 4 4) "abcd" `shouldBe` Left (BadSegment 0 (SegmentTooLong 4 3))
  describe "oversized input" $ do
    it "is refused on its length alone, before any decoding or splitting" $ do
      -- invalid UTF-8 and a thousand slashes would each be refused for another reason
      -- if the scan ran; the answer is the length
      let huge = BS.replicate (2 * 1024 * 1024) 0xff
      refusedReason huge `shouldBe` Left (ReferenceTooLong (2 * 1024 * 1024) 1024)
      refusedReason (BS.replicate 1025 0x2f) `shouldBe` Left (ReferenceTooLong 1025 1024)
    it "keeps a bounded copy of the reference in the refusal, not the reference" $ do
      let huge = BS.replicate (4 * 1024 * 1024) 0x61
      case parseReference m1 rootA huge of
        Left refusal → do
          BS.length (excerptBytes (refusalReference refusal)) `shouldBe` excerptCap
          excerptLength (refusalReference refusal) `shouldBe` 4 * 1024 * 1024
          length (show refusal) `shouldSatisfy` (< 400)
        Right key → expectationFailure ("accepted: " <> show key)
  describe "limits" $ do
    it "refuses a non-positive path, segment or segment-count limit, and a negative entry allowance" $ do
      identityLimits 0 1 1 0 `shouldBe` Left (LimitNotPositive PathBytes 0)
      identityLimits 8 0 1 0 `shouldBe` Left (LimitNotPositive SegmentBytes 0)
      identityLimits 8 4 0 0 `shouldBe` Left (LimitNotPositive Segments 0)
      identityLimits 8 4 1 (-1) `shouldBe` Left (LimitNotPositive Entries (-1))
    it "refuses a segment limit above the path limit or above the longest native name" $ do
      identityLimits 4 5 1 0 `shouldBe` Left (SegmentLimitTooLarge 5 4)
      identityLimits 4096 1024 1 0 `shouldBe` Left (SegmentLimitTooLarge 1024 1023)
    it "accepts an empty entry allowance and reports what it was given" $
      fmap (\l → (limitPathBytes l, limitSegmentBytes l, limitSegments l, limitEntries l)) (identityLimits 1024 255 32 0)
        `shouldBe` Right (1024, 255, 32, 0)

-- | When several things are wrong, the first in the documented order is the
-- refusal; the order puts the raw bounds before any decoding or normalization.
precedence ∷ Spec
precedence = describe "order of checks" $ do
  it "reports empty before anything" $
    refusedReason "" `shouldBe` Left EmptyReference
  it "reports total length before count, shape or content" $
    refusedReason ("/" <> BS.replicate 1100 0x2f) `shouldBe` Left (ReferenceTooLong 1101 1024)
  it "reports segment count before shape" $
    refusedReason ("/" <> BS.intercalate "/" (replicate 40 "a")) `shouldBe` Left (TooManySegments 41 32)
  it "reports slash shape before segment content" $
    refusedReason "/\\" `shouldBe` Left LeadingSlash
  it "reports the first bad segment" $
    refusedReason ("a:b/c\\d") `shouldBe` Left (BadSegment 0 (SegmentForbidden Colon 1 0x3a))
  it "reports an over-long segment before its content" $
    refusedReason (BS.replicate 256 0xff) `shouldBe` Left (BadSegment 0 (SegmentTooLong 256 255))
  it "reports malformed UTF-8 before a forbidden character that precedes it" $
    refusedReason (bytes [0x3a, 0xff]) `shouldBe` Left (BadSegment 0 (SegmentMalformedUtf8 1))

-- | A reference held as text is its UTF-8 encoding; bounds count encoded bytes.
textReferences ∷ Spec
textReferences = describe "text references" $ do
  it "yields the same key as the encoded bytes" $
    parseReferenceText m1 rootA (T.pack "de\x301/x") `shouldBe` parseReference m1 rootA (utf8 "d\xe9/x")
  it "counts encoded bytes, never characters" $ do
    fmap (const ()) (parseReferenceText m1 rootA (T.replicate 85 (T.pack "\x20ac"))) `shouldBe` Right ()
    attribution (parseReferenceText m1 rootA (T.replicate 86 (T.pack "\x20ac")))
      `shouldBe` Left (rootA, BadSegment 0 (SegmentTooLong 258 255))
  it "carries the root in the refusal" $ do
    attribution (parseReferenceText m1 rootB (T.pack "a:b"))
      `shouldBe` Left (rootB, BadSegment 0 (SegmentForbidden Colon 1 0x3a))
    attribution (parseReference m1 rootA "a:b")
      `shouldBe` Left (rootA, BadSegment 0 (SegmentForbidden Colon 1 0x3a))
  where
    attribution = either (\refusal → Left (refusalRoot refusal, refusalReason refusal)) (const (Right ()))
