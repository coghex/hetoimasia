-- | Reading an opened file: strict bounded chunks and metadata from the one
-- object that was opened, short reads, read errors, early termination, and the
-- refusal of a reader used outside its callback or thread.
module Test.Content.Reading (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.Posix.Files (deviceID, fileID, getFileStatus, removeLink)
import Test.Content.Support
import Test.Hspec

content ∷ BS.ByteString
content = "0123456789abcdef"

withFileTree ∷ (FilePath → IO a) → IO a
withFileTree use = withTree $ \tree → do
  let root = tree </> "root"
  createDirectory root
  writeBytes (root </> "file.bin") content
  writeBytes (root </> "empty.bin") ""
  use root

readFileWith ∷ ContentRoot → Int → IO BS.ByteString
readFileWith root size = withFile root (names ["file.bin"]) $ \reader → readAll size (readChunk reader)

spec ∷ Spec
spec = do
  describe "chunks" $ do
    it "returns every byte of the file, whatever the chunk size" $
      withFileTree $ \path →
        withRoot path $ \root →
          mapM_ (\size → readFileWith root size `shouldReturn` content) [1, 3, 5, 16, 17, 1000]

    it "returns an empty chunk for an empty file, and again at the end" $
      withFileTree $ \path →
        withRoot path $ \root →
          withFile root (names ["empty.bin"]) $ \reader → do
            readChunk reader 8 `shouldReturn` ""
            readChunk reader 8 `shouldReturn` ""

    it "returns chunks that own their memory and may be kept past the callback" $
      withFileTree $ \path →
        withRoot path $ \root → do
          kept ← withFile root (names ["file.bin"]) $ \reader → readChunk reader 4
          kept `shouldBe` "0123"

    it "reads a file larger than one chunk without buffering it whole" $
      withTree $ \tree → do
        let big = BS.concat (replicate 4096 content)
        createDirectory (tree </> "root")
        writeBytes (tree </> "root" </> "big.bin") big
        withRoot (tree </> "root") $ \root →
          withFile root (names ["big.bin"]) $ \reader → do
            first ← readChunk reader 1024
            BS.length first `shouldBe` 1024
            rest ← readAll 4096 (readChunk reader)
            first <> rest `shouldBe` big

  describe "metadata" $ do
    it "reports the size, link count and identity of the opened object" $
      withFileTree $ \path → do
        status ← getFileStatus (path </> "file.bin")
        withRoot path $ \root →
          withFile root (names ["file.bin"]) $ \reader → do
            metadata ← fileMetadata reader
            metadataSize metadata `shouldBe` fromIntegral (BS.length content)
            metadataLinkCount metadata `shouldBe` 1
            metadataIdentity metadata
              `shouldBe` NativeIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status))
            filePath reader `shouldBe` names ["file.bin"]

    it "keeps reading the opened object when its pathname is replaced mid-read" $
      withFileTree $ \path → do
        status ← getFileStatus (path </> "file.bin")
        withRoot path $ \root →
          withFile root (names ["file.bin"]) $ \reader → do
            first ← readChunk reader 4
            removeLink (path </> "file.bin")
            writeBytes (path </> "file.bin") "REPLACED REPLACED REPLACED"
            rest ← readAll 5 (readChunk reader)
            first <> rest `shouldBe` content
            metadata ← fileMetadata reader
            identityInode (metadataIdentity metadata) `shouldBe` fromIntegral (fileID status)

  describe "short reads, errors and early stop" $ do
    it "treats a short chunk as data, not as the end of the file" $
      withFileTree $ \path → do
        let shortened = mapNative (\native → native {nativeRead = \fd buffer size → nativeRead native fd buffer (min 2 size)}) productionSeam
        withRootVia shortened defaultContentLimits path $ \root →
          withFile root (names ["file.bin"]) $ \reader → do
            first ← readChunk reader 10
            BS.length first `shouldBe` 2
            rest ← readAll 10 (readChunk reader)
            first <> rest `shouldBe` content

    it "reports a read error as unreadable with the path, and closes everything" $
      withFileTree $ \path → do
        (seam, rig) ← recordingSeam
        let failing = mapNative (\native → native {nativeRead = \_ _ _ → pure (Left 5)}) seam
        withRootVia failing defaultContentLimits path $ \root → do
          failure' ← contentFailure (withFile root (names ["file.bin"]) (\reader → readChunk reader 4))
          failureKind failure' `shouldBe` Unreadable 5
          failurePath failure' `shouldBe` names ["file.bin"]
        _ ← asserting rig
        pure ()

    it "stops early without reading the rest, closing everything" $
      withFileTree $ \path → do
        (seam, rig) ← recordingSeam
        withRootVia seam defaultContentLimits path $ \root →
          withFile root (names ["file.bin"]) $ \reader →
            readChunk reader 4 `shouldReturn` "0123"
        log' ← events rig
        length [() | Read _ _ ← log'] `shouldBe` 1
        _ ← asserting rig
        pure ()

    it "refuses a provider that returns more than was asked as a defect, not as content trouble" $
      withFileTree $ \path → do
        let lying = mapNative (\native → native {nativeRead = \_ _ size → pure (Right (size + 1))}) productionSeam
        withRootVia lying defaultContentLimits path $ \root → do
          ExceptionWithContext _ defect ←
            failsWith (withFile root (names ["file.bin"]) (\reader → readChunk reader 4))
          case defect of
            ContentDefect (ProviderDefect OpRead _) → pure ()
            other → expectationFailure ("expected a provider defect, got " <> show other)

  describe "bounds and misuse" $ do
    it "refuses a chunk size below one as a defect and one above the caller's bound as a limit" $
      withFileTree $ \path → do
        let narrow = limitsOf 8 8
        withRootVia productionSeam narrow path $ \root →
          withFile root (names ["file.bin"]) $ \reader → do
            ExceptionWithContext _ zero ← failsWith (readChunk reader 0)
            zero `shouldBe` ContentDefect (BadChunkSize 0)
            ExceptionWithContext _ negative ← failsWith (readChunk reader (-3))
            negative `shouldBe` ContentDefect (BadChunkSize (-3))
            failureKindOf (readChunk reader 9) `shouldReturn` LimitExceeded ReadChunk 8
            -- refused on the bound alone: nothing is allocated for a request this size
            failureKindOf (readChunk reader maxBound) `shouldReturn` LimitExceeded ReadChunk 8
            failureKindOf (readChunk reader (10 ^ (12 ∷ Int))) `shouldReturn` LimitExceeded ReadChunk 8
            readChunk reader 8 `shouldReturn` "01234567"

    it "refuses a reader used after its callback, instead of reaching a reused descriptor" $
      withFileTree $ \path → do
        (seam, rig) ← recordingSeam
        retained ← newIORef Nothing
        withRootVia seam defaultContentLimits path $ \root → do
          withFile root (names ["file.bin"]) $ \reader → writeIORef retained (Just reader)
          -- the same thread, after the callback: the reader is dead, not foreign
          Just stale ← readIORef retained
          ExceptionWithContext _ afterRead ← failsWith (readChunk stale 4)
          afterRead `shouldBe` ContentDefect ReaderNotLive
          ExceptionWithContext _ afterMetadata ← failsWith (fileMetadata stale)
          afterMetadata `shouldBe` ContentDefect ReaderNotLive
        log' ← events rig
        length [() | Read _ _ ← log'] `shouldBe` 0

    it "refuses a reader used from a thread other than the one it was lent to" $
      withFileTree $ \path →
        withRoot path $ \root →
          withFile root (names ["file.bin"]) $ \reader → do
            outcome ← spawn (readChunk reader 4) >>= awaitOutcome
            case outcome of
              Left exception → show exception `shouldContain` "WrongThread"
              Right _ → expectationFailure "a reader was used from another thread"

    it "refuses a root used after its scope" $
      withFileTree $ \path → do
        retained ← newIORef Nothing
        withRoot path $ \root → writeIORef retained (Just root)
        Just stale ← readIORef retained
        ExceptionWithContext _ afterScope ← failsWith (readFileWith stale 4)
        afterScope `shouldBe` ContentDefect RootNotAdmitting
