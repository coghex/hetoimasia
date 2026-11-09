-- | A re-sealed byte of a live page never changes what a read answers, except as data.
--
-- Take a valid store, change one byte of one live page of the runs tree and recompute its
-- checksum, so the page is as valid as a checksum can make it, and read: every record,
-- by lookup, by floor and by ranged scan, must then be exactly what the reference says or
-- an integrity failure. A false absence, a record that is not the reference's, or a value
-- from another key is a defect. The one allowance is data: when the changed page is a leaf,
-- the records that leaf held, before and after the change, may read differently (a changed
-- value or key is a different record, which no structure can tell from an intended one);
-- every other record must still read exactly. Fixed seeds, bounded: nothing here is
-- timing-dependent.
module Test.TerrainRuntime.Store.Fuzz (spec, fuzzOnce, judgeMutated, Finding (..), Tally (..)) where

import Control.Monad (forM, forM_)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Page (..), decodePage, encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (RangeStart (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (decodeKey, encodeKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.Hspec
import Test.TerrainRuntime.Store.Bounds (wide)
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | What a mutation did that it must not have.
data Finding = Finding
  { fdPage ∷ !Word64
  , fdOffset ∷ !Int
  , fdByte ∷ !Word64
  , fdWhat ∷ String
  }
  deriving stock (Show)

-- | What one read came to: an integrity failure, exactly the reference's answer, an answer excused as
-- data (a record of a changed leaf), or a defect.
data Verdict = IntegrityError | EqualAnswer | Excused | Defect String

-- | How many reads came to each, over a run.
data Tally = Tally
  { tMutations ∷ !Int
  , tReads ∷ !Int
  , tIntegrity ∷ !Int
  , tEqual ∷ !Int
  , tExcused ∷ !Int
  , tDefects ∷ !Int
  }
  deriving stock (Show)

instance Semigroup Tally where
  Tally a b c d e f <> Tally a' b' c' d' e' f' = Tally (a + a') (b + b') (c + c') (d + d') (e + e') (f + f')

instance Monoid Tally where
  mempty = Tally 0 0 0 0 0 0

tallyOf ∷ [Verdict] → Tally
tallyOf vs = Tally 1 (length vs) (length [() | IntegrityError ← vs]) (length [() | EqualAnswer ← vs]) (length [() | Excused ← vs]) (length [() | Defect _ ← vs])

-- | Fill a window from the (mutated) disk until the read answers: a page that is refused, or a
-- read that reports corruption, is an integrity failure (@Left@).
through ∷ Show a ⇒ H → Disk → ReaderToken → (Window → ReadOutcome a) → Either String a
through h disk tok act = start
  where
    total = cfgUsablePages (hCfg h)
    start = either (const (Left "stale")) (\w → go w (0 ∷ Int)) (readerWindow (hStore h) tok)
    go w n
      | n > 4000 = Left "did not settle"
      | otherwise = case act w of
          Read r → Right r
          ReadNeeds p → case diskRead disk p of
            Nothing → Left ("page not on disk " <> show p)
            Just bs → case windowInsert total p bs w of
              Left e → Left ("refused " <> show e)
              Right w' → go w' (n + 1)
          other → Left (show other)

-- | Run a tree operation through a window filled from the (mutated) disk; a refused page, or a
-- stop that is not a missing page, is an integrity failure (@Left@).
throughM ∷ H → Disk → ReaderToken → M a → Either String a
throughM h disk tok act = start
  where
    total = cfgUsablePages (hCfg h)
    hw = rHw (storeRoots (hStore h))
    start = either (const (Left "stale")) (\w → go (windowBelow hw w) (0 ∷ Int)) (readerWindow (hStore h) tok)
    go w n
      | n > 4000 = Left "did not settle"
      | otherwise = case runM act (newEdit 0 w) of
          Right (a, _) → Right a
          Left (Need p) → case diskRead disk p of
            Nothing → Left ("page not on disk " <> show p)
            Just bs → case windowInsert total p bs w of
              Left e → Left ("refused " <> show e)
              Right w' → go w' (n + 1)
          Left stop' → Left (show stop')

reseal ∷ BS.ByteString → BS.ByteString
reseal bs = let body = BS.take 4092 bs in BS.append body (le32' (refCrc32c body))

-- | One mutation: the page, the byte and its new value, then every read judged.
fuzzOnce ∷ H → ReaderToken → Map.Map RecordKey Record → [RecordKey] → Word64 → Int → Word64 → Either String ([Finding], Tally)
fuzzOnce h tok ref keys page offset newByte = do
  original ← maybe (Left "page missing") Right (diskRead (hDisk h) (PageNo page))
  judgeMutated h tok ref keys page offset newByte (reseal (BS.concat [BS.take offset original, BS.singleton (fromIntegral newByte), BS.drop (offset + 1) original]))

-- | Judge every read over a disk in which a page was replaced by given (valid) bytes.
judgeMutated ∷ H → ReaderToken → Map.Map RecordKey Record → [RecordKey] → Word64 → Int → Word64 → BS.ByteString → Either String ([Finding], Tally)
judgeMutated h tok ref keys page offset newByte mutated = do
  original ← maybe (Left "page missing") Right (diskRead (hDisk h) (PageNo page))
  let ArenaId arenaNo = siArena (hIdent h)
      rootRef = fromMaybe (PageNo 0) (committedRoot (hStore h) TreeRuns)
      livePagesBelow = [q | q ← twPages (walkTree arenaNo (siSource (hIdent h)) (diskRead (hDisk h)) ((\(PageNo r) → r) <$> committedRoot (hStore h) TreeRuns))]
      disk' = diskWrite (PageNo page) mutated (hDisk h)
      total = cfgUsablePages (hCfg h)
      keysOf bs = case decodePage (hIdent h) total (PageNo page) bs of
        Right (Page TreeRuns 0 _ (Leaf es)) → [k | (kb, _) ← es, Just k ← [decodeKey TreeRuns kb]]
        _ → []
      isLeaf = case decodePage (hIdent h) total (PageNo page) original of
        Right (Page _ 0 _ (Leaf _)) → True
        _ → False
      -- the records a changed leaf may legitimately read differently
      allowed = if isLeaf then Set.fromList (keysOf original ++ keysOf mutated) else Set.empty
  -- lookups of a spread of keys, floors, and the full scan
  let firstKey = case keys of (k : _) → k; [] → KeyTodo 0
      -- the keys of the first leaves, where the first separators of the internal pages sit
      nearBoundaries = [keys !! i | i ← [0, 7 .. 260], i < length keys]
      sample = [keys !! ((offset * 31 + i * 197) `mod` length keys) | i ← [0 .. 39]] ++ Set.toList allowed
      judgeLookup k = case through h disk' tok (\w → readerLookup (hStore h) tok w k) of
        Left _ → [IntegrityError]
        Right got
          | Set.member k allowed → [Excused]
          | got == Map.lookup k ref → [EqualAnswer]
          | otherwise → [Defect ("lookup " <> show k <> " answered " <> show got <> " but the reference holds " <> show (Map.lookup k ref))]
      judgeFloor k = case k of
        KeyRun col _ → case through h disk' tok (\w → readerFloorRun (hStore h) tok w col 25) of
          Left _ → [IntegrityError]
          Right got
            | Set.member k allowed → [Excused]
            | got == fmap (const (10, 20)) (Map.lookup k ref) → [EqualAnswer]
            | otherwise → [Defect ("floor of " <> show k <> " answered " <> show got)]
        _ → [Excused]
      -- the whole tree by ranged reads, from the first key
      fullScan = go (RangeFrom firstKey) [] (0 ∷ Int)
        where
          go start acc n
            | n > 200 = Right (reverse acc)
            | otherwise = case through h disk' tok (\w → readerRange (hStore h) tok w TreeRuns start 256) of
                Left e → Left e
                Right [] → Right (reverse acc)
                Right rs → go (RangeAfter (fst (last rs))) (reverse rs ++ acc) (n + 1)
      sortedKeys = sortOn encodeKey keys
      ceilRef k = case [x | x ← sortedKeys, encodeKey x >= encodeKey k] of
        (x : _) → Just x
        [] → Nothing
      -- the least key at or after a key, from the tree's own ceiling
      judgeCeil k =
        case throughM h disk' tok (ceilKey TreeRuns False (Just (Disk rootRef)) (encodeKey k)) of
          Left _ → [IntegrityError]
          Right got
            | Set.member k allowed → [Excused]
            | otherwise →
                let want = ceilRef k
                    gotKey = got >>= \(kb, _) → decodeKey TreeRuns kb
                    touchesChanged = maybe False (`Set.member` allowed) want || maybe False (`Set.member` allowed) gotKey
                 in if gotKey == want then [EqualAnswer]
                    else if touchesChanged then [Excused]
                    else [Defect ("ceiling of " <> show k <> " answered " <> show gotKey <> " but the reference's is " <> show want)]
      -- a ranged read that starts at a key must return what follows it
      judgeRange k = case through h disk' tok (\w → readerRange (hStore h) tok w TreeRuns (RangeFrom k) 12) of
        Left _ → [IntegrityError]
        Right got →
          let want = take 12 [x | x ← sortedKeys, encodeKey x >= encodeKey k]
              gotKeys = map fst got
           in if gotKeys == want then [EqualAnswer]
              else if any (`Set.member` allowed) (want ++ gotKeys) then [Excused]
              else [Defect ("a scan from " <> show k <> " answered " <> show (length gotKeys) <> " records that are not the reference's")]
      -- a page the tree reaches is never declared unreachable
      judgeLive = concat
        [ case throughM h disk' tok (livePageAt TreeRuns (Just (Disk rootRef)) kb lvl) of
            Left _ → [IntegrityError]
            Right Nothing → [Defect ("a live page " <> show q <> " was declared unreachable")]
            Right (Just found) → if found == PageNo q then [EqualAnswer] else [Defect ("page " <> show q <> " was found as " <> show found)]
        | q ← take 10 (every 5 livePagesBelow)
        , Just (kb, lvl) ← [firstKeyOf q]
        , not (Set.member (PageNo q) mutatedSet)
        , not (Set.member (PageNo q) orphaned)
        ]
      mutatedSet = Set.singleton (PageNo page)
      -- a child pointer that was changed leaves its old child referenced by nothing: that page is unreachable now,
      -- and saying so is true (the damage is the pointer, which a read through it reports)
      childrenOf bs = case decodePage (hIdent h) total (PageNo page) bs of
        Right (Page _ _ _ (Inner cs)) → Set.fromList (map snd cs)
        _ → Set.empty
      orphaned = childrenOf original `Set.difference` childrenOf mutated
      every n xs = [x | (i, x) ← zip [0 ∷ Int ..] xs, i `mod` n == 0]
      firstKeyOf q = case decodePage (hIdent h) total (PageNo q) =<< maybe (Left BadMagic) Right (diskRead (hDisk h) (PageNo q)) of
        Right (Page _ lv _ (Leaf ((kb, _) : _))) → Just (kb, lv)
        Right (Page _ lv _ (Inner ((kb, _) : _))) → Just (kb, lv)
        _ → Nothing
      judgeScan = case fullScan of
        Left _ → [IntegrityError]
        Right got →
          let gotMap = Map.fromList got
              missing = [k | k ← Map.keys ref, not (Set.member k allowed), Map.lookup k gotMap /= Map.lookup k ref]
              extra = [k | k ← Map.keys gotMap, not (Set.member k allowed), not (Map.member k ref)]
           in if null missing && null extra then [EqualAnswer] else [Defect ("scan: " <> show (length missing) <> " records absent or different, " <> show (length extra) <> " extra")]
  let verdicts = concatMap judgeLookup sample ++ concatMap judgeFloor (take 12 sample) ++ concatMap judgeCeil nearBoundaries ++ concatMap judgeRange (every 3 nearBoundaries) ++ judgeLive ++ judgeScan
  Right ([Finding page offset newByte f | Defect f ← take 3 [v | v@(Defect _) ← verdicts]], tallyOf verdicts)

spec ∷ Spec
spec = describe "a re-sealed byte of a live page never changes what a read answers (except as data)" $ do
  (h0, keys) ← runIO (must (wide 6000))
  let ref = Map.fromList [(k, RecRun 20) | k ← keys]
      ArenaId a = siArena (hIdent h0)
      runsRoot = (\(PageNo p) → p) <$> committedRoot (hStore h0) TreeRuns
      pages = sortOn id (twPages (walkTree a (siSource (hIdent h0)) (diskRead (hDisk h0)) runsRoot))
  let parsedAt p = case diskRead (hDisk h0) (PageNo p) of
        Just bs → either (const Nothing) Just (decodePage (hIdent h0) (cfgUsablePages (hCfg h0)) (PageNo p) bs)
        Nothing → Nothing
      innerPages = [p | p ← pages, Just (Page _ lvl _ (Inner _)) ← [parsedAt p], lvl >= 1]
      leafPages = [p | p ← pages, Just (Page _ 0 _ (Leaf _)) ← [parsedAt p]]
      -- the byte offsets of the first separators and children of an internal page, where the structure sits
      structural g = 40 + fromIntegral (g `mod` 120)
  it "reads every record exactly or fails as corrupt, over fixed seeds of one-byte mutations" $ do
    length pages `shouldSatisfy` (> 20)
    innerPages `shouldSatisfy` (not . null)
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
    let h = h0 {hStore = s1}
        runSeed seed = do
          let rolls = take 60 (iterate (snd . nextWord) (mkRng seed))
          forM rolls $ \g → do
            let (w1, g1) = nextWord g
                (w2, g2) = nextWord g1
                (w3, _) = nextWord g2
                -- most mutations go to the few internal pages, where a separator or a child sits
                page
                  | w1 `mod` 10 < 6 = innerPages !! fromIntegral ((w1 `div` 10) `mod` fromIntegral (length innerPages))
                  | otherwise = leafPages !! fromIntegral ((w1 `div` 10) `mod` fromIntegral (length leafPages))
                offset = if w2 `mod` 2 == 0 then structural (w2 `div` 2) else 24 + fromIntegral (w2 `div` 2 `mod` 4000)
                newByte = w3 `mod` 256
            pure (either (\e → ([Finding page offset newByte e], mempty)) id (fuzzOnce h tok ref keys page offset newByte))
    results ← fmap concat (mapM runSeed [101, 202, 303, 404, 505, 606])
    let found = concatMap fst results
        tally = mconcat (map snd results)
    -- the counts the run is judged by: both outcomes happen, and nothing else
    putStrLn ("FUZZ " <> show tally)
    tMutations tally `shouldBe` 360
    tIntegrity tally `shouldSatisfy` (> 0)
    tEqual tally `shouldSatisfy` (> 0)
    case found of
      [] → pure ()
      fs → expectationFailure (unlines (map show (take 12 fs)) <> show (length fs) <> " findings")

  it "never reads a record that exists as absent when a separator is moved to another valid key, raised or lowered, the first or a later one" $ do
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
    let h = h0 {hStore = s1}
        total = cfgUsablePages (hCfg h0)
    rootNo ← maybe (expectationFailure "a runs root" >> fail "root") pure runsRoot
    let decodeAt p = maybe (Left "page missing") (either (Left . show) Right . decodePage (hIdent h0) total (PageNo p)) (diskRead (hDisk h0) (PageNo p))
    Page _ lvl _ rootBody ← must (decodeAt rootNo)
    es ← case rootBody of
      Inner xs@(_ : _ : _) → pure xs
      other → expectationFailure ("an inner runs root with two children expected: " <> take 100 (show other)) >> fail "root"
    let leafKeys c = case decodeAt (let PageNo q = c in q) of
          Right (Page _ 0 _ (Leaf ls)) → map fst ls
          _ → []
    firstLeaf ← case es of
      ((_, c0) : _) → pure (leafKeys c0)
      [] → fail "no children"
    secondLeaf ← case es of
      (_ : (_, c1) : _) → pure (leafKeys c1)
      _ → fail "no second child"
    firstLeaf `shouldSatisfy` ((> 6) . length)
    secondLeaf `shouldSatisfy` ((> 6) . length)
    let withSeparator i kb = [(if j == i then kb else k, c) | (j, (k, c)) ← zip [0 ∷ Int ..] es]
        variants =
          [ ("the first separator raised inside the first leaf", withSeparator 0 (firstLeaf !! 5))
          , ("the second separator lowered into the first leaf", withSeparator 1 (firstLeaf !! 5))
          , ("the second separator raised inside the second leaf", withSeparator 1 (secondLeaf !! 5))
          ]
    forM_ variants $ \(what, es') → do
      bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h0) (Page TreeRuns lvl (PageNo rootNo) (Inner es')))
      case judgeMutated h tok ref keys rootNo 0 0 bytes of
        Left e → expectationFailure (what <> ": " <> e)
        Right ([], tally) → do
          -- the reads of a moved separator are integrity failures or exactly the reference's answers
          putStrLn ("FUZZ separator " <> what <> ": " <> show tally)
          tDefects tally `shouldBe` 0
        Right (fs, _) → expectationFailure (what <> ": " <> unlines (map show fs))
      -- and the records it hid are integrity failures, not answers: no read of the first leaf's first record succeeds
      let disk' = diskWrite (PageNo rootNo) bytes (hDisk h0)
          firstKey = case keys of (k : _) → k; [] → KeyTodo 0
          hidden = case through h disk' tok (\w → readerLookup (hStore h) tok w firstKey) of
            Left _ → True
            Right got → got == Map.lookup firstKey ref
      (what, hidden) `shouldBe` (what, True)
