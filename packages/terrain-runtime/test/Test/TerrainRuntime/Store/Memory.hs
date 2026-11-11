-- | What the accounted-bytes constants of the store really retain.
--
-- Every figure a plan's RAM charge, a window bound or the admission is sized from is a constant of bytes. Reasoned from an ENCODED
-- size, it counted the wrong thing whenever the thing retained is a Haskell heap structure (the read facts: 152 charged for 576
-- retained). Each constant is therefore measured against the LARGEST valid instance of what it stands for, forced and held, by the
-- live heap a major collection leaves (the method of the suite's allocation evidence): the measured bytes per instance must not
-- exceed what is accounted for it.
--
-- "Largest valid instance" is a claim about a TYPE, so it is checked, not assumed. A row measures EVERY variant of the type (each
-- constructor, each optional field populated and not, each list at its cap, numbers at the largest magnitude the codec admits: all
-- coordinates are 64-bit and bounded by the codec, so no field is an unbounded integer and none is a bignum; they are built from
-- values near 2^62 so no box is shared the way a small @Int@ is), asserts that EVERY variant is within the accounted figure, and
-- asserts that the variant the row names as the largest is the largest measured. A row's accounted figure is the maximum over its
-- variants with a stated margin.
module Test.TerrainRuntime.Store.Memory (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import Data.ByteString.Short (toShort)
import qualified Data.ByteString.Short as SBS
import Data.IORef (newIORef, readIORef)
import Data.List (maximumBy)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import qualified Data.Set as Set
import Data.Int (Int64)
import Data.Word (Word64)
import GHC.Stats (RTSStats (..), GCDetails (..), getRTSStats)
import Hetoimasia.Terrain.Connectivity (Axis (..), ComponentKey, keyParameters, mkComponentKey)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisFromInteger)
import Hetoimasia.Terrain.Discovery (Authority (..), Header (..), Node (..), ReadSet (..), Record (..), RecordKey (..), Root (..), Todo (..), headerBytes, maxBatchUpdates, worstEdgeReads, worstEditReads)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page
import Hetoimasia.Terrain.Runtime.Store.Admission (worstTransactionCharge)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (PageState (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RamCharge (..), worstChargeWith)
import Hetoimasia.Terrain.Runtime.Store.Internal.Records
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import System.Mem (performMajorGC)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness

live ∷ IO Word64
live = performMajorGC >> performMajorGC >> (gcdetails_live_bytes . gc <$> getRTSStats)

-- | The live heap one element of a structure retains: the structure is built from @n@ distinct inputs, forced, held across a major
-- collection, and the growth of the live heap is divided by @n@. The inputs are built (and held) BEFORE the first reading, so what
-- is measured is the structure and not what it was made from.
retainedPer ∷ Int → [a] → (a → Int) → ([a] → IO b) → (b → IO Int) → IO Double
retainedPer n inputs sizeOf build force = do
  -- the inputs are forced all the way down first (a page's bytes included), so they are in the heap before the first reading
  _ ← evaluate (sum (map sizeOf inputs))
  heapBefore ← live
  structure ← build inputs
  -- held through an IORef across the collection: nothing can fuse the construction into the traversal, and the structure is
  -- reachable (and so counted) when the heap is read
  ref ← newIORef structure
  _ ← readIORef ref >>= force
  heapAfter ← live
  _ ← readIORef ref >>= force
  -- the inputs stay alive to here: when the structure shares or copies them, the measurement counts what the STRUCTURE adds, and a
  -- buffer that is both an input and (as a copy) part of the structure is not netted out when the input dies
  _ ← evaluate (length inputs)
  pure (fromIntegral (heapAfter - heapBefore) / fromIntegral n)
{-# NOINLINE retainedPer #-}

-- | One variant of what a row stands for, and the bytes one instance of it retains.
data Variant = Variant {varName ∷ String, varMeasured ∷ Double, varBudget ∷ Maybe Int}

-- | One accounted constant: what it stands for, what its LARGEST valid instance is and why (from the type), the variant that must
-- measure largest, the bytes accounted for one instance, and every variant measured. A row that names no largest variant holds
-- instances that are all the same size within a stated spread.
data Row = Row
  { rowName ∷ String
  , rowLargest ∷ String
  , rowExpect ∷ Maybe String
  , rowAccounted ∷ Int
  , rowVariants ∷ [Variant]
  }

rowMax ∷ Row → Variant
rowMax r = maximumBy (comparing varMeasured) (rowVariants r)

-- ---------------------------------------------------------------------------
-- Values at the largest magnitude, all distinct

-- | A number near the top of the coordinate range (@2^62 - 1@), distinct for each @i@.
big ∷ Int → Integer
big i = 4611686018427387903 - 11 * toInteger i

axisAt ∷ Int → AxisCoord
axisAt i = either (error . show) id (axisFromInteger (big i))

-- | A source component key with the first @p@ of its three optional coordinates populated.
compKey ∷ Int → Int → ComponentKey
compKey p i = fromMaybe (error "component key") (mkComponentKey (tileAt (big i) (big (i + 1)) (big (i + 2))) (take p [(AxisX, axisAt (i + 3)), (AxisY, axisAt (i + 4)), (AxisZ, axisAt (i + 5))]))

runNode ∷ Int → Node
runNode i = RunNode (columnAt (big i) (big (i + 1))) (fromInteger (big (i + 2)))

-- | Every kind of record key, and every kind of record, as a function of a distinct number.
keyKinds ∷ [(String, Int → RecordKey)]
keyKinds =
  [("run key", \i → runKey (big i) (big (i + 1)) (big (i + 2)))]
    <> [("source-node key, " <> show p <> " parameters", \i → KeyLink (SrcNode (compKey p i))) | p ← [0 .. 3]]
    <> [ ("run-node key", \i → KeyLink (runNode i))
       , ("todo key", \i → KeyTodo (fromInteger (big i)))
       ]

recordKinds ∷ [(String, Int → Record)]
recordKinds =
  [ ("run", \i → RecRun (fromInteger (big i)))
  , ("root", \i → RecRoot (Root (fromInteger (big i)) True))
  ]
    <> [("child, source node, " <> show p <> " parameters", \i → RecChild (SrcNode (compKey p (i + 7)))) | p ← [0 .. 3]]
    <> [ ("child, run node", \i → RecChild (runNode (i + 7)))
       , ("todo", \i → RecTodo (Todo (tileAt (big i) (big (i + 1)) (big (i + 2))) 6))
       ]

-- | The pairings of a key kind and a record kind a plan can hold: those the planner itself accepts (it checks every write by encoding
-- it and decoding it under its key).
validPairs ∷ [(String, Int → RecordKey, Int → Record)]
validPairs =
  [ (kn <> " with " <> rn, kf, rf)
  | (kn, kf) ← keyKinds
  , (rn, rf) ← recordKinds
  , decodeValue (kf 1) (encodeValue (rf 1)) == Just (rf 1)
  ]

-- | Forces every field of a key and a record (the encoders read all of them).
recordWeight ∷ (RecordKey, Maybe Record) → Int
recordWeight (k, v) = BS.length (encodeKey k) + maybe 0 (BS.length . encodeValue) v

-- ---------------------------------------------------------------------------
-- The densest valid pages, from the encoders

spec ∷ Spec
spec = describe "the accounted-bytes constants against what is retained (forced live heap, every variant of the largest valid instance)" $ do
  let total = 10000000
      -- endless supplies of VALID entries of each tree, ascending: the same encoders a store writes with
      runsSupply = [(encodeKey (runKey 0 0 (100 * toInteger i)), encodeValue (runRec (100 * toInteger i + 3))) | i ← [1 ∷ Int ..]]
      linksSrcSupply = [(encodeKey (linkKey (srcNode (toInteger i) 1 1)), encodeValue (rootRec (fromIntegral i) True)) | i ← [1 ∷ Int ..]]
      linksChildSupply = [(encodeKey (linkKey (srcNode (toInteger i) 1 1)), encodeValue (childRec (srcNode 3 (toInteger i) 1))) | i ← [1 ∷ Int ..]]
      todoSupply = [(encodeKey (todoKey (fromIntegral i)), encodeValue (todoRec 1 2 3 1)) | i ← [1 ∷ Int ..]]
      freeSupply = [(be64 (fromIntegral (2 * i)), be64 1) | i ← [1 ∷ Int ..]]
      retireEntrySupply = [encodeRetire (fromIntegral i) (Retire (PageNo 7) 3 1) | i ← [1 ∷ Int ..]]
      retirePageSupply = [(retiredKey (PageNo (fromIntegral i)), be64 5) | i ← [1 ∷ Int ..]]
      -- (tree, kind, supply)
      treeSupplies =
        [ (TreeRuns, "runs", runsSupply)
        , (TreeLinks, "links, source keys, roots", linksSrcSupply)
        , (TreeLinks, "links, source keys, children", linksChildSupply)
        , (TreeTodo, "todo", todoSupply)
        , (TreeFree, "free", freeSupply)
        , (TreeRetire, "retire, entries", retireEntrySupply)
        , (TreeRetire, "retire, retired pages", retirePageSupply)
        ]
      densePage tree inner supply pno =
        let level = if inner then 1 else 0
         in either (error . show) id (encodePage ident0 (Page tree level (PageNo pno) (denseBodyOf tree inner (take 400 supply))))
      entriesOf bs = either (error . show) (\pg → case pgBody pg of Leaf es → length es; Inner es → length es; List _ ps → length ps) (decodePage ident0 total (PageNo 1) bs)
      nFacts = maxReadFactBytes `div` recordFactBytes
  rows ← runIO $ do
    -- WINDOW PAGE: a validated 4,096-byte buffer; what the page says does not change what a window keeps
    mPage ← sequence
      [ do
          let pages = [(fromIntegral i, densePage tree inner sup (fromIntegral i)) | i ← ints 2000]
          v ← retainedPer 2000 pages (BS.length . snd) (\ps → pure (foldl' (\w (p, bs) → either (error . show) id (windowInsert total (PageNo p) bs w)) (emptyWindow ident0 0) ps)) (\w → evaluate (windowSize w + windowPayloadBytes w))
          pure (Variant (nm <> (if inner then ", internal" else ", leaf")) v Nothing)
      | (tree, nm, sup) ← treeSupplies
      , inner ← [False, True]
      , tree /= TreeLinks || nm == "links, source keys, children" || not inner
      ]
    -- PROBE: a map entry, the tag and level, and the first key of the page it classifies: the longest key a valid page holds is the
    -- links tree's 52 bytes, and the bound a page could carry at all is 'maxKeyBytes' (64), measured as well
    mProbe ← sequence
      [ do
          v ← retainedPer 5000 (ints 5000) id (\is → pure (Map.fromList [(PageNo (fromIntegral i), mk i) | i ← is])) (\m → evaluate (Map.size m + sum [case pr of ProbeTree _ l k → l + SBS.length k; ProbeList w → fromIntegral w; ProbeNone → 0 | pr ← Map.elems m]))
          pure (Variant nm v Nothing)
      | (nm, mk) ←
          [ ("key of " <> show len <> " bytes", \i → ProbeTree TreeLinks 3 (toShort (BS.pack [fromIntegral (i + j) | j ← [1 .. len]]))) | len ← [8, 24, 25, 52, maxKeyBytes]
          ]
            <> [("retirement list", \i → ProbeList (fromIntegral i * 4096)), ("nothing a store could read", const ProbeNone)]
      ]
    -- READ FACT, PACKED: the encoded key and value in one map entry. The values a valid fact holds: a record of every kind, the floor
    -- answer (16 bytes), an absent answer (empty); and the bound itself: a 64-byte key with a 64-byte value, which no valid record reaches
    mFact ← sequence $
      [ do
          v ← retainedPer nFacts (ints nFacts) id (\is → pure (windowCheckpoint (factsOf (Fingerprint ident0 1 [] []) [] (ReadSet [(kf i, Just (rf i)) | i ← is] [])) (emptyWindow ident0 1))) (\w → evaluate (windowReadFactCount w))
          -- each variant against ITS OWN charge: its key and value lengths and the fixed entry overhead
          pure (Variant nm v (Just (BS.length (encodeKey (kf 1)) + BS.length (encodeValue (rf 1)) + readFactOverheadBytes)))
      | (nm, kf, rf) ← validPairs
      ]
        <> [ do
               v ← retainedPer nFacts (ints nFacts) id (\is → pure (windowCheckpoint (factsOf (Fingerprint ident0 1 [] []) [] (ReadSet [] [((columnAt (big i) (big (i + 1)), fromInteger (big (i + 2))), if odd i then Just (fromInteger (big i), fromInteger (big (i + 1))) else Nothing) | i ← is])) (emptyWindow ident0 1))) (\w → evaluate (windowReadFactCount w))
               pure (Variant "floor answer (16 bytes) or absent" v (Just (BS.length (encodeKey (runKey 1 1 1)) + 16 + readFactOverheadBytes)))
           , do
               v ← retainedPer nFacts (ints nFacts) id (\is → pure (Map.fromList [(toShort (BS.append (be64 (fromIntegral i)) (BS.pack [fromIntegral (i + j) | j ← [1 .. maxKeyBytes - 8]])), toShort (BS.pack [fromIntegral (i + j + 3) | j ← [1 .. maxValueBytes]])) | i ← is])) (\m → evaluate (Map.size m))
               pure (Variant "the bound: a 64-byte key with a 64-byte value (not reachable by a valid record)" v (Just (maxKeyBytes + maxValueBytes + readFactOverheadBytes)))
           ]
    -- PROOF FACT: a member of the window's set of proofs; every constructor, the largest carries a version and a page
    mProof ← sequence
      [ do
          v ← retainedPer 20000 (ints 20000) id (\is → pure (Set.fromList [mk i | i ← is])) (\st → evaluate (Set.foldl' (\acc f → acc + factWeight f) (0 ∷ Int) st))
          pure (Variant nm v Nothing)
      | (nm, mk) ←
          [ ("unreachable", \i → FactUnreachable (PageNo (fromInteger (big i))))
          , ("retirable", \i → FactRetirable (PageNo (fromInteger (big i))))
          , ("not retired", \i → FactNotRetired (PageNo (fromInteger (big i))))
          , ("not free", \i → FactNotFree (PageNo (fromInteger (big i))))
          , ("gone (version and page)", \i → FactGone (fromInteger (big i)) (PageNo (fromInteger (big (i + 1)))))
          ]
      ]
    -- LISTS AND SETS OF PAGE NUMBERS: the replaced pages of an edit are a set, the supply and the loose pages are lists
    mCell ← sequence
      [ do
          v ← retainedPer 200000 (ints 200000) id (\is → pure (map (\i → PageNo (fromInteger (big i))) is)) (\ps → evaluate (foldl' (\acc (PageNo q) → acc + fromIntegral q) (0 ∷ Int) ps))
          pure (Variant "a list of page numbers (supply, loose pages)" v Nothing)
      , do
          v ← retainedPer 200000 (ints 200000) id (\is → pure (Set.fromList (map (\i → PageNo (fromInteger (big i))) is))) (\st → evaluate (Set.foldl' (\acc (PageNo q) → acc + fromIntegral q) (0 ∷ Int) st))
          pure (Variant "a set of page numbers (the replaced pages of an edit)" v Nothing)
      ]
    -- ROOT SET: every root present, the largest header, five checksums and the loose list at its cap (every cell a distinct number)
    mRoots ← sequence
      [ do
          v ← retainedPer 100 (ints 100) id (\is → pure [rootsOf full loose i | i ← is]) (\rs → evaluate (sum (map rootsWeight rs)))
          pure (Variant nm v Nothing)
      | (nm, full, loose) ←
          [ ("every root present, header at its largest, 5 checksums, loose list at its cap", True, looseCap)
          , ("no root present, loose list at its cap", False, looseCap)
          , ("every root present, loose list empty", True, 0)
          ]
      ]
    -- READER PIN: the entry of the map of readers (a key and the pins), every pinned root and checksum present
    mPin ← sequence
      [ do
          v ← retainedPer 1000 (ints 1000) id (\is → pure (Map.fromList [(fromIntegral (big i) ∷ Word64, pinRecord full i) | i ← is])) (\m → evaluate (sum [fromIntegral (pinVersion p) + length (pinCrcs p) + length [() | Just _ ← [pinRuns p, pinLinks p, pinTodo p]] | p ← Map.elems m]))
          pure (Variant nm v Nothing)
      | (nm, full) ← [("all three roots pinned, three checksums", True), ("no root pinned, no checksum", False)]
      ]
    -- TYPED WRITE: a plan holds the candidate's list, the map the planner builds to canonicalise it and the canonical list, all at once;
    -- every pairing of key and record it accepts is measured, and the populated source-node key and child is the largest
    mWrite ← sequence
      [ do
          v ← retainedPer 3000 (ints 3000) id (\is → pure (writesOf kf rf is)) (\(ws, m, canon) → evaluate (sum (map recordWeight canon) + Map.size m + length ws))
          pure (Variant nm v Nothing)
      | (nm, kf, rf) ← validPairs
      ]
    -- HOT NODE: a node parsed and held by an edit, the densest valid page of every tree and kind, leaf and internal
    mHot ← sequence
      [ do
          let sup' = take 400 sup
              bs0 = densePage tree inner sup' 1
              pages = [(fromIntegral i, densePage tree inner sup' (fromIntegral i)) | i ← ints 300]
          v ← retainedPer 300 pages (BS.length . snd) (\bufs → pure [(PageNo pno, either (error . show) id (decodePage ident0 total (PageNo pno) bs >>= parsedNode)) | (pno, bs) ← bufs]) (\ns → evaluate (sum [parsedNodeWeight n | (_, n) ← ns]))
          pure (Variant (nm <> (if inner then ", internal, " else ", leaf, ") <> show (entriesOf bs0) <> " entries") v Nothing)
      | (tree, nm, sup) ← treeSupplies
      , inner ← [False, True]
      , tree /= TreeLinks || nm == "links, source keys, children" || not inner
      ]
    -- PAGE STATE: an entry of the active transaction's map; the states are nullary, so every one costs the same
    mState ← sequence
      [ do
          v ← retainedPer 25600 (ints 25600) id (\is → pure (Map.fromList [(PageNo (fromInteger (big i)), st) | i ← is])) (\m → evaluate (Map.size m))
          pure (Variant nm v Nothing)
      | (nm, st) ← [("staged", PsStaged), ("in flight", PsInFlight), ("written", PsWritten), ("failed", PsFailed)]
      ]
    -- OVERLAY PAGE: a new page held packed, its payload plus what holds it (the two map entries, the packed record, the byte string);
    -- a leaf packs to its page payload, an internal page packs each entry one byte larger, so the shortest separator gives the most
    mOverlay ← sequence
      [ do
          let node = parsedNodeOf tree inner (take 400 sup)
              acc = packedBytes node
          v ← retainedPer 4000 (ints 4000) id (\is → pure (OverlayPair (IntMap.fromList [(i, packParsedNode i node) | i ← is]) (IntMap.fromList [(i, acc + i `mod` 3) | i ← is]))) (\(OverlayPair a b) → evaluate (sum (map storedPayload (IntMap.elems a)) + sum (IntMap.elems b)))
          pure (Variant (nm <> (if inner then ", internal, " else ", leaf, ") <> show (acc - overlayOverheadBytes) <> " packed payload bytes") v (Just acc))
      | (tree, nm, sup) ← [t | t@(tr, _, _) ← treeSupplies, tr `elem` [TreeFree, TreeRetire, TreeRuns]]
      , inner ← [False, True]
      ]
    -- WRITTEN PAGE: the plan's list of encoded pages, each a page number and a pinned 4,096-byte buffer; every kind of page it writes
    mWritten ← sequence
      [ do
          v ← retainedPer 3000 (ints 3000) id (\is → pure [(PageNo (fromIntegral i), mk i) | i ← is]) (\ps → evaluate (sum [BS.length b | (_, b) ← ps]))
          pure (Variant nm v Nothing)
      | (nm, mk) ←
          [ ("tree page, leaf (runs, densest)", \i → either (error . show) id (encodePage ident0 (Page TreeRuns 0 (PageNo (fromIntegral i)) (denseBodyOf TreeRuns False (take 400 runsSupply)))))
          , ("tree page, internal (free, densest)", \i → either (error . show) id (encodePage ident0 (Page TreeFree 1 (PageNo (fromIntegral i)) (denseBodyOf TreeFree True (take 400 freeSupply)))))
          , ("retirement list page at its cap", \i → either (error . show) id (encodePage ident0 (Page TreeRetire 0 (PageNo (fromIntegral i)) (List (fromIntegral i) [PageNo (fromIntegral (i * 600 + j)) | j ← [1 .. maxListPages]]))))
          ]
      ]
    -- FACTS VALUE: what the caller holds between a Checkpoint and windowCheckpoint. The read facts are packed AT CREATION, so nothing typed
    -- is in it; the proof facts are a LIST there (not the window's Set); the fingerprint holds the roots and the pinned versions
    mFacts ← sequence
      [ do
          v ← retainedPer nFacts (ints nFacts) id (\is → pure (factsOf (Fingerprint ident0 1 [] []) [] (ReadSet [(KeyLink (SrcNode (compKey 3 i)), Just (RecChild (SrcNode (compKey 3 (i + 7))))) | i ← is] []))) (\fx → evaluate (factsRetainedBytes fx))
          pure (Variant "N packed read facts, the largest kind (a source key and a source child)" v (Just (BS.length (encodeKey (KeyLink (SrcNode (compKey 3 1)))) + BS.length (encodeValue (RecChild (SrcNode (compKey 3 8)))) + readFactOverheadBytes)))
      , do
          v ← retainedPer 20000 (ints 20000) id (\is → pure (factsOf (Fingerprint ident0 1 [] []) [FactGone (fromInteger (big i)) (PageNo (fromInteger (big (i + 1)))) | i ← is] (ReadSet [] []))) (\fx → evaluate (factsRetainedBytes fx))
          pure (Variant "N proof facts, a list (the largest constructor)" v (Just factBytes))
      , do
          v ← retainedPer 200 (ints 200) id (\is → pure [Fingerprint ident0 (fromInteger (big i)) [(PageNo (fromInteger (big (i + k))), fromInteger (big (i + k))) | k ← [1 .. 5]] [(fromInteger (big (i + 10 * q)), [(PageNo (fromInteger (big (i + q + k))), fromInteger (big (i + q + k))) | k ← [1 .. 3]]) | q ← [1 .. maxReaders]] | i ← is]) (\fs → evaluate (sum [fromIntegral ver + length rs + sum [length ps | (_, ps) ← pins] | Fingerprint _ ver rs pins ← fs]))
          pure (Variant "one fingerprint at its worst: 5 root checksums and 16 pinned versions of 3 roots" v (Just fingerprintBytes))
      ]
    -- TYPED READ IN FLIGHT: what #661 holds while a read phase runs: the record read (as Haskell values), the map it keeps it in and the
    -- ascending list it is handed over as, all alive together
    mTypedRead ← sequence $
      [ do
          v ← retainedPer 3000 (ints 3000) id (\is → pure (typedReadsOf kf rf is)) (\(m, l) → evaluate (sum (map recordWeight l) + Map.size m))
          pure (Variant nm v Nothing)
      | (nm, kf, rf) ← validPairs
      ]
        <> [ do
               v ← retainedPer 3000 (ints 3000) id (\is → pure (let m = Map.fromList [((columnAt (big i) (big (i + 1)), fromInteger (big (i + 2)) ∷ Int64), if odd i then Just (fromInteger (big i) ∷ Int64, fromInteger (big (i + 1)) ∷ Int64) else Nothing) | i ← is] in (m, Map.toAscList m))) (\(m, l) → evaluate (Map.size m + length l))
               pure (Variant "floor query (a column and a level) with its answer" v Nothing)
           ]
    -- DISCOVERY HEADER: the always-resident control record (an authority and three counters), every field at its largest
    mHeader ← retainedPer 1000 (ints 1000) id (\is → pure [headerOf i | i ← is]) (\hs → evaluate (sum [fromIntegral (hHead h) + fromIntegral (hTail h) + hBytes h | h ← hs]))
    pure
      [ Row "window page (buffer + map entry)" "a 4,096-byte validated buffer whatever the page says: every tree, leaf and internal, measured; they differ by no more than their map entry" Nothing windowPageBytes mPage
      , Row "probe (map entry + key)" "the longest key a valid page holds is 52 bytes (the links tree); the bound a page could carry is 64 (maxKeyBytes), measured too" (Just "key of 64 bytes") probeBytes mProbe
      , Row "read fact, packed (key + value + entry)" "the longest valid key (52) with the longest valid value (53, a child that is a source node); encoded, so the optional coordinates of the typed form do not matter; the bound (64 + 64) is measured too" Nothing recordFactBytes mFact
      , Row "proof fact in a Set" "the constructor with the most fields: a version and a page" (Just "gone (version and page)") factBytes mProof
      , Row "page-number list cell (supply, loose pages)" "a cons cell and a boxed number" Nothing pageListCellBytes (take 1 mCell)
      , Row "page-number set element (the replaced pages of an edit)" "a map node, the boxed number and the pointers" Nothing pageSetElemBytes (drop 1 mCell)
      , Row "root set at the loose cap" "every Maybe root present, the header at its largest, five checksums, the loose list at its cap of 1,024 distinct pages" (Just "every root present, header at its largest, 5 checksums, loose list at its cap") rootRecordBytes mRoots
      , Row "reader pin (map entry + pins)" "all three pinned roots present and three checksums" (Just "all three roots pinned, three checksums") readerRecordBytes mPin
      , Row "typed write (key + record, the candidate's list, the planner's map and its canonical list)" "a source-node key and a source-node child, each with all three optional coordinates populated: the key and the value are the two largest constructors of their types" (Just "source-node key, 3 parameters with child, source node, 3 parameters") writeRetainedBytes mWrite
      , Row "parsed node in the hot set (with its list cell, tuple and page number)" "the densest valid page of any tree: the free tree's 8 + 8 byte extents give 225 entries; the table prints every tree and kind" Nothing hotNodeBytes mHot
      , Row "page-state map entry of the active transaction" "every state is nullary: one cost" Nothing pageStateEntryBytes mState
      , Row "overlay page (packed payload + what holds it)" "a leaf packs to its page payload; an internal page packs each entry one byte larger, so the shortest separator gives the most entries" Nothing overlayPageWorstBytes mOverlay
      , Row "written page (the plan's list entry: cons, tuple, page number, pinned buffer)" "a 4,096-byte pinned buffer whatever the page says; tree leaf, internal and list page measured" Nothing writtenPageBytes mWritten
      , Row "a Facts value (the caller's continuation: fingerprint, proof facts as a list, packed read facts)" "N packed reads at the largest kind, N proof facts of the largest constructor, the worst fingerprint (16 pinned versions of 3 roots)" Nothing (packedFactBytes (toShort (BS.replicate 52 0)) (toShort (BS.replicate 53 0))) mFacts
      , Row "typed read in flight (record + map entry + list cell, #661's read set during a read phase)" "a source-node key and a source-node child with all three optional coordinates populated, held in the core's map and in the list it is handed over as" (Just "source-node key, 3 parameters with child, source node, 3 parameters") typedReadBytes mTypedRead
      , Row "discovery header record" "an authority and three counters, all at their largest" Nothing headerBytes [Variant "header" mHeader Nothing]
      ]
  it "TABLE: every accounted constant, its largest valid instance and why, every variant measured against the accounted figure" $ do
    forM_ rows $ \r → do
      putStrLn ("MEMORY " <> rowName r <> " [accounted " <> show (rowAccounted r) <> " B]: largest valid instance: " <> rowLargest r)
      forM_ (rowVariants r) $ \v → putStrLn ("MEMORY   variant " <> varName v <> ": " <> show (round (varMeasured v) ∷ Int) <> " B")
      let m = varMeasured (rowMax r)
          acc = fromIntegral (fromMaybe (rowAccounted r) (varBudget (rowMax r))) ∷ Double
      putStrLn ("MEMORY   -> largest measured: " <> varName (rowMax r) <> " at " <> show (round m ∷ Int) <> " B of " <> show (round acc ∷ Int) <> " accounted (margin " <> show (round (acc - m) ∷ Int) <> " B, " <> show (round (100 * (acc - m) / m) ∷ Int) <> " %)")
    -- the constants that are LEDGER terms, not retained structures: no object of the store stands behind them
    putStrLn "MEMORY ledger terms (no store heap structure): ramPagePins (16 per window page), ramContinuation (1,024 + 8 per window page), the 4,096-byte scratch, descriptorRecordBytes (queued I/O descriptors of the admission)"
  forM_ rows $ \r → do
    it ("every variant retains no more than it is charged: " <> rowName r) $
      forM_ (rowVariants r) $ \v → (varName v, varMeasured v <= fromIntegral (fromMaybe (rowAccounted r) (varBudget v))) `shouldBe` (varName v, True)
    case rowExpect r of
      Nothing → pure ()
      Just nm → it ("the variant named the largest is the largest measured: " <> rowName r) $ do
        let named = [varMeasured v | v ← rowVariants r, varName v == nm]
        -- within two bytes of the maximum: measurement noise is a few bytes
        case named of
          [] → expectationFailure ("no variant named " <> nm)
          (m : _) → all (\o → m >= o - 2) (map varMeasured (rowVariants r)) `shouldBe` True
  it "the populated variants of a typed write are really populated: three optional coordinates in the key and in the child" $ do
    let key = compKey 3 1
        node = SrcNode key
    length (keyParameters key) `shouldBe` 3
    node `shouldBe` SrcNode (compKey 3 1)
    (length (keyParameters (compKey 0 1)), length (keyParameters (compKey 2 1))) `shouldBe` (0, 2)
    -- and a value near the top of the range is a value, not a small shared Int: the coordinates differ in every variant
    (big 1 > 4000000000000000000, big 1 /= big 2) `shouldBe` (True, True)
  it "the shortest key any tree holds is minKeyBytes (the densest internal page, and so the largest overlay page, follows from it)" $ do
    let lengths = [BS.length (encodeKey (todoKey 5)), BS.length (fst (encodeFree 5 1)), BS.length (versionKey 5), BS.length (retiredKey (PageNo 5)), BS.length (encodeKey (runKey 1 1 1)), BS.length (encodeKey (linkKey (srcNode 1 1 1)))]
    minimum lengths `shouldBe` minKeyBytes
    maxPackedPayloadBytes `shouldBe` pagePayloadBytes + pagePayloadBytes `div` (1 + minKeyBytes + innerEntryTail)
  it "the worst overlay of a plan dominates the largest packed page, for every plan that writes up to a transaction's pages" $ do
    overlayPageWorstBytes `shouldBe` overlayNodeBytes maxPackedPayloadBytes
    overlayWorstFor maxTxnPages `shouldBe` maxTxnPages * overlayNodeBytes maxPackedPayloadBytes
    (overlayBudgetRecord >= overlayWorstFor maxTxnPages, overlayBudgetBookkeeping >= overlayWorstFor bookkeepingReserve) `shouldBe` (True, True)
    -- and it is checked against what the measured variants really pack to, not against its own definition
    let packed = [b | r ← rows, take 12 (rowName r) == "overlay page", v ← rowVariants r, Just b ← [varBudget v]]
    (length packed > 0, all (<= overlayPageWorstBytes) packed) `shouldBe` (True, True)
  it "a plan's I/O charge is the MEASURED written page for every page it writes (not the 4,096 bytes of the buffer)" $ do
    case [r | r ← rows, take 12 (rowName r) == "written page"] of
      [r] → do
        let m = ceiling (varMeasured (rowMax r)) ∷ Int
        (ramIoBuffers (worstChargeWith maxTxnPages 0 0) >= maxTxnPages * m, ramIoBuffers (worstChargeWith maxTxnPages 0 0) `div` maxTxnPages) `shouldBe` (True, writtenPageBytes)
        -- and the budget a plan's pages are charged from is the same one the admission's accounts are sized from
        ramIoBuffers worstTransactionCharge `shouldBe` maxTxnPages * writtenPageBytes
      other → expectationFailure ("expected one written-page row, found " <> show (length other))
  it "the read phase in flight fits: the typed reads at the cap, a full window, the packed facts at their ceiling and the fixed records are within a plan's RAM, at the MEASURED typed read" $ do
    case [r | r ← rows, take 13 (rowName r) == "typed read in"] of
      [r] → do
        let m = ceiling (varMeasured (rowMax r)) ∷ Int
            -- restated here from the raw figures, independent of the derivation: the typed reads, a full window and its probes, the packed
            -- facts at their ceiling, the proof facts of a replayed read phase, the writes staging holds (192 at writeRetainedBytes) and
            -- the fixed records
            peak n = n * m + maxWindowBytes + worstOwnershipBytes + maxReadFactBytes + maxProofFacts * factBytes + 3 * maxBatchUpdates * writeRetainedBytes + readPhaseFixedBytes
        -- a removal reads at most worstEditReads, a unit of discovery worstEdgeReads, a batch the cap; each fits
        forM_ [worstEdgeReads, worstEditReads, maxTypedReads] $ \n → (n, peak n <= txnRamLimit) `shouldBe` (n, True)
        -- and the cap is above what a removal or one inspection can read, so it is never what refuses them
        (maxTypedReads >= worstEditReads, maxTypedReads >= worstEdgeReads) `shouldBe` (True, True)
        -- the cap is the largest the ACCOUNTED typed read allows: one more read at the accounted figure would not fit
        let fixed = maxWindowBytes + worstOwnershipBytes + maxReadFactBytes + maxProofFacts * factBytes + 3 * maxBatchUpdates * writeRetainedBytes + readPhaseFixedBytes
        (maxTypedReads * typedReadBytes + fixed <= txnRamLimit, (maxTypedReads + 1) * typedReadBytes + fixed > txnRamLimit) `shouldBe` (True, True)
      other → expectationFailure ("expected one typed-read row, found " <> show (length other))
  it "a Facts value of N read facts and N proof facts retains no more than factsRetainedBytes says (measured on one value, accounted on another)" $ do
    let fingerprintOf salt = Fingerprint ident0 (fromInteger (big salt)) [(PageNo (fromInteger (big (salt + k))), fromInteger (big (salt + k))) | k ← [1 .. 5]] [(fromInteger (big (salt + 10 * q)), [(PageNo (fromInteger (big (salt + q + k))), fromInteger (big (salt + q + k))) | k ← [1 .. 3]]) | q ← [1 .. maxReaders]]
        mkFacts salt = factsOf (fingerprintOf salt) [FactGone (fromInteger (big (i + salt))) (PageNo (fromInteger (big (i + salt + 1)))) | i ← [1 .. maxProofFacts]] (ReadSet [(KeyLink (SrcNode (compKey 3 (i + salt))), Just (RecChild (SrcNode (compKey 3 (i + salt + 7))))) | i ← ints nFacts] [])
    measured ← retainedPer 1 [()] (const 0) (\_ → pure (mkFacts 1)) (\fx → evaluate (factsRetainedBytes fx))
    let accounted = factsRetainedBytes (mkFacts 100000)
    putStrLn ("MEMORY a Facts value of " <> show nFacts <> " read facts and " <> show maxProofFacts <> " proof facts: retains " <> show (round measured ∷ Int) <> " B, accounted " <> show accounted <> " B")
    (measured <= fromIntegral accounted, accounted <= maxReadFactBytes + maxProofFacts * factBytes + fingerprintBytes) `shouldBe` (True, True)
  it "the read facts at their ceiling retain no more than the ceiling: N of them, near maxReadFactBytes, in total" $ do
    mTotal ← retainedPer 1 [()] (const 0) (\_ → pure (windowCheckpoint (factsOf (Fingerprint ident0 1 [] []) [] (ReadSet [(KeyLink (SrcNode (compKey 3 i)), Just (RecChild (SrcNode (compKey 3 (i + 7))))) | i ← ints nFacts] [])) (emptyWindow ident0 1))) (\w → evaluate (windowReadFactCount w))
    putStrLn ("MEMORY read facts at the ceiling: " <> show nFacts <> " facts retain " <> show (round mTotal ∷ Int) <> " B of " <> show maxReadFactBytes)
    (mTotal <= fromIntegral maxReadFactBytes) `shouldBe` True
    unless (nFacts > 0) (expectationFailure "no facts")
  where
    ints n = [1 .. n] ∷ [Int]
    typedReadsOf kf rf is =
      let m = Map.fromList [(kf i, Just (rf i)) | i ← is]
       in (m, Map.toAscList m)
    writesOf kf rf is =
      let ws = [(kf i, Just (rf i)) | i ← is]
          m = Map.fromList ws
          canon = Map.toAscList m
       in (ws, m, canon)
    factWeight f = case f of
      FactUnreachable (PageNo p) → fromIntegral p
      FactRetirable (PageNo p) → fromIntegral p
      FactNotRetired (PageNo p) → fromIntegral p
      FactNotFree (PageNo p) → fromIntegral p
      FactGone v (PageNo p) → fromIntegral (v + p)
    rootsOf full loose i =
      let pg k = if full then Just (PageNo (fromInteger (big (i + k)))) else Nothing
       in Roots
            { rVersion = fromInteger (big i)
            , rRuns = pg 1
            , rLinks = pg 2
            , rTodo = pg 3
            , rFree = pg 4
            , rRetire = pg 5
            , rHeader = headerOf i
            , rHw = fromInteger (big (i + 6))
            , rFreePages = fromInteger (big (i + 7))
            , rLivePages = fromInteger (big (i + 8))
            , rRetiredPages = fromInteger (big (i + 9))
            , rLoose = [PageNo (fromInteger (big (i * 2000 + j))) | j ← [1 .. loose]]
            , rRootCrcs = if full then [(t, fromInteger (big (i + k))) | (k, t) ← zip [10 ..] [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire]] else []
            }
    rootsWeight r = fromIntegral (rVersion r) + sum [fromIntegral q | PageNo q ← rLoose r] + sum [fromIntegral c | (_, c) ← rRootCrcs r] + length [() | Just _ ← [rRuns r, rLinks r, rTodo r, rFree r, rRetire r]] + hBytes (rHeader r) + fromIntegral (hHead (rHeader r))
    headerOf i = Header (Authority (ArenaId (fromInteger (big i))) (Revision (fromInteger (big (i + 1)))) (Revision (fromInteger (big (i + 2)))) (Revision (fromInteger (big (i + 3))))) (fromInteger (big (i + 4))) (fromInteger (big (i + 5))) (fromInteger (big (i + 6)))
    pinRecord full i =
      Pins
        { pinVersion = fromInteger (big i)
        , pinRuns = if full then Just (PageNo (fromInteger (big (i + 1)))) else Nothing
        , pinLinks = if full then Just (PageNo (fromInteger (big (i + 2)))) else Nothing
        , pinTodo = if full then Just (PageNo (fromInteger (big (i + 3)))) else Nothing
        , pinCrcs = if full then [(t, fromInteger (big (i + k))) | (k, t) ← zip [4 ..] [TreeRuns, TreeLinks, TreeTodo]] else []
        , pinHw = fromInteger (big (i + 8))
        }
    parsedNodeOf tree inner sup = either (error . show) id (parsedNode (Page tree (if inner then 1 else 0) (PageNo 1) (denseBodyOf tree inner sup)))

data OverlayPair = OverlayPair !(IntMap.IntMap Stored) !(IntMap.IntMap Int)

-- | The densest valid body of a page of a tree from an endless supply of its valid entries (or separators, for an internal page):
-- the most entries that encode.
denseBodyOf ∷ TreeId → Bool → [(BS.ByteString, BS.ByteString)] → Body
denseBodyOf tree inner sup = case [b | n ← [length sup, length sup - 1 .. 1], let b = bodyOf n, Right _ ← [encodePage ident0 (Page tree (if inner then 1 else 0) (PageNo 1) b)]] of
  (b : _) → b
  [] → error "no dense body encodes"
  where
    bodyOf n
      | inner = Inner [(k, Child (PageNo (3000000 + fromIntegral j)) (fromIntegral j)) | (j, (k, _)) ← zip [1 ∷ Int ..] (take n sup)]
      | otherwise = Leaf (take n sup)
