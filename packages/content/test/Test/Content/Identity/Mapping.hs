-- | The checked mapping from logical names to exact observed native components,
-- through the public identity boundary.
--
-- Evidence classes, labelled in each group: the mapping and its refusals are
-- pure and run on /supplied entries/, which is how a case-folding or
-- normalizing file system's collision is exercised wherever the file system
-- cannot hold both names. "Native trees" below creates real names in a
-- temporary directory, enumerates them with the content service, builds the
-- mapping from what the operating system reported, and opens the files by the
-- mapped native components. Where the file system folds or normalizes a pair of
-- names so both cannot exist, or refuses a non-UTF-8 name, that real case is
-- reported pending and the supplied-entry case stands as the evidence; none is
-- silently skipped, and the supplied entries are never claimed to prove native
-- behavior.
module Test.Content.Identity.Mapping (spec) where

import Control.Exception (IOException, evaluate, try)
import Control.Monad (forM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Internal (toForeignPtr0)
import Data.List (permutations, sort)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (isJust, isNothing)
import Hetoimasia.Content
  ( DirectoryEntry (..)
  , DirectoryReader
  , EntryKind (..)
  , FileMetadata (..)
  , fileMetadata
  , nativeNameBytes
  , readChunk
  , readEntry
  , withDirectory
  , withEntryDirectory
  , withFile
  )
import Hetoimasia.Content.Identity
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.Posix.ByteString (closeFd, createFile)
import System.Posix.Files (createLink)
import Test.Content.Identity.Support
import Test.Content.Support (drain, readAll, withRoot, withTree, writeBytes)
import Test.Hspec
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = do
  lookups
  collisions
  noCollisions
  structure
  entryBounds
  allowance
  diagnostics
  nativeTrees

-- | The mapping of a list of entries, which the example expects to build.
built ∷ [ObservedEntry] → IO NativeMapping
built entries = either (\refusal → fail ("refused: " <> show refusal)) pure (buildMapping m1 rootA entries)

-- | The reason an inventory was refused, if it was.
reasonFor ∷ [ObservedEntry] → Maybe InventoryReason
reasonFor entries = either (Just . inventoryReason) (const Nothing) (buildMapping m1 rootA entries)

-- | The exact native components a logical reference maps to.
nativeOf ∷ NativeMapping → ByteString → Maybe [ByteString]
nativeOf mapping reference =
  map nativeNameBytes . NonEmpty.toList . mappedNative <$> lookupPath mapping (contentKeyPath (keyOf rootA reference))

lookups ∷ Spec
lookups = describe "lookup (supplied entries)" $ do
  it "maps a logical path to the exact observed components" $ do
    mapping <- built [file ["images", "Hero.png"], file ["lua", "util.lua"]]
    nativeOf mapping "images/Hero.png" `shouldBe` Just ["images", "Hero.png"]
    nativeOf mapping "lua/util.lua" `shouldBe` Just ["lua", "util.lua"]
    mappingSize mapping `shouldBe` 2

  it "treats the directories a path passes through as addressable but not supplied" $ do
    mapping <- built [file ["images", "Hero.png"]]
    fmap mappedKind (lookupPath mapping (contentKeyPath (keyOf rootA "images"))) `shouldBe` Just ObservedDirectory
    fmap mappedSupplied (lookupPath mapping (contentKeyPath (keyOf rootA "images"))) `shouldBe` Just False
    fmap mappedSupplied (lookupPath mapping (contentKeyPath (keyOf rootA "images/Hero.png"))) `shouldBe` Just True
    mappingSize mapping `shouldBe` 1

  it "marks a directory supplied whether it arrives before or after its children" $ do
    first <- built [directory ["d"], file ["d", "x"]]
    second <- built [file ["d", "x"], directory ["d"]]
    mapM_
      (\mapping → fmap mappedSupplied (lookupPath mapping (contentKeyPath (keyOf rootA "d"))) `shouldBe` Just True)
      [first, second]
    mapM_ (\mapping → mappingSize mapping `shouldBe` 2) [first, second]

  it "finds a decomposed native name by its composed reference, returning the native spelling untouched" $ do
    mapping <- built [file ["cafe\x301.txt"]]
    nativeOf mapping (utf8 "caf\xe9.txt") `shouldBe` Just [utf8 "cafe\x301.txt"]
    nativeOf mapping (utf8 "cafe\x301.txt") `shouldBe` Just [utf8 "cafe\x301.txt"]

  it "finds a composed native name by its decomposed reference, and in a directory position" $ do
    mapping <- built [file ["d\xe9", "caf\xe9"]]
    nativeOf mapping (utf8 "de\x301/cafe\x301") `shouldBe` Just [utf8 "d\xe9", utf8 "caf\xe9"]

  it "requires the exact case: a case mismatch is missing content, with no native fallback" $ do
    mapping <- built [file ["images", "Hero.png"]]
    nativeOf mapping "images/hero.png" `shouldBe` Nothing
    nativeOf mapping "Images/Hero.png" `shouldBe` Nothing
    nativeOf mapping "IMAGES/HERO.PNG" `shouldBe` Nothing
    nativeOf mapping "images/Hero.png" `shouldSatisfy` isJust

  it "does not find what the inventory does not hold, nor a prefix or an extension of it" $ do
    mapping <- built [file ["lua", "util.lua"]]
    nativeOf mapping "lua/util" `shouldBe` Nothing
    nativeOf mapping "lua/util.lua/x" `shouldBe` Nothing
    nativeOf mapping "util.lua" `shouldBe` Nothing
    nativeOf mapping "init.lua" `shouldBe` Nothing

  it "keeps the same name in different parent directories separate" $ do
    mapping <- built [file ["a", "x.lua"], file ["b", "x.lua"]]
    nativeOf mapping "a/x.lua" `shouldBe` Just ["a", "x.lua"]
    nativeOf mapping "b/x.lua" `shouldBe` Just ["b", "x.lua"]

  it "keeps two distinct legal names for one file as two entries" $ do
    -- the mapping sees names, never inodes: a hard link is another path identity
    mapping <- built [file ["one.lua"], file ["two.lua"]]
    nativeOf mapping "one.lua" `shouldBe` Just ["one.lua"]
    nativeOf mapping "two.lua" `shouldBe` Just ["two.lua"]
    mappingSize mapping `shouldBe` 2

  it "lists every addressable entry in the order of its logical path" $ do
    mapping <- built [file ["lua", "util.lua"], file ["images", "Hero.png"], directory ["empty"]]
    map (logicalPathBytes . mappedPath) (mappingEntries mapping)
      `shouldBe` ["empty", "images", "images/Hero.png", "lua", "lua/util.lua"]
    map mappedSupplied (mappingEntries mapping) `shouldBe` [True, False, True, False, True]

  it "belongs to one root, and the same names in two roots are different keys" $ do
    a <- built [file ["x"]]
    b <- either (\refusal → fail (show refusal)) pure (buildMapping m1 rootB [file ["x"]])
    mappingRoot a `shouldBe` rootA
    mappingRoot b `shouldBe` rootB
    keyOf rootA "x" `shouldNotBe` keyOf rootB "x"

-- | One expected collision: the entries, how they collide, the two names (the
-- one seen first and the one that arrived), their kinds, and the directory.
data Expected = Expected
  { expectedBy ∷ CollisionKind
  , expectedPair ∷ (ByteString, ByteString)
  }

collisions ∷ Spec
collisions = describe "sibling collisions (supplied entries)" $ do
  let refuses label entries expected =
        it label $ do
          let found = collisionOf (buildMapping m1 rootA entries)
          fmap collisionBy found `shouldBe` Just (expectedBy expected)
          fmap (\c → sort [nativeNameBytes (collidingName (collisionExisting c)), nativeNameBytes (collidingName (collisionIncoming c))]) found
            `shouldBe` Just (sort [fst (expectedPair expected), snd (expectedPair expected)])
      caseless pair = Expected SameCaseless pair
      normalization pair = Expected SameNormalization pair
  describe "canonical caseless" $ do
    refuses "refuses two files that differ only in ASCII case" [file ["A"], file ["a"]] (caseless ("A", "a"))
    refuses "refuses two directories that differ only in case" [directory ["Maps"], directory ["maps"]] (caseless ("Maps", "maps"))
    refuses "refuses a file and a directory that differ only in case" [file ["Hero"], directory ["hero"]] (caseless ("Hero", "hero"))
    refuses "refuses sharp s against SS (a multi-code-point fold)" [file ["\xdf"], file ["SS"]] (caseless (utf8 "\xdf", "SS"))
    refuses "refuses capital sharp s against sharp s" [file ["\x1e9e"], file ["\xdf"]] (caseless (utf8 "\x1e9e", utf8 "\xdf"))
    refuses "refuses the ffi ligature against FFI" [file ["\xfb03"], file ["FFI"]] (caseless (utf8 "\xfb03", "FFI"))
    refuses "refuses dotted capital I against i with a combining dot" [file ["\x130"], file ["i\x307"]] (caseless (utf8 "\x130", utf8 "i\x307"))
    refuses "refuses capital and final sigma spellings" [file ["\x391\x3a3"], file ["\x3b1\x3c2"]] (caseless (utf8 "\x391\x3a3", utf8 "\x3b1\x3c2"))
    refuses "refuses the Kelvin sign against lowercase k" [file ["\x212a"], file ["k"]] (caseless (utf8 "\x212a", "k"))
    refuses "refuses names that fold to one key through both normalization steps" [file ["\x1e9b"], file ["\x1e61"]] (caseless (utf8 "\x1e9b", utf8 "\x1e61"))
    refuses "refuses a canonically reordered combining sequence in another case" [file ["A\x323\x307"], file ["a\x307\x323"]] (caseless (utf8 "A\x323\x307", utf8 "a\x307\x323"))
  describe "canonical equivalence" $ do
    refuses "refuses a composed and a decomposed spelling of one name" [file ["caf\xe9"], file ["cafe\x301"]] (normalization (utf8 "caf\xe9", utf8 "cafe\x301"))
    refuses "refuses them as directories too" [directory ["d\xe9"], directory ["de\x301"]] (normalization (utf8 "d\xe9", utf8 "de\x301"))
    refuses "refuses a file and a directory with equivalent spellings" [file ["d\xe9"], directory ["de\x301"]] (normalization (utf8 "d\xe9", utf8 "de\x301"))
    refuses "refuses canonically reordered combining marks" [file ["a\x323\x307"], file ["a\x307\x323"]] (normalization (utf8 "a\x323\x307", utf8 "a\x307\x323"))
    refuses "refuses the Kelvin sign against ASCII K, whose NFC form it shares" [file ["\x212a"], file ["K"]] (normalization (utf8 "\x212a", "K"))
    refuses "refuses the angstrom sign against the A with ring" [file ["\x212b"], file ["\xc5"]] (normalization (utf8 "\x212b", utf8 "\xc5"))
    refuses "refuses the two spellings of the triple fold" [file ["\x390"], file ["\x1fd3"]] (normalization (utf8 "\x390", utf8 "\x1fd3"))
    refuses "refuses a Hangul syllable against its jamo" [file ["\xd55c"], file ["\x1112\x1161\x11ab"]] (normalization (utf8 "\xd55c", utf8 "\x1112\x1161\x11ab"))
  describe "position" $ do
    it "reports the directory the siblings share, in NFC" $ do
      let found = collisionOf (buildMapping m1 rootA [file ["dir", "caf\xe9", "A"], file ["dir", "caf\xe9", "a"]])
      fmap (excerptBytes . collisionParent) found `shouldBe` Just (utf8 "dir/caf\xe9")
    it "reports an empty parent for the root" $
      fmap (excerptBytes . collisionParent) (collisionOf (buildMapping m1 rootA [file ["A"], file ["a"]])) `shouldBe` Just ""
    it "names the selected root and both entries in the refusal" $ do
      case buildMapping m1 rootB [file ["A"], file ["a"]] of
        Left refusal → do
          inventoryRoot refusal `shouldBe` rootB
          let rendered = show refusal
          rendered `shouldContain` "root-b"
          rendered `shouldContain` "collidingName = A,"
          rendered `shouldContain` "collidingName = a,"
        Right _ → expectationFailure "the siblings were accepted"
    it "records both kinds, the existing entry's and the incoming one's" $ do
      let found = collisionOf (buildMapping m1 rootA [file ["Hero"], directory ["hero"]])
      fmap (collidingKind . collisionExisting) found `shouldBe` Just ObservedFile
      fmap (collidingKind . collisionIncoming) found `shouldBe` Just ObservedDirectory
    it "collides ancestors even when no directory entry was supplied" $ do
      -- Hero/a and hero/b: only the files are supplied, yet Hero and hero are siblings
      let found = collisionOf (buildMapping m1 rootA [file ["Hero", "a"], file ["hero", "b"]])
      fmap collisionBy found `shouldBe` Just SameCaseless
      fmap (map nativeNameBytes . \c → [collidingName (collisionExisting c), collidingName (collisionIncoming c)]) found
        `shouldBe` Just ["Hero", "hero"]
      fmap (excerptBytes . collisionParent) found `shouldBe` Just ""
      fmap (collidingKind . collisionExisting) found `shouldBe` Just ObservedDirectory
    it "collides a supplied file with a directory another path implies" $ do
      let found = collisionOf (buildMapping m1 rootA [file ["Hero"], file ["hero", "x"]])
      fmap collisionBy found `shouldBe` Just SameCaseless
      fmap (collidingKind . collisionIncoming) found `shouldBe` Just ObservedDirectory
  it "refuses whichever order the entries arrive in" $ do
    let entries = [file ["A"], file ["a"], file ["b"]]
    [ collisionBy c
      | order ← permutations entries
      , Just c ← [collisionOf (buildMapping m1 rootA order)]
      ]
      `shouldBe` replicate 6 SameCaseless
    [ ()
      | order ← permutations [file ["x", "caf\xe9"], file ["x", "cafe\x301"], file ["y"]]
      , isNothing (collisionOf (buildMapping m1 rootA order))
      ]
      `shouldBe` []
  it "refuses rather than choosing a winner: no mapping, so no address, comes back" $ do
    let result = buildMapping m1 rootA [file ["A"], file ["a"]]
    either (const True) (const False) result `shouldBe` True

noCollisions ∷ Spec
noCollisions = describe "names that are not collisions (supplied entries)" $ do
  let accepts label entries = it label (reasonFor entries `shouldBe` Nothing)
  accepts "accepts the same name in different parent directories" [file ["x", "a"], file ["y", "a"]]
  accepts "accepts case-different names in different parent directories" [file ["x", "A"], file ["y", "a"]]
  accepts "accepts a file and a directory with different names" [file ["a"], directory ["b"]]
  accepts "accepts an unaccented letter beside its accented one" [file ["e"], file ["\xe9"]]
  accepts "accepts different letters" [file ["a"], file ["b"], file ["ab"]]
  accepts "accepts a name beside a different name that shares a prefix" [file ["Hero"], file ["Hero2"], file ["Her"]]
  accepts "accepts dotless i beside i, as the Turkic mappings are not applied" [file ["\x131"], file ["i"]]
  accepts "accepts a name that differs by a combining mark" [file ["e"], file ["e\x301"]]
  accepts "accepts an empty inventory" []
  accepts "accepts deep paths that share a prefix" [file ["a", "b", "c", "d"], file ["a", "b", "c", "e"], file ["a", "b", "x"]]

-- | Inventories that cannot be addressed unambiguously for a reason other than
-- a sibling collision are refused whole, not repaired or deduplicated.
structure ∷ Spec
structure = describe "structural refusals (supplied entries)" $ do
  let refusedAs label entries predicate = it label (maybe (expectationFailure "accepted") (`shouldSatisfy` predicate) (reasonFor entries))
      invalid problem reason = case reason of
        InvalidEntry _ found → found == problem
        _ → False
  refusedAs "refuses the same exact native path twice" [file ["a", "b"], file ["a", "b"]] (\r → case r of DuplicateEntry _ → True; _ → False)
  refusedAs "refuses the same directory supplied twice" [directory ["a"], directory ["a"]] (\r → case r of DuplicateEntry _ → True; _ → False)
  refusedAs "refuses a path below an entry supplied as a file" [file ["a"], file ["a", "b"]] (\r → case r of BelowNonDirectory _ _ → True; _ → False)
  refusedAs "refuses a file supplied after paths pass through it" [file ["a", "b"], file ["a"]] (\r → case r of NonDirectoryHasChildren _ → True; _ → False)
  refusedAs "refuses the self pseudo-entry" [nativeEntry ObservedDirectory ["."]] (invalid (BadComponent 0 SegmentDot))
  refusedAs "refuses the parent pseudo-entry" [nativeEntry ObservedDirectory [".."]] (invalid (BadComponent 0 SegmentDotDot))
  refusedAs "refuses a dot-dot component anywhere in the path" [nativeEntry ObservedFile ["a", "..", "b"]] (invalid (BadComponent 1 SegmentDotDot))
  refusedAs "refuses an empty component" [nativeEntry ObservedFile ["a", "", "b"]] (invalid (BadComponent 1 SegmentEmpty))
  refusedAs "refuses a separator inside a component" [nativeEntry ObservedFile ["a/b"]] (invalid (BadComponent 0 (SegmentSeparator 1)))
  refusedAs "refuses NUL inside a component" [nativeEntry ObservedFile ["a\0b"]] (invalid (BadComponent 0 (SegmentForbidden Nul 1 0)))
  refusedAs "refuses a backslash and a colon inside a component" [nativeEntry ObservedFile ["a\\b"]] (invalid (BadComponent 0 (SegmentForbidden Backslash 1 0x5c)))
  refusedAs "refuses a colon inside a component" [nativeEntry ObservedFile ["x", "a:b"]] (invalid (BadComponent 1 (SegmentForbidden Colon 1 0x3a)))
  refusedAs "refuses a control character inside a component" [nativeEntry ObservedFile ["a\x7f"]] (invalid (BadComponent 0 (SegmentForbidden Control 1 0x7f)))
  refusedAs "refuses an entry with no components" [nativeEntry ObservedFile []] (invalid EmptyEntryPath)
  refusedAs "refuses invalid native UTF-8 rather than omitting the entry" [nativeEntry ObservedFile [bytes [0x66, 0xff]]] (invalid (BadComponent 0 (SegmentMalformedUtf8 1)))
  refusedAs "refuses an overlong native encoding of a separator" [nativeEntry ObservedFile [bytes [0x61, 0xc0, 0xaf, 0x62]]] (invalid (BadComponent 0 (SegmentMalformedUtf8 1)))
  it "accepts a directory beside its own children in either order" $ do
    reasonFor [directory ["a"], file ["a", "b"]] `shouldBe` Nothing
    reasonFor [file ["a", "b"], directory ["a"]] `shouldBe` Nothing
  it "refuses the whole inventory for one bad entry among good ones: no partial mapping" $ do
    let good = [file ["one"], file ["two"], file ["three", "x"]]
        refused = buildMapping m1 rootA (good <> [nativeEntry ObservedFile [bytes [0xff]]] <> [file ["four"]])
    either (const False) (const True) refused `shouldBe` False
    -- the good entries on their own are unaffected: nothing was retained by the failed build
    mapping <- built good
    mappingSize mapping `shouldBe` 3
  it "names the entry that is wrong, bounded, and the root" $
    case buildMapping m1 rootB [file ["ok"], nativeEntry ObservedFile ["dir", bytes [0xff]]] of
      Left (InventoryRefusal root (InvalidEntry shown problem)) → do
        root `shouldBe` rootB
        excerptBytes shown `shouldBe` bytes ([0x64, 0x69, 0x72, 0x2f, 0xff])
        problem `shouldBe` BadComponent 1 (SegmentMalformedUtf8 0)
      other → expectationFailure ("unexpected: " <> either show (const "built") other)

-- | The byte and count bounds applied to observed names: native and NFC forms,
-- the whole relative path, and a smaller injected profile.
entryBounds ∷ Spec
entryBounds = describe "entry bounds (supplied entries)" $ do
  let components path = BS.split 0x2f path
      tight = limits 16 4 3 8
      refusalWith theLimits entries = either (Just . inventoryReason) (const Nothing) (buildMapping theLimits rootA entries)
  it "accepts a 255-byte native segment and refuses 256" $ do
    refusalWith m1 [nativeEntry ObservedFile [BS.replicate 255 0x61]] `shouldBe` Nothing
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith m1 [nativeEntry ObservedFile [BS.replicate 256 0x61]])
      `shouldBe` Just (Just (BadComponent 0 (SegmentTooLong 256 255)))
  it "accepts a 1,024-byte native path and refuses 1,025, separators counted" $ do
    refusalWith m1 [nativeEntry ObservedFile (components (exactly 255 1024))] `shouldBe` Nothing
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith m1 [nativeEntry ObservedFile (components (exactly 255 1025))])
      `shouldBe` Just (Just (EntryTooLong 1025 1024))
  it "accepts 32 components and refuses 33" $ do
    refusalWith m1 [nativeEntry ObservedFile (replicate 32 "a")] `shouldBe` Nothing
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith m1 [nativeEntry ObservedFile (replicate 33 "a")])
      `shouldBe` Just (Just (EntryTooDeep 33 32))
  it "counts multibyte native components in bytes" $ do
    refusalWith m1 [nativeEntry ObservedFile [utf8 (replicate 127 '\xe9' <> "a")]] `shouldBe` Nothing
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith m1 [file [replicate 128 '\xe9']])
      `shouldBe` Just (Just (BadComponent 0 (SegmentTooLong 256 255)))
  it "does not excuse an over-limit native name because its NFC form is shorter" $ do
    -- e + U+0301 is 3 bytes natively and 2 in NFC; the limit is 2
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith (limits 16 2 3 8) [file ["e\x301"]])
      `shouldBe` Just (Just (BadComponent 0 (SegmentTooLong 3 2)))
    refusalWith (limits 16 3 3 8) [file ["e\x301"]] `shouldBe` Nothing
  it "refuses more components than the profile allows" $
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith tight [nativeEntry ObservedFile ["abcd", "efgh", "ijkl", "mnop"]])
      `shouldBe` Just (Just (EntryTooDeep 4 3))
  it "refuses a native segment whose NFC form exceeds the segment limit" $ do
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith (limits 64 5 3 8) [file ["\x958"]])
      `shouldBe` Just (Just (BadComponent 0 (SegmentNormalizedTooLong 6 5)))
    refusalWith (limits 64 6 3 8) [file ["\x958"]] `shouldBe` Nothing
  it "refuses a native path whose NFC form exceeds the path limit" $ do
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith (limits 8 6 3 8) [file ["\x958", "\x958"]])
      `shouldBe` Just (Just (EntryNormalizedTooLong 13 8))
    refusalWith (limits 13 6 3 8) [file ["\x958", "\x958"]] `shouldBe` Nothing
  it "applies the whole relative native spelling, not only the individual names" $ do
    -- every name and the count are within their limits; the path with its separators is not
    let profile = limits 10 4 3 8
    refusalWith profile [nativeEntry ObservedFile ["abcd", "efgh"]] `shouldBe` Nothing
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) (refusalWith profile [nativeEntry ObservedFile ["abcd", "efgh", "ij"]])
      `shouldBe` Just (Just (EntryTooLong 12 10))
  it "bounds a diagnostic for a huge component, without keeping it" $ do
    let huge = BS.replicate (3 * 1024 * 1024) 0x61
    case buildMapping m1 rootA [nativeEntry ObservedFile ["dir", huge]] of
      Left (InventoryRefusal _ (InvalidEntry shown problem)) → do
        BS.length (excerptBytes shown) `shouldBe` excerptCap
        excerptLength shown `shouldBe` 3 * 1024 * 1024 + 4
        problem `shouldBe` EntryTooLong (3 * 1024 * 1024 + 4) 1024
      other → expectationFailure ("unexpected: " <> either show (const "built") other)

