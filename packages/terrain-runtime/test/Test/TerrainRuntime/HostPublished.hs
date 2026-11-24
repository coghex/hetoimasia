-- | A lease issued through a live creator lease ('attachArenaFrom'): the host publishes its creator lease and another client takes an
-- attachment to that incarnation, with no name to resolve. The attachment is never an owner lease, the source is validated when the
-- request is admitted and where the lease is issued, and every outcome leaves the service's leases balanced.
module Test.TerrainRuntime.HostPublished (spec) where

import Data.List (find)
import Hetoimasia.Terrain.Residency (Revision (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Control.Concurrent.STM (atomically, check, readTVar)
import Test.Hspec
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "host-published arena" $ do
  it "issues the requesting client its own attachment, which reads and removes like any attachment" $
    withService defaultConfig $ \svc → do
      (_, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      attached <- attachArenaFrom svc other creator >>= expectRight >>= await svc >>= expectSuccess
      cellIs <$> readCell svc attached (tile 3 4 5) >>= (`shouldBe` False)
      removed <- okOf (removeAt svc attached (tile 3 4 5) Nothing) >>= await svc >>= expectSuccess
      removeRevision removed `shouldBe` Revision 1
      -- the creator reads the edit the attachment made
      cellRevision <$> readCell svc creator (tile 3 4 5) >>= (`shouldBe` Revision 1)
      settleChecks svc

  it "is never an owner lease, whichever client asks, so it neither closes the arena nor grows its storage" $
    withService defaultConfig $ \svc → do
      (creatorClient, creator) <- openMain svc "main"
      -- the creator's own client takes an attachment through its own lease: by name that would be an owner lease
      own <- attachArenaFrom svc creatorClient creator >>= expectRight >>= await svc >>= expectSuccess
      refusedWith <$> growArena svc own 134217728 >>= (`shouldBe` Just RefusedAuthority)
      refusedWith <$> retryArena svc own >>= (`shouldBe` Just RefusedAuthority)
      -- releasing it, repeatedly, leaves the arena and its creator lease
      releaseLease svc own >>= (`shouldBe` Right ())
      releaseLease svc own >>= (`shouldBe` Right ())
      cellIs <$> readCell svc creator (tile 1 1 1) >>= (`shouldBe` False)
      -- and closing the last creator lease closes the arena with an attachment outstanding
      other <- okOf (registerClient svc)
      attached <- attachArenaFrom svc other creator >>= expectRight >>= await svc >>= expectSuccess
      releaseLease svc creator >>= (`shouldBe` Right ())
      cellAt svc attached (tile 1 1 1) >>= expectRight >>= await svc >>= (`shouldBe` Left (Failed ArenaClosed))
      heldLeases svc `shouldReturn` 1
      endClient svc other
      heldLeases svc `shouldReturn` 0
      settleChecks svc

  it "accepts only a live owner lease of the same service" $
    withService defaultConfig $ \svc → do
      (_, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      attached <- attachArenaFrom svc other creator >>= expectRight >>= await svc >>= expectSuccess
      -- an attachment is not authority to publish the arena
      refusedWith <$> attachArenaFrom svc other attached >>= (`shouldBe` Just RefusedAuthority)
      atomically (creatorLeaseSTM svc attached) >>= (`shouldBe` Left RefusedAuthority)
      atomically (creatorLeaseSTM svc creator) >>= (`shouldBe` Right ())
      -- a lease of another service is not authority either
      withService defaultConfig $ \foreign' → do
        (_, theirs) <- openMain foreign' "main"
        client <- okOf (registerClient svc)
        refusedWith <$> attachArenaFrom svc client theirs >>= (`shouldBe` Just RefusedAuthority)
        atomically (creatorLeaseSTM svc theirs) >>= (`shouldBe` Left RefusedAuthority)
      heldLeases svc `shouldReturn` 2
      settleChecks svc

  it "an expired grant settles not_found at admission and holds nothing" $
    withService defaultConfig $ \svc → do
      (creatorClient, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      releaseLease svc creator >>= (`shouldBe` Right ())
      atomically (creatorLeaseSTM svc creator) >>= (`shouldBe` Left RefusedAuthority)
      attachArenaFrom svc other creator >>= expectRight >>= await svc >>= (`shouldBe` Left (Failed NotFound))
      -- a client that ended takes the lease with it
      (ended, endedLease) <- openMain svc "second"
      endClient svc ended
      attachArenaFrom svc other endedLease >>= expectRight >>= await svc >>= (`shouldBe` Left (Failed NotFound))
      endClient svc creatorClient
      heldLeases svc `shouldReturn` 0
      settleChecks svc

  it "a stale source cannot reach the arena that reuses its name" $
    withService defaultConfig $ \svc → do
      (_, first) <- openMain svc "main"
      other <- okOf (registerClient svc)
      stale <- attachArenaFrom svc other first >>= expectRight >>= await svc >>= expectSuccess
      releaseLease svc first >>= (`shouldBe` Right ())
      (_, second) <- openMain svc "main"
      attachArenaFrom svc other first >>= expectRight >>= await svc >>= (`shouldBe` Left (Failed NotFound))
      cellAt svc stale (tile 1 1 1) >>= expectRight >>= await svc >>= (`shouldBe` Left (Failed ArenaClosed))
      -- the replacement is reached only through its own creator lease
      replacement <- attachArenaFrom svc other second >>= expectRight >>= await svc >>= expectSuccess
      cellIs <$> readCell svc replacement (tile 1 1 1) >>= (`shouldBe` False)
      settleChecks svc

  it "host closure while the attachment is pending settles not_found, and the grant is held for nothing" $
    withService defaultConfig $ \svc → do
      (creatorClient, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      host <- newHost False
      request <- attachArenaFromWith svc (hostEndpoint svc Nothing host) other creator >>= expectRight
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- the pending request holds its lease reservation, and the host closes the arena before the lease is issued
      heldLeases svc `shouldReturn` 2
      endClient svc creatorClient
      grant host
      waitFor (readTVar (hostSettled host) >>= check . not . null)
      settledOf host `shouldReturn` [Failed NotFound]
      cancel svc request >>= (`shouldBe` AlreadySettled)
      heldLeases svc `shouldReturn` 0
      settleChecks svc

  it "a cancelled attachment leaves no reservation and no lease, and cancelling again is harmless" $
    withService defaultConfig $ \svc → do
      (_, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      host <- newHost False
      request <- attachArenaFromWith svc (hostEndpoint svc Nothing host) other creator >>= expectRight
      heldLeases svc `shouldReturn` 2
      cancel svc request >>= (`shouldBe` CancelWon)
      cancel svc request >>= (`shouldBe` AlreadySettled)
      settledOf host `shouldReturn` [Cancelled]
      heldLeases svc `shouldReturn` 1
      settleChecks svc

  it "a full lease bank declines busy and returns the reservation" $
    withService defaultConfig {configMaxLeases = 2} $ \svc → do
      (_, creator) <- openMain svc "main"
      other <- okOf (registerClient svc)
      first <- attachArenaFrom svc other creator >>= expectRight >>= await svc >>= expectSuccess
      refusedWith <$> attachArenaFrom svc other creator >>= (`shouldBe` Just (RefusedBusy BusyLeases))
      heldLeases svc `shouldReturn` 2
      releaseLease svc first >>= (`shouldBe` Right ())
      _ <- attachArenaFrom svc other creator >>= expectRight >>= await svc >>= expectSuccess
      heldLeases svc `shouldReturn` 2
      settleChecks svc

-- | The leases the service holds: its own enumeration of them.
heldLeases ∷ Service → IO Word
heldLeases svc = maybe 0 (fromIntegral . limitRowHeld) . find ((== "leases") . limitRowName) <$> inspectLimits svc
