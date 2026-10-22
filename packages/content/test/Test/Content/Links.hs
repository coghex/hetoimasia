-- | No symbolic link is followed below the root, at any component, including
-- the one swapped in between two steps of an operation; and only regular files
-- and directories are content.
--
-- The race examples hold an operation at a named boundary, change the tree the
-- way a concurrent process could, and let the operation continue. A
-- check-then-open implementation reads the outside sentinel in exactly these
-- examples; 'checkThenOpenControl' runs that implementation against the same
-- swap to show the fixture can tell, and the service must refuse instead.
module Test.Content.Links (spec) where

import Control.Monad (unless)
import qualified Data.ByteString as BS
import Foreign.C.Error (Errno (Errno), eOPNOTSUPP, eNXIO)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native
import System.Directory (createDirectory, renameDirectory)
import System.FilePath ((</>))
import System.Posix.Files
  ( createNamedPipe
  , createSymbolicLink
  , getSymbolicLinkStatus
  , isRegularFile
  , removeLink
  , setFileMode
  , unionFileModes
  , ownerReadMode
  , ownerWriteMode
  )
import System.Posix.User (getEffectiveUserID)
import Test.Content.Support
import Test.Hspec
import Test.Support.Bounded (bounded)

foreign import ccall unsafe "hetct_make_socket"
  c_make_socket ∷ CString → IO CInt

data Layout = Layout {layoutRoot ∷ FilePath, layoutOutside ∷ FilePath}

secret ∷ BS.ByteString
secret = "OUTSIDE SECRET"

-- | A root holding @plain.txt@ and @dir/file.txt@, beside a sibling holding the
-- sentinel the examples must never read, and an @outside-dir/file.txt@ that
-- shadows @dir/file.txt@.
withLayout ∷ (Layout → IO a) → IO a
withLayout use = withTree $ \tree → do
  let root = tree </> "root"
      outside = tree </> "outside"
  createDirectory root
  createDirectory (root </> "dir")
  createDirectory outside
  createDirectory (tree </> "outside-dir")
  writeBytes (root </> "plain.txt") "plain"
  writeBytes (root </> "dir" </> "file.txt") "inside"
  writeBytes (outside </> "secret.txt") secret
  writeBytes (tree </> "outside-dir" </> "file.txt") secret
  use (Layout root tree)

readPath ∷ ContentRoot → [BS.ByteString] → IO BS.ByteString
readPath root path = withFile root (names path) $ \reader → readAll 3 (readChunk reader)