-- | The entry allowance stops the consumption of the enumeration.
allowance ∷ Spec
allowance = describe "entry allowance (supplied entries)" $ do
  let allowing n = limits 1024 255 32 n
      numbered i = nativeEntry ObservedFile [BC.pack (show (i ∷ Int))]
      built' = either (const False) (const True)
  it "accepts exactly the allowance and refuses one more, stating the allowance" $ do
    built' (buildMapping (allowing 3) rootA (map numbered [1 .. 3])) `shouldBe` True
    fmap inventoryReason (either Just (const Nothing) (buildMapping (allowing 3) rootA (map numbered [1 .. 4])))
      `shouldBe` Just (TooManyEntries 3)
  it "treats a zero allowance as an empty inventory only" $ do
    built' (buildMapping (allowing 0) rootA []) `shouldBe` True
    fmap inventoryReason (either Just (const Nothing) (buildMapping (allowing 0) rootA [numbered 1])) `shouldBe` Just (TooManyEntries 0)
  it "stops at the allowance without materializing an unbounded enumeration" $ do
    -- an infinite list: the build must return within its bound, so it never asked for the rest
    result <- bounded (evaluate (fmap inventoryReason (either Just (const Nothing) (buildMapping (allowing 100) rootA (map numbered [1 ..])))))
    result `shouldBe` Just (TooManyEntries 100)
  it "asks for no entry beyond the one that proves the allowance exceeded" $ do
    -- the element itself and everything after it are poisoned; only the cell is inspected
    let enumeration = map numbered [1 .. 3] <> [error "the fourth entry was inspected"] <> error "the rest was demanded"
    fmap inventoryReason (either Just (const Nothing) (buildMapping (allowing 3) rootA enumeration)) `shouldBe` Just (TooManyEntries 3)
  it "stops at the first refusal and demands nothing after it" $ do
    let enumeration = [numbered 1, nativeEntry ObservedFile [bytes [0xff]]] <> error "the rest was demanded"
    fmap (\r → case inventoryReason r of InvalidEntry _ _ → True; _ → False) (either Just (const Nothing) (buildMapping m1 rootA enumeration))
      `shouldBe` Just True
  it "counts supplied entries, not the directories they imply" $ do
    mapping <- either (\r → fail (show r)) pure (buildMapping (allowing 2) rootA [file ["a", "b", "c"], file ["a", "b", "d"]])
    mappingSize mapping `shouldBe` 2
    length (mappingEntries mapping) `shouldBe` 4

