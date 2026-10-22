-- | A failure of the engine or the application's own code is raised from the operation
-- that reached it, whatever the module's code did with the error it saw; it abandons the
-- chain and leaves the ledger balanced; and the failures of closing and releasing are kept
-- beside it. Memory running out at any point of a chain is a classified outcome and never
-- a crash or a wrong answer.
module Test.Lua.Boundary.Loader.Failures (spec) where

import Control.Exception (IOException, SomeException, fromException)
import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Hetoimasia.Foundation.Resource (cleanupFailures)
import Hetoimasia.Scripting.Lua.Internal.Owner (OwnerConfig (ownerBudget, ownerGranted, ownerLoader, ownerName, ownerRegistration), defaultOwnerConfig, withOwnedVm)
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

-- | Whether a failure is the application's own user error, which keeps its type.
isUserError ∷ SomeException → Bool
isUserError failure = case fromException failure of
  Just (_ ∷ IOException) → True
  Nothing → False

spec ∷ Spec
spec = describe "failures of the engine and the application" $ do
  it "takes back an admission whose acquire raised, and goes on" $
    withRig $ \rig owned → do
      writeIORef (rigAcquireFails rig) (Set.fromList [ident "bad"])
      before ← ledger owned
      admitted ← raised (admit owned "bad")
      either isUserError (const False) admitted `shouldBe` True
      after ← ledger owned
      after `shouldBe` before
      statusOfName owned "bad" >>= (`shouldBe` ModuleUnknown)
      writeIORef (rigAcquireFails rig) Set.empty
      admit owned "bad" >>= (`shouldBe` RootQueued)

  it "raises a supplier that fails inside a chain whatever the module does with the error, abandons the chain and goes on" $
    withRig $ \rig owned → do
      writeIORef (rigAcquireFails rig) (Set.fromList [ident "dep"])
      _ ← supply rig owned "outer" ["local g <close> = setmetatable({}, { __close = function() trace.mark('closed outer') end })", "return { inner = import('inner') }"]
      _ ← supply rig owned "inner" ["local ok, err = pcall(import, 'dep')", "trace.mark('inner caught ' .. tostring(ok))", "return {}"]
      _ ← admit owned "outer"
      advanced ← raised (advance owned)
      either isUserError (const False) advanced `shouldBe` True
      -- The chain is gone, its coroutines closed on the owner, and what it held recorded.
      found ← ledger owned
      (ledgerTasks found, countChainDepth (ledgerCounts found)) `shouldBe` (0, 0)
      found `shouldSatisfy` balanced
      traced rig >>= (`shouldBe` ["inner caught false", "closed outer"])
      failureOf owned "inner" >>= \failed → boundaryReason failed `shouldSatisfy` \case InternalError _ → True; _ → False
      failureOf owned "outer" >>= \failed → boundaryReason failed `shouldSatisfy` \case InternalError _ → True; _ → False
      statusOfName owned "dep" >>= (`shouldBe` ModuleUnknown)
      -- The loader is usable.
      writeIORef (rigAcquireFails rig) Set.empty
      _ ← supply rig owned "fresh" ["return {}"]
      _ ← admit owned "fresh"
      _ ← advance owned
      statusOfName owned "fresh" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)

  it "raises a resolver that fails the same way" $
    withRig $ \rig owned → do
      _ ← supply rig owned "a" ["local ok = pcall(import, 'b')", "return {}"]
      _ ← admit owned "a"
      writeIORef (rigResolverFails rig) True
      advanced ← raised (advance owned)
      either isUserError (const False) advanced `shouldBe` True
      ledger owned >>= (`shouldSatisfy` balanced)
      failureOf owned "a" >>= \failed → boundaryReason failed `shouldSatisfy` \case InternalError _ → True; _ → False

  it "keeps the failure of closing the abandoned chain beside the failure that abandoned it" $
    withRig $ \rig owned → do
      writeIORef (rigAcquireFails rig) (Set.fromList [ident "dep"])
      _ ← supply rig owned "outer" ["local g <close> = setmetatable({}, { __close = function() error('closing outer failed') end })", "return { inner = import('inner') }"]
      _ ← supply rig owned "inner" ["local ok = pcall(import, 'dep')", "return {}"]
      _ ← admit owned "outer"
      advanced ← raised (advance owned)
      case advanced of
        Right _ → fail "nothing was raised"
        Left failure → do
          isUserError failure `shouldBe` True
          length (cleanupFailures failure) `shouldSatisfy` (>= 1)
      ledger owned >>= (`shouldSatisfy` balanced)

  it "finishes what it could when a release fails, and raises the release's failure at the end of the advance" $
    withRig $ \rig owned → do
      writeIORef (rigReleaseFails rig) (Set.fromList [ident "a"])
      _ ← supply rig owned "a" ["return {}"]
      _ ← admit owned "a"
      advanced ← raised (advance owned)
      either isUserError (const False) advanced `shouldBe` True
      statusOfName owned "a" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
      ledger owned >>= (`shouldSatisfy` balanced)
      -- Raised once: the next advance has nothing left to raise.
      report ← advance owned
      advanceBlocked report `shouldBe` BlockedIdle

  describe "memory running out" $
    it "is a classified outcome at every point, never a wrong answer, and leaves the ledger balanced" $ do
      outcomes ← newIORef []
      forM_ [12000, 12150 .. 24000] $ \budget → do
        trial ← sweep budget
        modifyIORef' outcomes (trial :)
      found ← readIORef outcomes
      -- The sweep reaches a point where the chain ran out of memory and raised, one where
      -- a module failed for it, and one where nothing did.
      found `shouldSatisfy` elem Raised
      found `shouldSatisfy` elem Failed
      found `shouldSatisfy` elem Finished
      found `shouldSatisfy` all (\trial → case trial of Wrong _ → False; _ → True)

