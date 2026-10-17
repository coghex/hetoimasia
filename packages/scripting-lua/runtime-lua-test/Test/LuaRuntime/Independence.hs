-- | Independence (D-15): owners with different registrations and policies are
-- created and retired while others run, and nothing one does stops another or
-- widens its bindings.
module Test.LuaRuntime.Independence (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "independent owners" $ do
  it "creates and retires owners of different registrations and policies while another serves clients on its own thread, and none widens another's bindings" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      steady ← startOwner runtime (quickSpec fixture "steady" ["app"])
      client ← newEmptyMVar
      -- A client on a thread of its own keeps calling the steady owner.
      _ ← forkIO $ do
        results ← forM [1 .. 200 ∷ Int] $ \n → do
          ticket ← submit (ownerEndpoint steady) "namespaces" [] >>= accepted
          outcome ← settleOutcome ticket
          pure (n, returnedValues outcome)
        putMVar client results
      wide ← startOwner runtime (ownerSpec fixture "wide" ["app", "extra"] (optionalPolicy (const True)) (bounds 8 8))
      narrow ← startOwner runtime (ownerSpec fixture "narrow" ["extra"] (optionalPolicy (const True)) (bounds 8 8))
      -- Each keeps the bindings of its own policy.
      let namespaces owner = do
            ticket ← submit (ownerEndpoint owner) "namespaces" [] >>= accepted
            returnedValues <$> settleOutcome ticket
      namespaces wide >>= (`shouldBe` Just [VText "app,extra"])
      namespaces narrow >>= (`shouldBe` Just [VText "extra"])
      -- Retiring one neither stops another nor widens it.
      retireOwner wide
      awaitTerminal control wide >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      namespaces narrow >>= (`shouldBe` Just [VText "extra"])
      namespaces steady >>= (`shouldBe` Just [VText "app"])
      -- Failing one neither stops another nor widens it.
      failing ← submit (ownerEndpoint narrow) "extra_fail" [VText "binding"] >>= accepted
      awaitTerminal control narrow >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "binding"
        other → fail ("expected an unavailable owner, found " <> show other)
      _ ← settle failing
      namespaces steady >>= (`shouldBe` Just [VText "app"])
      -- A later owner is created while the steady one still serves.
      later ← startOwner runtime (ownerSpec fixture "later" ["extra"] requiredPolicy (bounds 8 8))
      namespaces later >>= (`shouldBe` Just [VText "extra"])
      results ← takeMVar client
      forM_ results $ \(_, answered) → answered `shouldBe` Just [VText "app"]
      retireOwner later
      retireOwner steady
