-- | Owner identity: unique within the runtime boundary that issued it, never
-- issued again, carried by the endpoint, every settlement and the exit record,
-- and conferring nothing.
module Test.LuaRuntime.Identity (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_, replicateM)
import qualified Data.Set as Set
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Hetoimasia.Scripting.Lua.Owner (CallResult (Returned))
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "owner identity" $ do
  it "never reissues an identity across many owners created and retired, more than two at once" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      issued ←
        forM [1 .. 5 ∷ Int] $ \cycleNumber → do
          owners ← replicateM 4 (startOwner runtime (quickSpec fixture "cycled" ["app"]))
          -- Each is live and distinct from the others while all four run.
          Set.size (Set.fromList (map ownerIdentity owners)) `shouldBe` 4
          forM_ owners retireOwner
          forM_ owners $ \owner → awaitTerminal control owner >>= (`shouldSatisfy` isStopped)
          pure (cycleNumber, map ownerIdentity owners)
      let everyone = concatMap snd issued
      length everyone `shouldBe` 20
      Set.size (Set.fromList everyone) `shouldBe` 20
      map ownerSequence everyone `shouldBe` [1 .. 20]

  it "keeps two runtime boundaries' identities apart even when their sequence numbers agree" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control first → do
      second ← newLuaRuntime' control
      a ← startOwner first (quickSpec fixture "a" ["app"])
      b ← startOwner second (quickSpec fixture "b" ["app"])
      ownerSequence (ownerIdentity a) `shouldBe` ownerSequence (ownerIdentity b)
      ownerIdentity a `shouldSatisfy` (/= ownerIdentity b)
      retireOwner a
      retireOwner b

  it "puts the identity and the label on the endpoint, on a fault and on the exit record" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      owner ← startOwner runtime (quickSpec fixture "the label" ["app"])
      let endpoint = ownerEndpoint owner
      endpointOwner endpoint `shouldBe` ownerIdentity owner
      endpointLabel endpoint `shouldBe` "the label"
      faulty ← submit endpoint "boom" [] >>= accepted
      settlement ← settle faulty
      settledOwner settlement `shouldBe` ownerIdentity owner
      settledLabel settlement `shouldBe` "the label"
      ticketOwner faulty `shouldBe` ownerIdentity owner
      retireOwner owner
      _ ← awaitTerminal control owner
      Just record ← atomically (ownerExitRecord owner)
      exitOwner record `shouldBe` ownerIdentity owner
      exitLabel record `shouldBe` "the label"

  it "gives two owners of one label the bindings of their own policies and no others" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      granted ← startOwner runtime (quickSpec fixture "same" ["app"])
      bare ← startOwner runtime (quickSpec fixture "same" [])
      wide ← startOwner runtime (quickSpec fixture "same" ["app", "extra"])
      let namespaces owner = do
            ticket ← submit (ownerEndpoint owner) "namespaces" [] >>= accepted
            returnedValues <$> settleOutcome ticket
      namespaces granted >>= (`shouldBe` Just [VText "app"])
      namespaces bare >>= (`shouldBe` Just [VText ""])
      namespaces wide >>= (`shouldBe` Just [VText "app,extra"])
      -- The identical label conferred nothing, and identities differ.
      length (Set.toList (Set.fromList (map ownerIdentity [granted, bare, wide]))) `shouldBe` 3
      -- And an owner keeps working beside them.
      ticket ← submit (ownerEndpoint granted) "echo" [VInteger 3] >>= accepted
      returnedValues <$> settleOutcome ticket >>= (`shouldBe` Just [VInteger 3])
      forM_ [granted, bare, wide] retireOwner
  where
    isStopped = \case
      WorkerStopped → True
      _ → False
    newLuaRuntime' = newLuaRuntime
    _unused = Returned
