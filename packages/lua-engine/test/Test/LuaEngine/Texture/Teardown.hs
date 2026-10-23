{-# LANGUAGE OverloadedStrings #-}

-- | Shutdown and teardown sequences cut by cancellation: whatever a close effect, a drain effect, a decode
-- handler's effect or the pipeline's own release raises, synchronously or by cancellation, the drain still
-- completes (the backend borrows buffers until it says otherwise, and the scope must not unwind under it),
-- the first exception is retained and raised after, and a synchronous failure is never lost to an effect
-- that raises after it. One gated example per site.
module Test.LuaEngine.Texture.Teardown (spec) where

import Control.Concurrent.MVar (readMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, tryWithContext)
import Control.Monad (forM_, void)
import Data.IORef (atomicModifyIORef', newIORef)
import Test.Hspec
import Test.HUnit.Lang (HUnitFailure (..))
import Hetoimasia.Scripting.Lua.Provider (Completion (..), RequestEndpoint (..), Submission (..))
import Test.LuaEngine.Texture.Contract (layout, small)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "teardown cut by cancellation" $ do
  it "completes the drain when a close callback raises cancellation while another upload is outstanding: the first exception is raised after the backend has ended both" $ do
    ExceptionWithContext _ _ ← fatalSession (config small layout) $ \session _ runtime → do
      outcome ←
        tryWithContext @SomeException $
          withNested
            session
            ( \nested → do
                vm ← startVm nested runtime "close-kill" OnArrival
                admitDriver nested vm "i"
                commandWith nested vm "i" "start" "k0" (Just (Load "a.png" True))
                commandWith nested vm "i" "start" "k1" (Just (Load "b.png" True))
                awaitUploads (ssFake nested) 2
                setCancelKills (ssFake nested) True
            )
            ( \nested → do
                -- The close has run and its callbacks raised. The drain must begin all the same: waiting for it
                -- is evidence it did (a drain that was skipped never counts a step), and it is still
                -- waiting on the backend.
                awaitPipeline nested ((>= 1) . readingDrainSteps)
                atomically (pipelineDrained (ssPipeline nested)) `shouldReturn` False
                note session "backend ending the uploads"
                forM_ [0, 1] $ \index → uploadN (ssFake nested) index >>= void . withdrawUpload (ssFake nested)
            )
      raisedIs ThreadKilled outcome
      seen ← history session
      filter (`elem` ["backend ending the uploads", "nested scope returned"]) seen
        `shouldBe` ["backend ending the uploads", "nested scope returned"]
    pure ()

  it "completes the drain when an effect the drain runs raises cancellation: it goes on, and the other obligations are still met before it is raised" $ do
    killFirst ← killsFirstCompletion
    gate ← newGate
    ExceptionWithContext _ _ ←
      fatalSession ((config small layout) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
        outcome ←
          tryWithContext @SomeException $
            withNested
              session
              ( \nested → do
                  vm ← startVmWith nested killFirst runtime "drain-kill" OnArrival
                  admitDriver nested vm "i"
                  closeGate (ssProbe session) "a.png"
                  commandWith nested vm "i" "start" "k0" (Just (Load "a.png" True))
                  awaitStarted (ssProbe session) 1
                  -- The second request's decode holds the decode worker at the gate, so nothing but the
                  -- drain can reap the first request's read.
                  commandWith nested vm "i" "start" "k1" (Just (Load "b.png" True))
                  readMVar (arrived gate)
              )
              ( \nested → do
                  awaitPipeline nested ((>= 1) . readingDrainSteps)
                  stepsBefore ← readingDrainSteps <$> pipelineNow nested
                  -- The first request's read retires; the drain reaps it and answers it, and the answer
                  -- raises. The drain must take another step: that is the evidence it went on.
                  openGate (ssProbe session) "a.png"
                  awaitPipeline nested (\reading → readingSettled reading >= 1 && readingDrainSteps reading > stepsBefore)
                  -- The second request's decode is still held: the scope has not been let go.
                  atomically (pipelineDrained (ssPipeline nested)) `shouldReturn` False
                  note session "decode being let go"
                  releaseHeldGate gate
              )
        raisedIs ThreadKilled outcome
        seen ← history session
        filter (`elem` ["decode being let go", "nested scope returned"]) seen
          `shouldBe` ["decode being let go", "nested scope returned"]
    pure ()

  it "latches a synchronous decode failure even when the answer effect it then runs raises cancellation" $ do
    killFirst ← killsFirstCompletion
    ExceptionWithContext _ _ ←
      fatalSession ((config small layout) {cfgHooks = noHooks {hookDecoding = \_ → throwIO (userError "decode hook defect")}}) $ \session _ runtime → do
        vm ← startVmWith session killFirst runtime "latch-first" OnArrival
        admitDriver session vm "i"
        commandWith session vm "i" "start" "k0" (Just (Load "a.png" True))
        -- Latched before the effect that raises, so it is the pipeline's first failure: the decode defect,
        -- not the cancellation the effect then raised.
        first ← atomically (awaitPipelineFailure (ssPipeline session))
        show first `shouldSatisfy` isInfixOf' "decode hook defect"
    pure ()

  it "does not swallow a cancellation raised by the pipeline's own release of a texture: it reaches the caller, and the failure is recorded on the cell" $ do
    ExceptionWithContext _ _ ← fatalSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "release-kill" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k0" (Just (Load "a.png" True))
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      command session vm "i" "cancel" "k0"
      awaitNote session "i cancel k0 cancelled"
      awaitUploadCancelled held
      setReleaseKills (ssFake session) True
      -- The backend ignores the cancellation and finishes; the pipeline releases the texture, the backend's
      -- release is cancelled, and the cancellation is the caller's to see.
      outcome ← tryWithContext @SomeException (finishUpload (ssFake session) held)
      raisedIs ThreadKilled (void outcome `seq` fmap (const ()) outcome)
      length <$> releaseCalls (ssFake session) `shouldReturn` 1
    pure ()

  describe "a nested scope that fails while a hook gate is held" $ do
    it "opens every gate before it waits for the drain when its helper fails an assertion: the failure is raised and the scope returns" $ do
      gate ← newGate
      ExceptionWithContext _ _ ← fatalSession ((config small layout) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
        outcome ←
          tryWithContext @SomeException $
            withNested
              session
              ( \nested → do
                  vm ← startVm nested runtime "inject-helper" OnArrival
                  admitDriver nested vm "i"
                  commandWith nested vm "i" "start" "k0" (Just (Load "a.png" True))
                  -- The decode worker is held at the gate when the scope closes.
                  readMVar (arrived gate)
              )
              (\_ → expectationFailure "injected helper failure")
        injected "injected helper failure" outcome
        seen ← history session
        seen `shouldContain` ["nested scope returned"]
      pure ()

    it "opens every gate before it waits for the drain when its body fails an assertion: the failure is raised and the scope returns" $ do
      gate ← newGate
      ExceptionWithContext _ _ ← fatalSession ((config small layout) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
        outcome ←
          tryWithContext @SomeException $
            withNested
              session
              ( \nested → do
                  vm ← startVm nested runtime "inject-body" OnArrival
                  admitDriver nested vm "i"
                  commandWith nested vm "i" "start" "k0" (Just (Load "a.png" True))
                  readMVar (arrived gate)
                  expectationFailure "injected body failure"
              )
              (\_ → pure ())
        injected "injected body failure" outcome
        seen <- history session
        seen `shouldContain` ["nested scope returned"]
      pure ()
  where
    injected expected outcome = case outcome of
      Left (ExceptionWithContext _ raised)
        | Just (HUnitFailure _ reason) ← fromException raised → show reason `shouldSatisfy` isInfixOf' expected
      Left (ExceptionWithContext _ raised) → expectationFailure ("the scope raised something else: " <> show raised)
      Right () → expectationFailure "the scope should have raised the injected failure"
    raisedIs expected outcome = case outcome of
      Left (ExceptionWithContext _ raised) → (fromException raised ∷ Maybe AsyncException) `shouldBe` Just expected
      Right _ → expectationFailure "the scope should have raised the cancellation"

-- | An endpoint wrapper under which the first request's completion raises a cancellation when it is
-- answered, and every later request's answers as usual.
killsFirstCompletion ∷ IO (RequestEndpoint → RequestEndpoint)
killsFirstCompletion = do
  first ← newIORef True
  pure $ \endpoint →
    endpoint
      { endpointSubmit = \submission → do
          killing ← atomicModifyIORef' first (\held → (False, held))
          endpointSubmit endpoint (if killing then submission {submissionCompletion = Completion (\_ → throwIO ThreadKilled)} else submission)
      }

isInfixOf' ∷ String → String → Bool
isInfixOf' needle = any (\suffix → take (length needle) suffix == needle) . suffixes
  where
    suffixes text = [drop n text | n ← [0 .. length text]]