diagnostics ∷ Spec
diagnostics = describe "bounded diagnostics" $ do
  it "keeps no more of a rejected reference than the excerpt cap, in a buffer of its own" $ do
    let huge = BS.replicate (1024 * 1024) 0x61
    case parseReference m1 rootA huge of
      Left refusal → do
        let kept = excerptBytes (refusalReference refusal)
        BS.length kept `shouldBe` excerptCap
        -- a slice of the large buffer would keep all of it alive
        sharesBuffer kept huge `shouldBe` False
        length (show refusal) `shouldSatisfy` (< 400)
      Right _ → expectationFailure "accepted"
  it "keeps no more of a rejected native path than the excerpt cap, in a buffer of its own" $ do
    let huge = BS.replicate (1024 * 1024) 0x61
    case buildMapping m1 rootA [nativeEntry ObservedFile [huge]] of
      Left (InventoryRefusal _ (InvalidEntry shown _)) → do
        BS.length (excerptBytes shown) `shouldBe` excerptCap
        sharesBuffer (excerptBytes shown) huge `shouldBe` False
      other → expectationFailure ("unexpected: " <> either show (const "built") other)
  it "keeps a mapped native name and a root key in buffers of their own, so a slice of a large buffer is not retained" $ do
    let large = BS.replicate (1024 * 1024) 0x61
        slice = BS.take 5 large
    mapping <- built [nativeEntry ObservedFile [slice]]
    case lookupPath mapping (contentKeyPath (keyOf rootA "aaaaa")) of
      Just found → sharesBuffer (nativeNameBytes (NonEmpty.head (mappedNative found))) large `shouldBe` False
      Nothing → expectationFailure "the slice's name was not found"
    either (const Nothing) (Just . rootKeyBytes) (rootKey slice) `shouldBe` Just slice
    either (const True) (\key → sharesBuffer (rootKeyBytes key) large) (rootKey slice) `shouldBe` False
  it "does not enumerate an unbounded component list to describe an entry that is too deep" $ do
    -- the list allocates as it is walked, so the bound can interrupt a regression
    result <- bounded (evaluate (fmap inventoryReason (either Just (const Nothing) (buildMapping m1 rootA [nativeEntry ObservedFile (map (BC.pack . show) [1 ∷ Int ..])]))))
    case result of
      Just (InvalidEntry shown problem) → do
        problem `shouldBe` EntryTooDeep 33 32
        BS.length (excerptBytes shown) `shouldSatisfy` (\n → n > 0 && n <= excerptCap)
      other → expectationFailure ("unexpected: " <> show other)
  it "allocates no more than the excerpt to describe a huge rejected component, however large" $ do
    -- the buffer is built before the measurement; only the work of the refusal is counted
    huge <- evaluate (BS.replicate (16 * 1024 * 1024) 0x61)
    entryAllocation <- allocatedBy $ case buildMapping m1 rootA [nativeEntry ObservedFile ["dir", huge]] of
      Left (InventoryRefusal _ (InvalidEntry shown problem)) → evaluate (BS.length (excerptBytes shown) + excerptLength shown + length (show problem))
      other → fail ("unexpected: " <> either show (const "built") other)
    referenceAllocation <- allocatedBy $ case parseReference m1 rootA huge of
      Left refusal → evaluate (BS.length (excerptBytes (refusalReference refusal)) + length (show refusal))
      Right key → fail ("accepted: " <> show key)
    -- a copy of the large component, even once, would be 16 MiB; the allowance is generous
    -- for the refusal's own small structures
    (entryAllocation < 256 * 1024, referenceAllocation < 256 * 1024) `shouldBe` (True, True)
  it "allocates no more than the excerpt to describe a huge component deep in a path" $ do
    huge <- evaluate (BS.replicate (16 * 1024 * 1024) 0x62)
    allocation <- allocatedBy $ case buildMapping m1 rootA [nativeEntry ObservedFile ["a", "b", huge, "c"]] of
      Left (InventoryRefusal _ (InvalidEntry shown _)) → evaluate (BS.length (excerptBytes shown))
      other → fail ("unexpected: " <> either show (const "built") other)
    allocation `shouldSatisfy` (< 256 * 1024)
  it "shows names escaped and never decoded" $ do
    show (keyOf rootA (utf8 "caf\xe9")) `shouldContain` "caf\\xc3\\xa9"
  it "renders an excerpt with the true length when it was cut" $
    case parseReference m1 rootA (BS.replicate 2000 0x61) of
      Left refusal → renderExcerpt (refusalReference refusal) `shouldContain` "(2000 bytes)"
      Right _ → expectationFailure "accepted"
  it "does not overflow at the largest limits the constructor accepts" $ do
    -- a segment-count limit of maxBound once made 'limit + 1' wrap and the entry read as empty
    let widest = limits maxBound 255 maxBound maxBound
        nearly = limits (maxBound - 1) 255 (maxBound - 1) (maxBound - 1)
    mapM_
      ( \theLimits → do
          mapping <- either (\r → fail (show r)) pure (buildMapping theLimits rootA [file ["a"], file ["b", "c"]])
          mappingSize mapping `shouldBe` 2
          fmap (logicalPathBytes . contentKeyPath) (parseReference theLimits rootA "a/b") `shouldBe` Right "a/b"
          case buildMapping theLimits rootA [nativeEntry ObservedFile [bytes [0xff]]] of
            Left (InventoryRefusal _ (InvalidEntry _ problem)) → problem `shouldBe` BadComponent 0 (SegmentMalformedUtf8 0)
            other → expectationFailure ("unexpected: " <> either show (const "built") other)
      )
      [widest, nearly]
    -- and an infinite component list is still described by a bounded prefix under a huge limit
    result <- bounded (evaluate (fmap inventoryReason (either Just (const Nothing) (buildMapping (limits 1024 255 3 10) rootA [nativeEntry ObservedFile (map (BC.pack . show) [1 ∷ Int ..])]))))
    fmap (\r → case r of InvalidEntry _ p → Just p; _ → Nothing) result `shouldBe` Just (Just (EntryTooDeep 4 3))
  it "bounds a root key" $ do
    rootKey "" `shouldBe` Left EmptyRootKey
    rootKey (BS.replicate (maxRootKeyBytes + 1) 0x61) `shouldBe` Left (RootKeyTooLong (maxRootKeyBytes + 1))
    fmap rootKeyBytes (rootKey (BS.replicate maxRootKeyBytes 0x61)) `shouldBe` Right (BS.replicate maxRootKeyBytes 0x61)

