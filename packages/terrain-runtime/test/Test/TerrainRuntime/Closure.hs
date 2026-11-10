-- | Closure and authority: arenas, leases, names, limits and the parent
-- session's admission, each against the requests that are still waiting.
module Test.TerrainRuntime.Closure (spec) where

import Control.Concurrent.STM
import Control.Monad (forM, forM_)
import Data.Text (pack)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

victim ∷ (Integer, Integer, Integer)
victim = (3, 4, 5)

-- | Nothing reserved or occupied beyond the arenas themselves, no command held.
quiescentModel ∷ Model → Bool
quiescentModel model =
  and [ledgerReserved (bankLedger model bank) == 0 | bank <- [ResidentBank, EditBank, StagingBank]]
    && slotInUse model CommandSlot == 0
    && slotInUse model LoadJobSlot == 0

-- | Every bank empty and every slot free.
quiescent ∷ Service → IO ()
quiescent svc = do
  model <- inspectModel svc
  forM_ [ResidentBank, EditBank, StagingBank] $ \bank → do
    let l = bankLedger model bank
    (bank, ledgerReserved l) `shouldBe` (bank, 0)
  forM_ [LoadJobSlot, CommandSlot] $ \slot → (slot, slotInUse model slot) `shouldBe` (slot, 0)

