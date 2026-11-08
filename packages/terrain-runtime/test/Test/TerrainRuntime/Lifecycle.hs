-- | Startup, cancellation, unexpected exit and cleanup: no untracked thread,
-- request, reservation, lease or borrower is left, and a dependency stays live
-- while a borrower is still using the service.
module Test.TerrainRuntime.Lifecycle (spec) where

import Control.Concurrent (killThread, yield)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), fromException, throwIO, try)
import Data.IORef
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (checkRuntime, withSupervision)
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Hetoimasia.Terrain.Residency (Revision (..))
import Hetoimasia.Terrain.Residency (Slot (..), slotInUse)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Supervised (supervisedOwner)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "Lifecycle" $ do
  it "reports a failed owner start and runs no body" $ do
    ran <- newIORef False
    let failing = Supervisor (\_ → throwIO (ErrorCall "no owner could start"))
    outcome <- try (withTerrainService defaultConfig (Ports alwaysAdmitting failing quiet noProbe) (\_ → writeIORef ran True))
    outcome `shouldBe` (Left (ErrorCall "no owner could start") ∷ Either ErrorCall ())
    readIORef ran `shouldReturn` False

  it "settles every request once and leaves nothing when the body is cancelled" $ do
    gate <- newDisarmedGate
    host <- newHost False
    started <- newEmptyMVar
    never <- newTVarIO False
    let served = withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob _ _ → True; _ → False) gate $ \svc → do
          (creator, _) <- openMain svc "main"
          other <- okOf (registerClient svc)
          attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
          armGate gate
          _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) attached (tile 3 4 5))
          awaitReached gate
          putMVar started ()
          -- Wait for a cancellation that never comes from this thread.
          atomically (readTVar never >>= check)
          endClient svc creator
    withOwnedThread served $ \thread wait → do
      bounded (takeMVar started)
      killThread thread
      bounded wait
    -- The owner was joined by the service's own boundary, and the one request
    -- that was in flight reached exactly one terminal outcome.
    settledOf host `shouldReturn` [Failed ArenaClosed]
    readTVarIO never `shouldReturn` False

  it "settles every other request exactly once when the owner ends unexpectedly" $ do
    gate <- newDisarmedGate
    withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate $ \svc → do
      (_, lease) <- openMain svc "main"
      other <- okOf (registerClient svc)
      attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
      bystander <- newHost False
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing bystander) attached (tile 7 7 7))
      waitFor (readTVar (hostReady bystander) >>= \n → check (n >= 1))
      armGate gate
      broken <- newHost True
      let failing = (hostEndpoint svc Nothing broken) {endpointSettle = \_ → throwSTM (ErrorCall "host defect")}
      _ <- okOf (removeWith svc failing lease (tile 1 1 1) Nothing)
      awaitReached gate
      openGate gate
      awaitOwnerStopped svc
      settledOf bystander `shouldReturn` [Failed ArenaClosed]
      -- Authority is revoked and nothing is admitted any more.
      cellAt svc attached (tile 0 0 0) >>= \r → refusedWith r `shouldBe` Just RefusedClosed
      registerClient svc >>= \r → refusedWith r `shouldBe` Just RefusedClosed
      defects <- inspectDefects svc
      length defects `shouldBe` 1
      inspectInvariants svc >>= (`shouldBe` [])
      model <- inspectModel svc
      slotInUse model CommandSlot `shouldBe` 0

  it "keeps settling the rest when one settlement callback fails during closure" $
    withService defaultConfig $ \svc → do
      (creator, _) <- openMain svc "main"
      other <- okOf (registerClient svc)
      attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
      good <- newHost False
      bad <- newHost False
      let failing = (hostEndpoint svc Nothing bad) {endpointSettle = \_ → throwSTM (ErrorCall "cleanup failure")}
      _ <- okOf (cellWith svc failing attached (tile 1 1 1))
      _ <- okOf (cellWith svc (hostEndpoint svc Nothing good) attached (tile 2 2 2))
      waitFor (readTVar (hostReady good) >>= \n → check (n >= 1))
      endClient svc creator
      settledOf good `shouldReturn` [Failed ArenaClosed]
      defects <- inspectDefects svc
      length defects `shouldBe` 1
      inspectInvariants svc >>= (`shouldBe` [])

  it "runs under the application's supervision and ends cleanly" $
    withLoggingLifetime quiet $ \lifetime →
      withSupervision lifetime $ \control → do
        withTerrainService defaultConfig (Ports alwaysAdmitting (supervisedOwner control) quiet noProbe) $ \svc → do
          (_, lease) <- openMain svc "main"
          answer <- readCell svc lease (tile 3 4 5)
          cellRevision answer `shouldBe` Revision 0
          checkRuntime control
          settleChecks svc

  it "surfaces a provider defect through supervision, as the owner's own failure" $ do
    outcome <- try $
      withLoggingLifetime quiet $ \lifetime →
        withSupervision lifetime $ \control →
          withTerrainService defaultConfig (Ports alwaysAdmitting (supervisedOwner control) quiet noProbe) $ \svc → do
            (_, lease) <- openMain svc "main"
            host <- newHost True
            let failing = (hostEndpoint svc Nothing host) {endpointSettle = \_ → throwSTM (ErrorCall "host defect")}
            _ <- okOf (removeWith svc failing lease (tile 1 1 1) Nothing)
            awaitOwnerStopped svc
            -- The failure is the supervised owner's, latched and rethrown with its own type.
            checkRuntime control
    case outcome of
      Left failure → fromException failure `shouldSatisfy` \found → case found of Just (ProviderDefect _) → True; _ → False
      Right () → expectationFailure "the supervised run ended cleanly although the owner failed"

  it "keeps the service live while a borrower still uses a snapshot, then ends in order" $ do
    events <- newMVar ([] ∷ [String])
    let note e = modifyMVar_ events (pure . (e :))
    boxed <- newEmptyMVar
    holding <- newEmptyMVar
    bodyDone <- newEmptyMVar
    release <- newEmptyMVar
    returned <- newEmptyMVar
    let served = do
          withService defaultConfig $ \svc → do
            (_, lease) <- openMain svc "main"
            _ <- readCell svc lease (tile 3 4 5)
            putMVar boxed (svc, lease)
            bounded (readMVar holding)
            note "body done"
            putMVar bodyDone svc
          note "service returned"
          putMVar returned ()
        borrower = do
          (svc, lease) <- bounded (readMVar boxed)
          let (borrowed, _) = decomposeTile (tile 3 4 5)
          _ <- withSnapshot svc lease [borrowed] $ \_ → do
            putMVar holding ()
            readMVar release
            note "borrow finished"
          pure ()
    withOwnedThread served $ \_ waitServed →
      withOwnedThread borrower $ \_ waitBorrower → do
        svc <- bounded (readMVar bodyDone)
        -- The body has finished and the service is closing: admission is closed.
        let closed = registerClient svc >>= \r → case r of
              Left RefusedClosed → pure ()
              Left other → fail ("unexpected refusal " <> show other)
              Right client → endClient svc client >> yield >> closed
        bounded closed
        -- Closing cannot finish while the borrow is outstanding.
        tryReadMVar returned `shouldReturn` Nothing
        putMVar release ()
        bounded waitBorrower
        bounded waitServed
    chronological <- reverse <$> readMVar events
    chronological `shouldBe` ["body done", "borrow finished", "service returned"]
