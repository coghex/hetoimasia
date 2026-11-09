-- | The byte form of every record the store keeps: #661's logical records, the
-- free extents of the allocator and the retirement entries.
--
-- Keys are encoded so that the lexicographic order of the bytes is exactly the
-- order of the logical key, which lets one generic tree index every category:
-- a signed 64-bit number is written big-endian with its sign bit flipped, an
-- unsigned one big-endian, and a constructor or an optional field is a leading tag
-- byte that sorts as the constructor or @Nothing < Just@ does.
--
-- @
-- TreeRuns    key  x(8) y(8) lo(8)                       24   -- Column x y, lower end
--             val  hi(8)                                  8
-- TreeLinks   key  0 tile(24) 3 * (present(1) coord(8))  52   -- SrcNode
--                  1 x(8) y(8) lo(8)                      25   -- RunNode
--             val  0 size(8) known(1)                    10   -- RecRoot
--                  1 node-key                         26..53   -- RecChild
-- TreeTodo    key  sequence(8)                            8
--             val  tile(24) done(1)                      25   -- done in 1 .. 6
-- TreeFree    key  start page(8)                          8
--             val  length(8)                              8   -- at least 1
-- TreeRetire  key  version(8)                             8   -- the version that replaced the pages
--             val  list page(8) count(2) done(2)         12   -- 1 <= count <= 505, done < count
-- @
--
-- A value that decodes is also checked: a tile and a column are in the supported
-- range, an interval has @lo < hi@ inside the level limits, a class size is at
-- least 1, a flag is 0 or 1, an absent optional coordinate is written as zero
-- bytes, and no byte is left over. Everything is bounded by the format's
-- 'maxKeyBytes' and 'maxValueBytes'.
--
-- State, ownership and lifetime: none. Pure functions.
module Hetoimasia.Terrain.Runtime.Store.Internal.Records
  ( treeOfKey
  , encodeKey
  , encodeValue
  , decodeKey
  , decodeValue
  , validateEntry
  , encodeFree
  , decodeFree
  , encodeRetire
  , decodeRetire
  , Retire (..)
  , be64
  , getBe64
  , le16
  , le32
  , le64
  , getLe16
  , getLe32
  , getLe64
  , levelMin
  , levelMaxExclusive
  ) where

import Data.Bits (shiftL, shiftR, xor, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Word (Word16, Word32, Word64)
import Hetoimasia.Terrain.Cell (Column (..), mkColumn)
import Hetoimasia.Terrain.Connectivity (Axis (..), keyOrigin, keyParameters, mkComponentKey)
import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord (..), axisFromInteger, axisValue, tileCoord)
import Hetoimasia.Terrain.Discovery (Node (..), Record (..), RecordKey (..), Root (..), Todo (..), edgeCount)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format

-- | The lowest supported level, @-2^62@.
levelMin ∷ Integer
levelMin = negate (2 ^ (62 ∷ Int))

-- | One past the highest supported level, @2^62@.
levelMaxExclusive ∷ Integer
levelMaxExclusive = 2 ^ (62 ∷ Int)

-- ---------------------------------------------------------------------------
-- Byte helpers

-- | A big-endian unsigned 64-bit number.
be64 ∷ Word64 → ByteString
be64 w = BS.pack [fromIntegral (w `shiftR` s) | s ← [56, 48 .. 0]]

getBe64 ∷ ByteString → Int → Word64
getBe64 bs off = foldl (\acc i → (acc `shiftL` 8) .|. fromIntegral (BS.index bs (off + i))) 0 [0 .. 7]

le16 ∷ Word16 → ByteString
le16 w = BS.pack [fromIntegral w, fromIntegral (w `shiftR` 8)]

le32 ∷ Word32 → ByteString
le32 w = BS.pack [fromIntegral (w `shiftR` s) | s ← [0, 8, 16, 24]]

le64 ∷ Word64 → ByteString
le64 w = BS.pack [fromIntegral (w `shiftR` s) | s ← [0, 8 .. 56]]

getLe16 ∷ ByteString → Int → Word16
getLe16 bs off = fromIntegral (BS.index bs off) .|. (fromIntegral (BS.index bs (off + 1)) `shiftL` 8)

