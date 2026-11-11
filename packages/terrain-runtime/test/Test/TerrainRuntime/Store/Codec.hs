-- | The private page codec against independently written bytes.
--
-- The expected bytes are built here from the documented layout with this suite's own
-- helpers and its own bitwise CRC32C ("Test.TerrainRuntime.Store.Reference"); the
-- production encoder is compared to them, and the production decoder is fed pages
-- the production encoder never made: every field wrong in turn, each page re-sealed
-- with a valid checksum so that only the structure can refuse it. The CRC32C is
-- checked against the iSCSI (RFC 3720 appendix B.4) vectors, and shown to be a
-- different function from the PNG CRC-32 the repository's other helpers compute.
module Test.TerrainRuntime.Store.Codec (spec) where

import Control.Monad (forM_)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Control.Exception (evaluate)
import Data.Int (Int64)
import System.Timeout (timeout)
import Data.Word (Word64, Word8)
import Hetoimasia.Terrain.Discovery (Authority (..), Header (..), Node (..), Record (..), RecordKey (..))
import Hetoimasia.Terrain.Connectivity (Axis (..), mkComponentKey)
import Hetoimasia.Terrain.Coordinate (axisFromInteger)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Crc32c (crc32c)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (decodeKey, decodeValue, encodeKey, encodeValue, levelMaxExclusive, levelMin)
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

-- | An order-preserving signed 64-bit field, from the documented layout.
bias ∷ Integer → ByteString
bias n = be64' (fromInteger (n + 2 ^ (63 ∷ Int)))

