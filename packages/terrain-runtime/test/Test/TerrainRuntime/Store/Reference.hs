-- | The independent references of the store's specs.
--
-- Nothing here calls the production encoder, decoder, tree or allocator to decide
-- what is expected:
--
-- * 'refCrc32c' is a bitwise CRC32C written from the polynomial, not the table of
--   the production module.
-- * 'parsePage' reads a page's bytes by the documented layout with its own helpers.
-- * 'walkTree' and 'ownership' traverse the committed roots over the pages as the
--   disk holds them and decide, from the parsed bytes alone, which pages are live,
--   retired, free or loose, that they partition @[0, hw)@ exactly, that every
--   tree is ordered, bounded by its parents' separators and a quarter full, and
--   that the store's counters equal what the traversal found. Freeing a shared page
--   fails the partition, not merely a count.
-- * 'Disk' is the bounded page provider: a map of written pages that a test can
--   stop accepting writes.
--
-- The one thing the suite takes from the production code is the data it feeds it:
-- a reference 'Data.Map' of the expected records.
module Test.TerrainRuntime.Store.Reference
  ( -- * Random
    Rng
  , mkRng
  , nextWord
  , below
  , pick
  , shuffle

    -- * Checksum and bytes
  , refCrc32c
  , le16', le32', le64', be64'
  , getLe16', getLe32', getLe64', getBe64'

    -- * The disk
  , Disk
  , emptyDisk
  , diskRead
  , diskWrite
  , diskPages
  , diskWrites

    -- * Parsing
  , RefBody (..)
  , RefPage (..)
  , parsePage

    -- * Traversal
  , TreeWalk (..)
  , walkTree
  , Ownership (..)
  , ownership
  ) where

import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Word (Word16, Word32, Word64, Word8)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), TreeId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.State (Roots (..))

-- ---------------------------------------------------------------------------
-- Random

-- | A reproducible generator (xorshift64*). Every generated sequence of the suite
-- names the seed that makes it, so a failure is replayed by its seed.
newtype Rng = Rng Word64
  deriving stock (Eq, Show)

mkRng ∷ Word64 → Rng
mkRng s = Rng (if s == 0 then 0x9E3779B97F4A7C15 else s)

nextWord ∷ Rng → (Word64, Rng)
nextWord (Rng s0) =
  let s1 = s0 `xor` (s0 `shiftR` 12)
      s2 = s1 `xor` (s1 `shiftL` 25)
      s3 = s2 `xor` (s2 `shiftR` 27)
   in (s3 * 0x2545F4914F6CDD1D, Rng s3)

-- | A number in @[0, n)@ (@n@ at least 1).
below ∷ Word64 → Rng → (Word64, Rng)
below n g = let (w, g') = nextWord g in (w `mod` max 1 n, g')

pick ∷ [a] → Rng → (a, Rng)
pick xs g = let (i, g') = below (fromIntegral (length xs)) g in (xs !! fromIntegral i, g')

