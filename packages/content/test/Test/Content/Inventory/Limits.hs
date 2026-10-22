-- | The bounds a scan enforces, each on both sides of its edge: the entry
-- allowance, path depth, path and segment bytes (on the supplied and the NFC
-- form), the per-file and per-root byte budgets with hard-link aliases charged
-- once per name, and the checks of the limits themselves.
--
-- Large-byte scenarios use small validated profiles; the M1 numbers are passed
-- as test inputs to the same check any profile passes, and the cheap ones (the
-- 10,000-entry allowance, 32 segments) are exercised at their real values.
module Test.Content.Inventory.Limits (spec) where

import Control.Exception (displayException)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Hetoimasia.Content
import Hetoimasia.Content.Identity (EntryProblem (..), InventoryReason (..), LimitsRefusal (..), SegmentProblem (..))
import qualified Hetoimasia.Content.Identity as Identity
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Inventory
import System.FilePath ((</>))
import System.Posix.Files (createLink)
import Test.Content.Inventory.Support
import Test.Content.Support
import Test.Hspec

refusalOf ∷ Either InventoryFailure Inventory → Maybe InventoryFailureReason
refusalOf = either (Just . inventoryFailureReason) (const Nothing)

pathOf ∷ Either InventoryFailure Inventory → Maybe [NativeName]
pathOf = either (Just . inventoryFailurePath) (const Nothing)

