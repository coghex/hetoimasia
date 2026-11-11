-- | The keys of every tree: every kind a tree holds, its length and its first byte, from the encoders; the kinds of one tree are
-- disjoint and ordered over the FULL range of their fields; and the store works across the whole range of its version counter.
--
-- Two kinds of key in one tree were told apart by a marker that is also a legal first byte of the other kind: an entry of the
-- retirement tree was its 8-byte version and a retired-page record @0xFF@ and a page, so from version @0xff00000000000000@ the
-- two interleaved and maintenance answered 'NoWork' with a page retired. Every retirement key is now a tag byte and a number
-- (@0x00@ a version, @0xFF@ a page): one key length, disjoint kinds, each ordered by its number.
module Test.TerrainRuntime.Store.Keys (spec) where

import Control.Monad (foldM, forM_)
import qualified Data.ByteString as BS
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Node (..), Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Harness

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | The edges of a 64-bit field: zero, one, the middle, the bytes where a prefix or a tag could collide, and the top.
edges ∷ [Word64]
edges = [0, 1, 2, 0x7f, 0x80, 0xfe, 0xff, 0x100, 0xfeffffffffffffff, 0xff00000000000000, 0xff00000000000001, 0xffffffffffffff00, maxBound - 1, maxBound]

-- | A store that STARTS at a given version (the counter a long-lived store reaches), with the records and the disk of 'newH'.
newHAt ∷ Word64 → H
newHAt v = h0 {hStore = storeFromRoots (hCfg h0) ident0 ((storeRoots (hStore h0)) {rVersion = v})}
  where
    h0 = newH smallSpec ident0

commitWrites ∷ H → [(RecordKey, Maybe Record)] → Either String H
commitWrites h ws = do
  (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) True False 1 ws)
  case out of
    Committed _ → Right h'
    Nothing' → Right h'
    Refusal' why → Left ("refused: " <> show why)

