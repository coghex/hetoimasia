-- | The startup scan: what it inventories, what it refuses, and the digests and
-- lengths it records, over real temporary trees the example owns.
--
-- Evidence is native except where an example says it is injected: the
-- permission-denied and read-error cases run through the adapter seam (Linux CI
-- runs as root, which ignores permission bits), with a real @chmod@ variant
-- that runs only when the effective user cannot bypass it and is otherwise
-- reported pending, so neither variant passes vacuously.
module Test.Content.Inventory.Scan (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), IOException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sort)
import Hetoimasia.Content
import Hetoimasia.Content.Identity (EntryProblem (..), Forbidden (..), InventoryReason (..), SegmentProblem (..))
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Inventory
import System.FilePath ((</>))
import System.Posix.Files (createNamedPipe, createSymbolicLink, setFileMode, ownerReadMode, ownerWriteMode, unionFileModes)
import qualified System.Posix.IO.ByteString as Raw
import System.Posix.User (getEffectiveUserID)
import Test.Content.Inventory.Support
import Test.Content.Support
import Test.Hspec

limits ∷ InventoryLimits
limits = limitsFrom baseSpec

-- | A tree with every kind of content the scan must include.
sampleTree ∷ FilePath → IO ()
sampleTree root =
  populate
    root
    [ ("abc.txt", "abc")
    , ("empty.bin", "")
    , (".hidden", "hello world")
    , ("dir/sub/deep.bin", BS.pack [0, 1, 2, 255, 254])
    , ("empty-dir/", "")
    , ("unused.png", "\137PNG\r\n\SUB\ngarbage that no decoder would accept")
    , ("unused.lua", "this is ((( not lua $$$")
    ]

