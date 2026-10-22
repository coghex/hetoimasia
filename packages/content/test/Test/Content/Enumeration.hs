-- | Enumerating directories and walking trees: kinds, lossless names, hard
-- links, mapping changes, depth, and the identity rules for mounts and cycles.
--
-- The cycle and device examples use the recording seam's identity overrides,
-- because a real directory cycle or a second device needs a bind mount, and
-- this suite creates no mounts. Everything else in this module is native.
module Test.Content.Enumeration (spec) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native
import System.Directory (createDirectory, removeFile, renameDirectory)
import System.FilePath ((</>))
import System.Posix.Files (createLink, createSymbolicLink)
import qualified System.Posix.IO.ByteString as Raw
import Test.Content.Support
import Test.Hspec

-- | Every entry below a reader, depth first in name order, as root-relative
-- paths with their kinds, descending into directories only.
walkTree ∷ DirectoryReader → IO [([NativeName], EntryKind)]
walkTree reader = do
  entries ← sortOn entryName <$> drain (readEntry reader)
  concat
    <$> forM entries
      ( \entry → do
          let here = directoryPath reader <> [entryName entry]
          case entryKind entry of
            KindDirectory → withEntryDirectory reader entry (fmap ((here, KindDirectory) :) . walkTree)
            kind → pure [(here, kind)]
      )

listing ∷ ContentRoot → [BS.ByteString] → IO [(NativeName, EntryKind)]
listing root path =
  withDirectory root (names path) $ \reader →
    sortOn fst . map (\e → (entryName e, entryKind e)) <$> drain (readEntry reader)