-- | How one trial of the sweep ended.
data Trial = Raised | Failed | Finished | NotBuilt | Wrong String
  deriving (Eq, Show)

-- | A chain run under a byte budget for the interpreter: three modules that import each
-- other in depth, with sources that are there at once. Whatever the budget, what the
-- loader says afterwards must agree with itself.
sweep ∷ Int → IO Trial
sweep budget = do
  rig ← newRig
  let config =
        (defaultOwnerConfig rigLibraries)
          { ownerBudget = Just budget
          , ownerRegistration = rigRegistration rig
          , ownerGranted = ["trace", "svc", "sched"]
          , ownerName = "tight"
          , ownerLoader = Just (rigLoader rig)
          }
  built ← newIORef False
  outcome ← raised . withOwnedVm config $ \owned → do
    writeIORef built True
    _ ← supply rig owned "leaf" ["return { name = 'leaf' }"]
    _ ← supply rig owned "mid" ["return { leaf = import('leaf') }"]
    _ ← supply rig owned "top" ["local g <close> = setmetatable({}, { __close = function() trace.mark('closed') end })", "return { mid = import('mid'), leaf = import('leaf') }"]
    _ ← admit owned "top"
    advanced ← raised (advance owned)
    status ← raised (statusOfName owned "top")
    counts ← raised (moduleLoaderCounts owned)
    held ← raised (ledger owned)
    stopped ← raised (stopModuleLoader owned)
    after ← raised (moduleLoaderCounts owned)
    pure (advanced, status, counts, held, stopped, after)
  wasBuilt ← readIORef built
  pure $ case outcome of
    Left _ | not wasBuilt → NotBuilt
    Left _ → Raised
    Right (advanced, status, counts, held, _, after) →
      let -- Every interest the loader took is released or held, in the loader's own books.
          books = either (const True) (\c → countInterestsAcquired c == countInterestsReleased c + countInterestsHeld c) counts
          -- A stopped loader holds none, whatever the stop itself did.
          stoppedBooks = either (const True) (\c → countInterestsHeld c == 0 && countChainDepth c == 0) after
          -- What the VM anchors agrees with the books when it can be read.
          anchored = either (const True) balanced held
          verdict = case (advanced, status) of
            (Right _, Right (ModuleReady _)) → Finished
            (Right _, Right (ModuleFailed fault)) → case boundaryReason fault of
              ScriptFailed _ _ → Failed
              ModuleRefused (DependencyFailed _ _) → Failed
              ModuleRefused (SourceTooLarge _) → Wrong "the source bound answered"
              other → Wrong (show other)
            (Left _, _) → Raised
            (Right _, Right other) → Wrong ("the chain ended with " <> show other)
            (Right _, Left _) → Raised
       in if books && stoppedBooks && anchored then verdict else Wrong ("books " <> show (books, stoppedBooks, anchored))
