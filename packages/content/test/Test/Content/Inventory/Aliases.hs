-- | Hard links, mounted subtrees, directory cycles and the root's own anchoring
-- as they meet the inventory.
--
-- A hard link is real. A mount or a second device and a directory cycle would
-- need privileged setup this suite does not do, so those examples use an
-- identity-overriding seam, named as such; they prove the inventory's handling
-- of what the native adapter reports, not the operating system's mounts.
module Test.Content.Inventory.Aliases (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Native (productionSeam)
import Hetoimasia.Content.Inventory
import System.Directory (createDirectory, removeFile, renameDirectory)
import System.FilePath ((</>))
import System.Posix.Files (createLink, createSymbolicLink)
import Test.Content.Inventory.Support
import Test.Content.Support
import Test.Hspec

limits ∷ InventoryLimits
limits = limitsFrom baseSpec {specBufferBytes = 8}

refusalOf ∷ Either ReadFailure a → Maybe ReadOutcome
refusalOf = either (Just . readFailureOutcome) (const Nothing)

spec ∷ Spec
spec = do
  describe "hard links (native)" $ do
    it "keeps each name its own entry with its own length and digest, and reads either" $
      withLayout $ \tree → do
        populate (rootPath tree) [("one.lua", "shared bytes")]
        createLink (rootPath tree </> "one.lua") (rootPath tree </> "two.lua")
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          pathsOf inventory `shouldBe` ["one.lua", "two.lua"]
          inventoryEntryCount inventory `shouldBe` 3
          inventoryByteTotal inventory `shouldBe` 24
          readVerified inventory root (keyFor inventory "one.lua") 4096 `shouldReturn` Right "shared bytes"
          readVerified inventory root (keyFor inventory "two.lua") 4096 `shouldReturn` Right "shared bytes"

    it "fails the next inside read when the shared bytes are edited through an outside name" $
      withLayout $ \tree → do
        populate (rootPath tree) [("inside.lua", "shared bytes")]
        createLink (rootPath tree </> "inside.lua") (tree </> "outside-name.lua")
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          writeBytes (tree </> "outside-name.lua") "SHARED BYTES"
          refusalOf <$> readVerified inventory root (keyFor inventory "inside.lua") 4096
            `shouldReturn` Just (ReadChanged DigestMismatch)

    it "counts and reads a hard link to a file in another directory of the same folder as a second path" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a/original", "bytes"), ("b/", "")]
        createLink (rootPath tree </> "a" </> "original") (rootPath tree </> "b" </> "alias")
        inventory ← scanned productionSeam limits (rootPath tree)
        pathsOf inventory `shouldBe` ["a", "a/original", "b", "b/alias"]
        inventoryByteTotal inventory `shouldBe` 10

  describe "mounted subtrees (identity injected)" $ do
    it "traverses a directory that reports another device, listing what is inside it" $
      withLayout $ \tree → do
        populate (rootPath tree) [("mnt/inside", "on another device")]
        seam ← overriding [("mnt", NativeIdentity 2 77)]
        withScanned seam limits (rootPath tree) $ \root inventory → do
          pathsOf inventory `shouldBe` ["mnt", "mnt/inside"]
          readVerified inventory root (keyFor inventory "mnt/inside") 4096 `shouldReturn` Right "on another device"

  describe "directory cycles (identity injected)" $ do
    it "refuses a directory that repeats an ancestor, naming the chain from the root" $
      withLayout $ \tree → do
        populate (rootPath tree) [("a/b/c/", "")]
        seam ← overriding [("a", NativeIdentity 1 10), ("c", NativeIdentity 1 10)]
        outcome ← scanning seam limits (rootPath tree)
        case outcome of
          Left failure' → do
            inventoryFailureReason failure' `shouldBe` Content (DirectoryCycle (names ["a", "b", "c"]) 1)
            inventoryFailurePath failure' `shouldBe` names ["a", "b", "c"]
          Right _ → expectationFailure "a cyclic tree was inventoried"

    it "refuses a directory that repeats the root itself" $
      withLayout $ \tree → do
        populate (rootPath tree) [("loop/", "")]
        rootIdentity ← withRootVia productionSeam rootLimits (rootPath tree) (pure . reportIdentity . rootReport)
        seam ← overriding [("loop", rootIdentity)]
        outcome ← scanning seam limits (rootPath tree)
        fmap inventoryFailureReason (either Just (const Nothing) outcome) `shouldBe` Just (Content (DirectoryCycle (names ["loop"]) 0))

    it "does not merge or refuse a repeated directory identity on a separate, non-cyclic branch" $
      withLayout $ \tree → do
        populate (rootPath tree) [("x/shared/f", "from x"), ("y/shared/f", "from y")]
        seam ← overriding [("shared", NativeIdentity 3 33)]
        withScanned seam limits (rootPath tree) $ \root inventory → do
          pathsOf inventory `shouldBe` ["x", "x/shared", "x/shared/f", "y", "y/shared", "y/shared/f"]
          readVerified inventory root (keyFor inventory "x/shared/f") 4096 `shouldReturn` Right "from x"
          readVerified inventory root (keyFor inventory "y/shared/f") 4096 `shouldReturn` Right "from y"

  describe "the anchored root (native)" $ do
    it "keeps scanning and reading the original directory when it is renamed" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "original root")]
        withScanned productionSeam limits (rootPath tree) $ \root inventory → do
          renameDirectory (rootPath tree) (tree </> "renamed-root")
          createDirectory (rootPath tree)
          writeBytes (rootPath tree </> "f") "an impostor at the old path"
          readVerified inventory root (keyFor inventory "f") 4096 `shouldReturn` Right "original root"

    it "keeps reading the original directory when the selection link is retargeted, and a new root selects the new target" $
      withLayout $ \tree → do
        populate (tree </> "first") [("f", "first root")]
        populate (tree </> "second") [("f", "second root"), ("extra", "x")]
        createSymbolicLink (tree </> "first") (tree </> "selection")
        withScanned productionSeam limits (tree </> "selection") $ \root inventory → do
          removeFile (tree </> "selection")
          createSymbolicLink (tree </> "second") (tree </> "selection")
          readVerified inventory root (keyFor inventory "f") 4096 `shouldReturn` Right "first root"
          pathsOf inventory `shouldBe` ["f"]
        withScanned productionSeam limits (tree </> "selection") $ \root inventory → do
          pathsOf inventory `shouldBe` ["extra", "f"]
          readVerified inventory root (keyFor inventory "f") 4096 `shouldReturn` Right "second root"

    it "keeps two roots and their inventories independent" $
      withLayout $ \tree → do
        populate (tree </> "left") [("f", "left bytes"), ("only-left", "l")]
        populate (tree </> "right") [("f", "right bytes")]
        withScanned productionSeam limits (tree </> "left") $ \leftRoot leftInventory →
          withScanned productionSeam limits (tree </> "right") $ \rightRoot rightInventory → do
            pathsOf leftInventory `shouldBe` ["f", "only-left"]
            pathsOf rightInventory `shouldBe` ["f"]
            readVerified leftInventory leftRoot (keyFor leftInventory "f") 4096 `shouldReturn` Right "left bytes"
            readVerified rightInventory rightRoot (keyFor rightInventory "f") 4096 `shouldReturn` Right "right bytes"
            -- an inventory is the content version of its own root only
            ExceptionWithContext _ defect ← failsWith (readVerified leftInventory rightRoot (keyFor leftInventory "f") 4096)
            defect `shouldBe` ContentDefect InventoryRootMismatch

    it "keeps an inventory's answers after its root's scope has ended, and refuses to read through the closed root" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "bytes")]
        (inventory, staleRoot) ← withRootVia productionSeam rootLimits (rootPath tree) $ \root →
          scanInventory limits testKey root >>= either (fail . show) (\inv → pure (inv, root))
        presenceOf inventory "f" `shouldBe` PresentFile 5
        ExceptionWithContext _ defect ← failsWith (readVerified inventory staleRoot (keyFor inventory "f") 4096)
        defect `shouldBe` ContentDefect RootNotAdmitting