shuffle ∷ [a] → Rng → ([a], Rng)
shuffle xs g0 = go xs g0 []
  where
    go [] g acc = (acc, g)
    go ys g acc = let (i, g') = below (fromIntegral (length ys)) g
                      (a, b) = splitAt (fromIntegral i) ys
                   in case b of
                        (z : zs) → go (a ++ zs) g' (z : acc)
                        [] → (acc, g')

-- ---------------------------------------------------------------------------
-- Checksum and bytes

-- | CRC32C, bit by bit from the reflected Castagnoli polynomial.
refCrc32c ∷ ByteString → Word32
refCrc32c = complement . BS.foldl' byte 0xFFFFFFFF
  where
    byte ∷ Word32 → Word8 → Word32
    byte crc b = bit (bit (bit (bit (bit (bit (bit (bit (crc `xor` fromIntegral b))))))))
    bit ∷ Word32 → Word32
    bit c = if c .&. 1 == 1 then (c `shiftR` 1) `xor` 0x82F63B78 else c `shiftR` 1

le16' ∷ Word16 → ByteString
le16' w = BS.pack [fromIntegral w, fromIntegral (w `shiftR` 8)]

le32' ∷ Word32 → ByteString
le32' w = BS.pack [fromIntegral (w `shiftR` (8 * i)) | i ← [0 .. 3]]

le64' ∷ Word64 → ByteString
le64' w = BS.pack [fromIntegral (w `shiftR` (8 * i)) | i ← [0 .. 7]]

be64' ∷ Word64 → ByteString
be64' w = BS.reverse (le64' w)

getLe16' ∷ ByteString → Int → Word16
getLe16' b o = fromIntegral (BS.index b o) .|. (fromIntegral (BS.index b (o + 1)) `shiftL` 8)

getLe32' ∷ ByteString → Int → Word32
getLe32' b o = sum [fromIntegral (BS.index b (o + i)) `shiftL` (8 * i) | i ← [0 .. 3]]

getLe64' ∷ ByteString → Int → Word64
getLe64' b o = sum [fromIntegral (BS.index b (o + i)) `shiftL` (8 * i) | i ← [0 .. 7]]

getBe64' ∷ ByteString → Int → Word64
getBe64' b o = sum [fromIntegral (BS.index b (o + 7 - i)) `shiftL` (8 * i) | i ← [0 .. 7]]

-- ---------------------------------------------------------------------------
-- The disk

-- | The pages written so far, and how many writes were accepted.
data Disk = Disk (Map Word64 ByteString) Int

emptyDisk ∷ Disk
emptyDisk = Disk Map.empty 0

diskRead ∷ Disk → PageNo → Maybe ByteString
diskRead (Disk m _) (PageNo p) = Map.lookup p m

diskWrite ∷ PageNo → ByteString → Disk → Disk
diskWrite (PageNo p) bs (Disk m n) = Disk (Map.insert p bs m) (n + 1)

diskPages ∷ Disk → Map Word64 ByteString
diskPages (Disk m _) = m

diskWrites ∷ Disk → Int
diskWrites (Disk _ n) = n

-- ---------------------------------------------------------------------------
-- Parsing

data RefBody
  = RefLeaf [(ByteString, ByteString)]
  | RefInner [(ByteString, Word64)]
  | RefList Word64 [Word64]
  deriving stock (Eq, Show)

data RefPage = RefPage
  { rpTree ∷ !Int
  , rpLevel ∷ !Int
  , rpNo ∷ !Word64
  , rpBody ∷ !RefBody
  , rpPayload ∷ !Int
  }
  deriving stock (Eq, Show)

-- | Parse a page by the documented layout: magic, version 1, kind, tree, the arena
-- and source identities, the page's own number, level, count, payload end and the
-- checksum of the first 4,092 bytes.
parsePage ∷ Word64 → Word64 → ByteString → Either String RefPage
parsePage arena source bs
  | BS.length bs /= 4096 = Left "length"
  | getLe32' bs 4092 /= refCrc32c (BS.take 4092 bs) = Left "checksum"
  | BS.take 4 bs /= BC.pack "HTRP" = Left "magic"
  | getLe16' bs 4 /= 1 = Left "version"
  | getLe64' bs 8 /= arena = Left "arena"
  | getLe64' bs 16 /= source = Left "source"
  | otherwise = do
      let kind = BS.index bs 6
          tree = fromIntegral (BS.index bs 7)
          level = fromIntegral (BS.index bs 32)
          count = fromIntegral (getLe16' bs 34) ∷ Int
          used = fromIntegral (getLe16' bs 36) ∷ Int
          payload = BS.take (used - 40) (BS.drop 40 bs)
      body ← case kind of
        1 → RefLeaf <$> leaf count payload
        2 → RefInner <$> inner count payload
        3 → Right (RefList (getLe64' payload 0) [getLe64' payload (8 + 8 * i) | i ← [0 .. count - 1]])
        _ → Left "kind"
      Right (RefPage tree level (getLe64' bs 24) body (used - 40))
  where
    leaf 0 _ = Right []
    leaf n p = do
      if BS.length p < 2 then Left "short leaf" else Right ()
      let kl = fromIntegral (BS.index p 0)
          vl = fromIntegral (BS.index p 1)
      if BS.length p < 2 + kl + vl then Left "short entry" else Right ()
      rest ← leaf (n - 1 ∷ Int) (BS.drop (2 + kl + vl) p)
      Right ((BS.take kl (BS.drop 2 p), BS.take vl (BS.drop (2 + kl) p)) : rest)
    inner 0 _ = Right []
    inner n p = do
      if BS.null p then Left "short inner" else Right ()
      let kl = fromIntegral (BS.index p 0)
      if BS.length p < 1 + kl + 8 then Left "short inner entry" else Right ()
      rest ← inner (n - 1 ∷ Int) (BS.drop (1 + kl + 8) p)
      Right ((BS.take kl (BS.drop 1 p), getLe64' p (1 + kl)) : rest)

-- ---------------------------------------------------------------------------
-- Traversal

-- | What a traversal of one tree found.
data TreeWalk = TreeWalk
  { twPages ∷ [Word64]
  , twLeaves ∷ [(ByteString, ByteString)]
  , twHeight ∷ !Int
  , twViolations ∷ [String]
  }
  deriving stock (Eq, Show)

-- | Walk a tree from its root over the pages the disk holds, checking from the
-- bytes alone: every page parses, its own number and level are what its parent
-- says, keys are strictly increasing and inside the parent's separators, and every
-- non-root node holds at least a quarter of a payload (4,052 / 4 bytes).
walkTree ∷ Word64 → Word64 → (PageNo → Maybe ByteString) → Maybe Word64 → TreeWalk
walkTree _ _ _ Nothing = TreeWalk [] [] 0 []
walkTree arena source rd (Just root) = go root Nothing Nothing Nothing True
  where
    go p lo hi expectLevel isRoot = case rd (PageNo p) of
      Nothing → TreeWalk [p] [] 0 ["missing page " <> show p]
      Just bs → case parsePage arena source bs of
        Left e → TreeWalk [p] [] 0 ["page " <> show p <> ": " <> e]
        Right pg →
          let own = [ "page " <> show p <> " claims number " <> show (rpNo pg) | rpNo pg /= p ]
              lvl = [ "page " <> show p <> " level " <> show (rpLevel pg) | Just l ← [expectLevel], l /= rpLevel pg ]
              occ = [ "page " <> show p <> " under-full: " <> show (rpPayload pg) | not isRoot, rpPayload pg < 4052 `div` 4 ]
           in case rpBody pg of
                RefLeaf es →
                  let ks = map fst es
                      order = [ "page " <> show p <> " leaf keys out of order" | not (strictly ks) ]
                      bounds = [ "page " <> show p <> " leaf outside bounds" | not (inside lo hi ks) ]
                   in TreeWalk [p] es 1 (own ++ lvl ++ occ ++ order ++ bounds)
                RefInner es →
                  let ks = map fst es
                      order = [ "page " <> show p <> " separators out of order" | not (strictly ks) ]
                      bounds = [ "page " <> show p <> " separators outside bounds" | not (inside lo hi ks) ]
                      kids = [ go c (Just k) (nextSep i es hi) (Just (rpLevel pg - 1)) False | (i, (k, c)) ← zip [0 ∷ Int ..] es ]
                   in TreeWalk
                        (p : concatMap twPages kids)
                        (concatMap twLeaves kids)
                        (1 + maximum (0 : map twHeight kids))
                        (own ++ lvl ++ occ ++ order ++ bounds ++ concatMap twViolations kids)
                RefList _ _ → TreeWalk [p] [] 0 ["page " <> show p <> " is a list inside a tree"]
    nextSep i es hi = if i + 1 < length es then Just (fst (es !! (i + 1))) else hi
    strictly ks = and (zipWith (<) ks (drop 1 ks))
    inside lo hi ks = all (\k → maybe True (<= k) lo && maybe True (k <) hi) ks

-- | The partition of the page space the store claims, found from the disk.
data Ownership = Ownership
  { owLive ∷ [Word64]
  , owRetired ∷ [Word64]
  , owFree ∷ [Word64]
  , owLoose ∷ [Word64]
  , owViolations ∷ [String]
  , owHeights ∷ [(TreeId, Int)]
  , owLeaves ∷ [(TreeId, [(ByteString, ByteString)])]
  }
  deriving stock (Eq, Show)

-- | Decide, from the disk and the committed roots alone, the state of every page,
-- and report every way the store's counters or the partition disagree with it.
ownership ∷ Word64 → Word64 → Store → (PageNo → Maybe ByteString) → Ownership
ownership arena source store rd = Ownership live retired free loose violations heights leaves
  where
    roots = storeRoots store
    treeRoot t = (\(PageNo p) → p) <$> committedRoot store t
    trees = [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire]
    walks = [(t, walkTree arena source rd (treeRoot t)) | t ← trees]
    walkOf t = maybe (TreeWalk [] [] 0 []) id (lookup t walks)
    retireEntries = [(getBe64' k 0, getBe64' v 0, getLe16' v 8, getLe16' v 10) | (k, v) ← twLeaves (walkOf TreeRetire), BS.length k == 8, BS.length v == 12]
    listPages = [lp | (_, lp, _, _) ← retireEntries]
    -- the retirement tree also indexes every retired page by number under its entry's version
    indexed = sortOn id [(getBe64' k 1, getBe64' v 0) | (k, v) ← twLeaves (walkOf TreeRetire), BS.length k == 9, BS.length v == 8]
    expectedIndex = sortOn id [(p, ver) | (ver, lp, _, _) ← retireEntries, Just (Right ps) ← [lookup lp listWalk], p ← ps]
    listWalk = [(lp, parseList ver lp c d) | (ver, lp, c, d) ← retireEntries]
    parseList ver lp c d = case rd (PageNo lp) of
      Nothing → Left ("retirement list page missing " <> show lp)
      Just bs → case parsePage arena source bs of
        Left e → Left ("retirement list page " <> show lp <> ": " <> e)
        Right pg → case rpBody pg of
          RefList stamp ps | stamp == ver && length ps == fromIntegral c → Right (drop (fromIntegral d) ps)
          _ → Left ("retirement list page " <> show lp <> " does not match its entry")
    retired = concat [ps | (_, Right ps) ← listWalk]
    free = concat [[s .. s + l - 1] | (k, v) ← twLeaves (walkOf TreeFree), BS.length k == 8, BS.length v == 8, let s = getBe64' k 0, let l = getBe64' v 0]
    loose = [p | PageNo p ← rLoose roots]
    live = concatMap (twPages . snd) walks ++ listPages
    hw = rHw roots
    allPages = live ++ retired ++ free ++ loose
    dup = [p | (p, n) ← Map.toList (Map.fromListWith (+) [(p, 1 ∷ Int) | p ← allPages]), n > 1]
    covered = Set.fromList allPages
    missing = [p | hw > 0, p ← [0 .. hw - 1], not (Set.member p covered)]
    beyond = [p | p ← allPages, p >= hw]
    freeCoalesced = and (zipWith (\(s1, l1) (s2, _) → s1 + l1 < s2) extents (drop 1 extents))
    extents = sortOn fst [(getBe64' k 0, getBe64' v 0) | (k, v) ← twLeaves (walkOf TreeFree), BS.length k == 8, BS.length v == 8]
    violations =
      concatMap (twViolations . snd) walks
        ++ [e | (_, Left e) ← listWalk]
        ++ [ "the retired-page index does not match the retirement lists: " <> show (length indexed) <> " indexed, " <> show (length expectedIndex) <> " listed" | indexed /= expectedIndex ]
        ++ [ "page owned twice: " <> show p | p ← take 5 dup ]
        ++ [ "page below hw owned by nobody: " <> show p | p ← take 5 missing ]
        ++ [ "page at or above hw owned: " <> show p | p ← take 5 beyond ]
        ++ [ "live counter " <> show (rLivePages roots) <> " /= " <> show (length live) | fromIntegral (rLivePages roots) /= length live ]
        ++ [ "retired counter " <> show (rRetiredPages roots) <> " /= " <> show (length retired) | fromIntegral (rRetiredPages roots) /= length retired ]
        ++ [ "free counter " <> show (rFreePages roots) <> " /= " <> show (length free) | fromIntegral (rFreePages roots) /= length free ]
        ++ [ "free extents are not coalesced" | not freeCoalesced ]
    heights = [(t, twHeight w) | (t, w) ← walks]
    leaves = [(t, twLeaves w) | (t, w) ← walks]