spec ∷ Spec
spec = describe "the keys of every tree: kinds, lengths, namespaces, and the whole range of the version counter" $ do
  it "TABLE: every tree and every kind of key it holds, its length and first byte, from the encoders; one key length per tree except the links tree" $ do
    let kinds ∷ [(String, String, [BS.ByteString])]
        kinds =
          [ ("runs", "run", [encodeKey (runKey x y lo) | x ← [0, 1, 99], y ← [0, 1, 99], lo ← [0, 1, 100]])
          , ("links", "source node", [encodeKey (linkKey (srcNode x y z)) | x ← [0, 1, 7], y ← [0, 3], z ← [0, 5]])
          , ("links", "run node", [encodeKey (linkKey (RunNode (columnAt x y) (fromInteger lo))) | x ← [0, 1, 7], y ← [0, 3], lo ← [0, 5]])
          , ("todo", "sequence", [encodeKey (todoKey n) | n ← edges])
          , ("free", "extent", [fst (encodeFree s 1) | s ← edges])
          , ("retire", "entry (version)", [versionKey v | v ← edges])
          , ("retire", "retired page", [retiredKey (PageNo p) | p ← edges])
          ]
        table = [(t, k, nub (map BS.length ks), nub (map (BS.take 1) ks)) | (t, k, ks) ← kinds]
    putStrLn ("KEYS table (tree, kind, lengths, first bytes): " <> show table)
    -- one key length per tree, except the links tree (source node 52 bytes, run node 25)
    let lengthsOf t = nub (concat [ls | (t', _, ls, _) ← table, t' == t])
    [(t, lengthsOf t) | t ← ["runs", "todo", "free", "retire"], length (lengthsOf t) /= 1] `shouldBe` []
    sort (lengthsOf "links") `shouldBe` [25, 52]
    lengthsOf "retire" `shouldBe` [retireKeyBytes]
  it "the kinds of the retirement tree are disjoint and each is ordered by its number, over the full range of its field" $ do
    let versions = sort edges
        pages = sort edges
    -- every entry key sorts before every retired-page key, whatever the version and the page
    [(v, p) | v ← edges, p ← edges, versionKey v >= retiredKey (PageNo p)] `shouldBe` []
    -- each kind orders as its number does, across the whole range (an 8-byte version had no such order against the tagged pages)
    map versionKey versions `shouldBe` sort (map versionKey versions)
    map (retiredKey . PageNo) pages `shouldBe` sort (map (retiredKey . PageNo) pages)
    [(a, b) | a ← edges, b ← edges, (a < b) /= (versionKey a < versionKey b)] `shouldBe` []
    [(a, b) | a ← edges, b ← edges, (a < b) /= (retiredKey (PageNo a) < retiredKey (PageNo b))] `shouldBe` []
    -- a key is of one kind or the other, and the predicate says which
    [v | v ← edges, not (isRetireEntryKey (versionKey v)) || isRetireEntryKey (retiredKey (PageNo v))] `shouldBe` []
  it "the reviewer's repro: from version 0xff00000000000000, a replaced run is a retired page and maintenance reclaims it (it answered NoWork)" $ do
    let h0 = newHAt 0xff00000000000000
        key = runKey 1 1 10
    h1 ← must (commitWrites h0 [(key, Just (runRec 20))])
    h2 ← must (commitWrites h1 [(key, Just (runRec 30))])
    rRetiredPages (storeRoots (hStore h2)) `shouldSatisfy` (> 0)
    (p, _, _) ← must (fillWith h2 (planMaintenance (hStore h2)))
    case p of
      Planned _ → pure ()
      other → expectationFailure ("maintenance did not plan across the boundary: " <> take 200 (show other))
    (drained, _) ← must (reclaimAll h2)
    rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
    must (checkH drained)
  it "runs a history of inserts, replacements, deletions and maintenance from a store that starts at each edge of the version counter: the checker and a full read agree after every step, and the counter ends in the typed refusal" $ do
    let starts = [0, 0xfe, 0xff, 0x100, 0xfeffffffffffff00, 0xff00000000000000, 0xffffffffffffff00 ∷ Word64]
        keys = [runKey (toInteger (i `div` 7)) (toInteger (i `mod` 7)) 10 | i ← [0 .. 119 ∷ Int]]
        step (h, ref) i = do
          let ws = [(k, if (i + j) `mod` 5 == 0 then Nothing else Just (runRec (toInteger (20 + (i * 3 + j) `mod` 11)))) | (j, k) ← zip [0 ∷ Int ..] (take 30 (drop ((i * 17) `mod` 90) keys))]
          h' ← commitWrites h ws
          let ref' = foldl (\m (k, v) → maybe (Map.delete k m) (\x → Map.insert k x m) v) ref ws
          must' (checkH h')
          must' (compareRecords (Map.toList ref') h')
          -- maintenance between some of them
          if i `mod` 3 == 0 then (\(h2, _) → (h2, ref')) <$> reclaimAllWithin 40 h' else Right (h', ref')
        must' = either Left Right
    forM_ starts $ \v → do
      (h, ref) ← must (foldM step (newHAt v, Map.empty) [1 .. 24])
      must (checkH h)
      (drained, _) ← must (reclaimAll h)
      rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
      must (compareRecords (Map.toList ref) drained)
    -- the counter ends in the typed refusal, never a wrap: the last commits before maxBound succeed, the one past it is refused
    let top = newHAt (maxBound - 3)
        k = runKey 2 2 10
    h1 ← must (commitWrites top [(k, Just (runRec 20))])
    h2 ← must (commitWrites h1 [(k, Just (runRec 21))])
    h3 ← must (commitWrites h2 [(k, Just (runRec 22))])
    rVersion (storeRoots (hStore h3)) `shouldBe` maxBound
    case commitDelta h3 Ordinary (deltaFor (hStore h3) True False 1 [(k, Just (runRec 23))]) of
      Right (_, Refusal' (Invalid VersionArithmetic)) → pure ()
      Right (_, out) → expectationFailure ("the commit past the last version was not the typed refusal: " <> take 200 (show out))
      Left e → expectationFailure ("the commit past the last version failed: " <> e)
