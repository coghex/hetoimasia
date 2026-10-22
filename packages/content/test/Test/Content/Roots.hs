-- | Selecting and anchoring a root: relative, absolute and symlink-selected
-- launch paths; the root staying put when its folder is renamed, its old path is
-- replaced or the selection link is retargeted; and the refusals of a selection
-- that is not a usable directory.
module Test.Content.Roots (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native (Native (..), Seam (..), productionSeam)
import System.Directory
  ( canonicalizePath
  , createDirectory
  , getCurrentDirectory
  , renameDirectory
  )
import System.FilePath ((</>))
import System.Posix.Files
  ( createSymbolicLink
  , deviceID
  , fileID
  , getFileStatus
  , removeLink
  , setFileMode
  )
import System.Posix.User (getEffectiveUserID)
import Test.Content.Support
import Test.Hspec

spec ∷ Spec
spec = do
  describe "selection" $ do
    it "opens an absolute path and reports the directory it actually opened" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        writeBytes (root </> "data.txt") "hello"
        expected ← identityOf root
        canonical ← canonicalizePath root
        withRoot root $ \open → do
          reportSelection (rootReport open) `shouldBe` BC.pack root
          reportIdentity (rootReport open) `shouldBe` expected
          reportResolved (rootReport open) `shouldBe` Just (BC.pack canonical)
          readBy open ["data.txt"] `shouldReturn` "hello"

    it "resolves a relative path against the launch directory and leaves that directory alone" $
      withTree $ \tree → do
        let root = tree </> "root"
        createDirectory root
        writeBytes (root </> "data.txt") "relative"
        relative ← relativeFromCurrent root
        startedIn ← getCurrentDirectory
        withRoot relative $ \open → do
          reportSelection (rootReport open) `shouldBe` BC.pack relative
          readBy open ["data.txt"] `shouldReturn` "relative"
        getCurrentDirectory `shouldReturn` startedIn

    it "does not expand shell syntax" $
      withTree $ \tree → do
        let literal = tree </> "~"
        createDirectory literal
        writeBytes (literal </> "data.txt") "tilde"
        withRoot literal $ \open → readBy open ["data.txt"] `shouldReturn` "tilde"
        failureKindOf (withRoot "~" (\_ → pure ())) `shouldReturn` NotFound

    it "follows a symbolic link as the selection, and in its ancestors" $
      withTree $ \tree → do
        let real = tree </> "real"
            selection = tree </> "selection"
            ancestor = tree </> "ancestor"
        createDirectory real
        createDirectory (real </> "inner")
        writeBytes (real </> "inner" </> "data.txt") "through links"
        createSymbolicLink real selection
        createSymbolicLink real ancestor
        expected ← identityOf (real </> "inner")
        withRoot (ancestor </> "inner") $ \open → do
          reportIdentity (rootReport open) `shouldBe` expected
          readBy open ["data.txt"] `shouldReturn` "through links"
        withRoot (selection </> "inner") $ \open →
          reportIdentity (rootReport open) `shouldBe` expected
        linkToInner ← pure (tree </> "to-inner")
        createSymbolicLink (real </> "inner") linkToInner
        withRoot linkToInner $ \open → do
          reportIdentity (rootReport open) `shouldBe` expected
          reportSelection (rootReport open) `shouldBe` BC.pack linkToInner

  describe "anchoring" $ do
    it "keeps reading the original directory after the root is renamed and its old path replaced" $
      withTree $ \tree → do
        let selected = tree </> "selected"
            moved = tree </> "moved"
        createDirectory selected
        writeBytes (selected </> "data.txt") "original"
        withRoot selected $ \original → do
          renameDirectory selected moved
          createDirectory selected
          writeBytes (selected </> "data.txt") "replacement"
          readBy original ["data.txt"] `shouldReturn` "original"
          withRoot selected $ \fresh → do
            readBy fresh ["data.txt"] `shouldReturn` "replacement"
            reportIdentity (rootReport fresh) `shouldNotBe` reportIdentity (rootReport original)
          readBy original ["data.txt"] `shouldReturn` "original"

    it "keeps reading the original directory after the selection link is retargeted" $
      withTree $ \tree → do
        let first = tree </> "first"
            second = tree </> "second"
            link = tree </> "link"
        createDirectory first
        createDirectory second
        writeBytes (first </> "data.txt") "first"
        writeBytes (second </> "data.txt") "second"
        createSymbolicLink first link
        withRoot link $ \original → do
          removeLink link
          createSymbolicLink second link
          readBy original ["data.txt"] `shouldReturn` "first"
          withRoot link $ \fresh → readBy fresh ["data.txt"] `shouldReturn` "second"
          readBy original ["data.txt"] `shouldReturn` "first"

    it "keeps the original directory usable after the pathname is removed and recreated empty" $
      withTree $ \tree → do
        let selected = tree </> "selected"
            moved = tree </> "moved"
        createDirectory selected
        writeBytes (selected </> "data.txt") "survives"
        withRoot selected $ \original → do
          renameDirectory selected moved
          createDirectory selected
          readBy original ["data.txt"] `shouldReturn` "survives"
          failureKindOf (readBy original ["absent"]) `shouldReturn` NotFound

  describe "refusal" $ do
    it "refuses a selection that does not exist, naming the selection" $
      withTree $ \tree → do
        failure' ← contentFailure (withRoot (tree </> "absent") (\_ → pure ()))
        failureKind failure' `shouldBe` NotFound
        attributedSelection (failureRoot failure') `shouldBe` BC.pack (tree </> "absent")
        attributedIdentity (failureRoot failure') `shouldBe` Nothing

    it "refuses a selection that is not a directory" $
      withTree $ \tree → do
        let file = tree </> "file"
        writeBytes file "not a directory"
        failureKindOf (withRoot file (\_ → pure ())) `shouldReturn` NotDirectory
        failureKindOf (withRoot (file </> "below") (\_ → pure ())) `shouldReturn` NotDirectory

    it "refuses an empty selection, a selection with NUL and an overlong one" $ do
      failureKindOf (withContentRootBytes defaultContentLimits "" (\_ → pure ()))
        `shouldReturn` InvalidSelection EmptySelection
      failureKindOf (withContentRootBytes defaultContentLimits "a\0b" (\_ → pure ()))
        `shouldReturn` InvalidSelection NulInSelection
      failureKindOf (withContentRootBytes defaultContentLimits (BS.replicate 5000 0x61) (\_ → pure ()))
        `shouldReturn` InvalidSelection (SelectionTooLong 5000)

    it "refuses a directory the effective user cannot open, where permission bits apply" $
      withTree $ \tree → do
        user ← getEffectiveUserID
        if user == 0
          then pendingWith "the effective user is root, which ignores permission bits; the injected permission-denied example covers this refusal"
          else do
            let closed = tree </> "closed"
            createDirectory closed
            setFileMode closed 0
            outcome ← failureKindOf (withRoot closed (\_ → pure ()))
            setFileMode closed 0o700
            case outcome of
              Unreadable _ → pure ()
              other → expectationFailure ("expected Unreadable, got " <> show other)

    it "refuses an injected permission denial as unreadable, on any user" $
      withTree $ \tree → do
        let denied = productionSeam {seamNative = (seamNative productionSeam) {nativeOpenRoot = \_ → pure (Left 13)}}
        failureKindOf (withRootVia denied defaultContentLimits tree (\_ → pure ()))
          `shouldReturn` Unreadable 13

    it "refuses a root whose directory-relative opening cannot be established" $
      withTree $ \tree → do
        let unsupported = productionSeam {seamNative = (seamNative productionSeam) {nativeOpenAt = \_ _ _ → pure (Left 38)}}
        failureKindOf (withRootVia unsupported defaultContentLimits tree (\_ → pure ()))
          `shouldReturn` Unsupported 38

    it "refuses a root whose identity cannot be read" $
      withTree $ \tree → do
        let unreadable = productionSeam {seamNative = (seamNative productionSeam) {nativeFstat = \_ → pure (Left 5)}}
        failureKindOf (withRootVia unreadable defaultContentLimits tree (\_ → pure ()))
          `shouldReturn` Unreadable 5

    it "closes the descriptor of a refused root" $
      withTree $ \tree → do
        (seam, rig) ← recordingSeam
        let unsupported = mapNative (\native → native {nativeOpenAt = \_ _ _ → pure (Left 38)}) seam
        _ ← failureKindOf (withRootVia unsupported defaultContentLimits tree (\_ → pure ()))
        asserting rig `shouldReturn` 1

readBy ∷ ContentRoot → [BS.ByteString] → IO BS.ByteString
readBy root path = withFile root (names path) $ \reader → readAll 4 (readChunk reader)

identityOf ∷ FilePath → IO NativeIdentity
identityOf path = do
  status ← getFileStatus path
  pure (NativeIdentity (fromIntegral (deviceID status)) (fromIntegral (fileID status)))
