{-# LANGUAGE OverloadedStrings #-}

-- | The decision that a delivered texture becomes a live lease or is released is one transition on its
-- cell: offered when the answer is handed to the host, adopted when the host builds the lease, claimed
-- when it is released. A shutdown (a failed pipeline, a closing scope) may claim only a texture nobody
-- offered, so a request that still waits is never answered with a success over a texture whose release has
-- begun. One gated example per path that publishes a texture and per path a shutdown releases one.
module Test.LuaEngine.Texture.Publication (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (void, when)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Test.Hspec
import Test.LuaEngine.Texture.Contract (layout, small, started)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "publication" $ do
  it "leaves a texture the host holds for adoption to the host when another job fails the pipeline: the lease is built over the live texture and the backend releases it once, for the lease" $ do
    failSecond ← failsFrom 1
    ExceptionWithContext _ _ ←
      fatalSession ((config small layout) {cfgHooks = noHooks {hookDecoding = failSecond}}) $ \session _ runtime → do
        owner ← startVm session runtime "adopting" OnArrival
        other ← startVm session runtime "failing" OnArrival
        admitDriver session owner "i"
        admitDriver session other "j"
        started session owner "i" "k0" "a.png"
        awaitUploads (ssFake session) 1
        held ← uploadN (ssFake session) 0
        -- The owner is held inside a callback, so the host has not yet built the lease when the texture
        -- is registered and its success reply reaches the host.
        commandWith session owner "i" "block" "g" Nothing
        awaitGate session "g"
        identity ← finishUpload (ssFake session) held
        -- Another instance's job fails in the decode worker, which fails the pipeline: it closes
        -- admission and tells every job to stop.
        started session other "j" "k1" "b.png"
        _ ← atomically (awaitPipelineFailure (ssPipeline session))
        awaitPipeline session ((== 0) . readingDecodeWorkers)
        -- The texture was offered before the shutdown, so the shutdown left it to the host.
        releaseCalls (ssFake session) `shouldReturn` []
        releaseGate session "g"
        command session owner "i" "wait_take" "k0"
        line ← lineStarting session "i wait_take k0 "
        Text.unpack line `shouldContain` "status=success"
        -- The lease is live over the live texture: it can be used, and nothing released it.
        command session owner "i" "use" "k0"
        awaitNote session ("i use k0 " <> Text.pack (show identity))
        releaseCalls (ssFake session) `shouldReturn` []
        ownerNow owner "i" >>= (`shouldBe` OwnerReading 1 128)
        -- The lease's own release asks the backend once, and the charges come back when it retires.
        command session owner "i" "release" "k0"
        awaitReleaseCalls (ssFake session) 1
        releaseCalls (ssFake session) `shouldReturn` [identity]
        retireTexture (ssFake session) identity
        awaitOwner owner "i" (== OwnerReading 0 0)
    pure ()

  it "answers a failure, and never a success, for a texture a failed pipeline claimed before the answer decided: the host builds no lease and the texture is released once" $ do
    failSecond ← failsFrom 1
    gate ← newGate
    ExceptionWithContext _ _ ←
      fatalSession
        ((config small layout) {cfgHooks = noHooks {hookDecoding = failSecond, hookOffering = hold gate}, cfgRelease = releaseHeldGate gate})
        $ \session _ runtime → do
          owner ← startVm session runtime "offering" OnArrival
          other ← startVm session runtime "failing" OnArrival
          admitDriver session owner "i"
          admitDriver session other "j"
          started session owner "i" "k0" "a.png"
          awaitUploads (ssFake session) 1
          held ← uploadN (ssFake session) 0
          -- The texture is registered and the job settled; the answer is held just before it decides.
          registered ← newEmptyMVar
          _ ← forkIO (finishUpload (ssFake session) held >>= putMVar registered)
          readMVar (arrived gate)
          started session other "j" "k1" "b.png"
          _ ← atomically (awaitPipelineFailure (ssPipeline session))
          -- The failed pipeline claims the texture nobody offered.
          awaitReleaseCalls (ssFake session) 1
          releaseHeldGate gate
          identity ← readMVar registered
          -- The answer found the texture claimed, so it answered a failure, which an opt-in request's
          -- service does not declare: the host counts a provider defect and builds nothing. Had the answer
          -- offered the texture it would have been adopted instead.
          awaitVmDiagnostic owner ((>= 1) . rdDefects)
          reading ← vmDiagnostics owner
          (rdAdopting reading, rdAdopted reading) `shouldBe` (0, 0)
          -- The texture was released once, by the failed pipeline, and holds its charges until it retires.
          releaseCalls (ssFake session) `shouldReturn` [identity]
          ownerNow owner "i" >>= (`shouldBe` OwnerReading 1 128)
    pure ()

  it "releases a delivered texture once, and answers nothing, when the host's interest ended before the answer decided: the withdrawal claims it and the answer finds it withdrawn" $ do
    gate ← newGate
    withSession ((config small layout) {cfgHooks = noHooks {hookOffering = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
      owner ← startVm session runtime "withdrawing" OnArrival
      admitDriver session owner "i"
      started session owner "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      registered ← newEmptyMVar
      _ ← forkIO (finishUpload (ssFake session) held >>= putMVar registered)
      readMVar (arrived gate)
      -- The job is settled and its texture delivered; the script cancels, and the host tells the pipeline.
      command session owner "i" "cancel" "k0"
      awaitNote session "i cancel k0 cancelled"
      awaitReleaseCalls (ssFake session) 1
      releaseHeldGate gate
      identity ← readMVar registered
      releaseCalls (ssFake session) `shouldReturn` [identity]
      -- The answer found the job withdrawn and said nothing: the host counts no late reply and no defect.
      reading ← vmDiagnostics owner
      (rdLateReplies reading, rdUnknownReplies reading, rdDefects reading, rdAdopting reading) `shouldBe` (0, 0, 0, 0)
      retireTexture (ssFake session) identity
      takeCancelled session owner "i" "k0"
      awaitOwner owner "i" (== OwnerReading 0 0)
      releaseCalls (ssFake session) `shouldReturn` [identity]

  it "releases an offered texture once when the host answers that the request already ended: the late answer is declined and the pipeline's release is the only one" $ do
    offering ← newGate
    cancelling ← newGate
    withSession
      ((config small layout) {cfgHooks = noHooks {hookOffering = hold offering, hookCancelling = hold cancelling}, cfgRelease = releaseHeldGate offering >> releaseHeldGate cancelling})
      $ \session _ runtime → do
        owner ← startVm session runtime "late" OnArrival
        admitDriver session owner "i"
        started session owner "i" "k0" "a.png"
        awaitUploads (ssFake session) 1
        held ← uploadN (ssFake session) 0
        registered ← newEmptyMVar
        _ ← forkIO (finishUpload (ssFake session) held >>= putMVar registered)
        readMVar (arrived offering)
        -- The host ends the request, and its telling the pipeline is held on the way: the job is not
        -- withdrawn yet, so the answer offers the texture to a host that no longer wants it.
        command session owner "i" "cancel" "k0"
        readMVar (arrived cancelling)
        releaseHeldGate offering
        identity ← readMVar registered
        awaitReleaseCalls (ssFake session) 1
        releaseCalls (ssFake session) `shouldReturn` [identity]
        reading ← vmDiagnostics owner
        (rdLateReplies reading + rdUnknownReplies reading, rdAdopting reading, rdDefects reading) `shouldBe` (1, 0, 0)
        -- The telling arrives now and finds nothing left to release.
        releaseHeldGate cancelling
        awaitNote session "i cancel k0 cancelled"
        retireTexture (ssFake session) identity
        takeCancelled session owner "i" "k0"
        awaitOwner owner "i" (== OwnerReading 0 0)
        releaseCalls (ssFake session) `shouldReturn` [identity]

  it "waits, when the scope closes, for the host to adopt or drop a texture it was offered, and does not release it: the adopted texture stays with its lease" $
    withSession (config small layout) $ \session _ runtime → do
      withNested
        session
        ( \nested → do
            owner ← startVm nested runtime "closing" OnArrival
            admitDriver nested owner "i"
            started nested owner "i" "k0" "a.png"
            awaitUploads (ssFake nested) 1
            held ← uploadN (ssFake nested) 0
            commandWith nested owner "i" "block" "g" Nothing
            awaitGate nested "g"
            void (finishUpload (ssFake nested) held)
        )
        ( \nested → do
            -- Closed with the host holding the offered texture: the scope is not drained, and the
            -- texture was not released.
            atomically (pipelineDrained (ssPipeline nested)) `shouldReturn` False
            releaseCalls (ssFake nested) `shouldReturn` []
            note session "host adopting"
            releaseGate nested "g"
            atomically (pipelineDrained (ssPipeline nested) >>= \drained → when (not drained) retry)
            releaseCalls (ssFake nested) `shouldReturn` []
            texturesLive (ssFake nested) >>= (`shouldSatisfy` ((== 1) . length))
        )
      seen ← history session
      filter (`elem` ["host adopting", "nested scope returned"]) seen
        `shouldBe` ["host adopting", "nested scope returned"]
  where
    -- Take the cancelled request's result: exactly one record, and no texture.
    takeCancelled ∷ Session → Vm → Text → Text → IO ()
    takeCancelled session vm name key = do
      command session vm name "take" key
      awaitNote session (name <> " take " <> key <> " {status=cancelled}")
    -- A decode hook that lets this many decodes through and then fails every one, as a defect.
    failsFrom ∷ Int → IO (a → IO ())
    failsFrom allowed = do
      seen ← newIORef (0 ∷ Int)
      pure $ \_ → do
        earlier ← atomicModifyIORef' seen (\count → (count + 1, count))
        when (earlier >= allowed) (throwIO (userError "decode hook defect"))
