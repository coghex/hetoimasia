-- | A folder that changes while it is scanned: growth, truncation, an early
-- end of file, a size that disagrees after the read, an entry swapped between
-- its listing and its opening, and a directory swapped for a link after it was
-- opened. Each mutation happens at a named boundary, so the order is explicit
-- and nothing sleeps.
--
-- A file is also read once more than its length asks for, to detect growth;
-- these examples show that probe is the only read beyond the bytes the scan was
-- charged for.
module Test.Content.Inventory.Changes (spec) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Inventory
import System.Directory (createDirectory, removeDirectory, removeFile, renameDirectory)
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink, setFileSize)
import Test.Content.Inventory.Support
import Test.Content.Support
import Test.Hspec

limits ∷ InventoryLimits
limits = limitsFrom baseSpec {specBufferBytes = 4}

refusalOf ∷ Either InventoryFailure Inventory → Maybe InventoryFailureReason
refusalOf = either (Just . inventoryFailureReason) (const Nothing)

-- | Run an action the first time a read finishes.
afterFirstRead ∷ IO () → Seam → IO Seam
afterFirstRead action seam = do
  fired ← newIORef False
  pure (onBoundary (\boundary → case boundary of AfterRead → once fired action; _ → pure ()) seam)

once ∷ IORef Bool → IO () → IO ()
once fired action = do
  first ← atomicModifyIORef' fired (\already → (True, not already))
  if first then action else pure ()

