-- | The copy-on-write B+tree over immutable pages: bounded reads through a window
-- of validated page buffers, and updates that never touch a committed page.
--
-- = The window
--
-- Every operation reads through a 'Window', a bounded set of validated page buffers
-- pages the caller has supplied. A page the operation needs and the window lacks
-- stops it with @'Need' page@: the pending result of a missing page, never an
-- empty index or an absent key. The caller fetches the page, adds it and runs the
-- operation again; the window is the continuation, so no work is lost and no
-- history-sized structure is retained. A page that fails its decode is never in
-- the window, and a page the tree reaches that contradicts its parent (a wrong
-- tree, a wrong level, a key outside the parent's separators) is refused with
-- 'Bad'.
--
-- = Structure
--
-- Leaves hold sorted key and value entries; an internal page holds sorted
-- separators, each the least key its child may hold, and child pages one level
-- lower. A key belongs to the last child whose separator is at most the key. The
-- root is the only node that may hold few entries. After a deletion every other
-- node that falls below a quarter of a payload ('minNodeBytes') is repacked with a
-- neighbour under the same parent, either merged into one page or split evenly
-- into two, so adjacent siblings never both fit one page and every non-root node
-- is at least a quarter full. An insertion that overflows splits a node by
-- bytes; a root that splits grows the tree by one level (refused beyond
-- 'maxLevel', never truncated) and a root left with one child gives its level back.
--
-- = Copy on write
--
-- An update copies each page it changes into an 'Edit' overlay and records the
-- committed page it replaces; a page already in the overlay is changed in place.
-- Nothing is numbered until the plan is finished: 'assignPages' gives the
-- reachable overlay pages their page numbers, children first, from the supply the
-- allocator chose, and 'freshPages' encodes them. An overlay page a later step
-- made unreachable costs nothing.
--
-- The worst cost of one update at height @h@ is @2h + 1@ new pages (a copy of the
-- path, a split at every level and a new root); a deletion copies the path and one
-- neighbour per level, at most @2h@.
--
-- State, ownership and lifetime: none beyond the values passed. An 'Edit' is the
-- working state of one plan and is discarded with it.
module Hetoimasia.Terrain.Runtime.Store.Internal.Tree
  ( -- * Window
    Window
  , emptyWindow
  , windowInsert
  , windowSize
  , windowVersion
  , windowIdentity
  , windowBytes
  , windowPageOverhead
  , windowPageNumbers
  , windowMember
  , windowPage

    -- * Plans
  , Stop (..)
  , M
  , runM
  , Edit
  , newEdit
  , editSteps
  , editReplaced
  , editWindow
  , editFreshBytes
  , overlayNodeBytes
  , hotNodes
  , hotNodeBytes
  , Ref (..)
  , liftStop
  , failInvariant

    -- * Reads
  , lookupKey
  , floorKey
  , ceilKey
  , rangeKeys

    -- * Updates
  , insertKey
  , deleteKey

    -- * Finishing
  , freshCount
  , assignPages
  , worstUpdatePages
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page

-- ---------------------------------------------------------------------------
-- Window

-- | A validated page buffer a window keeps: the 4 KiB buffer and what a lookup needs
-- to place it. The entries are parsed from the buffer when a node is visited, so the
-- window's memory is the pages and not a pointer structure around each of them.
data VPage = VPage
  { vpTree ∷ !TreeId
  , vpLevel ∷ !Int
  , vpBytes ∷ !ByteString
  }
  deriving stock (Eq, Show)

-- | Validated pages the caller has supplied, for one store and one version of it. A
-- window is the continuation of one plan or read; it is bound to the arena and source
-- it was made for (a page of another store is refused on insertion and a plan or read
-- through a window of another store or version is refused) and it is never carried
-- across a published version, because a page number may then name other content.
data Window = Window !StoreIdentity !Word64 !(Map PageNo VPage)
  deriving stock (Eq, Show)

-- | An empty window for a store and a version.
emptyWindow ∷ StoreIdentity → Word64 → Window
emptyWindow ident v = Window ident v Map.empty

-- | The version the window was filled for.
windowVersion ∷ Window → Word64
windowVersion (Window _ v _) = v

-- | The store the window was made for.
windowIdentity ∷ Window → StoreIdentity
windowIdentity (Window i _ _) = i

-- | The accounted bytes a window holds: each page's 4 KiB buffer and the map entry
-- and headers around it ('windowPageOverhead').
windowBytes ∷ Window → Int
windowBytes (Window _ _ m) = Map.size m * (pageSize + windowPageOverhead)

-- | The accounted overhead of one page in a window beyond its buffer.
windowPageOverhead ∷ Int
windowPageOverhead = 128

-- | Decode a page read for a page number against the window's store and add it. A page
-- that fails any check is refused and the window is unchanged.
windowInsert ∷ Word64 → PageNo → ByteString → Window → Either PageError Window
windowInsert total no bytes (Window ident v m) = do
  page ← decodePage ident total no bytes
  Right (Window ident v (Map.insert no (VPage (pgTree page) (pgLevel page) bytes) m))

windowSize ∷ Window → Int
windowSize (Window _ _ m) = Map.size m

windowPageNumbers ∷ Window → [PageNo]
windowPageNumbers (Window _ _ m) = Map.keys m

windowMember ∷ PageNo → Window → Bool
windowMember p (Window _ _ m) = Map.member p m

-- | A page the window holds, parsed into a value.
windowPage ∷ PageNo → Window → Maybe Page
windowPage p (Window _ _ m) = (\vp → Page (vpTree vp) (vpLevel vp) p (bodyOfValid (vpBytes vp))) <$> Map.lookup p m

-- ---------------------------------------------------------------------------
-- The plan monad

-- | Why an operation stopped.
data Stop
  = -- | A page the operation needs is not in the window: the work is pending.
    Need !PageNo
  | -- | A page contradicts its place in the tree, or the structure is invalid.
    Bad !PageError !PageNo
  | -- | An update would make the tree taller than 'maxLevel'.
    TooTall !TreeId
  | -- | An internal invariant of the tree code failed (never a caller's fault).
    Invariant !TreeId
  | -- | The overlay of new pages would hold more bytes than a plan may: the figure.
    Over !Int
  deriving stock (Eq, Show)

-- | A reference to a node: a committed page or an overlay page.
data Ref = Disk !PageNo | Fresh !Int
  deriving stock (Eq, Ord, Show)

data NBody
  = NLeaf [(ByteString, ByteString)]
  | NInner [(ByteString, Ref)]
  deriving stock (Eq, Show)

data Node = Node
  { nTree ∷ !TreeId
  , nLevel ∷ !Int
  , nBody ∷ !NBody
  }
  deriving stock (Eq, Show)

-- | The committed nodes a plan keeps parsed: the last 8 (per tree edit).
hotNodes ∷ Int
hotNodes = 8

-- | The accounted bytes of one parsed node held in that set: a dense leaf's entry
-- list, a cons cell, a pair and two string headers per entry (119 entries at most for a
-- record page and 225 for the smallest bookkeeping entry), rounded up.
hotNodeBytes ∷ Int
hotNodeBytes = 28000

-- | A new page held packed: its entries as one byte string.
data Stored = Stored !TreeId !Int !Bool !Int !ByteString

-- | The accounted bytes of one overlay page: its packed entries and a header.
overlayNodeBytes ∷ Int → Int
overlayNodeBytes payload = payload + 160

packNode ∷ Node → Stored
packNode (Node t l body) = case body of
  NLeaf es → Stored t l True (length es) (packBody (Left es))
  NInner es → Stored t l False (length es) (packBody (Right [(k, refCode r) | (k, r) ← es]))
  where
    refCode (Disk (PageNo p)) = (0, p)
    refCode (Fresh i) = (1, fromIntegral i)

unpackNode ∷ Stored → Node
unpackNode (Stored t l leaf n pl) = case unpackBody leaf n pl of
  Left es → Node t l (NLeaf es)
  Right es → Node t l (NInner [(k, if tag == 0 then Disk (PageNo c) else Fresh (fromIntegral c)) | (k, (tag, c)) ← es])

-- | The working state of one plan: the window, the new pages (packed, accounted and
-- bounded by a byte budget), the committed pages replaced and the visits made.
data Edit = Edit
  { eWin ∷ !Window
  , eFresh ∷ !(IntMap Stored)
  , eFreshBytes ∷ !Int
  , eSizes ∷ !(IntMap Int)
  , eFreshHot ∷ [(Int, Node)]
  -- ^ The last few new pages written, kept parsed (at most 'hotNodes'); an older one is
  -- packed into 'eFresh'. Every new page is accounted at its packed size in 'eSizes'.
  , eBudget ∷ !Int
  , eNext ∷ !Int
  , eReplaced ∷ !(Set PageNo)
  , eSteps ∷ !Int
  , eHot ∷ [(PageNo, Node)]
  -- ^ The last few committed nodes parsed, so a run of updates in one neighbourhood
  -- does not parse the same page again for every key. At most 'hotNodes' are held and
  -- 'hotNodeBytes' each is accounted in a plan's scratch.
  }

-- | A fresh plan state over a window, whose new pages may hold at most the given
-- accounted bytes.
newEdit ∷ Int → Window → Edit
newEdit budget w = Edit w IntMap.empty 0 IntMap.empty [] budget 0 Set.empty 0 []

-- | The accounted bytes of the new pages the plan holds now.
editFreshBytes ∷ Edit → Int
editFreshBytes = eFreshBytes

-- | The page reads this plan has made, counting every visit: the measure of its
-- bounded read work.
editSteps ∷ Edit → Int
editSteps = eSteps

-- | The committed pages this plan replaced or removed.
editReplaced ∷ Edit → Set PageNo
editReplaced = eReplaced

editWindow ∷ Edit → Window
editWindow = eWin

newtype M a = M {unM ∷ Edit → Either Stop (a, Edit)}

instance Functor M where
  fmap f (M g) = M $ \e → case g e of
    Left s → Left s
    Right (a, e') → Right (f a, e')

instance Applicative M where
  pure a = M $ \e → Right (a, e)
  M f <*> M g = M $ \e → case f e of
    Left s → Left s
    Right (h, e') → case g e' of
      Left s → Left s
      Right (a, e'') → Right (h a, e'')

instance Monad M where
  M g >>= f = M $ \e → case g e of
    Left s → Left s
    Right (a, e') → unM (f a) e'

-- | Run a plan step from a state.
runM ∷ M a → Edit → Either Stop (a, Edit)
runM = unM

stop ∷ Stop → M a
stop s = M (\_ → Left s)

-- | Fail the plan because an invariant of the tree code does not hold.
failInvariant ∷ TreeId → M a
failInvariant = stop . Invariant

-- | Lift a failed decode of a page the caller supplied into the plan.
liftStop ∷ Either Stop a → M a
liftStop (Left s) = stop s
liftStop (Right a) = pure a

getEdit ∷ M Edit
getEdit = M (\e → Right (e, e))

putEdit ∷ Edit → M ()
putEdit e = M (\_ → Right ((), e))

-- | Load a node, counting the visit. The tree and level are checked against what
-- the parent expects.
load ∷ TreeId → Maybe Int → Ref → M Node
load tree expectLevel ref = do
  e ← getEdit
  putEdit e {eSteps = eSteps e + 1}
  node ← case ref of
    Fresh i → maybe (stop (Invariant tree)) pure (freshNode e i)
    Disk p → case lookup p (eHot e) of
      Just hot | nTree hot == tree → pure hot
      _ → case eWin e of
        Window _ _ m → case Map.lookup p m of
          Nothing → stop (Need p)
          Just vp → case nodeOfPage tree p (Page (vpTree vp) (vpLevel vp) p (bodyOfValid (vpBytes vp))) of
            Left err → stop (Bad err p)
            Right n → do
              e2 ← getEdit
              putEdit e2 {eHot = take hotNodes ((p, n) : filter ((/= p) . fst) (eHot e2))}
              pure n
  case expectLevel of
    Just l | l /= nLevel node → stop (Bad (BadLevel (nLevel node)) (refPage ref))
    _ → pure node

refPage ∷ Ref → PageNo
refPage (Disk p) = p
refPage (Fresh _) = PageNo maxBound

nodeOfPage ∷ TreeId → PageNo → Page → Either PageError Node
nodeOfPage tree _ (Page t level _ body)
  | t /= tree = Left KindMismatch
  | otherwise = case body of
      Leaf es → Right (Node tree 0 (NLeaf es))
      Inner es → Right (Node tree level (NInner [(k, Disk c) | (k, c) ← es]))
      List _ → Left KindMismatch

-- | The keys a node holds must lie in the range its parent promises.
checkBounds ∷ Maybe ByteString → Maybe ByteString → Ref → Node → M ()
checkBounds lo hi ref node = case keysOf node of
  [] → stop (Bad KeyOrder (refPage ref))
  ks@(k0 : _)
    | maybe False (k0 <) lo → stop (Bad KeyOrder (refPage ref))
    | maybe False (\h → last ks >= h) hi → stop (Bad KeyOrder (refPage ref))
    | otherwise → pure ()

keysOf ∷ Node → [ByteString]
keysOf (Node _ _ (NLeaf es)) = map fst es
keysOf (Node _ _ (NInner es)) = map fst es

loadChecked ∷ TreeId → Maybe ByteString → Maybe ByteString → Maybe Int → Ref → M Node
loadChecked tree lo hi lvl ref = do
  node ← load tree lvl ref
  checkBounds lo hi ref node
  pure node

-- ---------------------------------------------------------------------------
-- Reads

-- | The index of the last separator at most the key, if any.
chooseChild ∷ ByteString → [(ByteString, a)] → Maybe Int
chooseChild k es = case length (takeWhile ((<= k) . fst) es) of
  0 → Nothing
  n → Just (n - 1)

-- | The bounds a child's keys lie in, from its position among its siblings.
childBounds ∷ Maybe ByteString → Maybe ByteString → [(ByteString, Ref)] → Int → (Maybe ByteString, Maybe ByteString)
childBounds lo hi es i =
  ( Just (fst (es !! i)) `orElse` lo
  , if i + 1 < length es then Just (fst (es !! (i + 1))) else hi
  )
  where
    orElse a _ = a

-- | The value stored under a key.
lookupKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe ByteString)
lookupKey _ Nothing _ = pure Nothing
lookupKey tree (Just root) k = go root Nothing Nothing Nothing
  where
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (lookup k es)
        NInner es → case chooseChild k es of
          Nothing → pure Nothing
          Just i →
            let (lo', hi') = childBounds lo hi es i
             in go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))

-- | The greatest entry whose key is at most the given key.
floorKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
floorKey _ Nothing _ = pure Nothing
floorKey tree (Just root) k = go root Nothing Nothing Nothing
  where
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (lastMaybe (takeWhile ((<= k) . fst) es))
        NInner es → case chooseChild k es of
          Nothing → pure Nothing
          Just i → do
            let (lo', hi') = childBounds lo hi es i
            r ← go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
            case r of
              Just _ → pure r
              Nothing
                | i > 0 →
                    let (plo, phi) = childBounds lo hi es (i - 1)
                     in extreme False (snd (es !! (i - 1))) plo phi (Just (nLevel n - 1))
                | otherwise → pure Nothing
    extreme leftmost ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (if leftmost then headMaybe es else lastMaybe es)
        NInner es →
          let i = if leftmost then 0 else length es - 1
              (lo', hi') = childBounds lo hi es i
           in extreme leftmost (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
    lastMaybe [] = Nothing
    lastMaybe xs = Just (last xs)
    headMaybe [] = Nothing
    headMaybe (x : _) = Just x

-- | The least entry whose key is at least (or, when strict, greater than) the key.
ceilKey ∷ TreeId → Bool → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
ceilKey _ _ Nothing _ = pure Nothing
ceilKey tree strict (Just root) k = go root Nothing Nothing Nothing
  where
    keep key = if strict then key > k else key >= k
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (firstMaybe (filter (keep . fst) es))
        NInner es → do
          let i = maybe 0 id (chooseChild k es)
              (lo', hi') = childBounds lo hi es i
          r ← go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
          case r of
            Just _ → pure r
            Nothing
              | i + 1 < length es →
                  let (nlo, nhi) = childBounds lo hi es (i + 1)
                   in leftmost (snd (es !! (i + 1))) nlo nhi (Just (nLevel n - 1))
              | otherwise → pure Nothing
    leftmost ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (firstMaybe es)
        NInner [] → failInvariant tree
        NInner es@((_, c0) : _) →
          let (lo', hi') = childBounds lo hi es 0
           in leftmost c0 lo' hi' (Just (nLevel n - 1))
    firstMaybe [] = Nothing
    firstMaybe (x : _) = Just x

-- | Up to @limit@ entries in key order from the first key at or after the start (or
-- strictly after it), stopping before a key at or after the end. Each entry costs
-- one bounded successor lookup, so the work is at most @limit@ times the tree's
-- height.
rangeKeys ∷ TreeId → Maybe Ref → Bool → ByteString → Maybe ByteString → Int → M [(ByteString, ByteString)]
rangeKeys _ Nothing _ _ _ _ = pure []
rangeKeys tree (Just root) strictStart start end limit = do
  (es, _, _) ← go root Nothing Nothing Nothing limit
  pure es
  where
    keep k = (if strictStart then k > start else k >= start) && maybe True (k <) end
    beforeEnd k = maybe True (k <) end
    -- Entries in order, how many more may be taken and whether the end was reached.
    go ref lo hi lvl n
      | n <= 0 = pure ([], 0, False)
      | otherwise = do
          nd ← loadChecked tree lo hi lvl ref
          case nBody nd of
            NLeaf es → do
              let inRange = filter (\(k, _) → keep k) es
                  taken = take n inRange
                  past = any (\(k, _) → not (beforeEnd k)) es
              pure (taken, n - length taken, past)
            NInner es → do
              let i0 = maybe 0 id (chooseChild start es)
              children nd lo hi es [i0 .. length es - 1] n []
    children _ _ _ _ [] n acc = pure (concat (reverse acc), n, False)
    children nd lo hi es (i : is) n acc
      | n <= 0 = pure (concat (reverse acc), 0, False)
      | maybe False (\e → fst (es !! i) >= e) end = pure (concat (reverse acc), n, True)
      | otherwise = do
          let (clo, chi) = childBounds lo hi es i
          (got, n', past) ← go (snd (es !! i)) clo chi (Just (nLevel nd - 1)) n
          if past
            then pure (concat (reverse (got : acc)), n', True)
            else children nd lo hi es is n' (got : acc)

-- ---------------------------------------------------------------------------
-- Overlay

-- | A new page as a parsed node: from the hot set, or unpacked from its packed form.
freshNode ∷ Edit → Int → Maybe Node
freshNode e i = case lookup i (eFreshHot e) of
  Just n → Just n
  Nothing → unpackNode <$> IntMap.lookup i (eFresh e)

-- | The accounted bytes of a node held packed: the length of its packed entries and a
-- header, computed without packing it.
packedBytes ∷ Node → Int
packedBytes (Node _ _ body) = overlayNodeBytes (case body of
  NLeaf es → sum [2 + BS.length k + BS.length v | (k, v) ← es]
  NInner es → sum [1 + BS.length k + 9 | (k, _) ← es])

-- | Set a new page, accounting its packed bytes and refusing the plan when the new
-- pages would hold more than the budget. The page is kept parsed in a small hot set;
-- the page that falls out of it is packed.
setFresh ∷ Int → Node → Edit → M Edit
setFresh i node e = do
  let size = packedBytes node
      total = eFreshBytes e - IntMap.findWithDefault 0 i (eSizes e) + size
  if total > eBudget e
    then stop (Over total)
    else do
      let hot = (i, node) : filter ((/= i) . fst) (eFreshHot e)
          (keep, spill) = splitAt hotNodes hot
          packedOut = foldr (\(j, n) m → IntMap.insert j (packNode n) m) (IntMap.delete i (eFresh e)) spill
      pure e {eFresh = packedOut, eFreshHot = keep, eSizes = IntMap.insert i size (eSizes e), eFreshBytes = total}

-- | Put a node in the overlay under a reference that is being rewritten: an overlay
-- page is changed in place; a committed page is recorded as replaced and its copy
-- gets a new overlay number.
rewrite ∷ Ref → Node → M Ref
rewrite (Fresh i) node = do
  e ← getEdit
  e' ← setFresh i node e
  putEdit e'
  pure (Fresh i)
rewrite (Disk p) node = do
  e ← getEdit
  let i = eNext e
  e' ← setFresh i node e
  putEdit e' {eNext = i + 1, eReplaced = Set.insert p (eReplaced e')}
  pure (Fresh i)

-- | A node with no committed predecessor.
fresh ∷ Node → M Ref
fresh node = do
  e ← getEdit
  let i = eNext e
  e' ← setFresh i node e
  putEdit e' {eNext = i + 1}
  pure (Fresh i)

-- | Drop a node that is no longer part of the tree.
discard ∷ Ref → M ()
discard (Fresh i) = do
  e ← getEdit
  let old = IntMap.findWithDefault 0 i (eSizes e)
  putEdit e {eFresh = IntMap.delete i (eFresh e), eFreshHot = filter ((/= i) . fst) (eFreshHot e), eSizes = IntMap.delete i (eSizes e), eFreshBytes = eFreshBytes e - old}
discard (Disk p) = do
  e ← getEdit
  putEdit e {eReplaced = Set.insert p (eReplaced e)}

bodyBytesOf ∷ NBody → Int
bodyBytesOf (NLeaf es) = sum (map entryBytes es)
bodyBytesOf (NInner es) = sum [1 + BS.length k + 8 | (k, _) ← es]

nodeBytesOf ∷ Node → Int
nodeBytesOf = bodyBytesOf . nBody

-- | The split of a list of sized entries into two non-empty halves that each fit a
-- payload, as even as the entries allow.
splitEven ∷ (a → Int) → [a] → Maybe ([a], [a])
splitEven size xs
  | null candidates = Nothing
  | otherwise = Just (splitAt (snd (minimum candidates)) xs)
  where
    total = sum (map size xs)
    prefixes = scanl1 (+) (map size xs)
    candidates =
      [ (abs (2 * p - total), j)
      | (j, p) ← zip [1 ..] (init prefixes)
      , p <= pagePayloadBytes
      , total - p <= pagePayloadBytes
      ]

-- ---------------------------------------------------------------------------
-- Insert

data Ins = InsOne !Ref | InsTwo !Ref !ByteString !Ref

-- | Insert or replace an entry and return the new root. An entry already holding
-- the value changes nothing (no copy, no replaced page): a no-op appends nothing.
insertKey ∷ TreeId → Maybe Ref → ByteString → ByteString → M (Maybe Ref)
insertKey tree root k v = do
  existing ← lookupKey tree root k
  if existing == Just v
    then pure root
    else case root of
      Nothing → Just <$> fresh (Node tree 0 (NLeaf [(k, v)]))
      Just r → do
        res ← ins r Nothing Nothing Nothing
        case res of
          InsOne r' → pure (Just r')
          InsTwo a sep b → do
            na ← load tree Nothing a
            let level = nLevel na + 1
            if level > maxLevel
              then stop (TooTall tree)
              else do
                lowest ← firstOf na
                Just <$> fresh (Node tree level (NInner [(lowest, a), (sep, b)]))
  where
    firstOf n = case keysOf n of
      (x : _) → pure x
      [] → stop (Invariant tree)
    ins ref lo hi lvl = do
      n ← loadChecked' lo hi lvl ref
      case nBody n of
        NLeaf es → do
          let es' = insertSorted (k, v) es
          finish ref n (NLeaf es')
        NInner es → do
          let i = maybe 0 id (chooseChild k es)
              (clo, chi) = childBounds lo hi es i
              below = maybe False (k <) (firstSep es)
              (clo', chi') = if below then (lo, chi) else (clo, chi)
          r ← ins (snd (es !! i)) clo' chi' (Just (nLevel n - 1))
          let relabel (sk, c) = if i == 0 && below then (k, c) else (sk, c)
              es' = case r of
                InsOne c → take i es ++ [relabel (fst (es !! i), c)] ++ drop (i + 1) es
                InsTwo c1 sep c2 → take i es ++ [relabel (fst (es !! i), c1), (sep, c2)] ++ drop (i + 1) es
          finish ref n (NInner es')
    -- A freshly inserted key may sit below the node's lowest key only on the
    -- leftmost spine, whose bounds are open; the check there tolerates it.
    loadChecked' lo hi lvl ref = do
      node ← load tree lvl ref
      case keysOf node of
        [] → stop (Bad KeyOrder (refPage ref))
        ks@(k0 : _)
          | maybe False (k0 <) lo → stop (Bad KeyOrder (refPage ref))
          | maybe False (\h → last ks >= h) hi → stop (Bad KeyOrder (refPage ref))
          | otherwise → pure node
    finish ref n body
      | bodyBytesOf body <= pagePayloadBytes = InsOne <$> rewrite ref n {nBody = body}
      | otherwise = case body of
          NLeaf es → case splitEven entryBytes es of
            Nothing → stop (Invariant tree)
            Just (l, r@((sk, _) : _)) → twoNodes ref n (NLeaf l) (NLeaf r) sk
            Just _ → stop (Invariant tree)
          NInner es → case splitEven (\(sk, _) → 1 + BS.length sk + 8) es of
            Nothing → stop (Invariant tree)
            Just (l, r@((sk, _) : _)) → twoNodes ref n (NInner l) (NInner r) sk
            Just _ → stop (Invariant tree)
    twoNodes ref n l r sep = do
      a ← rewrite ref n {nBody = l}
      b ← fresh n {nBody = r}
      pure (InsTwo a sep b)

firstSep ∷ [(ByteString, a)] → Maybe ByteString
firstSep ((s, _) : _) = Just s
firstSep [] = Nothing

insertSorted ∷ (ByteString, ByteString) → [(ByteString, ByteString)] → [(ByteString, ByteString)]
insertSorted (k, v) es = before ++ [(k, v)] ++ dropWhile ((== k) . fst) after
  where
    (before, after) = span ((< k) . fst) es

-- ---------------------------------------------------------------------------
-- Delete

-- | Remove an entry and return the new root, rebalancing under-full nodes and
-- collapsing a root left with one child. An absent key changes nothing.
deleteKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe Ref)
deleteKey _ Nothing _ = pure Nothing
deleteKey tree root@(Just r0) k = do
  existing ← lookupKey tree root k
  case existing of
    Nothing → pure root
    Just _ → do
      res ← del r0 Nothing Nothing Nothing
      case res of
        Nothing → pure Nothing
        Just r → Just <$> collapse r
  where
    collapse ref = do
      n ← load tree Nothing ref
      case nBody n of
        NInner [(_, c)] → do
          discard ref
          collapse c
        _ → pure ref
    del ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → case filter ((/= k) . fst) es of
          [] → discard ref >> pure Nothing
          es' → Just <$> rewrite ref n {nBody = NLeaf es'}
        NInner es → do
          i ← maybe (stop (Invariant tree)) pure (chooseChild k es)
          let (clo, chi) = childBounds lo hi es i
          r ← del (snd (es !! i)) clo chi (Just (nLevel n - 1))
          es' ← case r of
            Nothing → pure (take i es ++ drop (i + 1) es)
            Just c → do
              cn ← load tree (Just (nLevel n - 1)) c
              let replaced = take i es ++ [(fst (es !! i), c)] ++ drop (i + 1) es
              if nodeBytesOf cn < minNodeBytes && length es >= 2
                then rebalance lo hi (nLevel n - 1) i replaced
                else pure replaced
          case es' of
            [] → discard ref >> pure Nothing
            _ → Just <$> rewrite ref n {nBody = NInner es'}
    -- Repack the under-full child at index i with a neighbour: one merged node
    -- when the pair fits a page, otherwise two nodes split evenly.
    rebalance lo hi childLevel i es = do
      let j = if i + 1 < length es then i + 1 else i - 1
          (a, b) = (min i j, max i j)
          (sa, ra) = es !! a
          (_, rb) = es !! b
          (alo, ahi) = childBounds lo hi es a
          (blo, bhi) = childBounds lo hi es b
      -- both siblings are checked against the separators their parent promises, so a
      -- malformed one is refused and never merged into a replacement page
      na ← loadChecked tree alo ahi (Just childLevel) ra
      nb ← loadChecked tree blo bhi (Just childLevel) rb
      combined ← case (nBody na, nBody nb) of
        (NLeaf x, NLeaf y) → pure (Left (x ++ y))
        (NInner x, NInner y) → pure (Right (x ++ y))
        _ → stop (Invariant tree)
      let repacked = case combined of
            Left xs → case packEntries entryBytes xs of
              Nothing → Nothing
              Just parts → Just (map NLeaf parts)
            Right xs → case packEntries (\(sk, _) → 1 + BS.length sk + 8) xs of
              Nothing → Nothing
              Just parts → Just (map NInner parts)
      case repacked of
        Nothing → pure es
        Just bodies → do
          mapM_ discardOrReuse [ra, rb]
          refs ← mapM (fresh . Node tree childLevel) bodies
          let firstKeys = [sa] ++ [k' | body ← drop 1 bodies, Just k' ← [firstKeyOf body]]
              entries = zip firstKeys refs
          pure (take a es ++ entries ++ drop (b + 1) es)
    discardOrReuse = discard
    firstKeyOf (NLeaf ((x, _) : _)) = Just x
    firstKeyOf (NInner ((x, _) : _)) = Just x
    firstKeyOf _ = Nothing

-- | One page when the entries fit, else the most even valid split into two.
packEntries ∷ (a → Int) → [a] → Maybe [[a]]
packEntries size xs
  | sum (map size xs) <= pagePayloadBytes = Just [xs]
  | otherwise = (\(l, r) → [l, r]) <$> splitEven size xs

-- ---------------------------------------------------------------------------
-- Finishing

reachableFresh ∷ Edit → [Maybe Ref] → [Int]
reachableFresh e roots = reverse (snd (foldl' visit (Set.empty, []) [r | Just r ← roots]))
  where
    visit acc (Disk _) = acc
    visit (seen, out) (Fresh i)
      | Set.member i seen = (seen, out)
      | otherwise = case freshNode e i of
          Nothing → (seen, out)
          Just n →
            let (seen', out') = case nBody n of
                  NLeaf _ → (Set.insert i seen, out)
                  NInner es → foldl' visit (Set.insert i seen, out) (map snd es)
             in (seen', i : out')

-- | How many overlay pages the given roots reach: the new pages the plan writes
-- for these trees.
freshCount ∷ Edit → [Maybe Ref] → Int
freshCount e roots = length (reachableFresh e roots)

-- | Number the reachable overlay pages from a supply of page numbers, children before
-- parents, and encode each one as it is built: one parsed page exists at a time, and
-- each output buffer is forced before the next page is built, so the result holds the
-- encoded pages and nothing around them. It fails if the supply is short or a page
-- does not encode.
assignPages ∷ (Page → Either PageError ByteString) → Edit → [Maybe Ref] → [PageNo] → Either Stop ([(PageNo, ByteString)], [Maybe PageNo], [PageNo])
assignPages encode e roots supply0 = do
  let order = reachableFresh e roots
  if length supply0 < length order
    then Left (Invariant TreeFree)
    else do
      let (used, rest) = splitAt (length order) supply0
          numbering = Map.fromList (zip order used) ∷ Map Int PageNo
          resolve (Disk p) = Right p
          resolve (Fresh i) = maybe (Left (Invariant TreeFree)) Right (Map.lookup i numbering)
          toPage i = do
            n ← maybe (Left (Invariant TreeFree)) Right (freshNode e i)
            no ← maybe (Left (Invariant TreeFree)) Right (Map.lookup i numbering)
            body ← case nBody n of
              NLeaf es → Right (Leaf es)
              NInner es → Inner <$> traverse (\(sk, c) → (,) sk <$> resolve c) es
            Right (Page (nTree n) (nLevel n) no body)
          step acc i = do
            page ← toPage i
            bytes ← either (\err → Left (Bad err (pgNo page))) Right (encode page)
            -- force the buffer now, so the parsed page it came from can go
            -- and the page number, which would otherwise keep the whole parsed page alive
            let PageNo no = pgNo page
            no `seq` BS.length bytes `seq` Right ((PageNo no, bytes) : acc)
      encoded ← foldM' step [] order
      rootNos ← traverse (traverse resolve) roots
      Right (reverse encoded, rootNos, rest)
  where
    foldM' f z xs = go z xs
      where
        go acc [] = Right acc
        go acc (y : ys) = f acc y >>= \acc' → go acc' ys

-- | The most new pages one update of a tree of the given height writes: a copy of
-- the path, a split at every level and a new root.
worstUpdatePages ∷ Int → Int
worstUpdatePages height = 2 * height + 1
