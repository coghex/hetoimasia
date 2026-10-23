{-# LANGUAGE OverloadedStrings #-}

-- | The permanent limits and the temporary pressure: a full identity cache refuses a new module
-- before any work and never allocates a failed entry, request pressure is busy with nothing
-- reserved, and an accepted load that meets a limit fails as a load, with what it completed kept.
module Test.LuaEngine.Modules.Limits (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception (finally)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, void)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (CountLimit (ModuleChainDepth, ModuleIdentitiesPerVm, RequestsPerInstance), Profile)
import Hetoimasia.Scripting.Lua.Loading (LoaderHooks (..), LoaderPlan (..))
import Hetoimasia.Scripting.Lua.Provider (RequestEndpoint (..))
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support
import qualified Test.LuaEngine.Request.Profiles as Profiles

layout ∷ Layout
layout =
  Layout $
    [ (name <> ".lua", Char8.pack ("fx.record('eval " <> name <> "') return { id = '" <> name <> "' }"))
    | name ← ["i1", "i2", "i3", "i4", "d1", "d2", "e3", "g4", "r2"]
    ]
      <> [ ("bad1.lua", "this is not lua")
         , ("bad2.lua", "this is not lua either")
         , ("e1.lua", "local d = import('e2.lua') return { id = 'e1', d = d }")
         , ("e2.lua", "local d = import('e3.lua') return { id = 'e2', d = d }")
         , ("g1.lua", "local d = import('g2.lua') return { id = 'g1', d = d }")
         , ("g2.lua", "local d = import('g3.lua') return { id = 'g2', d = d }")
         , ("g3.lua", "local d = import('g4.lua') return { id = 'g3', d = d }")
         , ("r1.lua", "local d = import('d1.lua') local ok = pcall(import, 'd2.lua') return { id = 'r1', d = d }")
         , ("held.lua", "fx.block('held') local d = import('d1.lua') local ok = pcall(import, 'd2.lua') return { id = 'held', d = d }")
         ]

-- | Three identities, a chain of two.
tiny ∷ Profile
tiny = Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2)]

spec ∷ Spec
spec = describe "limits and pressure" $ do
  cache
  pressure
  loads
  refusals

