{-# LANGUAGE OverloadedStrings #-}

-- | The session's authored output under contention and failure (D-71): a whole call written under one
-- lock and flushed before it is released, per-owner order, a slow sink that blocks its writers, a sink that
-- raises being fatal even when Lua catches the stand-in, no retry through a failed sink, the scope that
-- owns the sinks outliving the owners that write to them, and what a half-made facade leaves behind.
module Test.LuaEngine.Facade.Sinks (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, readTVarIO)
import Control.Exception (SomeException, finally, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Owner (LibraryProfile (LibraryProfileM1), vmProfileConfig)
import Hetoimasia.Scripting.Lua.Registration (namespace)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.Support.Bounded (bounded)

files ∷ [(FilePath, ByteString)]
files = [("data.bin", "xx")]

spec ∷ Spec
spec = describe "authored output under contention and failure" $ do
  describe "a whole call" $ do
    it "is written under one lock and flushed before the lock is released: a call held in a slow sink keeps another VM's writer out until it returns" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scInit = ["print(api.role .. ' first\\n' .. api.role .. ' second')"]}) : files)) $ \world _ runtime →
        withFvm world runtime gameplayShape $ \gameplay → withFvm world runtime presentationShape $ \presentation → do
          holdSink world "gameplay first"
          _ ← admitOnly world gameplay "modules-test" mainPath
          awaitSinkEntered world "gameplay first"
          -- the presentation instance prints while the gameplay call is inside the sink
          _ ← admitOnly world presentation "modules-test" mainPath
          outLines world >>= (`shouldBe` [])
          releaseSink world
          out ← awaitOut world 4
          -- the two lines of the first call are together, and the second call follows whole
          out `shouldBe` ["gameplay first", "gameplay second", "presentation first", "presentation second"]
          readTVarIO (wFlushes world) >>= (`shouldBe` 2)
    it "keeps one owner's calls in the order it made them" $
      withOne Gameplay fixedM1Profile script {scInit = ["for i = 1, 20 do print('call ' .. i) warn('warning ' .. i) end"]} $ \world _ _ _ → do
        out ← outLines world
        err ← errLines world
        out `shouldBe` ["call " <> Text.pack (show i) | i ← [1 ∷ Int .. 20]]
        map (Text.dropWhile (/= ':')) err `shouldBe` [": warning " <> Text.pack (show i) | i ← [1 ∷ Int .. 20]]
        readTVarIO (wFlushes world) >>= (`shouldBe` 40)
  describe "a sink that fails" $ do
    it "is fatal to the owner even when the script caught the stand-in error, and is not retried or reported through" $ do
      seen ← newIORef ([], [])
      (_, raised) ←
        fatalWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scInit = ["local ok = pcall(print, 'boom')", "print('after ' .. tostring(ok))", "warn('and after')"]}) : files)) $ \world control runtime → do
          failSinkOn world "boom"
          withFvm world runtime gameplayShape $ \fvm → do
            _ ← admitOnly world fvm "modules-test" mainPath
            -- the owner ends: supervision raises it here
            (void (awaitEnded control fvm)) `finally` (((,) <$> outLines world <*> readTVarIO (wSinkEntered world)) >>= writeIORef seen)
      (written', handed) ← readIORef seen
      -- the sink was handed the line that failed, once, and nothing after: no retry, no report through it
      (written', handed) `shouldBe` ([], ["boom"])
      Text.pack (show raised) `shouldSatisfy` Text.isInfixOf "OutputFailure"
    it "is fatal when a flush fails, though the line was written, and nothing else is written after it" $ do
      seen ← newIORef []
      (_, raised) ←
        fatalWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scInit = ["pcall(print, 'written, not flushed')", "print('never')"]}) : files)) $ \world control runtime → do
          failFlushes world
          withFvm world runtime gameplayShape $ \fvm → do
            _ ← admitOnly world fvm "modules-test" mainPath
            (void (awaitEnded control fvm)) `finally` (outLines world >>= writeIORef seen)
      readIORef seen >>= (`shouldBe` ["written, not flushed"])
      Text.pack (show raised) `shouldSatisfy` Text.isInfixOf "OutputFailure"
  describe "the scope that owns the sinks" $ do
    it "outlives the owner that writes to them: a shutdown hook that prints while the owner retires still finds its sink" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scShutdown = ["print('goodbye')", "warn('goodbye')"]}) : files)) $ \world _ runtime → do
        withFvm world runtime gameplayShape $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pure ()
        -- the owner was retired when its scope ended, and its shutdown wrote before the sinks went away
        outLines world >>= (`shouldBe` ["goodbye"])
        errLines world >>= (`shouldSatisfy` (\found → length found == 1))
    it "closes to new calls when it ends and waits for the calls inside a sink, so a sink is never released under a writer" $ do
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      finished ← newEmptyMVar
      written ← newEmptyMVar
      let sink =
            OutputSink
              { sinkLine = \_ → putMVar entered () >> takeMVar gate
              , sinkFlush = pure ()
              }
          -- the gate is opened however the example ends, so the writer and the scope always unwind
          release = tryPutMVar gate () >> pure ()
      scope ← forkIO $ do
        withOutput sink sink $ \output → do
          void (forkIO (writeAuthored output Stdout ["held"] `finally` putMVar written ()))
          bounded (takeMVar entered)
        putMVar finished ()
      ( do
          awaitBlockedOnSTM scope
          -- the scope's body returned and it is waiting for the call in the sink
          tryReadMVar finished >>= (`shouldBe` Nothing)
        )
        `finally` release
      bounded (takeMVar finished)
      bounded (takeMVar written)
    it "does not take an interruption of a call inside a sink for a failure of the sink: later calls are still written" $ do
      entered ← newEmptyMVar
      gate ← newEmptyMVar
      seen ← newIORef []
      let sink =
            OutputSink
              { sinkLine = \line → modifyIORef' seen (line :) >> tryPutMVar entered () >> readMVar gate
              , sinkFlush = pure ()
              }
      withOutput sink sink $ \output → do
        done ← newEmptyMVar
        writer ← forkIO (writeAuthored output Stdout ["first"] `finally` putMVar done ())
        ( do
            bounded (takeMVar entered)
            killThread writer
            bounded (takeMVar done)
          )
          `finally` void (tryPutMVar gate ())
        writeAuthored output Stdout ["second"]
        atomically (outputFailure output) >>= (`shouldSatisfy` isNothing)
      readIORef seen >>= (`shouldBe` ["second", "first"])
    it "treats a call after the scope has ended as the engine's defect, writing nothing" $ do
      let sink = OutputSink {sinkLine = \_ → expectationFailure "nothing may be written", sinkFlush = pure ()}
      kept ← withOutput sink sink pure
      outcome ← try (writeAuthored kept Stdout ["late"])
      case outcome of
        Left found → show (found ∷ SomeException) `shouldSatisfy` Text.isInfixOf "after the output's scope ended" . Text.pack
        Right () → expectationFailure "the late call must be refused"
  describe "a facade made in part" $ do
    it "is refused whole when the bindings cannot be registered: a namespace of the engine's own name is not accepted, and nothing is installed" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script) : files)) $ \world _ runtime →
        withFvm world runtime gameplayShape $ \fvm →
          case installFacade (fvFacade fvm) [namespace "hetoimasia_engine" []] [] (vmProfileConfig LibraryProfileM1) of
            Left (RegistrationRefused _) → pure ()
            Left other → expectationFailure ("expected the registration refused, found " <> show other)
            Right _ → expectationFailure "a namespace of the engine's own name must be refused"
    it "ends the owner as an engine failure when the builder cannot bind the instance it was made for" $ do
      (reported, _) ←
        fatalWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script) : files)) $ \world control runtime →
          withFvm world runtime gameplayShape $ \fvm → do
            -- the identity is forgotten after it was declared and before the instance is admitted
            _ ← admitWith world fvm "modules-test" mainPath (\facade declared → forgetInstance facade (declaredId declared))
            void (awaitEnded control fvm)
      length reported `shouldBe` 1
      reported `shouldSatisfy` all (\(EngineFailure why) → "could not be bound" `Text.isInfixOf` why)