-- | A page, built from the documented layout alone.
buildPage ∷ Word64 → Word64 → Word64 → Word8 → Word8 → Word8 → Int → ByteString → ByteString
buildPage arena source no kind tree level count payload =
  let used = 40 + BS.length payload
      header =
        BS.concat
          [ BC.pack "HTRP"
          , le16' 1
          , BS.pack [kind, tree]
          , le64' arena
          , le64' source
          , le64' no
          , BS.pack [level, 0]
          , le16' (fromIntegral count)
          , le16' (fromIntegral used)
          , le16' 0
          ]
      unsealed = BS.concat [header, payload, BS.replicate (4092 - used) 0]
   in BS.append unsealed (le32' (refCrc32c unsealed))

leafPayload ∷ [(ByteString, ByteString)] → ByteString
leafPayload es = BS.concat [BS.concat [BS.pack [fromIntegral (BS.length k), fromIntegral (BS.length v)], k, v] | (k, v) ← es]

-- | Re-seal a mutated page with a valid checksum.
reseal ∷ ByteString → ByteString
reseal bs = let body = BS.take 4092 bs in BS.append body (le32' (refCrc32c body))

mutate ∷ Int → (Word8 → Word8) → ByteString → ByteString
mutate i f bs = BS.concat [BS.take i bs, BS.singleton (f (BS.index bs i)), BS.drop (i + 1) bs]

setBytes ∷ Int → ByteString → ByteString → ByteString
setBytes i new bs = BS.concat [BS.take i bs, new, BS.drop (i + BS.length new) bs]

total ∷ Word64
total = 16128

-- | The key of a retirement entry: its namespace tag and the version.
vkey ∷ Word64 → ByteString
vkey n = BS.cons 0 (be64' n)

decode ∷ ByteString → Either PageError Page
decode = decodePage ident0 total (PageNo 0)

-- | A valid one-entry runs leaf, page 0, arena 1, source 7.
runPage ∷ ByteString
runPage = buildPage 1 7 0 1 0 0 1 (leafPayload [(BS.concat [bias 3, bias (-4), bias 5], bias 9)])

spec ∷ Spec
spec = describe "the private page codec against independent bytes" $ do
  describe "CRC32C" $ do
    it "matches the iSCSI vectors (RFC 3720, appendix B.4) and the standard check value" $ do
      crc32c (BS.replicate 32 0) `shouldBe` 0x8A9136AA
      crc32c (BS.replicate 32 0xFF) `shouldBe` 0x62A8AB43
      crc32c (BS.pack [0 .. 31]) `shouldBe` 0x46DD794E
      crc32c (BS.pack [31, 30 .. 0]) `shouldBe` 0x113FDB5C
      crc32c (BC.pack "123456789") `shouldBe` 0xE3069283
      crc32c BS.empty `shouldBe` 0
    it "is not the CRC-32 of PNG and zlib, which gives 0xCBF43926 for the same text" $ do
      crc32c (BC.pack "123456789") `shouldNotBe` 0xCBF43926
    it "agrees with the independent bitwise implementation on generated buffers" $
      forM_ [1 .. 40 ∷ Word64] $ \seed → do
        let (len, g) = below 5000 (mkRng seed)
            bytes = fst (foldl (\(acc, gg) _ → let (w, g') = nextWord gg in (BS.snoc acc (fromIntegral w), g')) (BS.empty, g) [1 .. len])
        crc32c bytes `shouldBe` refCrc32c bytes
  describe "independently written pages" $ do
    it "encodes a one-run leaf to exactly the documented bytes" $ do
      let page = Page TreeRuns 0 (PageNo 0) (Leaf [(BS.concat [bias 3, bias (-4), bias 5], bias 9)])
      encodePage ident0 page `shouldBe` Right runPage
      BS.length runPage `shouldBe` 4096
      -- header fields at their documented offsets
      BS.take 4 runPage `shouldBe` BC.pack "HTRP"
      getLe16' runPage 4 `shouldBe` 1
      (BS.index runPage 6, BS.index runPage 7, BS.index runPage 32) `shouldBe` (1, 0, 0)
      (getLe64' runPage 8, getLe64' runPage 16, getLe64' runPage 24) `shouldBe` (1, 7, 0)
      (getLe16' runPage 34, getLe16' runPage 36) `shouldBe` (1, 40 + 2 + 24 + 8)
      getLe32' runPage 4092 `shouldBe` refCrc32c (BS.take 4092 runPage)
    it "is what the planner writes for that record, and decodes back to it" $ do
      let h0 = newH smallSpec ident0
          d = deltaFor (hStore h0) True False 1 [(runKey 3 (-4) 5, Just (runRec 9))]
      Right (Planned plan) ← pure (fillPlan h0 d Ordinary)
      plPages plan `shouldBe` [(PageNo 0, runPage)]
      decode runPage `shouldBe` Right (Page TreeRuns 0 (PageNo 0) (Leaf [(BS.concat [bias 3, bias (-4), bias 5], bias 9)]))
    it "writes every record kind in the documented key and value bytes and keeps them apart by tree" $ do
      let h0 = newH smallSpec ident0
          srcKey = srcNodeWith
          ws =
            [ (runKey 3 (-4) 5, Just (runRec 9))
            , (KeyLink srcKey, Just (rootRec 5 True))
            , (KeyLink (RunNode (columnAt 3 (-4)) 5), Just (RecChild srcKey))
            , (KeyTodo 77, Just (todoRec 1 2 3 4))
            ]
          d = deltaFor (hStore h0) True False 1 ws
      Right (Planned plan) ← pure (fillPlan h0 d Ordinary)
      let srcBytes = BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.pack [1], bias (-7), BS.replicate 9 0, BS.pack [1], bias 10]
          runNode = BS.concat [BS.singleton 1, bias 3, bias (-4), bias 5]
          linkLeaf = leafPayload (sort [(srcBytes, BS.concat [BS.singleton 0, be64' 5, BS.singleton 1]), (runNode, BS.cons 1 srcBytes)])
          todoLeaf = leafPayload [(be64' 77, BS.concat [bias 1, bias 2, bias 3, BS.singleton 4])]
          expected =
            [ (PageNo 0, runPage)
            , (PageNo 1, buildPage 1 7 1 1 1 0 2 linkLeaf)
            , (PageNo 2, buildPage 1 7 2 1 2 0 1 todoLeaf)
            ]
      plPages plan `shouldBe` expected
      BS.length srcBytes `shouldBe` 52
      forM_ expected $ \(p, bs) → either (const False) (const True) (decodePage ident0 total p bs) `shouldBe` True
    it "orders key bytes exactly as the logical keys, across negative and extreme coordinates" $ do
      let top' = 2 ^ (62 ∷ Int) - 1
          bot = negate (2 ^ (62 ∷ Int))
          runs = [runKey x y lo | x ← [bot, -1, 0, 1, top'], y ← [bot, 0, top'], lo ← [bot, -5, 0, 7, top' - 1]]
          todos = [KeyTodo n | n ← [0, 1, 255, 256, maxBound]]
          links = [KeyLink (srcNodeWith), KeyLink (RunNode (columnAt 0 0) 0), KeyLink (RunNode (columnAt 0 0) (-1)), KeyLink (RunNode (columnAt (-1) 5) 3)]
      forM_ [runs, todos, links] $ \ks →
        map snd (sort [(encodeKey k, k) | k ← ks]) `shouldBe` sort ks
  describe "boundary-sized valid encodings" $ do
    it "fills a page to exactly its payload and refuses one byte more" $ do
      let entry k = (BS.concat [BS.singleton 1, bias 0, bias 0, bias (fromIntegral k)], BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])
          mk n = [entry (i ∷ Int) | i ← [1 .. n]]
          fits n = encodePage ident0 (Page TreeLinks 0 (PageNo 0) (Leaf (mk n)))
          perEntry = 2 + 25 + 10
      -- 108 entries of 37 bytes take 3,996 of the 4,052 payload bytes; one longer entry fills the rest
      let n = 4052 `div` perEntry - 1
      either (const False) (const True) (fits n) `shouldBe` True
      let full = mk n ++ [(BS.concat [BS.singleton 1, bias 0, bias 0, bias 99999], BS.replicate (4052 - n * perEntry - 2 - 25) 0xAB)]
      bodyBytes (Leaf full) `shouldBe` 4052
      either (const False) (const True) (encodePage ident0 (Page TreeLinks 0 (PageNo 0) (Leaf (sortOn' full)))) `shouldBe` True
      encodePage ident0 (Page TreeLinks 0 (PageNo 0) (Leaf (full ++ [(BS.pack [9], BS.empty)]))) `shouldBe` Left (EntryTooLarge 4055)
    it "encodes the longest key and value (a three-parameter component key against a component parent) and the largest list" $ do
      let key = BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.pack [1], bias 5, BS.pack [1], bias 6, BS.pack [1], bias 7]
          child = BS.cons 1 (BS.concat [BS.singleton 0, bias 9, bias 9, bias 9, BS.pack [1], bias 5, BS.pack [1], bias 6, BS.pack [1], bias 7])
          ok = buildPage 1 7 0 1 1 0 1 (leafPayload [(key, child)])
      (BS.length key, BS.length child) `shouldBe` (52, 53)
      encodePage ident0 (Page TreeLinks 0 (PageNo 0) (Leaf [(key, child)])) `shouldBe` Right ok
      either (const False) (const True) (decode ok) `shouldBe` True
      -- a component that is its own parent is a malformed value, whatever its checksum
      decode (buildPage 1 7 0 1 1 0 1 (leafPayload [(key, BS.cons 1 key)])) `shouldBe` Left MalformedValue
      let list = Page TreeRetire 0 (PageNo 0) (List 1 [PageNo i | i ← [1 .. fromIntegral maxListPages]])
      maxListPages `shouldBe` 505
      either (const False) (const True) (encodePage ident0 list) `shouldBe` True
      either (const False) (const True) (encodePage ident0 (Page TreeRetire 0 (PageNo 0) (List 1 [PageNo i | i ← [1 .. 506]]))) `shouldBe` False
  describe "decode refusals (a valid checksum never rescues a malformed page)" $ do
    it "refuses a short, oversized or empty buffer before reading it" $ do
      decode (BS.take 4095 runPage) `shouldBe` Left (ShortPage 4095)
      decode BS.empty `shouldBe` Left (ShortPage 0)
      decode (BS.snoc runPage 0) `shouldBe` Left (OversizedPage 4097)
      decode (BS.replicate 100000 0) `shouldBe` Left (OversizedPage 100000)
    it "refuses a flipped bit anywhere in the page" $
      forM_ [0 .. 4095] $ \i → case decode (mutate i (`xor` 1) runPage) of
        Left (BadChecksum _ _) → pure ()
        other → expectationFailure ("byte " <> show i <> ": " <> show other)
    it "refuses each header field wrong in turn, with the checksum recomputed" $ do
      let check ∷ String → ByteString → PageError → Expectation
          check name bs e = (name, decode (reseal bs)) `shouldBe` (name, Left e)
      check "magic" (mutate 0 (+ 1) runPage) BadMagic
      check "version" (setBytes 4 (le16' 2) runPage) (UnsupportedVersion 2)
      check "kind" (mutate 6 (const 9) runPage) (UnsupportedKind 9)
      check "kind zero" (mutate 6 (const 0) runPage) (UnsupportedKind 0)
      check "tree" (mutate 7 (const 9) runPage) (UnsupportedTree 9)
      check "arena" (setBytes 8 (le64' 2) runPage) WrongArena
      check "source" (setBytes 16 (le64' 8) runPage) WrongSource
      check "page number" (setBytes 24 (le64' 5) runPage) (WrongPageNumber (PageNo 0) (PageNo 5))
      check "reserved byte 33" (mutate 33 (const 1) runPage) NonZeroReserved
      check "reserved bytes 38" (mutate 38 (const 1) runPage) NonZeroReserved
      check "leaf level" (mutate 32 (const 1) runPage) (BadLevel 1)
      check "count zero" (setBytes 34 (le16' 0) runPage) (BadCount 0)
      check "payload end below the header" (setBytes 36 (le16' 39) runPage) (BadUsedBytes 39)
      check "payload end past the checksum" (setBytes 36 (le16' 4093) runPage) (BadUsedBytes 4093)
      check "padding" (mutate 3000 (const 1) runPage) NonZeroPadding
      check "count beyond the entries" (setBytes 34 (le16' 2) runPage) (BadLength 0)
      check "payload end short of the entry" (setBytes 36 (le16' 70) runPage) NonZeroPadding
    it "refuses each entry wrong in turn" $ do
      let leaf t es = buildPage 1 7 0 1 t 0 (length es) (leafPayload es)
          dec = decodePage ident0 total (PageNo 0)
          key = BS.concat [bias 0, bias 0, bias 5]
          val = bias 9
      dec (leaf 0 [(BS.empty, val)]) `shouldBe` Left (KeyLength 0)
      dec (leaf 0 [(BS.replicate 65 1, val)]) `shouldBe` Left (KeyLength 65)
      dec (leaf 0 [(key, BS.replicate 65 1)]) `shouldBe` Left (ValueLength 65)
      dec (leaf 0 [(BS.append key (BS.pack [1]), val)]) `shouldBe` Left MalformedKey
      dec (leaf 0 [(key, BS.append val (BS.pack [1]))]) `shouldBe` Left MalformedValue
      -- interval: lo >= hi, hi beyond the top level
      dec (leaf 0 [(key, bias 5)]) `shouldBe` Left MalformedValue
      dec (leaf 0 [(key, bias 4)]) `shouldBe` Left MalformedValue
      dec (leaf 0 [(key, bias (2 ^ (62 ∷ Int) + 1))]) `shouldBe` Left MalformedValue
      -- a column outside the supported range
      dec (leaf 0 [(BS.concat [bias (2 ^ (62 ∷ Int)), bias 0, bias 5], val)]) `shouldBe` Left MalformedKey
      -- key order, duplicates and adjacent runs of one column (which must be coalesced)
      let k2 = BS.concat [bias 0, bias 0, bias 20]
      dec (leaf 0 [(k2, bias 25), (key, val)]) `shouldBe` Left KeyOrder
      dec (leaf 0 [(key, val), (key, val)]) `shouldBe` Left KeyOrder
      dec (leaf 0 [(key, bias 20), (k2, bias 25)]) `shouldBe` Left KeyOrder
      either (const False) (const True) (dec (leaf 0 [(key, bias 19), (k2, bias 25)])) `shouldBe` True
      -- links
      let src = BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.replicate 27 0]
      either (const False) (const True) (dec (leaf 1 [(src, BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])])) `shouldBe` True
      dec (leaf 1 [(src, BS.concat [BS.singleton 0, be64' 0, BS.singleton 0])]) `shouldBe` Left MalformedValue
      dec (leaf 1 [(src, BS.concat [BS.singleton 0, be64' 1, BS.singleton 2])]) `shouldBe` Left MalformedValue
      dec (leaf 1 [(src, BS.cons 1 src)]) `shouldBe` Left MalformedValue
      dec (leaf 1 [(BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.pack [2], BS.replicate 26 0], BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])]) `shouldBe` Left MalformedKey
      dec (leaf 1 [(BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.pack [0, 0, 0, 0, 0, 0, 0, 0, 1], BS.replicate 18 0], BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])]) `shouldBe` Left MalformedKey
      -- parameters are listed in axis order by construction; a present parameter out of range is refused
      dec (leaf 1 [(BS.concat [BS.singleton 0, bias 1, bias 2, bias 3, BS.pack [1], bias (2 ^ (62 ∷ Int)), BS.replicate 18 0], BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])]) `shouldBe` Left MalformedKey
      -- todo
      let tile = BS.concat [bias 1, bias 2, bias 3]
      either (const False) (const True) (dec (leaf 2 [(be64' 1, BS.snoc tile 1)])) `shouldBe` True
      dec (leaf 2 [(be64' 1, BS.snoc tile 0)]) `shouldBe` Left MalformedValue
      dec (leaf 2 [(be64' 1, BS.snoc tile 7)]) `shouldBe` Left MalformedValue
      dec (leaf 2 [(be64' 1, tile)]) `shouldBe` Left MalformedValue
      -- free extents: a positive length inside the page space, coalesced
      dec (leaf 3 [(be64' 10, be64' 5)]) `shouldBe` Right (Page TreeFree 0 (PageNo 0) (Leaf [(be64' 10, be64' 5)]))
      dec (leaf 3 [(be64' 10, be64' 0)]) `shouldBe` Left MalformedValue
      dec (leaf 3 [(be64' (total - 2), be64' 3)]) `shouldBe` Left MalformedValue
      dec (leaf 3 [(be64' maxBound, be64' 2)]) `shouldBe` Left MalformedValue
      dec (leaf 3 [(be64' 10, be64' 5), (be64' 15, be64' 1)]) `shouldBe` Left KeyOrder
      dec (leaf 3 [(be64' 10, be64' 7), (be64' 15, be64' 1)]) `shouldBe` Left KeyOrder
      -- retirement entries (keys: the tag 0x00 and the version)
      dec (leaf 4 [(vkey 3, BS.concat [be64' 9, le16' 4, le16' 1])]) `shouldBe` Right (Page TreeRetire 0 (PageNo 0) (Leaf [(vkey 3, BS.concat [be64' 9, le16' 4, le16' 1])]))
      dec (leaf 4 [(vkey 0, BS.concat [be64' 9, le16' 4, le16' 1])]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(vkey 3, BS.concat [be64' 9, le16' 0, le16' 0])]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(vkey 3, BS.concat [be64' 9, le16' 4, le16' 4])]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(vkey 3, BS.concat [be64' 9, le16' 507, le16' 0])]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(vkey 3, BS.concat [be64' total, le16' 4, le16' 0])]) `shouldBe` Left MalformedValue
    it "refuses an entry whose declared lengths run past the payload, in a leaf and in an internal page" $ do
      let dec = decodePage ident0 total (PageNo 0)
      -- a leaf entry claiming a 60-byte value with one byte left; an internal entry claiming a 24-byte key and no child
      dec (buildPage 1 7 0 1 0 0 1 (BS.pack [1, 60, 7])) `shouldBe` Left (BadLength 3)
      dec (buildPage 1 7 0 2 0 1 1 (BS.concat [BS.singleton 24, BS.replicate 14 1])) `shouldBe` Left (BadLength 15)
    it "refuses each field of a retired-page index entry wrong in turn, and an internal page's key lengths" $ do
      let leaf t es = buildPage 1 7 0 1 t 0 (length es) (leafPayload es)
          dec = decodePage ident0 total (PageNo 0)
          marked p = BS.cons 0xFF (be64' p)
          ver = be64' 7
          entry = (vkey 3, BS.concat [be64' 9, le16' 4, le16' 1])
      -- an index entry after a version entry is a well-formed leaf
      either (const False) (const True) (dec (leaf 4 [entry, (marked 5, ver)])) `shouldBe` True
      dec (leaf 4 [(BS.cons 0xFE (be64' 5), ver)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(BS.cons 0 (be64' 5), ver)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(marked total, ver)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(marked 5, be64' 0)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(marked 5, BS.take 7 ver)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(marked 5, BS.snoc ver 0)]) `shouldBe` Left MalformedValue
      dec (leaf 4 [(marked 6, ver), (marked 5, ver)]) `shouldBe` Left KeyOrder
      -- an internal page's separator lengths are checked before it is sliced
      let innerRaw kl = buildPage 1 7 0 2 0 1 1 (BS.concat [BS.singleton kl, BS.replicate (fromIntegral kl) 1, le64' 5, le32' 0])
      dec (innerRaw 0) `shouldBe` Left (KeyLength 0)
      dec (innerRaw 65) `shouldBe` Left (KeyLength 65)
    it "refuses internal and list pages with bad references, levels or order" $ do
      let inner lvl es = buildPage 1 7 0 2 0 lvl (length es) (BS.concat [BS.concat [BS.singleton (fromIntegral (BS.length k)), k, le64' c, le32' 0] | (k, c) ← es])
          list ps = buildPage 1 7 0 3 4 0 (length ps) (BS.concat (le64' 3 : map le64' ps))
          dec = decodePage ident0 total (PageNo 0)
          k1 = encodeKey (runKey 0 0 1)
          k2 = encodeKey (runKey 0 0 2)
      either (const False) (const True) (dec (inner 1 [(k1, 5), (k2, 6)])) `shouldBe` True
      dec (inner 1 [(k1, 0)]) `shouldBe` Left (BadReference (PageNo 0))
      dec (inner 1 [(k1, total)]) `shouldBe` Left (BadReference (PageNo total))
      dec (inner 1 [(k1, maxBound)]) `shouldBe` Left (BadReference (PageNo maxBound))
      dec (inner 0 [(k1, 5)]) `shouldBe` Left (BadLevel 0)
      dec (inner 8 [(k1, 5)]) `shouldBe` Left (BadLevel 8)
      dec (inner 1 [(k2, 5), (k1, 6)]) `shouldBe` Left KeyOrder
      dec (inner 1 [(k1, 5), (k1, 6)]) `shouldBe` Left KeyOrder
      -- a separator must be a key of its own tree: a re-sealed internal page whose separator no decoder
      -- of that tree accepts would make a descent skip records that exist
      let innerOf t lvl es = buildPage 1 7 0 2 t lvl (length es) (BS.concat [BS.concat [BS.singleton (fromIntegral (BS.length k)), k, le64' c, le32' 0] | (k, c) ← es])
          badSeparators ∷ [(String, Word8, ByteString)]
          badSeparators =
            [ ("runs: 24 bytes of 0xFF", 0, BS.replicate 24 0xFF)
            , ("runs: too short", 0, BS.replicate 7 1)
            , ("links: a tag that is neither", 1, BS.pack [7, 0, 0])
            , ("todo: not eight bytes", 2, BS.replicate 3 1)
            , ("free: not eight bytes", 3, BS.replicate 7 1)
            , ("retire: nine bytes with a tag that is neither", 4, BS.replicate 9 1)
            , ("retire: eight bytes (the key an entry had before it was tagged)", 4, be64' 3)
            ]
      forM_ badSeparators $ \(what, t, k) → (what, dec (innerOf t 1 [(k, 5)])) `shouldBe` (what, Left MalformedKey)
      -- and the separators of each tree's own keys are accepted
      either (const False) (const True) (dec (innerOf 0 1 [(encodeKey (runKey 0 0 5), 5)])) `shouldBe` True
      either (const False) (const True) (dec (innerOf 3 1 [(be64' 5, 5)])) `shouldBe` True
      either (const False) (const True) (dec (innerOf 4 1 [(vkey 3, 5), (BS.cons 0xFF (be64' 5), 6)])) `shouldBe` True
      either (const False) (const True) (dec (list [3, 4, 9])) `shouldBe` True
      dec (list [4, 3]) `shouldBe` Left KeyOrder
      dec (list [3, 3]) `shouldBe` Left KeyOrder
      dec (list [0]) `shouldBe` Left (BadReference (PageNo 0))
      dec (list [total]) `shouldBe` Left (BadReference (PageNo total))
      dec (buildPage 1 7 0 3 0 0 1 (BS.concat [le64' 3, le64' 5])) `shouldBe` Left (BadLevel 0)
      -- a list is stamped with the version of the entry that names it: never zero, and the payload is the stamp and the pages
      dec (buildPage 1 7 0 3 4 0 2 (BS.concat [le64' 0, le64' 3, le64' 4])) `shouldBe` Left MalformedValue
      dec (buildPage 1 7 0 3 4 0 2 (BS.concat [le64' 3, le64' 4])) `shouldBe` Left (BadLength 16)
      dec (list [3, 4]) `shouldBe` Right (Page TreeRetire 0 (PageNo 0) (List 3 [PageNo 3, PageNo 4]))
  describe "structures that could loop" $ do
    it "stops a cyclic or level-violating tree instead of following it" $ do
      let pageNo n = PageNo n
          inner lvl no child crc = buildPage 1 7 no 2 0 lvl 1 (BS.concat [BS.singleton 24, BS.concat [bias 0, bias 0, bias 0], le64' child, le32' crc])
          -- an internal entry records the checksum of its child: the first hop is recorded truly, the second (back to
          -- the first page) cannot be, and is never followed
          q = inner 1 6 5 0
          p = inner 1 5 6 (getLe32' q 4092)
          add win no bs = either (error . show) id (windowInsert total (pageNo no) bs win)
          w = add (add (uncheckedWindow ident0 0) 5 p) 6 q
      case runM (lookupKey TreeRuns (Just (Disk (pageNo 5))) (BS.concat [bias 0, bias 0, bias 0])) (newEdit 0 w) of
        Left (Bad (BadLevel 1) (PageNo 6)) → pure ()
        other → expectationFailure ("a cycle was not stopped: " <> either show (const "answered") other)
      -- a child that violates its parent's bounds is refused too
      let leafAt no k = buildPage 1 7 no 1 0 0 1 (leafPayload [(k, bias 9)])
          leaf6 = leafAt 6 (BS.concat [bias 0, bias 0, bias 0])
          parent = buildPage 1 7 5 2 0 1 1 (BS.concat [BS.singleton 24, BS.concat [bias 5, bias 5, bias 5], le64' 6, le32' (getLe32' leaf6 4092)])
          w2 = add (add (uncheckedWindow ident0 0) 5 parent) 6 leaf6
      case runM (lookupKey TreeRuns (Just (Disk (pageNo 5))) (BS.concat [bias 5, bias 5, bias 5])) (newEdit 0 w2) of
        Left (Bad KeyOrder (PageNo 6)) → pure ()
        other → expectationFailure ("bounds not enforced: " <> either show (const "answered") other)
      -- a missing page is pending, never an absent key
      case runM (lookupKey TreeRuns (Just (Disk (pageNo 5))) (BS.concat [bias 5, bias 5, bias 5])) (newEdit 0 (add (uncheckedWindow ident0 0) 5 parent)) of
        Left (Need (PageNo 6)) → pure ()
        other → expectationFailure ("a missing page must be pending: " <> either show (const "answered") other)
  describe "a child against its parent" $ do
    it "refuses a child of another tree and a child whose keys reach the parent's upper separator" $ do
      let add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          inner no cs = buildPage 1 7 no 2 0 1 (length cs) (BS.concat [BS.concat [BS.singleton 24, k, le64' c, le32' (getLe32' cb 4092)] | (k, (c, cb)) ← cs])
          sepL = runKeyBytes 1000
          sepR = runKeyBytes 5000
          -- a runs parent whose child is a leaf of the links tree
          linksLeaf = buildPage 1 7 6 1 1 0 1 (leafPayload [(BS.concat [BS.singleton 1, bias 0, bias 0, bias 1000], BS.concat [BS.singleton 0, be64' 1, BS.singleton 0])])
          wOther = add (add (uncheckedWindow ident0 0) 5 (inner 5 [(sepL, (6, linksLeaf))])) 6 linksLeaf
      case runM (lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL) (newEdit 0 wOther) of
        Left (Bad KindMismatch (PageNo 6)) → pure ()
        other → expectationFailure ("a child of another tree was followed: " <> either show (const "answered") other)
      -- the left child holds a key at the right separator, which belongs to the right child
      let leafKeys no ks = buildPage 1 7 no 1 0 0 (length ks) (leafPayload [(k, bias (lo + 1)) | (k, lo) ← ks])
          left = leafKeys 6 [(runKeyBytes 1000, 1000), (runKeyBytes 5000, 5000)]
          right = leafKeys 7 [(runKeyBytes 5000, 5000)]
          wBound = add (add (add (uncheckedWindow ident0 0) 5 (inner 5 [(sepL, (6, left)), (sepR, (7, right))])) 6 left) 7 right
      case runM (lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL) (newEdit 0 wBound) of
        Left (Bad KeyOrder (PageNo 6)) → pure ()
        other → expectationFailure ("a child reaching the upper separator was followed: " <> either show (const "answered") other)
  describe "a child's checksum" $ do
    it "refuses a child whose page carries another checksum than its parent records, also for a page that was just loaded through another pointer" $ do
      let add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          sepL = runKeyBytes 1000
          sepR = runKeyBytes 5000
          leaf6 = buildPage 1 7 6 1 0 0 1 (leafPayload [(runKeyBytes 1000, bias 1001)])
          good = getLe32' leaf6 4092
          entry k crc = BS.concat [BS.singleton 24, k, le64' 6, le32' crc]
          parentOf crcs = buildPage 1 7 5 2 0 1 (length crcs) (BS.concat [entry k crc | (k, crc) ← crcs])
          wOnly crcs = add (add (uncheckedWindow ident0 0) 5 (parentOf crcs)) 6 leaf6
          lookupWith crcs = runM (lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL) (newEdit 0 (wOnly crcs))
      -- the checksum the parent records is the page's: it is followed
      case lookupWith [(sepL, good)] of
        Right (Just _, _) → pure ()
        other → expectationFailure ("a child with its recorded checksum was refused: " <> either show (const "answered another way") other)
      -- another checksum: the same page, another version of it
      case lookupWith [(sepL, good + 1)] of
        Left (Bad (ChildChecksum want have) (PageNo 6)) → (want, have) `shouldBe` (good + 1, good)
        other → expectationFailure ("a child with another checksum was followed: " <> either show (const "answered") other)
      -- a page already loaded through a pointer that records its checksum is not taken from the cache for a pointer that records another
      let twice = lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL >> lookupKey TreeRuns (Just (Disk (PageNo 5))) sepR
      case runM twice (newEdit 0 (wOnly [(sepL, good), (sepR, good + 7)])) of
        Left (Bad (ChildChecksum want have) (PageNo 6)) → (want, have) `shouldBe` (good + 7, good)
        other → expectationFailure ("a cached page was used for a pointer that records another checksum: " <> either show (const "answered") other)
    it "refuses an under-full child however the page was obtained: cold, and hot after it was loaded as a root in the same plan" $ do
      -- a page first loaded as a ROOT (exempt from the minimum fill) and still hot when a parent names it as a child is the same page in
      -- another role. The hot cache is keyed by page number, so the role-dependent check must not live only in the decoding branch.
      let add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          sepL = runKeyBytes 1000
          small6 = buildPage 1 7 6 1 0 0 1 (leafPayload [(sepL, bias 1001)])
          crc6 = getLe32' small6 4092
          parent = buildPage 1 7 5 2 0 1 1 (BS.concat [BS.singleton 24, sepL, le64' 6, le32' crc6])
          crc5 = getLe32' parent 4092
          -- both pages are roots of this window (a pinned version's root and the committed one), each with its published checksum
          trusted = windowTrust [(PageNo 5, crc5), (PageNo 6, crc6)] (add (add (emptyWindow ident0 0) 5 parent) 6 small6)
          viaParent = lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL
          asRoot = lookupKey TreeRuns (Just (Disk (PageNo 6))) sepL
      -- cold: refused as under-full
      case runM viaParent (newEdit 0 trusted) of
        Left (Bad (UnderFull _) (PageNo 6)) → pure ()
        other → expectationFailure ("a cold under-full child was not refused: " <> either show (const "answered") other)
      -- the page read as the root first is a legal root
      case runM asRoot (newEdit 0 trusted) of
        Right (Just _, _) → pure ()
        other → expectationFailure ("an under-full ROOT was refused: " <> either show (const "answered another way") other)
      -- hot: loaded as a root, then reached as a child in the same plan, is refused alike
      case runM (asRoot >> viaParent) (newEdit 0 trusted) of
        Left (Bad (UnderFull _) (PageNo 6)) → pure ()
        other → expectationFailure ("a hot under-full child was accepted: " <> either show (const "answered") other)
    it "refuses a root with no recorded checksum in every production window, and reads it only through the test-only unchecked window" $ do
      let add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          sepL = runKeyBytes 1000
          -- a child of a production window holds at least a quarter of a payload: 30 entries of 34 bytes
          leaf6 = buildPage 1 7 6 1 0 0 30 (leafPayload [(runKeyBytes (1000 + 10 * i), bias (1003 + 10 * i)) | i ← [0 .. 29]])
          good = getLe32' leaf6 4092
          parent = buildPage 1 7 5 2 0 1 1 (BS.concat [BS.singleton 24, sepL, le64' 6, le32' good])
          fill w = add (add w 5 parent) 6 leaf6
          lookupIn w = runM (lookupKey TreeRuns (Just (Disk (PageNo 5))) sepL) (newEdit 0 (fill w))
          production = emptyWindow ident0 0
          rootCrc = getLe32' parent 4092
      -- a window that holds no checksum for the root refuses it
      case lookupIn production of
        Left (Bad RootChecksumMissing (PageNo 5)) → pure ()
        other → expectationFailure ("a root with no recorded checksum was read: " <> either show (const "answered") other)
      -- the checksum the root record publishes for it makes the same window read it
      case lookupIn (windowTrust [(PageNo 5, rootCrc)] production) of
        Right (Just _, _) → pure ()
        other → expectationFailure ("a root with its recorded checksum was refused: " <> either show (const "answered another way") other)
      -- another checksum for it is refused as such
      case lookupIn (windowTrust [(PageNo 5, rootCrc + 1)] production) of
        Left (Bad (ChildChecksum want have) (PageNo 5)) → (want, have) `shouldBe` (rootCrc + 1, rootCrc)
        other → expectationFailure ("a root with another checksum was read: " <> either show (const "answered") other)
      -- only the test-only constructor reads a root no record names
      case lookupIn (uncheckedWindow ident0 0) of
        Right (Just _, _) → pure ()
        other → expectationFailure ("the unchecked test window refused a root: " <> either show (const "answered another way") other)
  describe "rebalancing" $ do
    it "refuses a root collapse that would follow a cycle or a child of the wrong level" $ do
      let runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          sepL = runKeyBytes 1000
          sepR = runKeyBytes 5000
          inner no lvl cs = buildPage 1 7 no 2 0 lvl (length' cs) (BS.concat [BS.concat [BS.singleton 24, k, le64' c, le32' crc] | (k, c, crc) ← cs])
          length' = fromIntegral . length
          crcOf = (`getLe32'` 4092)
          add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          -- the left subtree holds one entry; the right one is a two-page cycle of level-1 pages (the
          -- record of the checksum of the page the cycle comes back to cannot be true, and is never followed)
          leaf = buildPage 1 7 4 1 0 0 1 (leafPayload [(runKeyBytes 1000, bias 1001)])
          leftInner = inner 1 1 [(sepL, 4, crcOf leaf)]
          cycB = inner 5 1 [(sepR, 2, 0)]
          cycA = inner 2 1 [(sepR, 5, crcOf cycB)]
          root = inner 3 2 [(sepL, 1, crcOf leftInner), (sepR, 2, crcOf cycA)]
          w = foldl (\acc (no, bs) → add acc no bs) (uncheckedWindow ident0 0) [(3, root), (1, leftInner), (4, leaf), (2, cycA), (5, cycB)]
      -- the deletion empties the left subtree, leaving a one-child root whose collapse reaches the cycle
      -- (a generous wall-clock guard turns a regression that loops into a failure, not a hang)
      outcome ← timeout 20000000 (evaluate (either Left (const (Right ())) (runM (deleteKey TreeRuns (Just (Disk (PageNo 3))) (runKeyBytes 1000)) (newEdit 1000000 w))))
      case outcome of
        Nothing → expectationFailure "the collapse did not terminate"
        Just (Left (Bad (BadLevel _) _)) → pure ()
        Just (Left err) → expectationFailure ("a different refusal: " <> show err)
        Just (Right ()) → expectationFailure "the collapse was not refused: a plan was produced"
    it "refuses a run node whose level is outside the supported coordinate range, in keys and in parent values" $ do
      let col = columnAt 3 (-4)
          limit = 4611686018427387904 ∷ Int64
          bad = [limit, maxBound, negate limit - 1]
          good = [limit - 1, 0, negate limit]
      forM_ bad $ \lo → do
        decodeKey TreeLinks (encodeKey (KeyLink (RunNode col lo))) `shouldBe` Nothing
        decodeKey TreeRuns (encodeKey (runKey 3 (-4) (toInteger lo))) `shouldBe` Nothing
        decodeValue (KeyLink srcNodeWith) (encodeValue (RecChild (RunNode col lo))) `shouldBe` Nothing
      forM_ good $ \lo → do
        decodeKey TreeLinks (encodeKey (KeyLink (RunNode col lo))) `shouldBe` Just (KeyLink (RunNode col lo))
        decodeValue (KeyLink srcNodeWith) (encodeValue (RecChild (RunNode col lo))) `shouldBe` Just (RecChild (RunNode col lo))
      levelMin `shouldBe` negate (2 ^ (62 ∷ Int))
      levelMaxExclusive `shouldBe` 2 ^ (62 ∷ Int)

    it "refuses a sibling whose keys break its parent's separators before merging it into a new page" $ do
      let runKeyBytes lo = BS.concat [bias 0, bias 0, bias lo]
          entries from = [(runKeyBytes lo, bias (lo + 1)) | lo ← [from, from + 10 .. from + 10 * 29]]
          -- a left leaf of 30 runs (just over the under-full threshold, so one deletion
          -- under-fills it) and a right leaf whose keys lie BELOW its separator
          left = buildPage 1 7 1 1 0 0 30 (leafPayload (entries 1000))
          right = buildPage 1 7 2 1 0 0 30 (leafPayload (entries 100))
          sepLeft = runKeyBytes 1000
          sepRight = runKeyBytes 5000
          parent = buildPage 1 7 3 2 0 1 2 (BS.concat [BS.concat [BS.singleton 24, k, le64' c, le32' (getLe32' cb 4092)] | (k, (c, cb)) ← [(sepLeft, (1, left)), (sepRight, (2, right))]])
          add win no bs = either (error . show) id (windowInsert total (PageNo no) bs win)
          w = add (add (add (uncheckedWindow ident0 0) 3 parent) 1 left) 2 right
      -- an ordinary lookup already refuses the malformed sibling
      case runM (lookupKey TreeRuns (Just (Disk (PageNo 3))) (runKeyBytes 5000)) (newEdit 0 w) of
        Left (Bad KeyOrder (PageNo 2)) → pure ()
        other → expectationFailure ("lookup: " <> either show (const "answered") other)
      -- and so must the deletion that would merge it
      case runM (deleteKey TreeRuns (Just (Disk (PageNo 3))) (runKeyBytes 1000)) (newEdit 1000000 w) of
        Left (Bad KeyOrder (PageNo 2)) → pure ()
        other → expectationFailure ("a malformed sibling was merged: " <> either show (const "a plan was produced") other)
  describe "revision and version arithmetic" $ do
    it "refuses a revision or version that would wrap, and a delta that names another authority" $ do
      let cfg = either (error . show) id (mkStoreConfig smallSpec)
          roots0 = storeRoots (hStore (newH smallSpec ident0))
          at c k st = roots0 {rHeader = (rHeader roots0) {hAuthority = Authority (ArenaId 1) (Revision c) (Revision k) (Revision st)}}
          store r = storeFromRoots cfg ident0 r
          plan r terrain knowledge =
            let s = store r
                hdr = storeHeader s
                Authority a (Revision c) (Revision k) (Revision st) = hAuthority hdr
                nextA = Authority a (Revision (if terrain then c + 1 else c)) (Revision (if knowledge then k + 1 else k)) (Revision (st + 1))
                d = Delta (hAuthority hdr) hdr {hAuthority = nextA} terrain knowledge 1 [(runKey 0 0 1, Just (runRec 3))]
             in planDelta cfg ident0 r (uncheckedWindow ident0 (rVersion r)) Ordinary d
          is' want p = p `shouldSatisfy` (\x → case x of Refused y → y == want; _ → False)
      is' (Invalid RevisionArithmetic) (plan (at maxBound 0 0) True False)
      is' (Invalid RevisionArithmetic) (plan (at 0 maxBound 0) False True)
      is' (Invalid RevisionArithmetic) (plan (at 0 0 maxBound) False False)
      -- unchanged revisions at their limit do not wrap and the plan proceeds
      plan (at maxBound maxBound 5) False False `shouldSatisfy` (\x → case x of Planned _ → True; _ → False)
      is' (Invalid VersionArithmetic) (plan roots0 {rVersion = maxBound} True False)
      -- a delta that names another incarnation, another base or inconsistent revisions
      let s0 = store roots0
          hdr0 = storeHeader s0
          Authority _ c0 k0 st0 = hAuthority hdr0
          w = [(runKey 0 0 1, Just (runRec 3))]
          other = Authority (ArenaId 9) c0 k0 st0
          stale = Authority (ArenaId 1) (Revision 5) k0 st0
          wrong = Authority (ArenaId 1) c0 k0 (Revision 5)
          go d = planDelta cfg ident0 roots0 (uncheckedWindow ident0 0) Ordinary d
      is' (Invalid ForeignArena) (go (Delta other hdr0 True False 1 w))
      is' (Stale (StaleAuthority stale (hAuthority hdr0))) (go (Delta stale hdr0 True False 1 w))
      is' (Invalid InconsistentRevisions) (go (Delta (hAuthority hdr0) hdr0 {hAuthority = wrong} True False 1 w))
      is' (Invalid InconsistentRevisions) (go (Delta (hAuthority hdr0) hdr0 True False 1 w))
      is' (Invalid (TooManyUpdates 65)) (go (Delta (hAuthority hdr0) hdr0 True False 65 w))
      is' (Stale (StaleWindow 3 0)) (planDelta cfg ident0 roots0 (uncheckedWindow ident0 3) Ordinary (Delta (hAuthority hdr0) hdr0 True False 1 w))
      _ ← pure (Map.empty ∷ Map.Map Int Int)
      pure ()
  where
    srcNodeWith = SrcNode (maybe (error "key") id (mkComponentKey (tileAt 1 2 3) [(AxisX, ax (-7)), (AxisZ, ax 10)]))
    ax = either (error . show) id . axisFromInteger
    sortOn' = sort