cache ∷ Spec
cache = describe "the identity cache" $ do
  it "refuses a new module at a full cache before any work, as a catchable limit error, and still joins and answers lookups" $
    withSession tiny (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        closeGate (ssProbe session) "i3.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "i1.lua"))
        command session vm "x" "start" "k2" [] (Just (fetch "i2.lua"))
        command session vm "x" "start" "k3" [] (Just (fetch "i3.lua"))
        awaitNote session "x start k3 started"
        awaitCounts vm (\c → jobsReady c == 2)
        readsBefore ← readsStarted (ssProbe session)
        command session vm "x" "pstart" "k4" [] (Just (fetch "i4.lua"))
        line ← lineStartingWith session "x pstart k4 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"
        -- Nothing was done for it: no read, no entry of any kind, no reservation left behind.
        readsStarted (ssProbe session) >>= (`shouldBe` readsBefore)
        counts' vm >>= \c → (jobsHeld c, jobsFailed c) `shouldBe` (3, 0)
        -- A pending identity is joined, a ready one answered, without a slot of their own.
        command session vm "y" "start" "k3" [] (Just (fetch "i3.lua"))
        awaitNote session "y start k3 started"
        command session vm "y" "start" "k1" [] (Just (fetch "i1.lua"))
        awaitNote session "y start k1 started"
        command session vm "y" "lookup" "k0" [("path", VText "i1.lua")] Nothing
        awaitNote session "y lookup k0 ready #i1.lua"
        counts' vm >>= \c → (jobsHeld c, waitersHeld c) `shouldBe` (3, 2)
        openGate (ssProbe session) "i3.lua"
        awaitCounts vm (\c → jobsReady c == 3)
        -- The cache stays full: nothing is evicted and nothing waits for room.
        command session vm "y" "pstart" "k5" [] (Just (fetch "i4.lua"))
        line' ← lineStartingWith session "y pstart k5 error"
        line' `shouldSatisfy` Text.isInfixOf "module limit"
        readsStarted (ssProbe session) >>= (`shouldBe` 3)

  it "counts failed entries: a cache of failures is as full as one of successes" $
    withSession tiny (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        forM_' ["bad1.lua", "bad2.lua", "i1.lua"] (closeGate (ssProbe session))
        forM_' [("k1", "bad1.lua"), ("k2", "bad2.lua"), ("k3", "i1.lua")] $ \(key, path) →
          command session vm "x" "start" key [] (Just (fetch path))
        awaitNote session "x start k3 started"
        -- The two failing modules fail with nobody waiting.
        forM_' ["k1", "k2"] $ \key → do
          command session vm "x" "cancel" key [] Nothing
          awaitNote session ("x cancel " <> key <> " cancelled")
        forM_' ["bad1.lua", "bad2.lua", "i1.lua"] (openGate (ssProbe session))
        awaitCounts vm (\c → jobsFailed c == 2 && jobsReady c == 1)
        command session vm "x" "pstart" "k4" [] (Just (fetch "i2.lua"))
        line ← lineStartingWith session "x pstart k4 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"
        counts' vm >>= \c → jobsHeld c `shouldBe` 3
        -- A full cache still answers lookups of what it holds, failures included.
        command session vm "x" "lookup" "k0" [("path", VText "bad1.lua")] Nothing
        awaitNote session "x lookup k0 failed module_error #bad1.lua"
        command session vm "x" "lookup" "k0" [("path", VText "i1.lua")] Nothing
        awaitNote session "x lookup k0 ready #i1.lua"
  where
    forM_' items action = mapM_ action items

pressure ∷ Spec
pressure = describe "temporary pressure" $
  it "is busy with nothing reserved: no handle, no read, and no identity taken from the permanent cache" $
    withSession (Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2), (RequestsPerInstance, 1)]) (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        mapM_ (admitDriver session vm) ["x", "y", "z", "w"]
        closeGate (ssProbe session) "i1.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "i1.lua"))
        awaitNote session "x start k1 started"
        -- The instance holds its one place: every further request is busy, however often asked.
        mapM_ (\key → command session vm "x" "start" key [] (Just (fetch "i2.lua"))) ["a", "b", "c"]
        awaitHistory session (\seen → length (filter (Text.isPrefixOf "x start") seen) == 4)
        history session >>= \seen → length (filter (Text.isInfixOf "busy:busy:") seen) `shouldBe` 3
        counts' vm >>= \c → (jobsHeld c, waitersHeld c, promisedHeld c) `shouldBe` (1, 1, 0)
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        -- The permanent cache has two places left, so none was taken by the busy answers.
        command session vm "y" "start" "k2" [] (Just (fetch "i2.lua"))
        command session vm "z" "start" "k3" [] (Just (fetch "i3.lua"))
        awaitNote session "y start k2 started"
        awaitNote session "z start k3 started"
        command session vm "w" "pstart" "k4" [] (Just (fetch "i4.lua"))
        line ← lineStartingWith session "w pstart k4 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"

loads ∷ Spec
loads = describe "an accepted load that meets a limit" $ do
  it "fails when the chain would be one past its depth, with the dependency given no entry and the shorter chain fine" $
    withSession (Profiles.counts [(ModuleChainDepth, 3)]) (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "k1" [] (Just (fetch "e1.lua"))
        awaitCounts vm (\c → jobsReady c == 3)
        command session vm "y" "start" "k2" [] (Just (fetch "g1.lua"))
        failure ← awaitFailure session "y"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "module_limit")
        -- The fourth module was never given a record.
        counts' vm >>= \c → (jobsHeld c, jobsFailed c, jobsReady c) `shouldBe` (6, 3, 3)
        command session vm "x" "lookup" "k0" [("path", VText "g4.lua")] Nothing
        awaitNote session "x lookup k0 not_ready #g4.lua"

  it "fails the chain that discovers the last identity, keeps what it completed, and is not made a success by catching the error" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        admitDriver session vm "z"
        command session vm "x" "start" "k1" [] (Just (fetch "r2.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "y" "start" "k2" [] (Just (fetch "r1.lua"))
        failure ← awaitFailure session "y"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "module_limit")
        -- The module that completed before the limit was met stays cached, and the one that
        -- would have been the fourth has no entry.
        counts' vm >>= \c → (jobsHeld c, jobsReady c, jobsFailed c) `shouldBe` (3, 2, 1)
        command session vm "z" "lookup" "k0" [("path", VText "d2.lua")] Nothing
        awaitNote session "z lookup k0 not_ready #d2.lua"
        readsBefore ← readsStarted (ssProbe session)
        command session vm "z" "start" "k3" [] (Just (fetch "d1.lua"))
        awaitNote session "z start k3 started"
        command session vm "z" "ready" "k3" [] Nothing
        awaitNote session "z ready k3 true"
        readsStarted (ssProbe session) >>= (`shouldBe` readsBefore)

  it "counts the room promised to a boot load against a dependency discovered meanwhile, so the load that was accepted is never the one refused" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "w"
        -- The dependency is cached first, so that the module will not suspend on it: nothing gives the
        -- owner a chance to admit the boot load before the module asks for a second dependency.
        command session vm "w" "start" "k0" [] (Just (fetch "d1.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "x" "start" "k1" [] (Just (fetch "held.lua"))
        awaitGate session "held"
        -- The owner is inside the module: the boot load is accepted from another thread, and its room
        -- is promised before the loader holds a record of it.
        ticket ← bootNow session vm "i1.lua"
        releaseGate session "held"
        failure ← awaitFailure session "x"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "module_limit")
        awaitBootOutcome ticket >>= (`shouldBe` BootReady)
        -- Three identities, none more: the dependency, the module, and the boot load that was promised
        -- the last; the second dependency was refused.
        counts' vm >>= \c → (jobsHeld c, jobsReady c, jobsFailed c) `shouldBe` (3, 2, 1)
        atomically (lookupImmediate (vmCoordinator vm) (moduleIdentity (key' session "d2.lua")))
          >>= \found → case found of
            ImmediateNotReady → pure ()
            _ → expectationFailure "the refused dependency should have no entry"

  it "refuses the dependency, and not the load already accepted, when the load is accepted between the loader's reading of the reserved room and its asking for the source" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime → do
      raced ← newIORef Nothing
      tickets ← newIORef []
      let afterReading plan =
            plan
              { planHooks =
                  (planHooks plan)
                    { hookReserved = \identity → do
                        seen ← hookReserved (planHooks plan) identity
                        -- The window: the room was counted, nothing has asked for the source yet.
                        armed ← readIORef raced
                        case armed of
                          Just act | identity == moduleIdentity (key' session "d2.lua") → do
                            writeIORef raced Nothing
                            act
                          _ → pure ()
                        pure seen
                    }
              }
      withVm session runtime "ui" (defaultOptions OnArrival) {optPlan = afterReading} $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "w"
        command session vm "w" "start" "k0" [] (Just (fetch "d1.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "x" "start" "k1" [] (Just (fetch "held.lua"))
        awaitGate session "held"
        -- Two identities are held (d1 and held) and one place is left: the boot load takes it as the
        -- module asks for its second dependency, which the loader's count still showed room for.
        writeIORef raced (Just (bootNow session vm "i1.lua" >>= \ticket → modifyIORef' tickets (ticket :)))
        releaseGate session "held"
        failure ← awaitFailure session "x"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "module_limit")
        readIORef tickets >>= \accepted → case accepted of
          [ticket] → awaitBootOutcome ticket >>= (`shouldBe` BootReady)
          other → expectationFailure ("expected one boot load, found " <> show (length other))
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)
        atomically (lookupImmediate (vmCoordinator vm) (moduleIdentity (key' session "i1.lua")))
          >>= \found → case found of
            ImmediateReady _ → pure ()
            _ → expectationFailure "the accepted boot load should be ready"

  it "turns the room a request reserved into the boot load's job, so the identity is counted once and the boot join is never refused at the limit" $ do
    gate ← newEmptyMVar
    let holding endpoint = endpoint {endpointSubmit = \submission → readMVar gate >> endpointSubmit endpoint submission}
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) {optWrap = holding} $ \vm →
        -- The gate is opened whatever the example finds, so that a failure of the example is not a
        -- hang of the owner it holds.
        (`finally` void (tryPutMVar gate ())) $ do
          admitDriver session vm "x"
          -- Two identities held, so the third place is the request's alone.
          mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i2.lua", "i3.lua"]
          command session vm "x" "start" "k1" [] (Just (fetch "i1.lua"))
          awaitCounts vm (\c → promisedHeld c == 1)
          -- The boot load of the same identity arrives before the request reaches the endpoint.
          ticket ← bootNow session vm "i1.lua"
          counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)
          putMVar gate ()
          awaitNote session "x start k1 started"
          awaitBootOutcome ticket >>= (`shouldBe` BootReady)
          command session vm "x" "ready" "k1" [] Nothing
          awaitNote session "x ready k1 true"
          counts' vm >>= \c → (jobsHeld c, promisedHeld c, jobsReady c) `shouldBe` (3, 0, 3)
          -- Counted once: a second new module is refused as a full cache.
          command session vm "x" "pstart" "k2" [] (Just (fetch "i4.lua"))
          line ← lineStartingWith session "x pstart k2 error"
          line `shouldSatisfy` Text.isInfixOf "module limit"

  it "refuses the request for good, as an ordinary error and not busy, when a boot load takes the last place between the argument check and the admission" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i2.lua", "i3.lua"]
        -- One place is left, so the check, which reads nothing of the cache, lets the request through. A boot
        -- load of another module takes the place before the admission does: the credit that would have taken
        -- it is the one that says the cache is full for good.
        raced ← newIORef Nothing
        betweenCheckAndAdmission session (bootModule (vmCoordinator vm) (key' session "i1.lua") >>= writeIORef raced . Just . either Just (const Nothing))
        command session vm "x" "pstart" "k1" [] (Just (fetch "i4.lua"))
        line ← lineStartingWith session "x pstart k1 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"
        line `shouldNotSatisfy` Text.isInfixOf "busy"
        readIORef raced >>= (`shouldBe` Just Nothing)
        awaitCounts vm (\c → jobsReady c == 3)
        counts' vm >>= \c → (jobsHeld c, promisedHeld c, waitersHeld c) `shouldBe` (3, 0, 0)
        -- The error was caught and the invocation went on: no handle, job or failed entry was made, and the instance answers.
        command session vm "x" "pstart" "k2" [] (Just (fetch "i1.lua"))
        awaitNote session "x pstart k2 started"

  it "refuses a request for good even when a temporary bank is full in the same transaction: the cache is decided before busy" $
    withSession (Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2), (RequestsPerInstance, 1)]) (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "pstart" "k1" [] (Just (fetch "i1.lua"))
        awaitNote session "x pstart k1 started"
        mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i2.lua", "i3.lua"]
        -- The instance's one place is held and the cache is full for good: a new module is refused, not busy.
        command session vm "x" "pstart" "k2" [] (Just (fetch "i4.lua"))
        line ← lineStartingWith session "x pstart k2 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"
        -- A module the cache holds only needs the request place, which is full: busy.
        command session vm "x" "pstart" "k3" [] (Just (fetch "i2.lua"))
        awaitHistory session (any (Text.isInfixOf "busy:busy:"))
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)

  it "is told busy by a boot load while the last place is only a request's reservation, and refused for good once that place is a permanent entry" $ do
    gate ← newEmptyMVar
    let holding endpoint = endpoint {endpointSubmit = \submission → readMVar gate >> endpointSubmit endpoint submission}
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) {optWrap = holding} $ \vm →
        (`finally` void (tryPutMVar gate ())) $ do
          admitDriver session vm "x"
          mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i2.lua", "i3.lua"]
          command session vm "x" "start" "k1" [] (Just (fetch "i1.lua"))
          awaitCounts vm (\c → promisedHeld c == 1)
          -- The place is held by a reservation the request may still give back: ask again, nothing taken.
          held ← bootModule (vmCoordinator vm) (key' session "i4.lua")
          either (`shouldBe` BootBusy) (const (expectationFailure "a place held only by a reservation should be busy")) held
          counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (2, 1)
          putMVar gate ()
          awaitNote session "x start k1 started"
          -- The request made the place a permanent entry: now the same boot load is refused for good.
          full ← bootModule (vmCoordinator vm) (key' session "i4.lua")
          either (`shouldBe` BootCacheFull) (const (expectationFailure "a full cache should refuse a new boot load")) full
          counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)

  it "keeps a temporarily busy answer busy, whatever another thread does to the identity cache meanwhile" $
    withSession (Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2), (RequestsPerInstance, 1)]) (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "i1.lua"
        command session vm "x" "pstart" "k1" [] (Just (fetch "i1.lua"))
        awaitNote session "x pstart k1 started"
        -- The instance's one place is held, so the next request is busy; the boot load that fills the cache
        -- in between changes nothing about why: the bank is asked first, and waiting could free it.
        betweenCheckAndAdmission session (void (bootNow session vm "i2.lua"))
        command session vm "x" "pstart" "k2" [] (Just (fetch "i1.lua"))
        line ← lineStartingWith session "x pstart k2 busy:"
        line `shouldSatisfy` Text.isInfixOf "busy:busy:"
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (2, 0)

  it "leaves nothing promised when a later check of the same binding rejects after this one passed" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        forM_ ["i1.lua", "i2.lua", "i3.lua", "i4.lua"] $ \path → do
          command session vm "x" "rstart" "kr" [] (Just (fetch path))
          line ← lineStartingWith session "x rstart kr error"
          line `shouldSatisfy` Text.isInfixOf "rejected by a later check"
        -- Four distinct modules were rejected after the check passed, and the cache has its three places.
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (0, 0)
        mapM_ (\path → command session vm "x" "pstart" "k" [] (Just (fetch path)) >> awaitNote session "x pstart k started") ["i1.lua"]
        counts' vm >>= \c → promisedHeld c `shouldBe` 0

-- | Refusals are told apart by what can change: what waiting can fix is busy, with nothing left
-- reserved; what it cannot is a refusal, decided with the reservation it would have taken.
refusals ∷ Spec
refusals = describe "refusals told apart by what can change" $ do
  it "leaves nothing promised when a request is busy on a temporary bank, with or without the argument check" $
    withSession (Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2), (RequestsPerInstance, 1)]) (3, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "i1.lua"
        command session vm "x" "ustart" "k1" [] (Just (fetch "i1.lua"))
        awaitNote session "x ustart k1 started"
        command session vm "x" "ustart" "k2" [] (Just (fetch "i2.lua"))
        awaitHistory session (any (Text.isInfixOf "busy:busy:"))
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (1, 0)

  it "refuses a call that skipped the check at a full cache for good, as the same ordinary error and never busy: the credit decides alone" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i1.lua", "i2.lua", "i3.lua"]
        command session vm "x" "ustart" "k1" [] (Just (fetch "i4.lua"))
        line ← lineStartingWith session "x ustart k1 error"
        line `shouldSatisfy` Text.isInfixOf "module limit"
        line `shouldNotSatisfy` Text.isInfixOf "busy"
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)

  it "refuses a boot load at a full cache for good, and is busy only while boot loads are unsettled, with nothing taken either way" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) {optBootWaiters = 1} $ \vm → do
        closeGate (ssProbe session) "i1.lua"
        first ← bootNow session vm "i1.lua"
        -- One unsettled boot load is all that may be: another is busy, however many places remain.
        busy ← bootModule (vmCoordinator vm) (key' session "i2.lua")
        either (`shouldBe` BootBusy) (const (expectationFailure "a second unsettled boot load should be busy")) busy
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (1, 0)
        openGate (ssProbe session) "i1.lua"
        awaitBootOutcome first >>= (`shouldBe` BootReady)
        mapM_ (\path → bootNow session vm path >>= awaitBootOutcome >>= (`shouldBe` BootReady)) ["i2.lua", "i3.lua"]
        -- The cache is full for good: a new module is refused, one it holds is answered.
        full ← bootModule (vmCoordinator vm) (key' session "i4.lua")
        either (`shouldBe` BootCacheFull) (const (expectationFailure "a full cache should refuse a new boot load")) full
        again ← bootModule (vmCoordinator vm) (key' session "i1.lua")
        either (\refused → expectationFailure ("a held module should be answered, found " <> show refused)) (const (pure ())) again
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (3, 0)

  it "refuses a request at a coordinator that has closed with the same ordinary error the check raises, and takes no place; a call that skipped the check is refused the same way" $
    withSession tiny (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeModuleCoordinator (vmCoordinator vm)
        command session vm "x" "pstart" "k1" [] (Just (fetch "i1.lua"))
        line ← lineStartingWith session "x pstart k1 error"
        line `shouldSatisfy` Text.isInfixOf "stopped"
        line `shouldNotSatisfy` Text.isInfixOf "busy"
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (0, 0)
        command session vm "x" "ustart" "k2" [] (Just (fetch "i1.lua"))
        line' ← lineStartingWith session "x ustart k2 error"
        line' `shouldSatisfy` Text.isInfixOf "stopped"
        counts' vm >>= \c → (jobsHeld c, promisedHeld c) `shouldBe` (0, 0)

counts' ∷ Vm → IO Counts
counts' = counts

lineStartingWith ∷ Session → Text.Text → IO Text.Text
lineStartingWith session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → awaitHistory session (any (Text.isPrefixOf prefix)) >> lineStartingWith session prefix