-- | Whether two byte strings are views of one buffer.
sharesBuffer ∷ ByteString → ByteString → Bool
sharesBuffer left right = fst (toForeignPtr0 left) == fst (toForeignPtr0 right)

-- ---------------------------------------------------------------------------
-- Native trees

-- | Walk a directory the content service enumerates, reporting what it saw.
observe ∷ DirectoryReader → [ByteString] → IO [ObservedEntry]
observe reader prefix = do
  entries ← drain (readEntry reader)
  fmap concat . forM entries $ \entry → do
    let path = prefix <> [nativeNameBytes (entryName entry)]
    case entryKind entry of
      KindDirectory → (ObservedEntry path ObservedDirectory :) <$> withEntryDirectory reader entry (\sub → observe sub path)
      KindRegular → pure [ObservedEntry path ObservedFile]
      other → fail ("an entry of kind " <> show other <> " was not expected in this fixture")

-- | What the operating system reports for a temporary tree.
observed ∷ FilePath → IO [ObservedEntry]
observed tree = withRoot tree $ \root → withDirectory root [] (`observe` [])

-- | Create a file by exact name bytes, or say the file system refused the name.
tryCreate ∷ FilePath → ByteString → IO Bool
tryCreate directoryPath nameBytes = do
  result ← try (createFile (BC.pack directoryPath <> "/" <> nameBytes) 0o644 >>= closeFd)
  pure (either (\e → const False (e ∷ IOException)) (const True) result)

