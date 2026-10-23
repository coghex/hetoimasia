{-# LANGUAGE OverloadedStrings #-}

-- | A dependency that is also requested at a later position: evaluated once, within the importer's
-- chain, at the importer's position, while its own request is answered at its own.
module Test.LuaEngine.Modules.Promotion (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("a.lua", "local b = import('b.lua') fx.record('eval a') fx.block('a') return { id = 'a', b = b }")
    , ("b.lua", "fx.record('eval b') return { id = 'b' }")
    , ("fa.lua", "local fb = import('fb.lua') fx.record('eval fa') return { id = 'fa' }")
    , ("fb.lua", "fx.record('eval fb') error('fb broke')")
    , ("ua.lua", "local ub = import('ub.lua') fx.record('eval ua') return { id = 'ua', ub = ub }")
    , ("ub.lua", "fx.record('eval ub') return { id = 'ub' }")
    , ("chain1.lua", "local d = import('chain2.lua') fx.record('eval chain1') return { id = 'chain1', d = d }")
    , ("chain2.lua", "local d = import('chain3.lua') fx.record('eval chain2') return { id = 'chain2', d = d }")
    , ("chain3.lua", "local d = import('chain4.lua') fx.record('eval chain3') return { id = 'chain3', d = d }")
    , ("chain4.lua", "fx.record('eval chain4') return { id = 'chain4' }")
    , ("top.lua", "local l = import('left.lua') local r = import('right.lua') fx.record('eval top') return { id = 'top', l = l, r = r }")
    , ("left.lua", "local base = import('base.lua') fx.record('eval left') return { id = 'left', base = base }")
    , ("right.lua", "local base = import('base.lua') fx.record('eval right') return { id = 'right', base = base }")
    , ("base.lua", "fx.record('eval base') return { id = 'base' }")
    , ("main.lua", "local dep = import('dep.lua') fx.record('eval main') return { id = 'main', dep = dep }")
    , ("dep.lua", "fx.record('eval dep') return { id = 'dep' }")
    , ("cyc_a.lua", "local b = import('cyc_b.lua') fx.record('eval cyc_a') return { id = 'cyc_a' }")
    , ("cyc_b.lua", "local a = import('cyc_a.lua') fx.record('eval cyc_b') return { id = 'cyc_b' }")
    ]

evalsOf ∷ Session → IO [Text.Text]
evalsOf session = filter (Text.isPrefixOf "eval") <$> history session

spec ∷ Spec
spec = describe "a dependency requested for a later position" $ do
  it "is evaluated once at the importer's position, before its tick begins, while its own request waits for its own" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "ka" [] (Just (fetchAt 10 "a.lua"))
        command session vm "y" "start" "kb" [] (Just (fetchAt 12 "b.lua"))
        awaitNote session "x start ka started"
        awaitNote session "y start kb started"
        -- Both sources arrive at once; nothing is evaluated for want of a turn.
        awaitFinished (ssProbe session) 2
        history session >>= (`shouldSatisfy` all (not . Text.isPrefixOf "eval"))
        forM_ [1 .. 9 ∷ Int] (const (grantOne control vm))
        tickOf vm >>= (`shouldBe` 9)
        -- Tick nine is finished and tick ten has not begun: the importer's chain runs now, inside a
        -- module that holds the owner, and the dependency was evaluated within it, once.
        awaitGate session "a"
        tickOf vm >>= (`shouldBe` 9)
        history session >>= (`shouldBe` ["x start ka started", "y start kb started", "eval b", "eval a"])
        -- The next grant would reach tick ten, which the unfinished job holds.
        grantStep vm
        tickOf vm >>= (`shouldBe` 9)
        releaseGate session "a"
        awaitTick control vm 10
        -- At tick ten the importer's request is answered; the dependency's is not, though its
        -- cache is complete.
        command session vm "x" "ready" "ka" [] Nothing
        awaitNote session "x ready ka true"
        command session vm "x" "lookup" "ka" [("path", VText "b.lua")] Nothing
        awaitNote session "x lookup ka ready #b.lua"
        command session vm "y" "ready" "kb" [] Nothing
        awaitNote session "y ready kb false"
        countNotes session "eval b" >>= (`shouldBe` 1)
        grantOne control vm
        grantOne control vm
        command session vm "y" "take" "kb" [] Nothing
        awaitNote session "y take kb {status=success,value=table(b)}"
        countNotes session "eval b" >>= (`shouldBe` 1)
        readsStarted (ssProbe session) >>= (`shouldBe` 2)

  it "fails the importer at its position and the dependency's own request only at the dependency's" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 4 "fa.lua"))
        command session vm "y" "start" "ky" [] (Just (fetchAt 6 "fb.lua"))
        awaitNote session "x start kx started"
        awaitNote session "y start ky started"
        forM_ [1 .. 3 ∷ Int] (const (grantOne control vm))
        awaitCounts vm (\c → jobsFailed c == 2)
        evalsOf session >>= (`shouldBe` ["eval fb"])
        grantOne control vm
        xFailure ← awaitFailure session "x"
        fmap fst (requestFailureOf xFailure) `shouldBe` Just "module"
        -- The dependency's own request is healthy until its own tick.
        command session vm "y" "ready" "ky" [] Nothing
        awaitNote session "y ready ky false"
        command session vm "y" "lookup" "k0" [("path", VText "fb.lua")] Nothing
        awaitNote session "y lookup k0 failed module_error #fb.lua"
        grantOne control vm
        grantOne control vm
        yFailure ← awaitFailure session "y"
        fmap fst (requestFailureOf yFailure) `shouldBe` Just "module"
        countNotes session "eval fb" >>= (`shouldBe` 1)

  it "settles a presentation request for a dependency when its outcome is published, after one evaluation" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        closeGate (ssProbe session) "ub.lua"
        command session vm "x" "start" "ka" [] (Just (fetch "ua.lua"))
        command session vm "y" "start" "kb" [] (Just (fetch "ub.lua"))
        awaitNote session "x start ka started"
        awaitNote session "y start kb started"
        awaitStarted (ssProbe session) 2
        command session vm "y" "ready" "kb" [] Nothing
        awaitNote session "y ready kb false"
        openGate (ssProbe session) "ub.lua"
        awaitCounts vm (\c → jobsReady c == 2)
        evalsOf session >>= (`shouldBe` ["eval ub", "eval ua"])
        command session vm "y" "settled_take" "kb" [] Nothing
        awaitNote session "y take kb {status=success,value=table(ub)}"
        command session vm "x" "settled_take" "ka" [] Nothing
        awaitNote session "x take ka {status=success,value=table(ua)}"
        readsStarted (ssProbe session) >>= (`shouldBe` 2)

  it "fails a presentation request for a dependency that failed, when the failure is published" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "ka" [] (Just (fetch "fa.lua"))
        command session vm "y" "start" "kb" [] (Just (fetch "fb.lua"))
        xFailure ← awaitFailure session "x"
        fmap fst (requestFailureOf xFailure) `shouldBe` Just "module"
        yFailure ← awaitFailure session "y"
        fmap fst (requestFailureOf yFailure) `shouldBe` Just "module"
        countNotes session "eval fb" >>= (`shouldBe` 1)

  it "evaluates a longer chain depth first in Lua's call order, and a shared base once" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "chain1.lua"))
        command session vm "x" "start" "k2" [] (Just (fetch "top.lua"))
        awaitCounts vm (\c → jobsReady c == 8)
        evalsOf session
          >>= ( `shouldBe`
                  [ "eval chain4", "eval chain3", "eval chain2", "eval chain1"
                  , "eval base", "eval left", "eval right", "eval top"
                  ]
              )

  it "reuses a dependency that is already queued as a root, without a second read" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "dep.lua"
        command session vm "x" "start" "kd" [] (Just (fetch "dep.lua"))
        command session vm "x" "start" "km" [] (Just (fetch "main.lua"))
        awaitNote session "x start km started"
        awaitFinished (ssProbe session) 1
        finishedPaths (ssProbe session) >>= (`shouldBe` ["main.lua"])
        openGate (ssProbe session) "dep.lua"
        awaitCounts vm (\c → jobsReady c == 2)
        evalsOf session >>= (`shouldBe` ["eval dep", "eval main"])
        readsStarted (ssProbe session) >>= (`shouldBe` 2)

  it "rejects a cycle with its chain, leaves no partial export, and fails every module in it" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "cyc_a.lua"))
        failure ← awaitFailure session "x"
        case requestFailureOf failure of
          Just (endpoint, why) → do
            endpoint `shouldBe` "module"
            why `shouldSatisfy` Text.isInfixOf "module_cycle"
          Nothing → expectationFailure ("expected a request failure, found " <> show failure)
        counts vm >>= \c → (jobsFailed c, jobsReady c) `shouldBe` (2, 0)
        evalsOf session >>= (`shouldBe` [])
