{-# LANGUAGE OverloadedStrings #-}

-- | The permanent limits and the temporary pressure: a full identity cache refuses a new module
-- before any work and never allocates a failed entry, request pressure is busy with nothing
-- reserved, and an accepted load that meets a limit fails as a load, with what it completed kept.
module Test.LuaEngine.Modules.Limits (spec) where

import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (CountLimit (ModuleChainDepth, ModuleIdentitiesPerVm, RequestsPerInstance), Profile)
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
         ]

-- | Three identities, a chain of two.
tiny ∷ Profile
tiny = Profiles.counts [(ModuleIdentitiesPerVm, 3), (ModuleChainDepth, 2)]

spec ∷ Spec
spec = describe "limits and pressure" $ do
  cache
  pressure
  loads

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
        counts' vm >>= \c → (jobsHeld c, waitersHeld c) `shouldBe` (1, 1)
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

counts' ∷ Vm → IO Counts
counts' = counts

lineStartingWith ∷ Session → Text.Text → IO Text.Text
lineStartingWith session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → awaitHistory session (any (Text.isPrefixOf prefix)) >> lineStartingWith session prefix