nativeTrees ∷ Spec
nativeTrees = describe "native trees (a real temporary directory, enumerated by the content service)" $ do
  it "maps a reference to the spelling the file system reports and opens the file by it" $
    withTree $ \tree → do
      createDirectory (tree </> "images")
      writeBytes (tree </> "images" </> "Hero.png") "hero bytes"
      writeBytes (tree </> "readme.txt") "readme"
      entries ← observed tree
      mapping ← built entries
      found ← maybe (fail "the reference found nothing") pure (lookupPath mapping (contentKeyPath (keyOf rootA "images/Hero.png")))
      map nativeNameBytes (NonEmpty.toList (mappedNative found)) `shouldBe` ["images", "Hero.png"]
      -- the boundary: the mapped native components are exactly what the opener takes
      contents ← withRoot tree $ \root → withFile root (NonEmpty.toList (mappedNative found)) (\reader → readAll 64 (readChunk reader))
      contents `shouldBe` "hero bytes"
      nativeOf mapping "images/hero.png" `shouldBe` Nothing

  it "finds a file created with a decomposed name by its composed reference, whatever spelling the file system kept" $
    withTree $ \tree → do
      writeBytes (tree </> "x") "placeholder"
      created ← tryCreate tree (utf8 "cafe\x301.txt")
      created `shouldBe` True
      entries ← observed tree
      mapping ← built entries
      -- the file system reports either the spelling it was given or its own normalization;
      -- either way the composed and the decomposed reference reach the one reported spelling
      let viaComposed = nativeOf mapping (utf8 "caf\xe9.txt")
          viaDecomposed = nativeOf mapping (utf8 "cafe\x301.txt")
      viaComposed `shouldSatisfy` isJust
      viaComposed `shouldBe` viaDecomposed
      case viaComposed of
        Just [reported] → reported `shouldSatisfy` (`elem` [utf8 "caf\xe9.txt", utf8 "cafe\x301.txt"])
        other → expectationFailure ("unexpected components: " <> show other)

  it "keeps two hard-linked names as two path identities, each opening the same bytes" $
    withTree $ \tree → do
      writeBytes (tree </> "one.lua") "shared bytes"
      createLink (tree </> "one.lua") (tree </> "two.lua")
      entries ← observed tree
      mapping ← built entries
      mappingSize mapping `shouldBe` 2
      let pathsOf = map (logicalPathBytes . mappedPath) (mappingEntries mapping)
      sort pathsOf `shouldBe` ["one.lua", "two.lua"]
      links ← forM ["one.lua", "two.lua"] $ \reference → do
        found ← maybe (fail "missing") pure (lookupPath mapping (contentKeyPath (keyOf rootA reference)))
        withRoot tree $ \root → withFile root (NonEmpty.toList (mappedNative found)) $ \reader → do
          metadata ← fileMetadata reader
          contents ← readAll 64 (readChunk reader)
          pure (metadataLinkCount metadata, contents)
      links `shouldBe` [(2, "shared bytes"), (2, "shared bytes")]

  it "refuses a real tree holding names that differ only in case, where the file system keeps both" $
    withTree $ \tree → do
      writeBytes (tree </> "Case.txt") "upper"
      second ← tryCreate tree "case.txt"
      entries ← observed tree
      if second && length entries == 2
        then fmap collisionBy (collisionOf (buildMapping m1 rootA entries)) `shouldBe` Just SameCaseless
        else
          pendingWith
            "this file system folds case, so both names cannot exist; the supplied-entry collision examples above are the evidence, and they do not claim native behavior"

  it "refuses a real tree holding canonically equivalent names, where the file system keeps both" $
    withTree $ \tree → do
      first ← tryCreate tree (utf8 "caf\xe9")
      second ← tryCreate tree (utf8 "cafe\x301")
      entries ← observed tree
      let both = length [() | e ← entries, observedPath e `elem` [[utf8 "caf\xe9"], [utf8 "cafe\x301"]]] == 2
      if first && second && both
        then fmap collisionBy (collisionOf (buildMapping m1 rootA entries)) `shouldBe` Just SameNormalization
        else
          pendingWith
            "this file system treats canonically equivalent names as one, so both cannot exist; the supplied-entry examples above are the evidence"

  it "refuses a real tree holding a name that is not valid UTF-8, where the file system accepts one" $
    withTree $ \tree → do
      created ← tryCreate tree (bytes [0x62, 0x61, 0x64, 0xff, 0xfe])
      if created
        then do
          entries ← observed tree
          fmap inventoryReason (either Just (const Nothing) (buildMapping m1 rootA entries))
            `shouldSatisfy` (\r → case r of Just (InvalidEntry _ (BadComponent 0 (SegmentMalformedUtf8 3))) → True; _ → False)
        else
          pendingWith
            "this file system accepts only valid UTF-8 names, so a real one cannot exist; the supplied raw-name examples above are the evidence"

  it "hands the opener the observed bytes themselves, never a normalized request to guess from" $
    withTree $ \tree → do
      writeBytes (tree </> "plain.lua") "a"
      entries ← observed tree
      mapping ← built entries
      found ← maybe (fail "missing") pure (lookupPath mapping (contentKeyPath (keyOf rootA "plain.lua")))
      map nativeNameBytes (NonEmpty.toList (mappedNative found)) `shouldBe` ["plain.lua"]