spec ∷ Spec
spec = describe "Closure and authority" $ do
  describe "names, leases and authority" $ do
    it "rejects a duplicate name, answers not_found for an absent one, and shares by name" $
      withService defaultConfig $ \svc → do
        (creator, lease) <- openMain svc "main"
        again <- okOf (openArena svc creator "main" soilOverStone) >>= await svc
        again `shouldBe` Left (Failed NameInUse)
        other <- okOf (registerClient svc)
        okOf (attachArena svc other "missing") >>= await svc >>= (`shouldBe` Left (Failed NotFound))
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        a <- readCell svc lease (tile 1 1 1)
        b <- readCell svc attached (tile 1 1 1)
        a `shouldBe` b
        settleChecks svc

    it "refuses forged, foreign, released and closed authority before work" $
      withService defaultConfig $ \svc → do
        (creator, lease) <- openMain svc "main"
        withService defaultConfig $ \elsewhere → do
          foreignClient <- okOf (registerClient elsewhere)
          -- Authority from another service is refused, never confused with ours.
          cellAt elsewhere lease (tile 0 0 0) >>= (\r → refusedWith r `shouldBe` Just RefusedAuthority)
          openArena svc foreignClient "x" soilOverStone >>= (\r → refusedWith r `shouldBe` Just RefusedAuthority)
          releaseLease elsewhere lease >>= (`shouldBe` Left RefusedAuthority)
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        releaseLease svc attached >>= (`shouldBe` Right ())
        -- A released lease is not authority any more.
        cellAt svc attached (tile 0 0 0) >>= (\r → refusedWith r `shouldBe` Just RefusedAuthority)
        -- Releasing twice is harmless.
        releaseLease svc attached >>= (`shouldBe` Right ())
        endClient svc creator
        cellAt svc lease (tile 0 0 0) >>= (\r → refusedWith r `shouldBe` Just RefusedAuthority)
        settleChecks svc

    it "answers arena_closed through an attached lease after the creator ends" $
      withService defaultConfig $ \svc → do
        (creator, _) <- openMain svc "main"
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        endClient svc creator
        -- The creator's final owner lease is gone: the arena closes even though
        -- the attached lease remains, and the attachment now answers arena_closed.
        okOf (cellAt svc attached (tile 0 0 0)) >>= await svc >>= (`shouldBe` Left (Failed ArenaClosed))
        -- The name is free again and a fresh incarnation opens under it.
        lease2 <- okOf (openArena svc other "main" soilOverStone) >>= await svc >>= expectSuccess
        fresh <- readCell svc lease2 (tile 0 0 0)
        cellIncarnation fresh `shouldBe` ArenaId 1
        okOf (cellAt svc attached (tile 0 0 0)) >>= await svc >>= (`shouldBe` Left (Failed ArenaClosed))
        settleChecks svc

    it "closes one of two arenas without stopping the other" $
      withService defaultConfig $ \svc → do
        (creatorA, _) <- openMain svc "a"
        (_, leaseB) <- openMain svc "b"
        endClient svc creatorA
        answer <- readCell svc leaseB (tile 1 2 3)
        cellIncarnation answer `shouldBe` ArenaId 1
        settleChecks svc

  describe "limits" $ do
    it "holds four arenas, 64 leases and eight views" $
      withService defaultConfig $ \svc → do
        client <- okOf (registerClient svc)
        leases <- forM [1 .. 4 ∷ Int] $ \n → okOf (openArena svc client (pack ("arena" <> show n)) soilOverStone) >>= await svc >>= expectSuccess
        fifth <- openArena svc client "fifth" soilOverStone
        refusedWith fifth `shouldBe` Just (RefusedBusy BusyArenas)
        -- 4 owner leases so far; attach up to 64.
        others <- forM [1 .. 60 ∷ Int] $ \_ → do
          c <- okOf (registerClient svc)
          okOf (attachArena svc c "arena1") >>= await svc >>= expectSuccess
        extra <- registerClient svc >>= expectRight >>= \c → attachArena svc c "arena1"
        refusedWith extra `shouldBe` Just (RefusedBusy BusyLeases)
        -- A refused admission left nothing behind.
        length (leases <> others) `shouldBe` 64
        views <- forM [1 .. 8 ∷ Int] $ \_ → okOf (openView svc client)
        ninth <- openView svc client
        refusedWith ninth `shouldBe` Just (RefusedBusy BusyViews)
        mapM_ (closeView svc) views
        _ <- okOf (openView svc client)
        settleChecks svc

    it "refuses to issue an identity that would wrap" $
      withService defaultConfig {configFirstIdentity = maxBound - 4} $ \svc → do
        client <- okOf (registerClient svc)
        lease <- okOf (openArena svc client "main" soilOverStone) >>= await svc >>= expectSuccess
        -- The open took one request identity; the last identity is never issued.
        _ <- readCell svc lease (tile 0 0 0)
        _ <- readCell svc lease (tile 0 0 0)
        _ <- readCell svc lease (tile 0 0 0)
        cellAt svc lease (tile 0 0 0) >>= (\r → refusedWith r `shouldBe` Just RefusedExhausted)
        -- Reads of what exists are not disturbed, and nothing was left behind.
        inspectInvariants svc >>= (`shouldBe` [])

    it "refuses to issue a content revision that would wrap" $
      withService defaultConfig {configFirstRevision = maxBound - 3} $ \svc → do
        (_, lease) <- openMain svc "main"
        first' <- removeCell' svc lease (tile 0 0 1)
        removeRevision first' `shouldBe` Revision (maxBound - 2)
        second <- removeCell' svc lease (tile 0 0 2)
        removeRevision second `shouldBe` Revision (maxBound - 1)
        removeAt svc lease (tile 0 0 3) Nothing >>= (\r → refusedWith r `shouldBe` Just RefusedExhausted)
        -- Reads continue, and the refusal changed nothing.
        answer <- readCell svc lease (tile 0 0 3)
        (cellRevision answer, cellIs answer) `shouldBe` (Revision (maxBound - 1), False)
        settleChecks svc

  describe "closing against pending work" $ do
    it "settles a pending load once when its arena closes, and returns every credit" $ do
      gate <- newDisarmedGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointJob _ _ → True; _ → False) gate $ \svc → do
        (creator, lease) <- openMain svc "main"
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        armGate gate
        theirs <- okOf (cellAt svc attached (tile 3 4 5))
        ours <- okOf (cellAt svc lease (tile 3 4 5))
        awaitReached gate
        endClient svc creator
        -- Another client's request ends because the arena did; the creator's
        -- own was cancelled with the lease it was made through.
        await svc theirs >>= (`shouldBe` Left (Failed ArenaClosed))
        await svc ours >>= (`shouldBe` Left Cancelled)
        openGate gate
        waitFor (inspectModelSTM svc >>= \m → check (quiescentModel m))
        quiescent svc
        settleChecks svc

    it "settles a staged edit once when its arena closes and commits nothing" $
      withService defaultConfig $ \svc → do
        (creator, _) <- openMain svc "main"
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        host <- newHost False
        let (x, y, z) = victim
        _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) attached (tile x y z) Nothing)
        waitFor (readTVar (hostReady host) >>= \n → if n == 0 then retry else pure ())
        endClient svc creator
        grant host
        settledOf host `shouldReturn` [Failed ArenaClosed]
        -- A fresh incarnation under the same name starts from its recipe.
        lease2 <- okOf (openArena svc other "main" soilOverStone) >>= await svc >>= expectSuccess
        fresh <- readCell svc lease2 (tile x y z)
        (cellIncarnation fresh, cellRevision fresh, cellIs fresh) `shouldBe` (ArenaId 1, Revision 0, False)
        settleChecks svc

    it "settles a staged read once when its arena closes" $
      withService defaultConfig $ \svc → do
        (creator, _) <- openMain svc "main"
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        host <- newHost False
        _ <- okOf (cellWith svc (hostEndpoint svc Nothing host) attached (tile 3 4 5))
        waitFor (readTVar (hostReady host) >>= \n → if n == 0 then retry else pure ())
        endClient svc creator
        grant host
        settledOf host `shouldReturn` [Failed ArenaClosed]
        quiescent svc
        settleChecks svc

    it "cancels a pending open and frees its name, and answers not_found to a pending attach after closure" $
      withService defaultConfig $ \svc → do
        client <- okOf (registerClient svc)
        host <- newHost False
        _ <- okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "main" soilOverStone)
        waitFor (readTVar (hostReady host) >>= \n → if n == 0 then retry else pure ())
        -- A waiting open blocks a duplicate but is invisible to attach.
        duplicate <- okOf (openArena svc client "main" soilOverStone) >>= await svc
        duplicate `shouldBe` Left (Failed NameInUse)
        other <- okOf (registerClient svc)
        okOf (attachArena svc other "main") >>= await svc >>= (`shouldBe` Left (Failed NotFound))
        endClient svc client
        settledOf host `shouldReturn` [Cancelled]
        -- The name is free again.
        lease <- okOf (openArena svc other "main" soilOverStone) >>= await svc >>= expectSuccess
        _ <- readCell svc lease (tile 0 0 0)
        settleChecks svc

    it "lets cancel, release and close proceed with the ordinary queue full" $ do
      let config = configWith (\s → s {specQueuedCommands = 2})
      withService config $ \svc → do
        (creator, _) <- openMain svc "main"
        other <- okOf (registerClient svc)
        attached <- okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
        hostA <- newHost False
        hostB <- newHost False
        a <- okOf (cellWith svc (hostEndpoint svc Nothing hostA) attached (tile 0 0 0))
        _ <- okOf (cellWith svc (hostEndpoint svc Nothing hostB) attached (tile 1 0 0))
        waitFor (readTVar (hostReady hostB) >>= \n → if n == 0 then retry else pure ())
        cellAt svc attached (tile 2 0 0) >>= (\r → fmap isBusy (refusedWith r) `shouldBe` Just True)
        -- Busy created nothing, and control still works.
        cancel svc a >>= (`shouldBe` CancelWon)
        again <- okOf (cellAt svc attached (tile 2 0 0))
        cancel svc (pendingRequest again) >>= (`shouldBe` CancelWon)
        endClient svc creator
        settledOf hostB `shouldReturn` [Failed ArenaClosed]
        closeService svc
        settleChecks svc

  describe "the parent session's admission" $ do
    it "dominates every gate: new work is refused and a staged edit does not commit" $ do
      open <- newTVarIO True
      withServiceUsing defaultConfig (SessionAdmission (readTVar open)) noProbe $ \svc → do
        (_, lease) <- openMain svc "main"
        client2 <- okOf (registerClient svc)
        -- A waiting acquisition, a staged edit and a waiting load.
        acquisition <- newHost False
        _ <- okOf (openArenaWith svc (hostEndpoint svc Nothing acquisition) client2 "other" soilOverStone)
        editing <- newHost False
        let (x, y, z) = victim
        _ <- okOf (removeWith svc (hostEndpoint svc (Just lease) editing) lease (tile x y z) Nothing)
        waitFor (readTVar (hostReady editing) >>= \n → if n == 0 then retry else pure ())
        atomically (writeTVar open False)
        awaitClosed svc
        grant editing
        grant acquisition
        -- Exactly one terminal outcome each, and the edit never committed.
        settledOf editing `shouldReturn` [Failed ArenaClosed]
        settledOf acquisition `shouldReturn` [Cancelled]
        r1 <- cellAt svc lease (tile x y z)
        refusedWith r1 `shouldBe` Just (RefusedClosed)
        r2 <- openArena svc client2 "again" soilOverStone
        refusedWith r2 `shouldBe` Just (RefusedClosed)
        r3 <- registerClient svc
        refusedWith r3 `shouldBe` Just (RefusedClosed)
        inspectInvariants svc >>= (`shouldBe` [])

    it "is read inside the commit arbitration" $ do
      open <- newTVarIO True
      gate <- newDisarmedGate
      withGatedService defaultConfig (SessionAdmission (readTVar open)) (\p → case p of PointBeforeCommit _ → True; _ → False) gate $ \svc → do
        (_, lease) <- openMain svc "main"
        host <- newHost True
        let (x, y, z) = victim
        armGate gate
        _ <- okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x y z) Nothing)
        awaitReached gate
        -- The owner is at the boundary with the edit ready; the session ends first.
        atomically (writeTVar open False)
        openGate gate
        awaitClosed svc
        settledOf host `shouldReturn` [Failed ArenaClosed]
        inspectInvariants svc >>= (`shouldBe` [])


  describe "asking whether the service admits work" $ do
    it "is true while it runs, and false once the parent session has ended, or the service is closing or closed" $ do
      open <- newTVarIO True
      withServiceUsing defaultConfig (SessionAdmission (readTVar open)) noProbe $ \svc → do
        atomically (serviceAdmitting svc) `shouldReturn` True
        -- the parent session ends: the answer follows it at once (the owner then closes the service, which it never reopens)
        atomically (writeTVar open False)
        atomically (serviceAdmitting svc) `shouldReturn` False
        awaitClosed svc
        atomically (serviceAdmitting svc) `shouldReturn` False
        -- and it agrees with what an admission does: the same refusal, nothing created
        registerClient svc >>= \r → refusedWith r `shouldBe` Just RefusedClosed
        inspectInvariants svc >>= (`shouldBe` [])
      withService defaultConfig $ \svc → do
        atomically (serviceAdmitting svc) `shouldReturn` True
        closeService svc
        atomically (serviceAdmitting svc) `shouldReturn` False

    it "is a precheck only: a service that closes after it still refuses the admission, atomically, and leaves nothing behind" $ do
      withService defaultConfig $ \svc → do
        (_, lease) <- openMain svc "main"
        atomically (serviceAdmitting svc) `shouldReturn` True
        -- the service closes between the precheck and the admission
        closeService svc
        modelBefore <- inspectModel svc
        r <- cellAt svc lease (tile 0 0 0)
        refusedWith r `shouldBe` Just RefusedClosed
        modelAfter <- inspectModel svc
        modelAfter `shouldBe` modelBefore
        inspectInvariants svc >>= (`shouldBe` [])

  describe "inspecting a staged removal" $
    it "tells a host before the commit whether the removal changes content, and nothing for any other request" $ do
      gate <- newDisarmedGate
      withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate $ \svc → do
        (_, lease) <- openMain svc "main"
        host <- newHost True
        let (x, y, z) = victim
            ep = hostEndpoint svc Nothing host
        -- a removal of solid: staged and held at the commit, it will advance the revision
        armGate gate
        solid <- okOf (removeWith svc ep lease (tile x y z) Nothing)
        awaitReached gate
        atomically (stagedRemovalChanges svc solid) `shouldReturn` Just True
        openGate gate
        awaitSettled host 1
        -- once settled it stages nothing
        atomically (stagedRemovalChanges svc solid) `shouldReturn` Nothing
        -- a removal of air commits as unchanged, and says so before the commit
        gate2 <- newDisarmedGate
        withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate2 $ \svc2 → do
          (_, lease2) <- openMain svc2 "main"
          host2 <- newHost True
          let ep2 = hostEndpoint svc2 Nothing host2
          armGate gate2
          air <- okOf (removeWith svc2 ep2 lease2 (tile 0 0 100) Nothing)
          awaitReached gate2
          atomically (stagedRemovalChanges svc2 air) `shouldReturn` Just False
          -- another service's request, and the request of this service asked of the other, are nothing to it
          atomically (stagedRemovalChanges svc2 solid) `shouldReturn` Nothing
          openGate gate2
          awaitSettled host2 1
        -- a read stages an answer, never a removal
        gate3 <- newDisarmedGate
        withGatedService defaultConfig alwaysAdmitting (\p → case p of PointBeforeCommit _ → True; _ → False) gate3 $ \svc3 → do
          (_, lease3) <- openMain svc3 "main"
          host3 <- newHost True
          armGate gate3
          readReq <- okOf (cellWith svc3 (hostEndpoint svc3 Nothing host3) lease3 (tile x y z))
          awaitReached gate3
          atomically (stagedRemovalChanges svc3 readReq) `shouldReturn` Nothing
          openGate gate3
          awaitSettled host3 1
        inspectInvariants svc >>= (`shouldBe` [])
  where
    isBusy = \case RefusedBusy _ → True; _ → False
    -- Until the host has been told this many terminal outcomes.
    awaitSettled host n = bounded (atomically (readTVar (hostSettled host) >>= \seen → check (length seen >= n)))
