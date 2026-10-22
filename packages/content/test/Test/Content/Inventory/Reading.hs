-- | The verified read: it returns exactly the bytes whose length and SHA-256
-- the inventory holds, or a structured refusal and no bytes at all.
--
-- Every example reads through one open root and an inventory scanned from it.
-- Changes are made to the folder between the scan and the read, or at a named
-- boundary inside the read, and a recording consumer proves what was delivered:
-- nothing at all on a refusal.
module Test.Content.Inventory.Reading (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Content
import qualified Hetoimasia.Content.Identity as Identity
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Inventory
import System.Directory (createDirectory, removeDirectory, removeFile, renameDirectory, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, setFileSize, setFileTimes, unionFileModes, createSymbolicLink)
import System.Posix.User (getEffectiveUserID)
import Test.Content.Inventory.Support
import Test.Content.Support
import Test.Hspec

limits ∷ InventoryLimits
limits = limitsFrom baseSpec {specBufferBytes = 8}

pattern50 ∷ ByteString
pattern50 = BC.pack (take 50 (cycle ['a' .. 'z']))

-- | What a verified read refused with, if it refused.
refusalOf ∷ Either ReadFailure a → Maybe ReadOutcome
refusalOf = either (Just . readFailureOutcome) (const Nothing)

-- | A consumer that records every byte string it is given.
newtype Consumer = Consumer (IORef [ByteString])

newConsumer ∷ IO Consumer
newConsumer = Consumer <$> newIORef []

-- | Offer a read's result to the consumer: only a success reaches it.
deliver ∷ Consumer → Either ReadFailure ByteString → IO ()
deliver (Consumer ref) = either (const (pure ())) (\bytes → modifyIORef' ref (bytes :))

received ∷ Consumer → IO [ByteString]
received (Consumer ref) = reverse <$> readIORef ref

readOf ∷ Inventory → ContentRoot → ByteString → Int → IO (Either ReadFailure ByteString)
readOf inventory root reference = readVerified inventory root (keyFor inventory reference)

-- | A seam that denies or fails only once armed, so the scan before it is
-- unaffected. Injected.
armed ∷ IORef Bool → (Native → Native) → Seam → Seam
armed flag change = mapNative $ \native →
  let faulty = change native
   in native
        { nativeOpenAt = \parent component directory →
            readIORef flag >>= \on → (if on then nativeOpenAt faulty else nativeOpenAt native) parent component directory
        , nativeRead = \fd buffer size →
            readIORef flag >>= \on → (if on then nativeRead faulty else nativeRead native) fd buffer size
        }

spec ∷ Spec
spec = do
  describe "the bytes it returns" $ do
    it "returns exactly the inventoried bytes, whatever their length, in bounded reads" $
      withLayout $ \tree → do
        populate (rootPath tree) [("empty", ""), ("short", "abc"), ("multi", pattern50), ("exact", BS.replicate 16 9)]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          before' ← length <$> events rig
          readOf inventory root "empty" 4096 `shouldReturn` Right ""
          readOf inventory root "short" 4096 `shouldReturn` Right "abc"
          readOf inventory root "multi" 4096 `shouldReturn` Right pattern50
          readOf inventory root "exact" 16 `shouldReturn` Right (BS.replicate 16 9)
          after' ← drop before' <$> events rig
          -- 0+1, 3+1, 50+1 and 16+1 bytes asked for, none in a request above the buffer
          maximum (requestSizes after') `shouldBe` 8
          sum (requestSizes after') `shouldBe` (0 + 1) + (3 + 1) + (50 + 1) + (16 + 1)
        _ ← asserting rig
        pure ()

    it "reads each uncached request again, from the file, and verifies it each time" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          before' ← length . requestSizes <$> events rig
          _ ← readOf inventory root "f" 4096
          _ ← readOf inventory root "f" 4096
          after' ← length . requestSizes <$> events rig
          -- 7 requests of at most 8 and a probe, twice
          after' - before' `shouldBe` 2 * 8

    it "keeps the bytes it delivered unchanged when the file is edited afterwards, and the next read refuses" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "original bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          delivered ← readOf inventory root "f" 4096 >>= either (fail . show) pure
          writeBytes (rootPath tree </> "f") "edited  bytes!"
          delivered `shouldBe` "original bytes"
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadChanged DigestMismatch)

  describe "what is decided from the inventory alone" $ do
    it "refuses a key that is absent, a case mismatch or a directory as not found, opening nothing" $
      withLayout $ \tree → do
        populate (rootPath tree) [("abc.txt", "abc"), ("dir/inner", "x")]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          before' ← length <$> events rig
          forM_ ["missing.txt", "ABC.txt", "Abc.TXT", "dir", "dir/other", "abc.txt/below"] $ \reference →
            refusalOf <$> readOf inventory root reference 4096 `shouldReturn` Just ReadNotFound
          after' ← drop before' <$> events rig
          [e | e@(Opened _ _) ← after'] `shouldBe` []
          requestSizes after' `shouldBe` []

    it "refuses the key of another root as not found" $
      withLayout $ \tree → do
        populate (rootPath tree) [("abc.txt", "abc")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          let other = either (error . show) id (Identity.rootKey "another-root")
              otherKey = either (error . show) id (Identity.parseReference (inventoryIdentityLimits limits) other "abc.txt")
          refusalOf <$> readVerified inventory root otherKey 4096 `shouldReturn` Just ReadNotFound
          inspectEntry inventory otherKey `shouldBe` Absent

    it "reports an inventoried length above the caller's ceiling as too large, before any open or read" $
      withLayout $ \tree → do
        populate (rootPath tree) [("big", BS.replicate 100 1), ("empty", "")]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          before' ← length <$> events rig
          refusalOf <$> readOf inventory root "big" 99 `shouldReturn` Just (ReadTooLarge 100 99)
          refusalOf <$> readOf inventory root "big" 0 `shouldReturn` Just (ReadTooLarge 100 0)
          after' ← drop before' <$> events rig
          [e | e@(Opened _ _) ← after'] `shouldBe` []
          requestSizes after' `shouldBe` []
          readOf inventory root "big" 100 `shouldReturn` Right (BS.replicate 100 1)
          readOf inventory root "empty" 0 `shouldReturn` Right ""

    it "accepts a ceiling of exactly the inventoried length and refuses one byte fewer" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          readOf inventory root "f" 50 `shouldReturn` Right pattern50
          refusalOf <$> readOf inventory root "f" 49 `shouldReturn` Just (ReadTooLarge 50 49)

    it "treats a negative ceiling and another root's handle as misuse, not as a refusal" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "x")]
        populate (tree </> "second") [("f", "x")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          ExceptionWithContext _ negative ← failsWith (readOf inventory root "f" (-1))
          negative `shouldBe` ContentDefect (BadReadCeiling (-1))
          withRootVia productionSeam rootLimits (tree </> "second") $ \second → do
            ExceptionWithContext _ wrong ← failsWith (readOf inventory second "f" 4096)
            wrong `shouldBe` ContentDefect InventoryRootMismatch

  describe "a file that changed since the scan" $ do
    it "refuses a same-length edit, and the consumer receives nothing" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        consumer ← newConsumer
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          writeBytes (rootPath tree </> "f") (BC.map succ pattern50)
          result ← readOf inventory root "f" 4096
          deliver consumer result
          refusalOf result `shouldBe` Just (ReadChanged DigestMismatch)
        received consumer `shouldReturn` []

    it "refuses a longer file without reading it, and a shorter one" $
      withLayout $ \tree → do
        populate (rootPath tree) [("longer", "0123456789"), ("shorter", "0123456789")]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          writeBytes (rootPath tree </> "longer") "0123456789 and more bytes after the end"
          writeBytes (rootPath tree </> "shorter") "01234"
          before' ← length <$> events rig
          refusalOf <$> readOf inventory root "longer" 4096 `shouldReturn` Just (ReadChanged (LengthChanged 10 39))
          refusalOf <$> readOf inventory root "shorter" 4096 `shouldReturn` Just (ReadChanged (LengthChanged 10 5))
          -- the length is compared before a byte of the result is allocated or read
          requestSizes . drop before' <$> events rig `shouldReturn` []

    it "refuses a file inventoried within the ceiling that grew past it, allocating and reading nothing for the growth" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          appendFile (rootPath tree </> "f") (replicate 10000 'x')
          before' ← length <$> events rig
          refusalOf <$> readOf inventory root "f" 50 `shouldReturn` Just (ReadChanged (LengthChanged 50 10050))
          requestSizes . drop before' <$> events rig `shouldReturn` []

    it "refuses growth that lands after the open, reading no more than one byte beyond the inventoried length" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        total ← newCounter
        (recorded, rig) ← recordingSeam
        let seam = onBoundary (\boundary → case boundary of ReadOpened _ → appendFile (rootPath tree </> "f") (replicate 10000 'x'); _ → pure ()) (bytesReturned total recorded)
        withScanned seam limits (rootPath tree) $ \root inventory → do
          scanBytes ← readCount total
          refusalOf <$> readOf inventory root "f" 50 `shouldReturn` Just (ReadChanged (Grew 50))
          now ← readCount total
          now - scanBytes `shouldBe` 51
        _ ← asserting rig
        pure ()

    it "refuses a file truncated while it is read" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        started ← newIORef False
        let seam = onBoundary (\boundary → case boundary of ReadOpened _ → writeIORef started True; AfterRead → readIORef started >>= \on → if on then setFileSize (rootPath tree </> "f") 0 >> writeIORef started False else pure (); _ → pure ()) productionSeam
        withScanned seam limits (rootPath tree) $ \root inventory →
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadChanged (Truncated 50 8))

    it "refuses a missing file, a renamed file and a file whose directory is gone as changed content" $
      withLayout $ \tree → do
        populate (rootPath tree) [("gone", "x"), ("renamed", "x"), ("dir/inner", "x")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          removeFile (rootPath tree </> "gone")
          renameFile (rootPath tree </> "renamed") (rootPath tree </> "renamed-away")
          removeFile (rootPath tree </> "dir" </> "inner")
          removeDirectory (rootPath tree </> "dir")
          refusalOf <$> readOf inventory root "gone" 4096 `shouldReturn` Just (ReadChanged Missing)
          refusalOf <$> readOf inventory root "renamed" 4096 `shouldReturn` Just (ReadChanged Missing)
          refusalOf <$> readOf inventory root "dir/inner" 4096 `shouldReturn` Just (ReadChanged Missing)
          -- the new name is not admitted
          refusalOf <$> readOf inventory root "renamed-away" 4096 `shouldReturn` Just ReadNotFound

    it "refuses a file whose name was changed only in case, on a filesystem that would still resolve the old spelling" $
      withLayout $ \tree → do
        populate (rootPath tree) [("Hero.png", "hero bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          readOf inventory root "Hero.png" 4096 `shouldReturn` Right "hero bytes"
          renameFile (rootPath tree </> "Hero.png") (rootPath tree </> "hero.png")
          -- the bytes are untouched; the spelling the inventory holds is not there any more
          refusalOf <$> readOf inventory root "Hero.png" 4096 `shouldReturn` Just (ReadChanged Missing)
          refusalOf <$> readOf inventory root "hero.png" 4096 `shouldReturn` Just ReadNotFound

    it "refuses a file under a directory whose name was changed only in case" $
      withLayout $ \tree → do
        populate (rootPath tree) [("Assets/Hero.png", "hero bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          renameDirectory (rootPath tree </> "Assets") (rootPath tree </> "assets-tmp")
          renameDirectory (rootPath tree </> "assets-tmp") (rootPath tree </> "assets")
          refusalOf <$> readOf inventory root "Assets/Hero.png" 4096 `shouldReturn` Just (ReadChanged Missing)

    it "refuses a file replaced by a directory or by a link, and never reads what the link names" $
      withLayout $ \tree → do
        populate (rootPath tree) [("becomes-dir", "x"), ("becomes-link", "x")]
        writeBytes (tree </> "sentinel.txt") "outside sentinel"
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          removeFile (rootPath tree </> "becomes-dir")
          createDirectory (rootPath tree </> "becomes-dir")
          removeFile (rootPath tree </> "becomes-link")
          createSymbolicLink (tree </> "sentinel.txt") (rootPath tree </> "becomes-link")
          before' ← length <$> events rig
          refusalOf <$> readOf inventory root "becomes-dir" 4096 `shouldReturn` Just (ReadChanged (Retyped (ForbiddenType KindDirectory KindRegular)))
          refusalOf <$> readOf inventory root "becomes-link" 4096 `shouldReturn` Just (ReadChanged (Retyped ForbiddenLink))
          requestSizes . drop before' <$> events rig `shouldReturn` []
        _ ← asserting rig
        pure ()

    it "refuses an intermediate directory replaced by a link to an outside directory holding the same names" $
      withLayout $ \tree → do
        populate (rootPath tree) [("dir/inner", "inside")]
        populate tree [("outside/inner", "inside")]
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          removeFile (rootPath tree </> "dir" </> "inner")
          removeDirectory (rootPath tree </> "dir")
          createSymbolicLink (tree </> "outside") (rootPath tree </> "dir")
          before' ← length <$> events rig
          refusalOf <$> readOf inventory root "dir/inner" 4096 `shouldReturn` Just (ReadChanged (Retyped ForbiddenLink))
          requestSizes . drop before' <$> events rig `shouldReturn` []

    it "succeeds after a timestamp-only or permission change" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "same bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          setFileTimes (rootPath tree </> "f") 1000000000 1000000000
          setFileMode (rootPath tree </> "f") (unionFileModes ownerReadMode ownerWriteMode)
          readOf inventory root "f" 4096 `shouldReturn` Right "same bytes"

    it "succeeds after identical bytes replace the file at the same legal path" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "same bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          writeBytes (rootPath tree </> "replacement") "same bytes"
          renameFile (rootPath tree </> "replacement") (rootPath tree </> "f")
          readOf inventory root "f" 4096 `shouldReturn` Right "same bytes"

    it "does not admit a new path, and an unchanged known path still reads" $
      withLayout $ \tree → do
        populate (rootPath tree) [("known", "known bytes")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          before' ← pure (pathsOf inventory)
          writeBytes (rootPath tree </> "new-file") "arrived after startup"
          refusalOf <$> readOf inventory root "new-file" 4096 `shouldReturn` Just ReadNotFound
          readOf inventory root "known" 4096 `shouldReturn` Right "known bytes"
          pathsOf inventory `shouldBe` before'
          inspectEntry inventory (keyFor inventory "known") `shouldBe` PresentFile 11
          presenceOf inventory "new-file" `shouldBe` Absent

  describe "access and read errors" $ do
    it "reports an injected permission denial at the open as an I/O error" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "x")]
        flag ← newIORef False
        let seam = armed flag (\native → native {nativeOpenAt = \_ _ _ → pure (Left 13)}) productionSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          writeIORef flag True
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadIoError (Unreadable 13))

    it "reports a file made unreadable by its permission bits as an I/O error, where the effective user cannot bypass them" $
      withLayout $ \tree → do
        user ← getEffectiveUserID
        if user == 0
          then pendingWith "the effective user is root, which ignores permission bits; the injected permission-denied example above covers this refusal"
          else do
            populate (rootPath tree) [("f", "x")]
            withScanned productionSeam limits (rootPath tree) $ \root inventory → do
              setFileMode (rootPath tree </> "f") 0
              outcome ← readOf inventory root "f" 4096
              setFileMode (rootPath tree </> "f") (unionFileModes ownerReadMode ownerWriteMode)
              refusalOf outcome `shouldBe` Just (ReadIoError (Unreadable 13))

    it "reports an injected read error as an I/O error, distinct from changed content" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        flag ← newIORef False
        (recorded, rig) ← recordingSeam
        let seam = armed flag (\native → native {nativeRead = \_ _ _ → pure (Left 5)}) recorded
        withScanned seam limits (rootPath tree) $ \root inventory → do
          writeIORef flag True
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadIoError (Unreadable 5))
        _ ← asserting rig
        pure ()

  describe "a mutation between fingerprinting and a would-be second open" $ do
    it "cannot reach the consumer: a file replaced after it was opened is still the bytes that were verified" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "verified original")]
        consumer ← newConsumer
        let replace = do
              writeBytes (rootPath tree </> "replacement") "SUBSTITUTED BYTES"
              renameFile (rootPath tree </> "replacement") (rootPath tree </> "f")
            seam = onBoundary (\boundary → case boundary of ReadOpened _ → replace; _ → pure ()) productionSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          -- the descriptor already held names the object that was verified
          first ← readOf inventory root "f" 4096
          deliver consumer first
          received consumer `shouldReturn` ["verified original"]
          -- the next read opens the path again and finds what is there now
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadChanged DigestMismatch)

    it "is refused when the held file is edited in place after it was opened, and the consumer receives nothing" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "verified original")]
        consumer ← newConsumer
        let edit = writeBytes (rootPath tree </> "f") "SUBSTITUTED BYTES"
            seam = onBoundary (\boundary → case boundary of ReadOpened _ → edit; _ → pure ()) productionSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          result ← readOf inventory root "f" 4096
          deliver consumer result
          refusalOf result `shouldBe` Just (ReadChanged DigestMismatch)
        received consumer `shouldReturn` []

    it "compares digests only after every byte is in the buffer, so a late edit cannot be half-delivered" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", pattern50)]
        consumer ← newConsumer
        let edit = writeBytes (rootPath tree </> "f") (BS.replicate 50 0x2a)
            seam = onBoundary (\boundary → case boundary of ReadBeforeCompare _ → edit; _ → pure ()) productionSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          -- the edit lands after the last byte was read: the bytes in the buffer are the verified ones
          result ← readOf inventory root "f" 4096
          deliver consumer result
          received consumer `shouldReturn` [pattern50]
          refusalOf <$> readOf inventory root "f" 4096 `shouldReturn` Just (ReadChanged DigestMismatch)
