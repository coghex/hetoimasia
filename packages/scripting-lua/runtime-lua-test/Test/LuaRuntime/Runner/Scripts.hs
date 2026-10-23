-- | The directory 'withScripts' gives an example (#556): one no other call is given, in this process
-- or in any other that shares the temporary root, removed on every exit of the example.
module Test.LuaRuntime.Runner.Scripts (spec) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, retry)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, catch, finally, fromException, mask, throwIO, try, uninterruptibleMask_)
import Control.Monad (forM, forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.Set as Set
import System.Directory (doesDirectoryExist, getTemporaryDirectory, listDirectory)
import System.FilePath (dropTrailingPathSeparator, takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy, shouldThrow)
import Test.LuaRuntime.Runner.Support (createExclusiveDirectory, scriptAt, withScripts)
import Test.LuaRuntime.Support (bounded)

-- | What an example throws out of the body it was given a directory for.
data Thrown = Thrown
  deriving (Eq, Show)

instance Exception Thrown

-- | How many callers hold a directory at once.
callers ∷ Int
callers = 24

-- | What caller @n@ writes under the name every caller uses, so a directory it shared would show
-- another caller's text.
contentOf ∷ Int → ByteString
contentOf n = Char8.pack ("-- caller " <> show n <> "\n")

-- | A source of candidate names that answers these in turn, and how many it has been asked for.
candidates ∷ [FilePath] → IO (IO FilePath, IO Int)
candidates names = do
  remaining ← newIORef names
  asked ← newIORef (0 ∷ Int)
  let next = do
        atomicModifyIORef' asked (\n → (n + 1, ()))
        atomicModifyIORef' remaining (\held → case held of
          name : rest → (rest, name)
          [] → error "the source of candidates ran out")
  pure (next, readIORef asked)

-- | Start a worker for each action, run the body while they run, then open the gate they wait on and wait
-- for every worker to terminate before this returns. The workers are started under a mask and the body
-- runs unmasked inside it, so no exit of the body (a failed assertion, an exception, a cancellation
-- delivered to the example) can leave a worker running or a worker unstarted-but-registered: the gate is
-- opened and the workers are joined, uninterruptibly because each ends once the gate is open, on every
-- path. Answers the body's outcome and each worker's, so the caller raises the workers' failures (the
-- cause of any check they fail) before the body's, and so never swallows either.
withWorkers ∷ MVar () → [IO ()] → ([ThreadId] → IO a) → IO (Either SomeException a, [Either SomeException ()])
withWorkers gate actions body = mask $ \restore → do
  started ←
    forM actions $ \action → do
      done ← newEmptyMVar
      thread ← forkIOWithUnmask (\unmask → try (unmask action) >>= putMVar done)
      pure (thread, done)
  outcome ← try (restore (body (map fst started)))
  _ ← tryPutMVar gate ()
  outcomes ← uninterruptibleMask_ (mapM (takeMVar . snd) started)
  pure (outcome, outcomes)

-- | Whether this is the cancellation 'killThread' delivers.
cancelled ∷ SomeException → Bool
cancelled failure = fromException failure == Just ThreadKilled

-- | Raise the first failure among the workers', then the body's, and otherwise answer the body's result.
settled ∷ (Either SomeException a, [Either SomeException ()]) → IO a
settled (outcome, outcomes) = do
  forM_ outcomes (either throwIO pure)
  either throwIO pure outcome