spec ∷ Spec
spec = do
  describe "links that are already there" $ do
    it "refuses a final symbolic link to a file in the same root" $
      withLayout $ \layout → do
        createSymbolicLink "plain.txt" (layoutRoot layout </> "same.txt")
        withRoot (layoutRoot layout) $ \root → do
          failure' ← contentFailure (readPath root ["same.txt"])
          failureKind failure' `shouldBe` ForbiddenLink
          failurePath failure' `shouldBe` names ["same.txt"]

    it "refuses a final symbolic link to a file outside the root" $
      withLayout $ \layout → do
        createSymbolicLink "../outside/secret.txt" (layoutRoot layout </> "out.txt")
        withRoot (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["out.txt"]) `shouldReturn` ForbiddenLink

    it "refuses a dangling final symbolic link as a link, not as a missing file" $
      withLayout $ \layout → do
        createSymbolicLink "absent" (layoutRoot layout </> "dangling.txt")
        withRoot (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["dangling.txt"]) `shouldReturn` ForbiddenLink

    it "refuses an intermediate symbolic link to a directory in the same root" $
      withLayout $ \layout → do
        createSymbolicLink "dir" (layoutRoot layout </> "dlink")
        withRoot (layoutRoot layout) $ \root → do
          failure' ← contentFailure (readPath root ["dlink", "file.txt"])
          failureKind failure' `shouldBe` ForbiddenLink
          failurePath failure' `shouldBe` names ["dlink"]

    it "refuses an intermediate symbolic link to a directory outside the root" $
      withLayout $ \layout → do
        createSymbolicLink "../outside-dir" (layoutRoot layout </> "dlink")
        withRoot (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["dlink", "file.txt"]) `shouldReturn` ForbiddenLink

    it "refuses a link back into the same root, however many components it takes" $
      withLayout $ \layout → do
        createSymbolicLink ".." (layoutRoot layout </> "dir" </> "back")
        createSymbolicLink "." (layoutRoot layout </> "self")
        withRoot (layoutRoot layout) $ \root → do
          failureKindOf (readPath root ["dir", "back", "plain.txt"]) `shouldReturn` ForbiddenLink
          failureKindOf (readPath root ["self", "plain.txt"]) `shouldReturn` ForbiddenLink
          failureKindOf (withDirectory root (names ["self"]) (\_ → pure ())) `shouldReturn` ForbiddenLink

    it "refuses a symbolic link named as a directory to enumerate" $
      withLayout $ \layout → do
        createSymbolicLink "dir" (layoutRoot layout </> "dlink")
        withRoot (layoutRoot layout) $ \root →
          failureKindOf (withDirectory root (names ["dlink"]) (\_ → pure ())) `shouldReturn` ForbiddenLink

    it "reports a link as a link when enumerating, and refuses to open it as either kind" $
      withLayout $ \layout → do
        createSymbolicLink "dir" (layoutRoot layout </> "dlink")
        createSymbolicLink "plain.txt" (layoutRoot layout </> "flink")
        withRoot (layoutRoot layout) $ \root →
          withDirectory root [] $ \listing → do
            entries ← drain (readEntry listing)
            lookup (name "dlink") [(entryName e, entryKind e) | e ← entries] `shouldBe` Just KindSymlink
            lookup (name "flink") [(entryName e, entryKind e) | e ← entries] `shouldBe` Just KindSymlink
            dlink ← entryNamed entries "dlink"
            flink ← entryNamed entries "flink"
            failureKindOf (withEntryDirectory listing dlink (\_ → pure ())) `shouldReturn` ForbiddenLink
            failureKindOf (withEntryFile listing flink (\_ → pure ())) `shouldReturn` ForbiddenLink

  describe "links that appear during an operation" $ do
    it "never reads the sentinel when the final file becomes a link just before it is opened" $
      withLayout $ \layout → do
        (seam, rig) ← recordingSeam
        let target = layoutRoot layout </> "dir" </> "file.txt"
            swapped = onBoundary (swapBefore 1 "file.txt" (replaceWithLink target "../../outside/secret.txt")) seam
        withRootVia swapped defaultContentLimits (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["dir", "file.txt"]) `shouldReturn` ForbiddenLink
        noReads rig
        _ ← asserting rig
        pure ()

    it "never reads the sentinel when an intermediate directory becomes a link just before it is opened" $
      withLayout $ \layout → do
        (seam, rig) ← recordingSeam
        let directory = layoutRoot layout </> "dir"
            swapped = onBoundary (swapBefore 0 "dir" (replaceDirectoryWithLink directory (layoutOutside layout </> "outside-dir"))) seam
        withRootVia swapped defaultContentLimits (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["dir", "file.txt"]) `shouldReturn` ForbiddenLink
        noReads rig
        _ ← asserting rig
        pure ()

    it "refuses a final file that becomes a link to another file of the same root" $
      withLayout $ \layout → do
        let target = layoutRoot layout </> "dir" </> "file.txt"
            swapped = onBoundary (swapBefore 1 "file.txt" (replaceWithLink target "../plain.txt")) productionSeam
        withRootVia swapped defaultContentLimits (layoutRoot layout) $ \root →
          failureKindOf (readPath root ["dir", "file.txt"]) `shouldReturn` ForbiddenLink

    it "refuses an enumerated directory that becomes a link before it is opened" $
      withLayout $ \layout → do
        withRoot (layoutRoot layout) $ \root →
          withDirectory root [] $ \listing → do
            entries ← drain (readEntry listing)
            dir ← entryNamed entries "dir"
            replaceDirectoryWithLink (layoutRoot layout </> "dir") (layoutOutside layout </> "outside-dir")
            outcome ← failureKindOf (withEntryDirectory listing dir (\_ → pure ()))
            outcome `shouldBe` MappingChanged (Just KindDirectory) (Just KindSymlink)

    it "keeps reading the object it opened when the file is replaced by a link after the open" $
      withLayout $ \layout → do
        let target = layoutRoot layout </> "dir" </> "file.txt"
            swapped = onBoundary (swapAfter 1 "file.txt" (replaceWithLink target "../../outside/secret.txt")) productionSeam
        withRootVia swapped defaultContentLimits (layoutRoot layout) $ \root →
          readPath root ["dir", "file.txt"] `shouldReturn` "inside"

    it "keeps reading beneath the directory it opened when that directory is replaced by a link after the open" $
      withLayout $ \layout → do
        let directory = layoutRoot layout </> "dir"
            swapped = onBoundary (swapAfter 0 "dir" (replaceDirectoryWithLink directory (layoutOutside layout </> "outside-dir"))) productionSeam
        withRootVia swapped defaultContentLimits (layoutRoot layout) $ \root →
          readPath root ["dir", "file.txt"] `shouldReturn` "inside"

    it "checkThenOpenControl: a check followed by a pathname open does read the sentinel under the same swap" $
      withLayout $ \layout → do
        let target = layoutRoot layout </> "dir" </> "file.txt"
        checkThenOpenControl target (replaceWithLink target "../../outside/secret.txt") `shouldReturn` secret

  describe "entries that are not regular files or directories" $ do
    it "refuses a FIFO without waiting for a writer" $
      withLayout $ \layout → do
        createNamedPipe (layoutRoot layout </> "pipe") (unionFileModes ownerReadMode ownerWriteMode)
        withRoot (layoutRoot layout) $ \root → do
          bounded (failureKindOf (readPath root ["pipe"])) `shouldReturn` ForbiddenType KindFifo KindRegular
          bounded (failureKindOf (withDirectory root (names ["pipe"]) (\_ → pure ()))) `shouldReturn` ForbiddenType KindFifo KindDirectory
          bounded (failureKindOf (readPath root ["pipe", "below"])) `shouldReturn` ForbiddenType KindFifo KindDirectory

    it "refuses a socket by its type, however the native open reports it" $
      withLayout $ \layout → do
        let socketPath = layoutRoot layout </> "sock"
        status ← withCString socketPath c_make_socket
        if status /= 0
          then pendingWith ("a socket node could not be created here (status " <> show status <> ")")
          else do
            withRoot (layoutRoot layout) $ \root → do
              bounded (failureKindOf (readPath root ["sock"])) `shouldReturn` ForbiddenType KindSocket KindRegular
              bounded (failureKindOf (withDirectory root (names ["sock"]) (\_ → pure ()))) `shouldReturn` ForbiddenType KindSocket KindDirectory
            let Errno enxio = eNXIO
                Errno eopnotsupp = eOPNOTSUPP
            mapM_
              ( \code → do
                  let reporting = mapNative (\native → native {nativeOpenAt = \parent component directory → if component == name "sock" then pure (Left (fromIntegral code)) else nativeOpenAt native parent component directory}) productionSeam
                  withRootVia reporting defaultContentLimits (layoutRoot layout) $ \root →
                    failureKindOf (readPath root ["sock"]) `shouldReturn` ForbiddenType KindSocket KindRegular
              )
              [enxio, eopnotsupp]

    it "refuses a directory where a file is required, and a file where a directory is" $
      withLayout $ \layout →
        withRoot (layoutRoot layout) $ \root → do
          failureKindOf (readPath root ["dir"]) `shouldReturn` ForbiddenType KindDirectory KindRegular
          failureKindOf (withDirectory root (names ["plain.txt"]) (\_ → pure ())) `shouldReturn` ForbiddenType KindRegular KindDirectory
          failure' ← contentFailure (readPath root ["plain.txt", "below"])
          failureKind failure' `shouldBe` ForbiddenType KindRegular KindDirectory
          failurePath failure' `shouldBe` names ["plain.txt"]
          failureKindOf (withFile root [] (\_ → pure ())) `shouldReturn` ForbiddenType KindDirectory KindRegular

    it "refuses device, block-device and other kinds the adapter reports for an opened file" $
      withLayout $ \layout →
        mapM_
          ( \kind → do
              let retyped = mapNative (\native → native {nativeFstat = \fd → fmap (\stat → if statKind stat == KindRegular then stat {statKind = kind} else stat) <$> nativeFstat native fd}) productionSeam
              withRootVia retyped defaultContentLimits (layoutRoot layout) $ \root →
                failureKindOf (readPath root ["plain.txt"]) `shouldReturn` ForbiddenType kind KindRegular
          )
          [KindCharDevice, KindBlockDevice, KindOther]

  describe "missing and unreadable entries" $ do
    it "reports a missing file or directory as not found, naming the path" $
      withLayout $ \layout →
        withRoot (layoutRoot layout) $ \root → do
          failure' ← contentFailure (readPath root ["absent.txt"])
          failureKind failure' `shouldBe` NotFound
          failurePath failure' `shouldBe` names ["absent.txt"]
          failure'' ← contentFailure (readPath root ["absent", "file.txt"])
          failureKind failure'' `shouldBe` NotFound
          failurePath failure'' `shouldBe` names ["absent"]
          failureKindOf (withDirectory root (names ["absent"]) (\_ → pure ())) `shouldReturn` NotFound

    it "refuses a file the effective user cannot read, where permission bits apply" $
      withLayout $ \layout → do
        user ← getEffectiveUserID
        if user == 0
          then pendingWith "the effective user is root, which ignores permission bits; the injected permission-denied example covers this refusal"
          else do
            let closed = layoutRoot layout </> "closed.txt"
            writeBytes closed "closed"
            setFileMode closed 0
            outcome ← withRoot (layoutRoot layout) $ \root → failureKindOf (readPath root ["closed.txt"])
            setFileMode closed 0o600
            outcome `shouldBe` Unreadable 13

    it "reports an injected permission denial as unreadable, naming the errno" $
      withLayout $ \layout → do
        let denied = mapNative (\native → native {nativeOpenAt = \parent component directory → if component == name "plain.txt" then pure (Left 13) else nativeOpenAt native parent component directory}) productionSeam
        withRootVia denied defaultContentLimits (layoutRoot layout) $ \root → do
          failure' ← contentFailure (readPath root ["plain.txt"])
          failureKind failure' `shouldBe` Unreadable 13
          failurePath failure' `shouldBe` names ["plain.txt"]

    it "refuses a path deeper than the caller's bound before opening anything" $
      withLayout $ \layout → do
        (seam, rig) ← recordingSeam
        let narrow = limitsOf 2 1024
        withRootVia seam narrow (layoutRoot layout) $ \root → do
          failureKindOf (readPath root ["a", "b", "c"]) `shouldReturn` LimitExceeded PathDepth 2
          failureKindOf (withDirectory root (names ["a", "b", "c"]) (\_ → pure ())) `shouldReturn` LimitExceeded PathDepth 2
        before' ← length . filter isOpened <$> events rig
        before' `shouldBe` 2
        _ ← asserting rig
        pure ()
  where
    isOpened = \case
      Opened _ _ → True
      _ → False