getLe32 ∷ ByteString → Int → Word32
getLe32 bs off = foldr (\i acc → (acc `shiftL` 8) .|. fromIntegral (BS.index bs (off + i))) 0 [0 .. 3]

getLe64 ∷ ByteString → Int → Word64
getLe64 bs off = foldr (\i acc → (acc `shiftL` 8) .|. fromIntegral (BS.index bs (off + i))) 0 [0 .. 7]

-- | A signed number as order-preserving big-endian bytes.
biased ∷ Int64 → ByteString
biased x = be64 (fromIntegral x `xor` 0x8000000000000000)

getBiased ∷ ByteString → Int → Int64
getBiased bs off = fromIntegral (getBe64 bs off `xor` 0x8000000000000000)

-- ---------------------------------------------------------------------------
-- Logical keys

-- | The tree a logical key belongs to.
treeOfKey ∷ RecordKey → TreeId
treeOfKey (KeyRun _ _) = TreeRuns
treeOfKey (KeyLink _) = TreeLinks
treeOfKey (KeyTodo _) = TreeTodo

tileBytes ∷ TileCoord → ByteString
tileBytes (TileCoord x y z) = BS.concat [biased (axisValue x), biased (axisValue y), biased (axisValue z)]

getTile ∷ ByteString → Int → Maybe TileCoord
getTile bs off =
  either (const Nothing) Just $
    tileCoord (toInteger (getBiased bs off)) (toInteger (getBiased bs (off + 8))) (toInteger (getBiased bs (off + 16)))

columnBytes ∷ Column → ByteString
columnBytes (Column x y) = BS.append (biased (axisValue x)) (biased (axisValue y))

getColumn ∷ ByteString → Int → Maybe Column
getColumn bs off = either (const Nothing) Just (mkColumn (toInteger (getBiased bs off)) (toInteger (getBiased bs (off + 8))))

optionalBytes ∷ Maybe AxisCoord → ByteString
optionalBytes Nothing = BS.replicate 9 0
optionalBytes (Just c) = BS.cons 1 (biased (axisValue c))

nodeBytes ∷ Node → ByteString
nodeBytes (SrcNode key) =
  BS.concat
    [ BS.singleton 0
    , tileBytes (keyOrigin key)
    , BS.concat [optionalBytes (lookup axis params) | axis ← [AxisX, AxisY, AxisZ]]
    ]
  where
    params = keyParameters key
nodeBytes (RunNode col lo) = BS.concat [BS.singleton 1, columnBytes col, biased lo]

getNode ∷ ByteString → Maybe Node
getNode bs = case BS.uncons bs of
  Just (0, _) | BS.length bs == 52 → do
    origin ← getTile bs 1
    ps ← sequence [optionalAt (25 + 9 * i) axis | (i, axis) ← zip [0 ..] [AxisX, AxisY, AxisZ]]
    SrcNode <$> mkComponentKey origin [p | Just p ← ps]
  Just (1, _) | BS.length bs == 25 → RunNode <$> getColumn bs 1 <*> Just (getBiased bs 17)
  _ → Nothing
  where
    optionalAt off axis = case BS.index bs off of
      0 | BS.all (== 0) (BS.take 8 (BS.drop (off + 1) bs)) → Just Nothing
      1 → case axisFromInteger (toInteger (getBiased bs (off + 1))) of
        Right c → Just (Just (axis, c))
        Left _ → Nothing
      _ → Nothing

-- | The ordered key bytes of a logical key.
encodeKey ∷ RecordKey → ByteString
encodeKey (KeyRun col lo) = BS.append (columnBytes col) (biased lo)
encodeKey (KeyLink node) = nodeBytes node
encodeKey (KeyTodo n) = be64 n

-- | The logical key a tree's key bytes name, if they are well formed.
decodeKey ∷ TreeId → ByteString → Maybe RecordKey
decodeKey TreeRuns bs
  | BS.length bs == 24 = do
      col ← getColumn bs 0
      let lo = getBiased bs 16
      if toInteger lo >= levelMin then Just (KeyRun col lo) else Nothing