spec ∷ Spec
spec = do
  describe "a file that changes while it is read" $ do
    it "refuses growth, reading at most one byte beyond what it was charged for" $
      withLayout $ \tree → do
        populate (rootPath tree) [("grows", "0123456789")]
        total ← newCounter
        (recorded, rig) ← recordingSeam
        grown ← afterFirstRead (appendFile (rootPath tree </> "grows") "MORE") (bytesReturned total recorded)
        outcome ← scanning grown limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Changed (Grew 10))
        -- ten bytes were charged for; the probe is the only read beyond them
        readCount total `shouldReturn` 11
        _ ← asserting rig
        pure ()

    it "refuses a file at the per-file limit that grows past it, without reading past the probe" $
      withLayout $ \tree → do
        let exact = limitsFrom baseSpec {specFileBytes = 12, specBufferBytes = 4}
        populate (rootPath tree) [("full", "0123456789ab")]
        total ← newCounter
        grown ← afterFirstRead (appendFile (rootPath tree </> "full") (replicate 100 'x')) (bytesReturned total productionSeam)
        outcome ← scanning grown exact (rootPath tree)
        refusalOf outcome `shouldBe` Just (Changed (Grew 12))
        readCount total `shouldReturn` 13

    it "refuses truncation to nothing in the middle of the read, naming the bytes seen" $
      withLayout $ \tree → do
        populate (rootPath tree) [("shrinks", "0123456789")]
        truncated ← afterFirstRead (setFileSize (rootPath tree </> "shrinks") 0) productionSeam
        outcome ← scanning truncated limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Changed (Truncated 10 4))

    it "refuses an early end of the file reported by the provider (injected)" $
      withLayout $ \tree → do
        populate (rootPath tree) [("early", "0123456789")]
        served ← newIORef 0
        outcome ← scanning (endingReadsAfter served 2 productionSeam) limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Changed (Truncated 10 8))

    it "refuses a size that disagrees after the read (injected metadata)" $
      withLayout $ \tree → do
        populate (rootPath tree) [("lies", "0123456789")]
        calls ← newIORef (0 ∷ Int)
        let lying = mapNative
              ( \native →
                  native
                    { nativeFstat = \fd →
                        nativeFstat native fd >>= \result → case result of
                          Right stat | statKind stat == KindRegular → do
                            count ← atomicModifyIORef' calls (\c → (c + 1, c + 1))
                            -- the open's own type check, the metadata before the read, then the one after
                            pure (Right (if count >= 3 then stat {statSize = statSize stat + 1} else stat))
                          other → pure other
                    }
              )
              productionSeam
        outcome ← scanning lying limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Changed (LengthChanged 10 11))

    it "does not notice an edit that keeps the length and lands behind the hash, and says so" $
      withLayout $ \tree → do
        populate (rootPath tree) [("edited", "abc")]
        let edited = onBoundary (\boundary → case boundary of ScanFileHashed _ → writeBytes (rootPath tree </> "edited") "xyz"; _ → pure ()) productionSeam
        -- the scan holds the bytes it observed; the edit is found when the file is next read
        inventory ← scanned edited limits (rootPath tree)
        entry ← entryFor inventory "edited"
        fmap (show . factDigest) (entryFact entry) `shouldBe` Just abcDigest
        withRootVia productionSeam rootLimits (rootPath tree) $ \root →
          readVerified inventory root (keyFor inventory "edited") 4096
            `shouldReturn` Left (ReadFailure (inventoryRoot inventory) (keyFor inventory "edited") (ReadChanged DigestMismatch))

  describe "an entry that changes between its listing and its opening" $ do
    it "refuses a file replaced by a directory, as a changed mapping" $
      withLayout $ \tree → do
        populate (rootPath tree) [("swap", "file")]
        let swapped = onBoundary (at "swap" (removeFile (rootPath tree </> "swap") >> createDirectory (rootPath tree </> "swap"))) productionSeam
        outcome ← scanning swapped limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Content (MappingChanged (Just KindRegular) (Just KindDirectory)))

    it "refuses a file replaced by a link to an outside file, and never reads the outside file" $
      withLayout $ \tree → do
        populate (rootPath tree) [("swap", "file")]
        writeBytes (tree </> "sentinel.txt") "outside sentinel"
        (recorded, rig) ← recordingSeam
        let swapped = onBoundary (at "swap" (removeFile (rootPath tree </> "swap") >> createSymbolicLink (tree </> "sentinel.txt") (rootPath tree </> "swap"))) recorded
        outcome ← scanning swapped limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Content (MappingChanged (Just KindRegular) (Just KindSymlink)))
        requestSizes <$> events rig `shouldReturn` []
        _ ← asserting rig
        pure ()

    it "refuses a file removed after it was listed" $
      withLayout $ \tree → do
        populate (rootPath tree) [("gone", "file")]
        let removed = onBoundary (at "gone" (removeFile (rootPath tree </> "gone"))) productionSeam
        outcome ← scanning removed limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Content (MappingChanged (Just KindRegular) Nothing))

    it "refuses a directory replaced by a link to an outside directory, and never enters it" $
      withLayout $ \tree → do
        populate (rootPath tree) [("sub/inside", "inside")]
        populate tree [("outside/sentinel.txt", "outside sentinel")]
        (recorded, rig) ← recordingSeam
        let swapped =
              onBoundary
                (at "sub" (renameDirectory (rootPath tree </> "sub") (tree </> "moved") >> createSymbolicLink (tree </> "outside") (rootPath tree </> "sub")))
                recorded
        outcome ← scanning swapped limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Content (MappingChanged (Just KindDirectory) (Just KindSymlink)))
        opened ← openedNames <$> events rig
        opened `shouldSatisfy` notElem "sub"
        opened `shouldSatisfy` notElem "sentinel.txt"
        _ ← asserting rig
        pure ()

    it "keeps reading the original directory when it is renamed away and replaced by a link after it was opened" $
      withLayout $ \tree → do
        populate (rootPath tree) [("sub/inside", "inside")]
        populate tree [("outside/sentinel.txt", "outside sentinel")]
        -- the directory is already open when the first of its entries is charged
        let swapped =
              onBoundary
                ( \boundary → case boundary of
                    ScanEntryCharged 3 →
                      renameDirectory (rootPath tree </> "sub") (tree </> "moved")
                        >> createSymbolicLink (tree </> "outside") (rootPath tree </> "sub")
                    _ → pure ()
                )
                productionSeam
        inventory ← scanned swapped limits (rootPath tree)
        pathsOf inventory `shouldBe` ["sub", "sub/inside"]
        presenceOf inventory "sub/inside" `shouldBe` PresentFile 6

  describe "a directory that changes after it was listed" $ do
    it "does not see an entry added to an already-listed directory, and the inventory is exactly what was observed" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a", "1"), ("b", "2")]
        let adding = onBoundary (at "a" (writeBytes (rootPath tree </> "late") "added after the listing")) productionSeam
        inventory ← scanned adding limits (rootPath tree)
        pathsOf inventory `shouldBe` ["a", "b"]
        presenceOf inventory "late" `shouldBe` Absent

    it "refuses a directory removed after it was listed" $
      withLayout $ \tree → do
        populate (rootPath tree) [("vanishes/", "")]
        let removed = onBoundary (at "vanishes" (removeDirectory (rootPath tree </> "vanishes"))) productionSeam
        outcome ← scanning removed limits (rootPath tree)
        refusalOf outcome `shouldBe` Just (Content (MappingChanged (Just KindDirectory) Nothing))