spec ∷ Spec
spec = do
  describe "listing" $ do
    it "lists each entry with its own kind and never the structural entries" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "dir")
        writeBytes (root </> "file") "f"
        createSymbolicLink "file" (root </> "link")
        withRoot root $ \open →
          listing open []
            `shouldReturn` [(name "dir", KindDirectory), (name "file", KindRegular), (name "link", KindSymlink)]
        withRoot root $ \open →
          listing open ["dir"] `shouldReturn` []

    it "reports the directory's own identity and its path" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "dir")
        withRoot root $ \open →
          withDirectory open (names ["dir"]) $ \reader → do
            directoryPath reader `shouldBe` names ["dir"]
            directoryIdentity reader `shouldNotBe` reportIdentity (rootReport open)
        withRoot root $ \open →
          withDirectory open [] $ \reader →
            directoryIdentity reader `shouldBe` reportIdentity (rootReport open)

    it "stops an enumeration early and closes everything" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        mapM_ (\n → writeBytes (root </> n) "x") ["a", "b", "c"]
        (seam, rig) ← recordingSeam
        withRootVia seam defaultContentLimits root $ \open →
          withDirectory open [] $ \reader → do
            first ← readEntry reader
            fmap entryKind first `shouldBe` Just KindRegular
        _ ← asserting rig
        pure ()

  describe "lossless names" $ do
    it "enumerates and opens a name that is not valid UTF-8, where the filesystem accepts one" $
      withTree $ \tree → do
        let root = tree </> "root"
            invalid = BS.pack [0xff, 0xfe, 0x61]
        createDirectory root
        created ← try @IOException (Raw.createFile (BC.pack root <> "/" <> invalid) 0o600 >>= Raw.closeFd)
        case created of
          Left _ →
            pendingWith "this filesystem refuses a file name that is not valid UTF-8 (APFS does); the seam-supplied example covers the API"
          Right () →
            withRoot root $ \open → do
              entries ← listing open []
              map (nativeNameBytes . fst) entries `shouldBe` [invalid]
              opened ← either (fail . show) pure (nativeName invalid)
              withFile open [opened] (\reader → readChunk reader 4) `shouldReturn` ""

    it "carries a seam-supplied non-UTF-8 name through enumeration byte for byte" $
      withTree $ \tree → do
        let root = tree </> "root"
            invalid = BS.pack [0xff, 0xfe]
        createDirectory root
        supplying ← supplyingNames [invalid]
        withRootVia supplying defaultContentLimits root $ \open → do
          entries ← listing open []
          map (nativeNameBytes . fst) entries `shouldBe` [invalid]
          map snd entries `shouldBe` [KindRegular]

    it "refuses a provider name that could cross a component boundary" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        supplying ← supplyingNames ["a/b"]
        withRootVia supplying defaultContentLimits root $ \open →
          failureKindOf (listing open []) `shouldReturn` InvalidComponent SeparatorInName

  describe "hard links" $ do
    it "exposes both names with the same identity and separate paths" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        writeBytes (root </> "one") "shared bytes"
        createLink (root </> "one") (root </> "two")
        withRoot root $ \open → do
          entries ← listing open []
          entries `shouldBe` [(name "one", KindRegular), (name "two", KindRegular)]
          identities ←
            forM ["one", "two"] $ \n →
              withFile open (names [n]) $ \reader → do
                metadata ← fileMetadata reader
                bytes ← readAll 5 (readChunk reader)
                pure (filePath reader, metadataLinkCount metadata, metadataIdentity metadata, bytes)
          map (\(p, _, _, _) → p) identities `shouldBe` [names ["one"], names ["two"]]
          map (\(_, links, _, _) → links) identities `shouldBe` [2, 2]
          case identities of
            [(_, _, first, _), (_, _, second, _)] → first `shouldBe` second
            other → expectationFailure ("expected two files, got " <> show (length other))
          map (\(_, _, _, bytes) → bytes) identities `shouldBe` ["shared bytes", "shared bytes"]

    it "walks both names of a hard link as two entries" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "sub")
        writeBytes (root </> "one") "x"
        createLink (root </> "one") (root </> "sub" </> "alias")
        withRoot root $ \open →
          withDirectory open [] walkTree
            `shouldReturn` [ (names ["one"], KindRegular)
                           , (names ["sub"], KindDirectory)
                           , (names ["sub", "alias"], KindRegular)
                           ]

  describe "mapping changes" $ do
    it "refuses an enumerated file that was removed, replaced by a directory or by a link" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        mapM_ (\n → writeBytes (root </> n) "x") ["gone", "dir", "link"]
        withRoot root $ \open →
          withDirectory open [] $ \reader → do
            entries ← drain (readEntry reader)
            gone ← entryNamed entries "gone"
            dir ← entryNamed entries "dir"
            link ← entryNamed entries "link"
            removeFile (root </> "gone")
            removeFile (root </> "dir")
            createDirectory (root </> "dir")
            removeFile (root </> "link")
            createSymbolicLink "elsewhere" (root </> "link")
            failureKindOf (withEntryFile reader gone (\_ → pure ()))
              `shouldReturn` MappingChanged (Just KindRegular) Nothing
            failureKindOf (withEntryFile reader dir (\_ → pure ()))
              `shouldReturn` MappingChanged (Just KindRegular) (Just KindDirectory)
            failureKindOf (withEntryFile reader link (\_ → pure ()))
              `shouldReturn` MappingChanged (Just KindRegular) (Just KindSymlink)

    it "refuses an enumerated directory that was replaced by a file" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "dir")
        withRoot root $ \open →
          withDirectory open [] $ \reader → do
            entries ← drain (readEntry reader)
            dir ← entryNamed entries "dir"
            renameDirectory (root </> "dir") (root </> "moved")
            writeBytes (root </> "dir") "now a file"
            failureKindOf (withEntryDirectory reader dir (\_ → pure ()))
              `shouldReturn` MappingChanged (Just KindDirectory) (Just KindRegular)

    it "refuses an entry whose kind the operation cannot open, without opening it" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "dir")
        writeBytes (root </> "file") "x"
        (seam, rig) ← recordingSeam
        withRootVia seam defaultContentLimits root $ \open →
          withDirectory open [] $ \reader → do
            entries ← drain (readEntry reader)
            dir ← entryNamed entries "dir"
            file ← entryNamed entries "file"
            opensBefore ← length . filter isOpen <$> events rig
            failureKindOf (withEntryFile reader dir (\_ → pure ())) `shouldReturn` ForbiddenType KindDirectory KindRegular
            failureKindOf (withEntryDirectory reader file (\_ → pure ())) `shouldReturn` ForbiddenType KindRegular KindDirectory
            opensAfter ← length . filter isOpen <$> events rig
            opensAfter `shouldBe` opensBefore
        _ ← asserting rig
        pure ()

    it "refuses an entry that disappears between the directory read and its kind query" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        writeBytes (root </> "vanishing") "x"
        let racing = mapNative (\native → native {nativeStatAt = \_ component → if component == name "vanishing" then pure (Left 2) else pure (Left 1)}) productionSeam
        withRootVia racing defaultContentLimits root $ \open → do
          failure' ← contentFailure (listing open [])
          failureKind failure' `shouldBe` MappingChanged Nothing Nothing
          failurePath failure' `shouldBe` names ["vanishing"]

  describe "depth, devices and cycles" $ do
    it "refuses a traversal deeper than the caller's bound" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "a")
        createDirectory (root </> "a" </> "b")
        createDirectory (root </> "a" </> "b" </> "c")
        withRootVia productionSeam (limitsOf 2 1024) root $ \open →
          failureKindOf (withDirectory open [] walkTree) `shouldReturn` LimitExceeded PathDepth 2
        withRootVia productionSeam (limitsOf 3 1024) root $ \open →
          withDirectory open [] walkTree
            `shouldReturn` [(names ["a"], KindDirectory), (names ["a", "b"], KindDirectory), (names ["a", "b", "c"], KindDirectory)]

    it "reads beneath a directory that reports another device, and does not skip it" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "mnt")
        writeBytes (root </> "mnt" </> "inside") "on another device"
        seam ← overriding [("mnt", NativeIdentity 99 5)]
        withRootVia seam defaultContentLimits root $ \open → do
          withDirectory open [] walkTree
            `shouldReturn` [(names ["mnt"], KindDirectory), (names ["mnt", "inside"], KindRegular)]
          withFile open (names ["mnt", "inside"]) (\reader → readAll 8 (readChunk reader))
            `shouldReturn` "on another device"

    it "refuses a directory that repeats on its own ancestor chain, with the chain" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "a")
        createDirectory (root </> "a" </> "b")
        createDirectory (root </> "a" </> "b" </> "c")
        seam ← overriding [("a", NativeIdentity 1 10), ("c", NativeIdentity 1 10)]
        withRootVia seam defaultContentLimits root $ \open → do
          failure' ← contentFailure (withDirectory open [] walkTree)
          failureKind failure' `shouldBe` DirectoryCycle (names ["a", "b", "c"]) 1
          failurePath failure' `shouldBe` names ["a", "b", "c"]

    it "refuses a directory that repeats the root itself" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "loop")
        withRootVia productionSeam defaultContentLimits root $ \open → do
          let rootIdentity = reportIdentity (rootReport open)
          seam ← overriding [("loop", rootIdentity)]
          withRootVia seam defaultContentLimits root $ \again →
            failureKindOf (withDirectory again [] walkTree) `shouldReturn` DirectoryCycle (names ["loop"]) 0

    it "refuses an intermediate component that repeats an ancestor when a path is opened" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        createDirectory (root </> "a")
        createDirectory (root </> "a" </> "b")
        writeBytes (root </> "a" </> "b" </> "f") "x"
        seam ← overriding [("b", NativeIdentity 1 10), ("a", NativeIdentity 1 10)]
        withRootVia seam defaultContentLimits root $ \open →
          failureKindOf (withFile open (names ["a", "b", "f"]) (\_ → pure ()))
            `shouldReturn` DirectoryCycle (names ["a", "b"]) 1

    it "does not treat a repeated identity on another branch as a cycle, and keeps the paths apart" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        mapM_ (\n → createDirectory (root </> n) >> createDirectory (root </> n </> "shared")) ["x", "y"]
        writeBytes (root </> "x" </> "shared" </> "f") "x"
        writeBytes (root </> "y" </> "shared" </> "f") "y"
        seam ← overriding [("shared", NativeIdentity 3 33)]
        withRootVia seam defaultContentLimits root $ \open →
          withDirectory open [] walkTree
            `shouldReturn` [ (names ["x"], KindDirectory)
                           , (names ["x", "shared"], KindDirectory)
                           , (names ["x", "shared", "f"], KindRegular)
                           , (names ["y"], KindDirectory)
                           , (names ["y", "shared"], KindDirectory)
                           , (names ["y", "shared", "f"], KindRegular)
                           ]
  where
    isOpen = \case
      Opened _ _ → True
      _ → False

