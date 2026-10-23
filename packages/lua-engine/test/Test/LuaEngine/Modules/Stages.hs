{-# LANGUAGE OverloadedStrings #-}

-- | The stages a source passes and the numbers a coordinator is made from: a source that arrives
-- before the loader holds a record of its identity, requests made and cancelled over and over, the
-- fixed profile's numbers, and the specifications that are refused.
module Test.LuaEngine.Modules.Stages (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (try)
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (statusReserved))
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (rdOutstanding))
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("a.lua", "fx.record('eval a') return { id = 'a' }")
    , ("b.lua", "fx.record('eval b') return { id = 'b' }")
    , ("bad.lua", "this is not lua")
    ]

spec ∷ Spec
spec = describe "stages and construction" $ do
  stages
  construction

stages ∷ Spec
stages = describe "the stages of a source" $ do
  it "may arrive before the loader holds a record of its identity: the supplier is answered with it, once" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        -- The owner is held inside the request's own hook, so the loader cannot take the root until
        -- the read, running meanwhile on a worker, has finished.
        command session vm "x" "start_block" "k1" [("name", VText "hold")] (Just (fetch "a.lua"))
        awaitGate session "hold"
        awaitFinished (ssProbe session) 1
        awaitCounts vm (\c → bytesOrdinary c > 0)
        evalsOf session >>= (`shouldBe` [])
        releaseGate session "hold"
        awaitCounts vm (\c → jobsReady c == 1)
        evalsOf session >>= (`shouldBe` ["eval a"])
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        awaitCounts vm (\c → bytesOrdinary c == 0)

  it "may be a failure known before the loader holds a record: the load fails as an accepted one" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start_block" "k1" [("name", VText "hold")] (Just (fetch "missing.lua"))
        awaitGate session "hold"
        releaseGate session "hold"
        failure ← awaitFailure session "x"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "not_found")

  it "is not multiplied by a request made and cancelled again and again: one job, no waiter and no place left behind" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "a.lua"
        forM_ [1 .. 30 ∷ Int] $ \n → do
          let key = "k" <> Text.pack (show n)
          command session vm "x" "start" key [] (Just (fetch "a.lua"))
          command session vm "x" "cancel" key [] Nothing
          command session vm "x" "take" key [] Nothing
          awaitNote session ("x take " <> key <> " {status=cancelled}")
        awaitVmDiagnostic vm (\d → rdOutstanding d == 0)
        counts vm >>= \c → (jobsHeld c, waitersHeld c, readsBegun c) `shouldBe` (1, 0, 1)
        openGate (ssProbe session) "a.lua"
        awaitCounts vm (\c → jobsReady c == 1)
        evalsOf session >>= (`shouldBe` ["eval a"])
  where
    evalsOf session = filter (Text.isPrefixOf "eval") <$> history session

construction ∷ Spec
construction = describe "a coordinator" $ do
  it "is made from the fixed profile's numbers: 256 identities, a source of 1 MiB, a bank of 16 MiB with 1 MiB reserved" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        let limits = coordinatorLimits (vmCoordinator vm)
        (limitIdentities limits, limitSourceBytes limits, limitSlots limits, limitBootWaiters limits) `shouldBe` (256, 1048576, 4, 2)
        limitBank limits `shouldBe` BankLimits 16777216 1048576
        _ ← pure runtime
        pure ()

  it "holds its slots from the pool for its life and gives them back when it closes" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime → do
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0
      withVm session runtime "ui" (defaultOptions OnArrival) $ \_ →
        poolReading session >>= \reading → statusReserved reading `shouldBe` 4
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "is refused when the pool cannot hold its slots, taking none of them" $
    withSession fixedM1Profile (2, 3) realReader layout $ \session _ runtime → do
      refused ← try @PoolTooSmall (withVm session runtime "ui" (defaultOptions OnArrival) $ \_ → pure ())
      refused `shouldBe` Left (PoolTooSmall 4)
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "is refused with fewer than two slots, no boot subscription, or a reserve its bank cannot spare" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime → do
      one ← try @ModuleSpecRefused (withVm session runtime "ui" (defaultOptions OnArrival) {optSlots = 1} $ \_ → pure ())
      one `shouldBe` Left (SlotsBelowTwo 1)
      none ← try @ModuleSpecRefused (withVm session runtime "ui" (defaultOptions OnArrival) {optBootWaiters = 0} $ \_ → pure ())
      none `shouldBe` Left (BootWaitersBelowOne 0)
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "is refused when the active chain's reserve is as large as its bank, which would leave prefetch nothing" $
    withSession (withSource 100 200 200) (2, 8) realReader layout $ \session _ runtime → do
      refused ← try @ModuleSpecRefused (withVm session runtime "ui" (defaultOptions OnArrival) $ \_ → pure ())
      refused `shouldBe` Left (ReserveRefused 200 100 200)
      _ ← atomically (pure ())
      pure ()