spec ∷ Spec
spec = do
  describe "the limits themselves" $ do
    it "accepts the approved M1 numbers, and listed each back" $ do
      let checked = either (error . show) id (inventoryLimits m1Spec)
      (inventoryEntries checked, inventorySegments checked, inventoryPathBytes checked, inventorySegmentBytes checked) `shouldBe` (10000, 32, 1024, 255)
      (inventoryFileBytes checked, inventoryRootBytes checked, inventoryBufferBytes checked) `shouldBe` (64 * 1024 * 1024, 1024 * 1024 * 1024, 64 * 1024)
      -- the identity policy is given one entry fewer than the allowance: the root is not addressable
      (Identity.limitEntries (inventoryIdentityLimits checked), Identity.limitSegments (inventoryIdentityLimits checked)) `shouldBe` (9999, 32)

    it "refuses a value below one, naming the limit" $ do
      let refused change = inventoryLimits (change baseSpec)
      refused (\s → s {specEntries = 0}) `shouldBe` Left (SpecNotPositive NameEntries 0)
      refused (\s → s {specSegments = 0}) `shouldBe` Left (SpecNotPositive NameSegments 0)
      refused (\s → s {specPathBytes = -1}) `shouldBe` Left (SpecNotPositive NamePathBytes (-1))
      refused (\s → s {specSegmentBytes = 0}) `shouldBe` Left (SpecNotPositive NameSegmentBytes 0)
      refused (\s → s {specFileBytes = 0}) `shouldBe` Left (SpecNotPositive NameFileBytes 0)
      refused (\s → s {specRootBytes = 0}) `shouldBe` Left (SpecNotPositive NameRootBytes 0)
      refused (\s → s {specBufferBytes = 0}) `shouldBe` Left (SpecNotPositive NameBufferBytes 0)

    it "refuses a segment larger than the path or than a native name, and a file larger than its root" $ do
      inventoryLimits baseSpec {specSegmentBytes = 201} `shouldBe` Left (IdentityRefused (SegmentLimitTooLarge 201 200))
      inventoryLimits baseSpec {specPathBytes = 5000, specSegmentBytes = 1024} `shouldBe` Left (IdentityRefused (SegmentLimitTooLarge 1024 1023))
      inventoryLimits baseSpec {specFileBytes = 16385} `shouldBe` Left (FileLimitAboveRoot 16385 16384)
      inventoryLimits baseSpec {specEntries = 1} `shouldSatisfy` either (const False) (const True)

  describe "the entry allowance" $ do
    let small = limitsFrom baseSpec {specEntries = 6}

    it "accepts exactly the allowance, the root and every directory and file counted" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a/", ""), ("a/one", "1"), ("b", "2"), ("c", "3"), ("d", "4")]
        inventory ← scanned productionSeam small (rootPath tree)
        inventoryEntryCount inventory `shouldBe` 6

    it "refuses one past the allowance at the entry that crosses it, and stops reading the directory there" $
      withLayout $ \tree → do
        populate (rootPath tree) [('f' : show n, "x") | n ← [1 .. 40 ∷ Int]]
        listed ← newCounter
        outcome ← scanning (countStreamReads listed productionSeam) small (rootPath tree)
        case outcome of
          Left failure' → do
            inventoryFailureReason failure' `shouldBe` Exceeded BoundEntries 7 6
            length (inventoryFailurePath failure') `shouldBe` 1
          Right _ → expectationFailure "an inventory past the allowance was published"
        -- five accepted entries and the one that crossed, and the two structural
        -- names the enumeration skips: no more of the forty
        raw ← readCount listed
        raw `shouldSatisfy` (\n → n >= 6 && n <= 8)

    it "counts directories, files, hidden and empty ones alike" $
      withLayout $ \tree → do
        populate (rootPath tree) [("d1/", ""), ("d2/", ""), (".h1", ""), (".h2", ""), ("e", ""), ("f", "")]
        outcome ← scanning productionSeam small (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundEntries 7 6)

    it "accepts 10,000 entries including the root at the real M1 allowance, and refuses a 10,000th file" $
      withLayout $ \tree → do
        let m1 = limitsFrom m1Spec
        forM_ [1 .. 9999 ∷ Int] $ \n → writeBytes (rootPath tree </> ("f" <> show n)) "x"
        accepted ← scanned productionSeam m1 (rootPath tree)
        inventoryEntryCount accepted `shouldBe` 10000
        writeBytes (rootPath tree </> "one-too-many") "x"
        outcome ← scanning productionSeam m1 (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundEntries 10001 10000)

    it "refuses an enormous directory (injected listing) at the allowance without reading the rest" $
      withLayout $ \tree → do
        seam ← supplyingEntries [(BC.pack ('n' : show n), KindRegular) | n ← [1 .. 20000 ∷ Int]]
        listed ← newCounter
        let counted = countStreamReads listed seam
        outcome ← scanning counted (limitsFrom m1Spec) (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundEntries 10001 10000)
        -- 9,999 supplied names accepted and the one that crossed, with the two
        -- structural names the enumeration skips
        raw ← readCount listed
        raw `shouldSatisfy` (\n → n >= 10000 && n <= 10002)

  describe "path depth" $ do
    let nested n = BC.unpack (BS.intercalate "/" (replicate n "d"))

    it "accepts a path of exactly the segment limit, directories and files alike" $
      withLayout $ \tree → do
        populate (rootPath tree) [(nested 7 </> "f", "x"), (nested 8 <> "/", "")]
        inventory ← scanned productionSeam (limitsFrom baseSpec) (rootPath tree)
        presenceOf inventory (BC.pack (nested 7 </> "f")) `shouldBe` PresentFile 1
        presenceOf inventory (BC.pack (nested 8)) `shouldBe` PresentDirectory

    it "refuses a file one segment past the limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [(nested 8 </> "f", "x")]
        file ← scanning productionSeam (limitsFrom baseSpec) (rootPath tree)
        case refusalOf file of
          Just (Identity (InvalidEntry _ (EntryTooDeep 9 8))) → pure ()
          other → expectationFailure ("expected a too-deep refusal, got " <> show other)

    it "refuses a directory one segment past the limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [(nested 9 <> "/", "")]
        directory ← scanning productionSeam (limitsFrom baseSpec) (rootPath tree)
        case refusalOf directory of
          Just (Identity (InvalidEntry _ (EntryTooDeep 9 8))) → pure ()
          other → expectationFailure ("expected a too-deep refusal, got " <> show other)

    it "accepts 32 segments at the real M1 depth" $
      withLayout $ \tree → do
        populate (rootPath tree) [(nested 31 </> "f", "x")]
        accepted ← scanned productionSeam (limitsFrom m1Spec) (rootPath tree)
        presenceOf accepted (BC.pack (nested 31 </> "f")) `shouldBe` PresentFile 1

    it "refuses 33 segments at the real M1 depth" $
      withLayout $ \tree → do
        populate (rootPath tree) [(nested 32 </> "f", "x")]
        outcome ← scanning productionSeam (limitsFrom m1Spec) (rootPath tree)
        case refusalOf outcome of
          Just (Identity (InvalidEntry _ (EntryTooDeep 33 32))) → pure ()
          other → expectationFailure ("expected a too-deep refusal, got " <> show other)

  describe "path and segment bytes" $ do
    let pathBudget = limitsFrom baseSpec {specPathBytes = 64, specSegmentBytes = 40}
        segmentBudget = limitsFrom baseSpec {specSegmentBytes = 8}

    it "accepts a path of exactly the byte limit" $
      withLayout $ \tree → do
        let directory = replicate 31 'x'
        populate (rootPath tree) [(directory </> replicate 32 'y', "p")]
        accepted ← scanned productionSeam pathBudget (rootPath tree)
        presenceOf accepted (BC.pack (directory </> replicate 32 'y')) `shouldBe` PresentFile 1

    it "refuses a path one byte past the byte limit" $
      withLayout $ \tree → do
        let directory = replicate 31 'x'
        populate (rootPath tree) [(directory </> replicate 33 'y', "p")]
        outcome ← scanning productionSeam pathBudget (rootPath tree)
        case refusalOf outcome of
          Just (Identity (InvalidEntry _ (EntryTooLong 65 64))) → pure ()
          other → expectationFailure ("expected a path-length refusal, got " <> show other)

    it "accepts a segment of exactly the byte limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [(replicate 8 's', "x")]
        accepted ← scanned productionSeam segmentBudget (rootPath tree)
        inventoryEntryCount accepted `shouldBe` 2

    it "refuses a segment one byte past the byte limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [(replicate 9 's', "x")]
        outcome ← scanning productionSeam segmentBudget (rootPath tree)
        case refusalOf outcome of
          Just (Identity (InvalidEntry _ (BadComponent 0 (SegmentTooLong 9 8)))) → pure ()
          other → expectationFailure ("expected a segment-length refusal, got " <> show other)

    it "accepts a real 255-byte name at the M1 segment limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [(replicate 255 'n', "x")]
        inventory ← scanned productionSeam (limitsFrom m1Spec) (rootPath tree)
        inventoryEntryCount inventory `shouldBe` 2

    it "checks the NFC form as well: a name that fits as supplied and grows past the limit under NFC is refused (injected name)" $
      withLayout $ \tree → do
        -- U+0958 is three bytes and its NFC form, U+0915 U+093C, is six
        seam ← supplyingEntries [("\xe0\xa5\x98", KindRegular)]
        let narrow = limitsFrom baseSpec {specSegmentBytes = 5}
        outcome ← scanning seam narrow (rootPath tree)
        case refusalOf outcome of
          Just (Identity (InvalidEntry _ (BadComponent 0 (SegmentNormalizedTooLong 6 5)))) → pure ()
          other → expectationFailure ("expected an NFC length refusal, got " <> show other)

    it "bounds the evidence it keeps, however long the offending name is" $
      withLayout $ \tree → do
        populate (rootPath tree) [(replicate 255 'z', "x")]
        outcome ← scanning productionSeam (limitsFrom baseSpec {specSegmentBytes = 8}) (rootPath tree)
        case outcome of
          Left failure' → length (show failure') `shouldSatisfy` (< 600)
          Right _ → expectationFailure "an over-long name was accepted"

  describe "file and root bytes" $ do
    let budget = limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 40}

    it "accepts a file of exactly the per-file limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [("exact", BS.replicate 16 1)]
        accepted ← scanned productionSeam budget (rootPath tree)
        presenceOf accepted "exact" `shouldBe` PresentFile 16

    it "refuses a file one byte past the per-file limit, before reading any of it" $
      withLayout $ \tree → do
        populate (rootPath tree) [("past", BS.replicate 17 1)]
        (seam, rig) ← recordingSeam
        outcome ← scanning seam budget (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundFileBytes 17 16)
        requestSizes <$> events rig `shouldReturn` []

    it "accepts an aggregate of exactly the per-root limit" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a", BS.replicate 16 1), ("b", BS.replicate 16 2), ("c", BS.replicate 8 3)]
        accepted ← scanned productionSeam budget (rootPath tree)
        inventoryByteTotal accepted `shouldBe` 40

    it "refuses an aggregate one byte past the per-root limit, before reading the file that crosses it" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a", BS.replicate 16 1), ("b", BS.replicate 16 2), ("c", BS.replicate 9 3)]
        (seam, rig) ← recordingSeam
        outcome ← scanning seam budget (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundRootBytes 41 40)
        pathOf outcome `shouldBe` Just (names ["c"])
        -- two files of 16 bytes were read, each as one request and the one-byte probe, and nothing of "c"
        sum . requestSizes <$> events rig `shouldReturn` 32 + 2

    it "charges each hard-link alias separately against the root budget" $
      withLayout $ \tree → do
        populate (rootPath tree) [("one", BS.replicate 16 7)]
        createLink (rootPath tree </> "one") (rootPath tree </> "two")
        let tight = limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 31}
        outcome ← scanning productionSeam tight (rootPath tree)
        refusalOf outcome `shouldBe` Just (Exceeded BoundRootBytes 32 31)
        pathOf outcome `shouldBe` Just (names ["two"])
        let exact = limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 32}
        accepted ← scanned productionSeam exact (rootPath tree)
        inventoryByteTotal accepted `shouldBe` 32
        -- the root, and two names for one inode
        inventoryEntryCount accepted `shouldBe` 3

    it "does not compare the aggregate with unique inodes or allocated blocks" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a", BS.replicate 10 1), ("b", BS.replicate 10 1), ("c", BS.replicate 10 1), ("d", "")]
        createLink (rootPath tree </> "a") (rootPath tree </> "e")
        accepted ← scanned productionSeam (limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 40}) (rootPath tree)
        inventoryByteTotal accepted `shouldBe` 40
        outcome ← scanning productionSeam (limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 39}) (rootPath tree)
        case refusalOf outcome of
          Just (Exceeded BoundRootBytes _ 39) → pure ()
          other → expectationFailure ("expected the aggregate to refuse, got " <> show other)

    it "counts an empty file as a valid entry that costs no bytes" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a", ""), ("b", ""), ("c", "")]
        accepted ← scanned productionSeam (limitsFrom baseSpec {specFileBytes = 1, specRootBytes = 1}) (rootPath tree)
        inventoryByteTotal accepted `shouldBe` 0
        inventoryEntryCount accepted `shouldBe` 4

  describe "short listed" $ do
    it "treat a short chunk as data, producing the same length and digest" $
      withLayout $ \tree → do
        populate (rootPath tree) [("abc.txt", "abc")]
        (seam, rig) ← recordingSeam
        inventory ← scanned (shortReads 1 seam) (limitsFrom baseSpec) (rootPath tree)
        entry ← entryFor inventory "abc.txt"
        fmap (show . factDigest) (entryFact entry) `shouldBe` Just abcDigest
        -- three one-byte listed and the probe
        length . requestSizes <$> events rig `shouldReturn` 4

  describe "the evidence names a limit" $ do
    it "renders a refusal with the root and path, bounded" $
      withLayout $ \tree → do
        populate (rootPath tree) [("big", BS.replicate 17 1)]
        outcome ← scanning productionSeam (limitsFrom baseSpec {specFileBytes = 16, specRootBytes = 40}) (rootPath tree)
        case outcome of
          Left failure' → displayException failure' `shouldSatisfy` ("big" `isInfixOf`)
          Right _ → expectationFailure "an oversized file was accepted"