-- | A seam that reports chosen native identities for directories by the name
-- they were opened under; every other answer is the real one.
overriding ∷ [(BS.ByteString, NativeIdentity)] → IO Seam
overriding table = do
  opened ← newIORef Map.empty
  let wanted = Map.fromList [(name n, identity) | (n, identity) ← table]
      native = seamNative productionSeam
      remember ∷ IORef (Map.Map Int NativeName) → Int → NativeName → IO ()
      remember ref fd component = atomicModifyIORef' ref (\m → (Map.insert fd component m, ()))
  pure
    productionSeam
      { seamNative =
          native
            { nativeOpenAt = \parent component directory → do
                result ← nativeOpenAt native parent component directory
                case result of
                  Right (NativeFd fd) → remember opened (fromIntegral fd) component
                  Left _ → pure ()
                pure result
            , nativeFstat = \(NativeFd fd) → do
                result ← nativeFstat native (NativeFd fd)
                known ← readIORef opened
                pure $ case (result, Map.lookup (fromIntegral fd) known >>= (`Map.lookup` wanted)) of
                  (Right stat, Just identity) | statKind stat == KindDirectory → Right stat {statIdentity = identity}
                  _ → result
            }
      }

-- | A seam whose enumerations yield these raw names after the real ones,
-- answering the kind query for them as a regular file.
supplyingNames ∷ [BS.ByteString] → IO Seam
supplyingNames extra = do
  remainingNames ← newIORef extra
  let native = seamNative productionSeam
      injected = map name' extra
      name' bytes = either (const Nothing) Just (nativeName bytes)
  pure
    productionSeam
      { seamNative =
          native
            { nativeReadStream = \stream →
                nativeReadStream native stream >>= \case
                  Right Nothing →
                    atomicModifyIORef' remainingNames $ \remaining → case remaining of
                      [] → ([], Right Nothing)
                      next : rest → (rest, Right (Just next))
                  other → pure other
            , nativeStatAt = \parent component →
                if Just component `elem` injected
                  then pure (Right (NativeStat KindRegular (NativeIdentity 1 1) 0 1))
                  else nativeStatAt native parent component
            }
      }