spec ∷ Spec
spec = describe "script directories" $ do
  it "gives callers that hold their directories at once a directory each, with their own files, all removed afterwards" $ bounded $ do
    -- Every caller holds its directory until all of them have one, so none can be given a path another
    -- has already let go of. A caller that is not given a directory exits instead of arriving.
    release ← newEmptyMVar
    arrived ← newTVarIO []
    exited ← newTVarIO (0 ∷ Int)
    base ← getTemporaryDirectory
    let caller n =
          withScripts [("shared.lua", contentOf n), ("own-" <> show n <> ".lua", contentOf n)] (\paths → do
            atomically (modifyTVar' arrived ((n, paths) :))
            readMVar release)
            `finally` atomically (modifyTVar' exited (+ 1))
    directories ←
      withWorkers release (map caller [1 .. callers]) (\_ → do
        held ← atomically $ do
          found ← readTVar arrived
          gone ← readTVar exited
          if length found + gone < callers then retry else pure found
        length held `shouldBe` callers
        let directories = [takeDirectory (scriptAt paths 0) | (_, paths) ← held]
        Set.size (Set.fromList directories) `shouldBe` callers
        forM_ held $ \(n, paths) → do
          let directory = takeDirectory (scriptAt paths 0)
          doesDirectoryExist directory `shouldReturn` True
          sort <$> listDirectory directory `shouldReturn` sort ["shared.lua", "own-" <> show n <> ".lua"]
          mapM ByteString.readFile paths `shouldReturn` [contentOf n, contentOf n]
          takeDirectory directory `shouldBe` dropTrailingPathSeparator base
        pure directories) >>= settled
    forM_ directories $ \directory → doesDirectoryExist directory `shouldReturn` False

  it "removes the directory when the example throws" $ bounded $ do
    seen ← newIORef Nothing
    withScripts [("a.lua", contentOf 0)] (\paths → writeIORef seen (Just (takeDirectory (scriptAt paths 0))) >> throwIO Thrown)
      `shouldThrow` (== Thrown)
    readIORef seen >>= \case
      Nothing → fail "the example never ran"
      Just directory → doesDirectoryExist directory `shouldReturn` False

  it "removes the directory when the example is cancelled while it holds it" $ bounded $ do
    entered ← newEmptyMVar
    unheld ← newEmptyMVar
    -- A worker that is not given a directory says so, instead of leaving the example waiting for it.
    let holder =
          withScripts [("a.lua", contentOf 0)] (\paths → putMVar entered (Right (takeDirectory (scriptAt paths 0))) >> readMVar unheld)
            `catch` \failure → void (tryPutMVar entered (Left failure)) >> throwIO (failure ∷ SomeException)
    (checked, outcomes) ←
      withWorkers unheld [holder] $ \threads → do
        held ← takeMVar entered
        case held of
          Left failure → fail ("the caller was not given a directory: " <> show failure)
          Right directory → do
            doesDirectoryExist directory `shouldReturn` True
            mapM_ killThread threads
            pure directory
    -- Both are read once the worker has terminated: it was cancelled, and its directory is gone.
    forM_ [failure | Left failure ← outcomes, not (cancelled failure)] throwIO
    directory ← either throwIO pure checked
    outcomes `shouldSatisfy` all (either cancelled (const False))
    doesDirectoryExist directory `shouldReturn` False

  it "passes over a candidate that is taken and leaves it, and what it holds, as it was" $ bounded $ do
    withScripts [("a.lua", contentOf 0)] $ \paths → do
      let arena = takeDirectory (scriptAt paths 0)
      (next, asked) ← candidates ["taken", "free"]
      -- Another caller's directory, with its file.
      _ ← createExclusiveDirectory arena (pure "taken")
      ByteString.writeFile (arena </> "taken" </> "theirs.lua") (contentOf 1)
      created ← createExclusiveDirectory arena next
      created `shouldBe` arena </> "free"
      asked `shouldReturn` 2
      listDirectory (arena </> "taken") `shouldReturn` ["theirs.lua"]
      ByteString.readFile (arena </> "taken" </> "theirs.lua") `shouldReturn` contentOf 1

  it "gives up on a source whose every candidate is taken, and leaves the taken one as it was" $ bounded $ do
    withScripts [("a.lua", contentOf 0)] $ \paths → do
      let arena = takeDirectory (scriptAt paths 0)
      _ ← createExclusiveDirectory arena (pure "taken")
      createExclusiveDirectory arena (pure "taken") `shouldThrow` isAlreadyExistsError
      listDirectory (arena </> "taken") `shouldReturn` []

  it "does not treat a failure to create that is not a taken path as a taken path" $ bounded $ do
    withScripts [("a.lua", contentOf 0)] $ \paths → do
      let arena = takeDirectory (scriptAt paths 0)
      (next, asked) ← candidates ["x", "y"]
      createExclusiveDirectory (arena </> "absent") next `shouldThrow` isDoesNotExistError
      asked `shouldReturn` 1