spec ∷ Spec
spec = do
  describe "what it inventories" $ do
    it "holds the root, every directory and every file, hidden and unused ones included, with exact lengths and independently known digests" $
      withLayout $ \tree → do
        sampleTree (rootPath tree)
        inventory ← scanned productionSeam limits (rootPath tree)
        sort (pathsOf inventory)
          `shouldBe` sort ["abc.txt", "empty.bin", ".hidden", "dir", "dir/sub", "dir/sub/deep.bin", "empty-dir", "unused.png", "unused.lua"]
        -- the root, the nine entries above
        inventoryEntryCount inventory `shouldBe` 10
        abc ← entryFor inventory "abc.txt"
        fmap (\fact → (factLength fact, show (factDigest fact))) (entryFact abc) `shouldBe` Just (3, abcDigest)
        empty ← entryFor inventory "empty.bin"
        fmap (\fact → (factLength fact, show (factDigest fact))) (entryFact empty) `shouldBe` Just (0, emptyDigest)
        hidden ← entryFor inventory ".hidden"
        fmap (\fact → (factLength fact, show (factDigest fact))) (entryFact hidden) `shouldBe` Just (11, helloWorldDigest)
        directory ← entryFor inventory "dir/sub"
        entryFact directory `shouldBe` Nothing
        -- 3 + 0 + 11 + 5 + 41 + 23, counting each file once
        inventoryByteTotal inventory `shouldBe` fromIntegral (sum [3, 0, 11, 5, BS.length "\137PNG\r\n\SUB\ngarbage that no decoder would accept", BS.length "this is ((( not lua $$$"])
        presenceOf inventory "abc.txt" `shouldBe` PresentFile 3
        presenceOf inventory "dir" `shouldBe` PresentDirectory
        presenceOf inventory "empty-dir" `shouldBe` PresentDirectory
        presenceOf inventory "unused.png" `shouldSatisfy` (/= Absent)

    it "records the SHA-256 of a file larger than one buffer, reading it in bounded chunks and probing one byte past the end" $
      withLayout $ \tree → do
        writeBytes (rootPath tree </> "million.a") (BS.replicate 1000000 0x61)
        (seam, rig) ← recordingSeam
        let big = limitsFrom baseSpec {specFileBytes = 1000000, specRootBytes = 2000000, specBufferBytes = 4096}
        inventory ← scanned seam big (rootPath tree)
        million ← entryFor inventory "million.a"
        fmap (\fact → (factLength fact, show (factDigest fact))) (entryFact million) `shouldBe` Just (1000000, millionADigest)
        log' ← events rig
        -- 244 full chunks of 4096 and one of 576, then the one-byte probe
        let sizes = requestSizes log'
        maximum sizes `shouldBe` 4096
        length (filter (== 4096) sizes) `shouldBe` 244
        take 245 sizes `shouldBe` replicate 244 4096 <> [576]
        drop 245 sizes `shouldBe` [1]
        _ ← asserting rig
        pure ()

    it "lists the same logical paths however the operating system orders a directory" $
      withLayout $ \tree → do
        populate (rootPath tree) [(BC.unpack n, "x") | n ← ["zeta", "alpha", "Mid", "beta"]]
        inventory ← scanned productionSeam limits (rootPath tree)
        pathsOf inventory `shouldBe` ["Mid", "alpha", "beta", "zeta"]

    it "keeps no copy of any file's bytes: the inventory holds lengths and digests only" $
      withLayout $ \tree → do
        populate (rootPath tree) [("secret.bin", "do not retain these bytes")]
        inventory ← scanned productionSeam limits (rootPath tree)
        entry ← entryFor inventory "secret.bin"
        -- the whole of what is retained about the file
        fmap factLength (entryFact entry) `shouldBe` Just 25
        show (listInventory inventory) `shouldNotContain` "retain"

  describe "what it refuses" $ do
    it "refuses an unused, unreadable file (injected permission denial) with the root, path and errno, and returns no inventory" $
      withLayout $ \tree → do
        populate (rootPath tree) [("used.txt", "ok"), ("unused/never-requested.dat", "x")]
        let denied = denyingOpen "never-requested.dat" 13 productionSeam
        outcome ← scanning denied limits (rootPath tree)
        case outcome of
          Left failure' → do
            inventoryFailurePath failure' `shouldBe` names ["unused", "never-requested.dat"]
            inventoryFailureReason failure' `shouldBe` Content (Unreadable 13)
            attributedSelection (inventoryFailureRoot failure') `shouldBe` BC.pack (rootPath tree)
          Right _ → expectationFailure "an unreadable file was inventoried"

    it "refuses an unused, unreadable file by its real permission bits, where the effective user cannot bypass them" $
      withLayout $ \tree → do
        user ← getEffectiveUserID
        if user == 0
          then pendingWith "the effective user is root, which ignores permission bits; the injected permission-denied example above covers this refusal"
          else do
            populate (rootPath tree) [("closed.dat", "x")]
            setFileMode (rootPath tree </> "closed.dat") 0
            outcome ← scanning productionSeam limits (rootPath tree)
            setFileMode (rootPath tree </> "closed.dat") (unionFileModes ownerReadMode ownerWriteMode)
            fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content (Unreadable 13))

    it "refuses a read error (injected) with the path and errno, closing everything" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a.bin", "abcdef")]
        (seam, rig) ← recordingSeam
        outcome ← scanning (failingRead 5 seam) limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content (Unreadable 5))
        fmap inventoryFailurePath (either Just (const Nothing) outcome) `shouldBe` Just (names ["a.bin"])
        _ ← asserting rig
        pure ()

    it "refuses an invalid name, even on an unused file, before any sibling is read" $
      withLayout $ \tree → do
        populate (rootPath tree) [("fine.txt", "x"), ("bad:name.txt", "unused")]
        (seam, rig) ← recordingSeam
        outcome ← scanning seam limits (rootPath tree)
        case fmap inventoryFailureReason (either Just (const Nothing) outcome) of
          Just (Identity (InvalidEntry _ (BadComponent 0 (SegmentForbidden Colon 3 _)))) → pure ()
          other → expectationFailure ("expected an invalid-name refusal, got " <> show other)
        -- the listing is judged as a whole before any entry of it is opened
        requestSizes <$> events rig `shouldReturn` []

    it "refuses two siblings that collide by canonical caseless comparison, before reading either (supplied names)" $
      withLayout $ \tree → do
        seam ← supplyingEntries [("Stra\xc3\x9f" <> "e", KindRegular), ("STRASSE", KindRegular)]
        outcome ← scanning seam limits (rootPath tree)
        case fmap inventoryFailureReason (either Just (const Nothing) outcome) of
          Just (Identity (SiblingCollision _)) → pure ()
          other → expectationFailure ("expected a sibling collision, got " <> show other)

    it "refuses a name that is not valid UTF-8 as bad inventory, never decoding it (supplied name)" $
      withLayout $ \tree → do
        seam ← supplyingEntries [(BS.pack [0xff, 0xfe, 0x61], KindRegular)]
        outcome ← scanning seam limits (rootPath tree)
        case fmap inventoryFailureReason (either Just (const Nothing) outcome) of
          Just (Identity (InvalidEntry _ (BadComponent 0 (SegmentMalformedUtf8 0)))) → pure ()
          other → expectationFailure ("expected a malformed-name refusal, got " <> show other)

    it "refuses a real name that is not valid UTF-8, where the filesystem holds one" $
      withLayout $ \tree → do
        created ← try @IOException (Raw.createFile (BC.pack (rootPath tree) <> "/" <> BS.pack [0xff, 0xfe, 0x61]) 0o600 >>= Raw.closeFd)
        case created of
          Left _ → pendingWith "this filesystem refuses a file name that is not valid UTF-8 (APFS does); the supplied-name example above covers the refusal"
          Right () → do
            outcome ← scanning productionSeam limits (rootPath tree)
            case fmap inventoryFailureReason (either Just (const Nothing) outcome) of
              Just (Identity (InvalidEntry _ (BadComponent 0 (SegmentMalformedUtf8 0)))) → pure ()
              other → expectationFailure ("expected a malformed-name refusal, got " <> show other)

    it "refuses an unsupported native open as unsupported, naming the errno (injected)" $
      withLayout $ \tree → do
        populate (rootPath tree) [("odd.bin", "x")]
        let unsupported = denyingOpen "odd.bin" 22 productionSeam
        outcome ← scanning unsupported limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content (Unsupported 22))
        fmap inventoryFailurePath (either Just (const Nothing) outcome) `shouldBe` Just (names ["odd.bin"])

    it "refuses a symbolic link inside the folder, even a dangling one, naming the path" $
      withLayout $ \tree → do
        populate (rootPath tree) [("real.txt", "x"), ("sub/", "")]
        createSymbolicLink "nowhere" (rootPath tree </> "sub" </> "dangling")
        outcome ← scanning productionSeam limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content ForbiddenLink)
        fmap inventoryFailurePath (either Just (const Nothing) outcome) `shouldBe` Just (names ["sub", "dangling"])

    it "refuses a type that is not a file or a directory (a FIFO), without waiting for a writer" $
      withLayout $ \tree → do
        populate (rootPath tree) [("real.txt", "x")]
        createNamedPipe (rootPath tree </> "pipe") 0o600
        outcome ← scanning productionSeam limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content (ForbiddenType KindFifo KindRegular))
        fmap inventoryFailurePath (either Just (const Nothing) outcome) `shouldBe` Just (names ["pipe"])

    it "refuses an oversized unused file before reading a byte of it" $
      withLayout $ \tree → do
        populate (rootPath tree) [("big.bin", BS.replicate 4097 0x62), ("small.txt", "x")]
        (seam, rig) ← recordingSeam
        outcome ← scanning seam limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Exceeded BoundFileBytes 4097 4096)
        fmap inventoryFailurePath (either Just (const Nothing) outcome) `shouldBe` Just (names ["big.bin"])
        requestSizes <$> events rig `shouldReturn` []
        _ ← asserting rig
        pure ()

    it "does not scan twice: a refusal is final, with no retry" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a.bin", "x")]
        attempts ← newCounter
        let failing = countReads attempts (failingRead 5 productionSeam)
        _ ← scanning failing limits (rootPath tree)
        -- the countReads wrapper sits outside the failing read, so it counts attempts
        readCount attempts `shouldReturn` 1

    it "performs no decoding: a malformed image and malformed Lua are inventoried, never opened as anything but bytes" $
      withLayout $ \tree → do
        populate (rootPath tree) [("broken.png", "\137PNG not really"), ("broken.lua", "function (((")]
        inventory ← scanned productionSeam limits (rootPath tree)
        presenceOf inventory "broken.png" `shouldBe` PresentFile 15
        presenceOf inventory "broken.lua" `shouldBe` PresentFile 12

  describe "the limits it needs of its root" $ do
    it "refuses, as misuse, an inventory buffer larger than the root's read chunk" $
      withLayout $ \tree → do
        let narrow = limitsOf 64 32
        ExceptionWithContext _ defect ←
          failsWith (withRootVia productionSeam narrow (rootPath tree) (scanInventory limits testKey))
        defect `shouldBe` ContentDefect (InventoryLimitsExceedRoot ReadChunk 64 32)

    it "refuses, as misuse, a segment bound deeper than the root's path depth" $
      withLayout $ \tree → do
        let shallow = limitsOf 4 4096
        ExceptionWithContext _ defect ←
          failsWith (withRootVia productionSeam shallow (rootPath tree) (scanInventory limits testKey))
        defect `shouldBe` ContentDefect (InventoryLimitsExceedRoot PathDepth 8 4)
