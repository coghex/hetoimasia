-- | 'filesystemOf' owns the private file it profiles through a scope: its unlink and its close are both
-- attempted on every exit, and a cleanup that fails is never dropped (docs/resources.md's failure table):
-- the call then fails, any profiling failure primary and every cleanup failure retained beside it.
module Test.TerrainRuntime.Storage.Filesystem (spec) where

import Control.Exception (ExceptionWithContext (..), SomeException, tryWithContext)
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Hetoimasia.Terrain.Runtime.Storage (filesystemOfWith)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..), StorageFailure (..))
import System.Directory (listDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import qualified Test.TerrainRuntime.Storage.Harness as H

data Ran = Ran
  { ranOutcome ∷ Either (ExceptionWithContext SomeException) (Either StorageFailure BC.ByteString)
  , ranOps ∷ [NativeOp]
  , ranFiles ∷ [FilePath]
  }

run ∷ (H.Probe → IO ()) → IO Ran
run rules = withSystemTempDirectory "hetoimasia-filesystem-of" $ \dir → do
  probe ← H.newProbe
  rules probe
  outcome ← tryWithContext @SomeException (filesystemOfWith (H.seamFor probe) (BC.pack dir))
  Ran outcome <$> H.events probe <*> listDirectory dir

eio ∷ H.Act
eio = H.FailWith (Errno 5)

isUnlink, isClose, isStatfs ∷ NativeOp → Bool
isUnlink = (== OpUnlinkFile)
isClose = (== OpCloseFile)
isStatfs = (== OpStatFilesystem)

spec ∷ Spec
spec = describe "filesystemOf's cleanup" $ do
  it "answers the filesystem's name and leaves no file when every cleanup succeeds" $ do
    r ← run (\_ → pure ())
    case ranOutcome r of
      Right (Right name) → BC.null name `shouldBe` False
      other → expectationFailure ("expected a name, got " <> either (show . (\(ExceptionWithContext _ e) → e)) show other)
    ranFiles r `shouldBe` []

  it "fails, retaining the unlink's failure, when the unlink fails, and still closes the descriptor" $ do
    r ← run (\p → H.addRule p 1 isUnlink eio)
    case ranOutcome r of
      Left (ExceptionWithContext ctx _) → length (cleanupFailuresInContext ctx) `shouldBe` 1
      Right other → expectationFailure ("a failed unlink was not reported: " <> show other)
    length (filter isClose (ranOps r)) `shouldBe` 1

  it "fails, retaining the close's failure, when the close fails, after the unlink" $ do
    r ← run (\p → H.addRule p 1 isClose eio)
    case ranOutcome r of
      Left (ExceptionWithContext ctx _) → length (cleanupFailuresInContext ctx) `shouldBe` 1
      Right other → expectationFailure ("a failed close was not reported: " <> show other)
    ranFiles r `shouldBe` []

  it "answers the profiling failure as before when only profiling fails" $ do
    r ← run (\p → H.addRule p 1 isStatfs eio)
    case ranOutcome r of
      Right (Left (StorageIo _)) → pure ()
      other → expectationFailure ("expected a storage_io failure, got " <> either (show . (\(ExceptionWithContext _ e) → e)) show other)
    ranFiles r `shouldBe` []

  it "keeps the profiling failure primary and retains both cleanup failures when all three fail" $ do
    r ← run (\p → H.addRule p 1 isStatfs eio >> H.addRule p 1 isUnlink eio >> H.addRule p 1 isClose eio)
    case ranOutcome r of
      Left (ExceptionWithContext ctx e) → do
        show e `shouldSatisfy` ("ProfileFailed" `isInfixOf`)
        length (cleanupFailuresInContext ctx) `shouldBe` 2
      Right other → expectationFailure ("the failures were not reported: " <> show other)