decodeKey TreeLinks bs = KeyLink <$> getNode bs
decodeKey TreeTodo bs
  | BS.length bs == 8 = Just (KeyTodo (getBe64 bs 0))
decodeKey _ _ = Nothing

-- | The value bytes of a logical record.
encodeValue ∷ Record → ByteString
encodeValue (RecRun hi) = biased hi
encodeValue (RecRoot (Root size known)) = BS.concat [BS.singleton 0, be64 size, BS.singleton (if known then 1 else 0)]
encodeValue (RecChild node) = BS.cons 1 (nodeBytes node)
encodeValue (RecTodo (Todo tile done)) = BS.snoc (tileBytes tile) done

-- | The record a value names under a key, if the value is well formed and of the
-- kind the key requires.
decodeValue ∷ RecordKey → ByteString → Maybe Record
decodeValue (KeyRun _ lo) bs
  | BS.length bs == 8 =
      let hi = getBiased bs 0
       in if toInteger hi <= levelMaxExclusive && lo < hi then Just (RecRun hi) else Nothing
decodeValue (KeyLink node) bs = case BS.uncons bs of
  Just (0, rest)
    | BS.length rest == 9
    , let size = getBe64 rest 0
    , size >= 1 → case BS.index rest 8 of
        0 → Just (RecRoot (Root size False))
        1 → Just (RecRoot (Root size True))
        _ → Nothing
  Just (1, rest) → do
    parent ← getNode rest
    if parent /= node then Just (RecChild parent) else Nothing
  _ → Nothing
decodeValue (KeyTodo _) bs
  | BS.length bs == 25 = do
      tile ← getTile bs 0
      let done = BS.index bs 24
      if done >= 1 && done < edgeCount then Just (RecTodo (Todo tile done)) else Nothing
decodeValue _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Bookkeeping records

-- | A free extent's bytes: key start, value length.
encodeFree ∷ Word64 → Word64 → (ByteString, ByteString)
encodeFree start len = (be64 start, be64 len)

-- | A free extent from its bytes, with the page space it must lie in.
decodeFree ∷ Word64 → ByteString → ByteString → Maybe (Word64, Word64)
decodeFree total k v
  | BS.length k == 8 && BS.length v == 8
  , let start = getBe64 k 0
  , let len = getBe64 v 0
  , len >= 1
  , toInteger start + toInteger len <= toInteger total =
      Just (start, len)
decodeFree _ _ _ = Nothing

-- | A retirement entry: the retirement list page, how many pages it holds and how
-- many have been reclaimed.
data Retire = Retire
  { retList ∷ !PageNo
  , retCount ∷ !Word16
  , retDone ∷ !Word16
  }
  deriving stock (Eq, Show)

encodeRetire ∷ Word64 → Retire → (ByteString, ByteString)
encodeRetire version (Retire (PageNo p) c d) = (be64 version, BS.concat [be64 p, le16 c, le16 d])

decodeRetire ∷ Word64 → ByteString → ByteString → Maybe (Word64, Retire)
decodeRetire total k v
  | BS.length k == 8 && BS.length v == 12
  , let version = getBe64 k 0
  , version >= 1
  , let p = getBe64 v 0
  , p < total
  , let c = getLe16 v 8
  , let d = getLe16 v 10
  , c >= 1 && fromIntegral c <= maxListPages
  , d < c =
      Just (version, Retire (PageNo p) c d)
decodeRetire _ _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Entry validation

-- | Whether a leaf entry of a tree is well formed, with the page space the store
-- has (for the bookkeeping trees' page references).
validateEntry ∷ TreeId → Word64 → ByteString → ByteString → Either PageError ()
validateEntry tree total k v = case tree of
  TreeFree → maybe (Left MalformedValue) (const (Right ())) (decodeFree total k v)
  TreeRetire → maybe (Left MalformedValue) (const (Right ())) (decodeRetire total k v)
  _ → do
    key ← maybe (Left MalformedKey) Right (decodeKey tree k)
    _ ← maybe (Left MalformedValue) Right (decodeValue key v)
    Right ()
