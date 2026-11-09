-- | The private page codec: a 4 KiB immutable page, its layout, its checksum and
-- every check a decoded page passes before anything uses it.
--
-- = Layout
--
-- Every multi-byte header field is little-endian; keys inside entries are the
-- order-preserving big-endian forms of "Hetoimasia.Terrain.Runtime.Store.Internal.Records".
--
-- @
--    0  4  magic "HTRP"
--    4  2  format version (1)
--    6  1  kind: 1 leaf, 2 internal, 3 retirement list
--    7  1  tree: 0 runs, 1 links, 2 todo, 3 free, 4 retire (a list page is tree 4)
--    8  8  arena incarnation
--   16  8  source identity
--   24  8  this page's own number
--   32  1  level: 0 for a leaf or a list, 1 .. 7 for an internal page
--   33  1  reserved, zero
--   34  2  entry count
--   36  2  end of the payload (40 + payload bytes)
--   38  2  reserved, zero
--   40     payload, then zero padding up to 4092
-- 4092  4  CRC32C of bytes 0 .. 4091
-- @
--
-- Leaf entries are @keyLen(1) valueLen(1) key value@; internal entries are
-- @keyLen(1) key childPage(8)@, the key being the least key the child may hold; a
-- list is the eight-byte version of the retirement entry that names it, then a
-- strictly increasing sequence of eight-byte page numbers.
--
-- = What a decode checks
--
-- Length (a short or oversized buffer is refused before it is read), the checksum,
-- magic, version, kind, tree, arena, source and the page's own number (a page read
-- from the wrong place is refused), the reserved bytes, the level against the kind,
-- the count and payload length against the bytes available, every entry's lengths
-- against the key and value bounds before it is sliced, that the entries end
-- exactly at the stated end and that the padding is zero, strictly increasing
-- keys, every child and list reference inside the page space and never the page
-- itself, and the structure of each leaf entry (a well-formed key and value of the
-- tree's own category, adjacent runs and adjacent free extents already coalesced).
-- A page with a recomputed valid checksum but a malformed structure is refused by
-- the same checks. Nothing partial is returned.
--
-- State, ownership and lifetime: none. Pure functions over strict byte strings.
module Hetoimasia.Terrain.Runtime.Store.Internal.Page
  ( Body (..)
  , Page (..)
  , bodyBytes
  , entryBytes
  , innerEntryBytes
  , encodePage
  , decodePage
  , bodyOfValid
  , packBody
  , unpackBody
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64, Word8)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Crc32c (crc32c)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Records

-- | A page's content.
data Body
  = -- | Sorted key and value byte strings.
    Leaf [(ByteString, ByteString)]
  | -- | Sorted separator keys, each with its child page.
    Inner [(ByteString, PageNo)]
  | -- | The version of the retirement entry that names the page, and a strictly
    -- increasing list of page numbers (retirement work). The version lets a page be
    -- told apart from a live list without a sweep of the retirement tree.
    List !Word64 [PageNo]
  deriving stock (Eq, Show)

-- | A decoded, validated page.
data Page = Page
  { pgTree ∷ !TreeId
  , pgLevel ∷ !Int
  , pgNo ∷ !PageNo
  , pgBody ∷ !Body
  }
  deriving stock (Eq, Show)

-- | The bytes one leaf entry takes.
entryBytes ∷ (ByteString, ByteString) → Int
entryBytes (k, v) = 2 + BS.length k + BS.length v

-- | The bytes one internal entry takes.
innerEntryBytes ∷ (ByteString, PageNo) → Int
innerEntryBytes (k, _) = 1 + BS.length k + 8

-- | The payload bytes of a body.
bodyBytes ∷ Body → Int
bodyBytes (Leaf es) = sum (map entryBytes es)
bodyBytes (Inner es) = sum (map innerEntryBytes es)
bodyBytes (List _ ps) = 8 + 8 * length ps

kindOf ∷ Body → Int
kindOf (Leaf _) = 1
kindOf (Inner _) = 2
kindOf (List _ _) = 3

countOf ∷ Body → Int
countOf (Leaf es) = length es
countOf (Inner es) = length es
countOf (List _ ps) = length ps

-- | Encode a page, refusing a body that does not fit or breaks a bound.
encodePage ∷ StoreIdentity → Page → Either PageError ByteString
encodePage ident (Page tree level (PageNo no) body)
  | bodyBytes body > pagePayloadBytes = Left (EntryTooLarge (bodyBytes body))
  | countOf body < 1 || countOf body > 65535 = Left (BadCount (countOf body))
  | otherwise = do
      payload ← payloadOf body
      let used = pageHeaderBytes + BS.length payload
          ArenaId arena = siArena ident
          header =
            BS.concat
              [ BC.pack "HTRP"
              , le16 formatVersion
              , BS.pack [fromIntegral (kindOf body), treeCode tree]
              , le64 arena
              , le64 (siSource ident)
              , le64 no
              , BS.pack [fromIntegral level, 0]
              , le16 (fromIntegral (countOf body))
              , le16 (fromIntegral used)
              , le16 0
              ]
          unsealed = BS.concat [header, payload, BS.replicate (pageChecksumOffset - used) 0]
      Right (BS.append unsealed (le32 (crc32c unsealed)))
  where
    payloadOf (Leaf es) = BS.concat <$> traverse leafEntry es
    payloadOf (Inner es) = BS.concat <$> traverse innerEntry es
    payloadOf (List v ps) = Right (BS.concat (le64 v : [le64 p | PageNo p ← ps]))
    leafEntry (k, v)
      | BS.length k < 1 || BS.length k > maxKeyBytes = Left (KeyLength (BS.length k))
      | BS.length v > maxValueBytes = Left (ValueLength (BS.length v))
      | otherwise = Right (BS.concat [BS.pack [fromIntegral (BS.length k), fromIntegral (BS.length v)], k, v])
    innerEntry (k, PageNo c)
      | BS.length k < 1 || BS.length k > maxKeyBytes = Left (KeyLength (BS.length k))
      | otherwise = Right (BS.concat [BS.singleton (fromIntegral (BS.length k)), k, le64 c])

-- | Decode and fully validate one page. The arguments are the identity the page
-- must be bound to, the number of pages in the page space (the bound of every
-- reference), the page number it was read for, and the bytes.
decodePage ∷ StoreIdentity → Word64 → PageNo → ByteString → Either PageError Page
decodePage ident total expected bs
  | BS.length bs < pageSize = Left (ShortPage (BS.length bs))
  | BS.length bs > pageSize = Left (OversizedPage (BS.length bs))
  | stored /= actual = Left (BadChecksum stored actual)
  | BS.take 4 bs /= BC.pack "HTRP" = Left BadMagic
  | version /= formatVersion = Left (UnsupportedVersion version)
  | otherwise = do
      kind ← if rawKind >= 1 && rawKind <= 3 then Right rawKind else Left (UnsupportedKind rawKind)
      tree ← maybe (Left (UnsupportedTree rawTree)) Right (treeFromCode rawTree)
      let ArenaId arena = siArena ident
      if getLe64 bs 8 /= arena then Left WrongArena else Right ()
      if getLe64 bs 16 /= siSource ident then Left WrongSource else Right ()
      let no = PageNo (getLe64 bs 24)
      if no /= expected then Left (WrongPageNumber expected no) else Right ()
      if BS.index bs 33 /= 0 || getLe16 bs 38 /= 0 then Left NonZeroReserved else Right ()
      let level = fromIntegral (BS.index bs 32) ∷ Int
          count = fromIntegral (getLe16 bs 34) ∷ Int
          used = fromIntegral (getLe16 bs 36) ∷ Int
      if used < pageHeaderBytes || used > pageChecksumOffset then Left (BadUsedBytes used) else Right ()
      if count < 1 then Left (BadCount count) else Right ()
      if BS.any (/= 0) (BS.take (pageChecksumOffset - used) (BS.drop used bs)) then Left NonZeroPadding else Right ()
      let payload = BS.take (used - pageHeaderBytes) (BS.drop pageHeaderBytes bs)
      body ← case kind of
        1 → do
          if level /= 0 then Left (BadLevel level) else Right ()
          Leaf <$> leafEntries count payload
        2 → do
          if level < 1 || level > maxLevel then Left (BadLevel level) else Right ()
          Inner <$> innerEntries no count payload
        _ → do
          if level /= 0 || tree /= TreeRetire then Left (BadLevel level) else Right ()
          uncurry List <$> listEntries no count payload
      let page = Page tree level no body
      validateBody tree total page
      Right page
  where
    stored = getLe32 bs pageChecksumOffset
    actual = crc32c (BS.take pageChecksumOffset bs)
    version = getLe16 bs 4
    rawKind = BS.index bs 6
    rawTree = BS.index bs 7
    leafEntries n payload = go n payload []
      where
        go 0 rest acc
          | BS.null rest = Right (reverse acc)
          | otherwise = Left (BadLength (BS.length rest))
        go k rest acc = case BS.unpack (BS.take 2 rest) of
          [kl, vl]
            | kl < 1 || fromIntegral kl > maxKeyBytes → Left (KeyLength (fromIntegral kl))
            | fromIntegral vl > maxValueBytes → Left (ValueLength (fromIntegral vl))
            | BS.length rest < 2 + fromIntegral kl + fromIntegral vl → Left (BadLength (BS.length rest))
            | otherwise →
                let body = BS.drop 2 rest
                    key = BS.take (fromIntegral kl) body
                    val = BS.take (fromIntegral vl) (BS.drop (fromIntegral kl) body)
                 in go (k - 1 ∷ Int) (BS.drop (fromIntegral kl + fromIntegral vl) body) ((key, val) : acc)
          _ → Left (BadLength (BS.length rest))
    innerEntries self n payload = go n payload []
      where
        go 0 rest acc
          | BS.null rest = Right (reverse acc)
          | otherwise = Left (BadLength (BS.length rest))
        go k rest acc = case BS.uncons rest of
          Just (kl, body)
            | kl < 1 || fromIntegral kl > maxKeyBytes → Left (KeyLength (fromIntegral kl))
            | BS.length body < fromIntegral kl + 8 → Left (BadLength (BS.length rest))
            | otherwise →
                let key = BS.take (fromIntegral kl) body
                    child = PageNo (getLe64 body (fromIntegral kl))
                 in if refOk self child
                      then go (k - 1 ∷ Int) (BS.drop (fromIntegral kl + 8) body) ((key, child) : acc)
                      else Left (BadReference child)
          Nothing → Left (BadLength 0)
    listEntries self n payload
      | BS.length payload /= 8 + 8 * n = Left (BadLength (BS.length payload))
      | getLe64 payload 0 < 1 = Left MalformedValue
      | otherwise =
          let ps = [PageNo (getLe64 payload (8 + 8 * i)) | i ← [0 .. n - 1]]
           in case filter (not . refOk self) ps of
                (bad : _) → Left (BadReference bad)
                [] → Right (getLe64 payload 0, ps)
    refOk self child@(PageNo c) = child /= self && c < total

-- | The body of a page buffer that 'decodePage' already validated, parsed again without
-- re-checking: a window keeps the validated buffer (4 KiB) and not a list of entries,
-- so its memory is the page and not a pointer structure around it.
bodyOfValid ∷ ByteString → Body
bodyOfValid bs = case BS.index bs 6 of
  1 → Leaf (leaf count payload)
  2 → Inner (inner count payload)
  _ → List (getLe64 payload 0) [PageNo (getLe64 payload (8 + 8 * i)) | i ← [0 .. count - 1]]
  where
    count = fromIntegral (getLe16 bs 34) ∷ Int
    used = fromIntegral (getLe16 bs 36) ∷ Int
    payload = BS.take (used - pageHeaderBytes) (BS.drop pageHeaderBytes bs)
    leaf 0 _ = []
    leaf n p = case BS.unpack (BS.take 2 p) of
      [kl, vl] →
        let body = BS.drop 2 p
            k = BS.take (fromIntegral kl) body
            v = BS.take (fromIntegral vl) (BS.drop (fromIntegral kl) body)
         in (k, v) : leaf (n - 1 ∷ Int) (BS.drop (fromIntegral kl + fromIntegral vl) body)
      _ → []
    inner 0 _ = []
    inner n p = case BS.uncons p of
      Just (kl, body) →
        (BS.take (fromIntegral kl) body, PageNo (getLe64 body (fromIntegral kl))) : inner (n - 1 ∷ Int) (BS.drop (fromIntegral kl + 8) body)
      Nothing → []

-- | A node's entries packed into one byte string (the form an overlay page is kept in):
-- leaf entries as @keyLen valueLen key value@, internal entries as @keyLen key tag
-- target(8)@ where the tag says whether the target is a committed page (0) or an
-- overlay page (1). One packed page costs its bytes and a small header, not a list
-- cell, a pair and two string headers per entry.
packBody ∷ Either [(ByteString, ByteString)] [(ByteString, (Word8, Word64))] → ByteString
packBody (Left es) = BS.concat [BS.concat [BS.pack [fromIntegral (BS.length k), fromIntegral (BS.length v)], k, v] | (k, v) ← es]
packBody (Right es) = BS.concat [BS.concat [BS.singleton (fromIntegral (BS.length k)), k, BS.singleton t, le64 c] | (k, (t, c)) ← es]

-- | The inverse of 'packBody' for @count@ entries of the stated kind.
unpackBody ∷ Bool → Int → ByteString → Either [(ByteString, ByteString)] [(ByteString, (Word8, Word64))]
unpackBody isLeaf count0 payload0
  | isLeaf = Left (leaf count0 payload0)
  | otherwise = Right (inner count0 payload0)
  where
    leaf 0 _ = []
    leaf n p = case BS.unpack (BS.take 2 p) of
      [kl, vl] →
        let body = BS.drop 2 p
            k = BS.take (fromIntegral kl) body
            v = BS.take (fromIntegral vl) (BS.drop (fromIntegral kl) body)
         in (k, v) : leaf (n - 1 ∷ Int) (BS.drop (fromIntegral kl + fromIntegral vl) body)
      _ → []
    inner 0 _ = []
    inner n p = case BS.uncons p of
      Just (kl, body) →
        let k = BS.take (fromIntegral kl) body
            rest = BS.drop (fromIntegral kl) body
         in case BS.uncons rest of
              Just (t, tgt) → (k, (t, getLe64 tgt 0)) : inner (n - 1 ∷ Int) (BS.drop 8 tgt)
              Nothing → []
      Nothing → []

-- | Whether an internal page's separator is a well-formed key of its tree: a record tree's
-- key decodes (a column, level and category within the coordinate range), a free extent's key
-- is a page number, a retirement tree's key is a version or a retired page's marker and number.
-- A separator that is not would make a descent skip records that exist and answer absent.
validateSeparator ∷ TreeId → ByteString → Either PageError ()
validateSeparator tree k = case tree of
  TreeFree → ok (BS.length k == 8)
  TreeRetire → ok (BS.length k == 8 || (BS.length k == 9 && BS.index k 0 == 0xFF))
  _ → ok (decodeKey tree k /= Nothing)
  where
    ok b = if b then Right () else Left MalformedKey

-- | The structure inside a decoded page: ordering and the checks that need only
-- the page itself.
validateBody ∷ TreeId → Word64 → Page → Either PageError ()
validateBody tree total (Page _ _ _ body) = case body of
  Leaf es → do
    increasing (map fst es)
    mapM_ (uncurry (validateEntry tree total)) es
    adjacent tree es
  Inner es → do
    increasing (map fst es)
    -- a separator is a key of the tree it indexes (the least key its child may hold)
    mapM_ (validateSeparator tree . fst) es
  List _ ps → if and (zipWith (<) ps (drop 1 ps)) then Right () else Left KeyOrder
  where
    increasing ks = if and (zipWith (<) ks (drop 1 ks)) then Right () else Left KeyOrder
    adjacent TreeRuns es = pairs runOk es
    adjacent TreeFree es = pairs freeOk es
    adjacent _ _ = Right ()
    pairs f es = case es of
      (a : b : rest) → f a b >> pairs f (b : rest)
      _ → Right ()
    -- Runs of one column are disjoint and never adjacent: they are coalesced.
    runOk (ka, va) (kb, _) = do
      ka' ← maybe (Left MalformedKey) Right (decodeKey TreeRuns ka)
      kb' ← maybe (Left MalformedKey) Right (decodeKey TreeRuns kb)
      va' ← maybe (Left MalformedValue) Right (decodeValue ka' va)
      case (ka', va', kb') of
        (KeyRun ca _, RecRun hi, KeyRun cb lo2)
          | ca == cb && lo2 <= hi → Left KeyOrder
        _ → Right ()
    -- Free extents are disjoint and coalesced: a gap separates neighbours.
    freeOk (ka, va) (kb, _) = case (decodeFree total ka va, BS.length kb == 8) of
      (Just (s, l), True) | getBe64 kb 0 <= s + l → Left KeyOrder
      _ → Right ()