noReads ∷ Rig → IO ()
noReads rig = do
  log' ← events rig
  [e | e@(Read _ _) ← log'] `shouldBe` []

swapBefore ∷ Int → BS.ByteString → IO () → Boundary → IO ()
swapBefore index component swap = \case
  BeforeOpen i n | i == index && n == name component → swap
  _ → pure ()

swapAfter ∷ Int → BS.ByteString → IO () → Boundary → IO ()
swapAfter index component swap = \case
  AfterOpen i n | i == index && n == name component → swap
  _ → pure ()

-- | Replace the file at @path@ with a link to @target@.
replaceWithLink ∷ FilePath → FilePath → IO ()
replaceWithLink path target = removeLink path >> createSymbolicLink target path

-- | Replace the directory at @path@ with a link to @target@, moving it aside.
replaceDirectoryWithLink ∷ FilePath → FilePath → IO ()
replaceDirectoryWithLink path target = do
  renameDirectory path (path <> "-moved")
  createSymbolicLink target path

-- | The implementation the service must not be: test that the path is a regular
-- file, run the swap a concurrent process could make, then open by pathname.
checkThenOpenControl ∷ FilePath → IO () → IO BS.ByteString
checkThenOpenControl path swap = do
  status ← getSymbolicLinkStatus path
  unless (isRegularFile status) (fail "control: not a regular file")
  swap
  BS.readFile path
