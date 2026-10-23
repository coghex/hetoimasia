{-# LANGUAGE OverloadedStrings #-}

-- | A session whose construction fails part of the way: every built already made is released exactly once, in the
-- opposite order, the failure that stopped it is the outcome's, and a release that fails too is kept beside it.
--
-- The failures are injected at the harness's points, which name the steps; what they exercise is real: the owners
-- started, the scopes unwound, the workers waited for.
module Test.LuaEngine.Session.Construction (spec) where

import Control.Concurrent (forkIO, myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, toException, try)
import Control.Monad (void)
import Data.List (sort)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "construction" $ do
  it "releases every built it made exactly once, and makes the failure that stopped it the outcome's" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildFacade) (toException (userError "construction failed"))
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → void (awaitRetired session)
      released ← releasedSteps recorder
      -- the owner of the first role was running and is stopped and awaited; the second role got as far as its facade
      released `shouldBe` sort [(Gameplay, built) | built ← [BuildCoordinator, BuildData, BuildFacade, BuildOwner]] <> sort [(Presentation, built) | built ← [BuildCoordinator, BuildData, BuildFacade]]
      out ← outLines (seWorld env)
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
      fmap (Text.isInfixOf "construction failed" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True

  it "keeps the failures of releases beside the failure that stopped construction, and releases the rest regardless" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Built Presentation BuildOwner) (toException (userError "construction failed"))
      failAt recorder (Released Gameplay BuildFacade) (toException (userError "the gameplay facade's release failed"))
      failAt recorder (Released Presentation BuildCoordinator) (toException (userError "the presentation coordinator's release failed"))
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → void (awaitRetired session)
      released ← releasedSteps recorder
      released `shouldBe` sort [(role, built) | role ← [Gameplay, Presentation], built ← [BuildCoordinator, BuildData, BuildFacade, BuildOwner]]
      outVerdict outcome `shouldBe` VerdictFailure
      let report = outEngine outcome
      fmap eeMessage (erPrimary report) `shouldSatisfy` maybe False (Text.isInfixOf "construction failed")
      messages (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "the gameplay facade's release failed")
      messages (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "the presentation coordinator's release failed")
      mapM_ (\entry → eeCode entry `shouldBe` CleanupFailure) (erSecondary report)
      reportAccounted report `shouldBe` 3

  it "refuses a second instance of a role the session does not have, before any Lua" $
    withSetup ((setup (roleScript printScript)) {suShape = GameplayAlone, suHarness = noHarness {harnessSecond = [Presentation]}}) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      fmap eeRole (erPrimary (outEngine outcome)) `shouldBe` Just (Just Presentation)

  it "retires nothing early: a role is retired only after its owner has ended and everything it borrowed was released" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      void . runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
      points ← recorded recorder
      -- each owner ended before its built was released
      mapM_
        ( \role → do
            let ended = indexOf (OwnerEnded role) points
                released = indexOf (Released role BuildOwner) points
            (ended, released) `shouldSatisfy` (\(a, b) → maybe False id ((<) <$> a <*> b))
        )
        [Gameplay, Presentation]
  cancellation
  where
    messages = map eeMessage
    indexOf point points = lookup point (zip points [0 ∷ Int ..])

-- | The steps the session released, sorted, one entry for each release.
releasedSteps ∷ Recorder → IO [(Role, BuildStep)]
releasedSteps recorder = sort . (\points → [(role, built) | Released role built ← points]) <$> recorded recorder

-- | The session's thread is cancelled while it is parked at a point: everything built is released exactly once,
-- every owner has ended before its step is released, and the cancellation is the exception that comes out.
cancellation ∷ Spec
cancellation = describe "cancellation of the calling thread" $
  mapM_
    ( \(name, point, dispatched) →
        it ("releases everything exactly once when it lands " <> name) $
          withSetup (setup (roleScript printScript)) $ \env → do
            recorder ← newRecorder
            holdAt recorder point
            self ← myThreadId
            handle ← newEmptyMVar
            _ ← forkIO $ do
              session ← readMVar handle
              awaitPoint recorder point
              throwTo self ThreadKilled
              -- the unwinding closes the gates; only then is a point on an owner's thread let go, which that owner
              -- needs in order to end
              void (awaitStatus session (\status → statusStopping status))
              releaseHold recorder point
            result ← try (runSession (scenarioSpec env (recordingHarness recorder (sxHarness (seSpec env)))) (putMVar handle))
            case result of
              Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
              Right _ → expectationFailure "the cancellation was lost"
            points ← recorded recorder
            -- each owner that was built ended before its step was released, and every built step was released once
            let built = [(role, built') | Built role built' ← points]
                releasedOnce = sort [(role, released) | Released role released ← points]
            releasedOnce `shouldBe` sort built
            out ← outLines (seWorld env)
            -- before the gate opened no root ran; once it had, the inits that were dispatched ran and were shut down,
            -- and no tick was ever granted
            if dispatched
              then out `shouldSatisfy` all (not . Text.isPrefixOf "update")
              else out `shouldBe` []
    )
    [ ("between the intent and the issuance of an admission", Intended (InstanceKey Gameplay 0), False)
    , ("after an admission was accepted and before it was tracked", Issued (InstanceKey Gameplay 0), False)
    , ("while an owner is parked at the dispatch gate", Validating (InstanceKey Presentation 0), False)
    , ("while an owner is dispatched and its init is about to begin", Dispatched (InstanceKey Gameplay 0), True)
    ]
