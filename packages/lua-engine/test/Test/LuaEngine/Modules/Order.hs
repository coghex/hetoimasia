{-# LANGUAGE OverloadedStrings #-}

-- | The order independent roots evaluate in, and what has to be true before one may: the order they
-- were admitted in or placed at, never the order their sources arrived in; hooks and stop served
-- while a loader waits; an independent VM unaffected.
module Test.LuaEngine.Modules.Order (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("u1.lua", "fx.record('eval u1') return { id = 'u1' }")
    , ("u2.lua", "fx.record('eval u2') return { id = 'u2' }")
    , ("u3.lua", "fx.record('eval u3') return { id = 'u3' }")
    , ("l1.lua", "fx.record('eval l1') return { id = 'l1' }")
    , ("l2.lua", "fx.record('eval l2') return { id = 'l2' }")
    , ("late.lua", "fx.record('eval late') return { id = 'late' }")
    , ("bad.lua", "this is not lua")
    ]

evalsOf ∷ Session → IO [Text.Text]
evalsOf session = filter (Text.isPrefixOf "eval") <$> history session

spec ∷ Spec
spec = describe "evaluation order" $ do
  describe "on an owner that settles on arrival" $ do
    it "follows request admission, not the order sources arrive in, and exposes nothing before its turn" $
      withSession fixedM1Profile (3, 8) realReader layout $ \session _ runtime →
        withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
          admitDriver session vm "x"
          closeGate (ssProbe session) "u1.lua"
          closeGate (ssProbe session) "u2.lua"
          command session vm "x" "start" "k1" [] (Just (fetch "u1.lua"))
          command session vm "x" "start" "k2" [] (Just (fetch "u2.lua"))
          command session vm "x" "start" "k3" [] (Just (fetch "u3.lua"))
          awaitNote session "x start k3 started"
          -- The last source arrives first; nothing is evaluated, and nothing is settled.
          awaitFinished (ssProbe session) 1
          finishedPaths (ssProbe session) >>= (`shouldBe` ["u3.lua"])
          command session vm "x" "ready" "k3" [] Nothing
          awaitNote session "x ready k3 false"
          evalsOf session >>= (`shouldBe` [])
          openGate (ssProbe session) "u2.lua"
          awaitFinished (ssProbe session) 2
          command session vm "x" "ready" "k2" [] Nothing
          awaitNote session "x ready k2 false"
          evalsOf session >>= (`shouldBe` [])
          openGate (ssProbe session) "u1.lua"
          awaitCounts vm (\c → jobsReady c == 3)
          evalsOf session >>= (`shouldBe` ["eval u1", "eval u2", "eval u3"])
          finishedPaths (ssProbe session) >>= (`shouldBe` ["u3.lua", "u2.lua", "u1.lua"])

    it "serves hooks and stop while the loader waits for a source, and another VM goes on" $
      withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
        withVm session runtime "waiting" (defaultOptions OnArrival) $ \vm →
          withVm session runtime "free" (defaultOptions OnArrival) $ \other → do
            admitDriver session vm "x"
            admitDriver session vm "z"
            admitDriver session other "o"
            closeGate (ssProbe session) "u1.lua"
            command session vm "x" "start" "k1" [] (Just (fetch "u1.lua"))
            awaitNote session "x start k1 started"
            awaitStarted (ssProbe session) 1
            -- A hook runs on the waiting VM.
            command session vm "z" "lookup" "k0" [("path", VText "u1.lua")] Nothing
            awaitNote session "z lookup k0 not_ready #u1.lua"
            -- The other VM loads a module through the same pool meanwhile.
            command session other "o" "start" "k9" [] (Just (fetch "u2.lua"))
            awaitNote session "o start k9 started"
            awaitCounts other (\c → jobsReady c == 1)
            command session other "o" "settled_take" "k9" [] Nothing
            awaitNote session "o take k9 {status=success,value=table(u2)}"
            -- The waiting VM's stop is served: its instance shuts down while the source is held.
            stopInstance session vm "z"
            awaitNote session "shutdown stopped"
            counts vm >>= \c → (jobsLive c, jobsReady c) `shouldBe` (1, 0)
            openGate (ssProbe session) "u1.lua"
            awaitCounts vm (\c → jobsReady c == 1)

  describe "on an owner that settles at assigned ticks" $ do
    it "does not let a later ready root overtake an earlier one that waits for its source" $
      withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
        withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
          admitDriver session vm "x"
          closeGate (ssProbe session) "l1.lua"
          command session vm "x" "start" "k1" [] (Just (fetchAt 3 "l1.lua"))
          command session vm "x" "start" "k2" [] (Just (fetchAt 3 "l2.lua"))
          awaitNote session "x start k2 started"
          awaitFinished (ssProbe session) 1
          finishedPaths (ssProbe session) >>= (`shouldBe` ["l2.lua"])
          forM_ [1, 2 ∷ Int] (const (grantOne control vm))
          -- Tick three is held for the first, whose source has not arrived; the second, ready and
          -- due at the same tick, waits behind it.
          grantStep vm
          evalsOf session >>= (`shouldBe` [])
          tickOf vm >>= (`shouldBe` 2)
          openGate (ssProbe session) "l1.lua"
          awaitTick control vm 3
          evalsOf session >>= (`shouldBe` ["eval l1", "eval l2"])

    it "starts nothing and exposes nothing when a source arrives, only at the position's boundary" $
      withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
        withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
          admitDriver session vm "x"
          admitDriver session vm "y"
          command session vm "x" "start" "k1" [] (Just (fetchAt 5 "late.lua"))
          command session vm "y" "start" "k2" [] (Just (fetchAt 5 "bad.lua"))
          awaitNote session "x start k1 started"
          awaitNote session "y start k2 started"
          awaitFinished (ssProbe session) 2
          forM_ [1 .. 3 ∷ Int] (const (grantOne control vm))
          evalsOf session >>= (`shouldBe` [])
          counts vm >>= \c → (jobsLive c, jobsReady c, jobsFailed c) `shouldBe` (2, 0, 0)
          command session vm "x" "ready" "k1" [] Nothing
          awaitNote session "x ready k1 false"
          grantOne control vm
          -- Everything before tick five has finished: both roots are evaluated, the failing one
          -- fails its own request only when its tick is served.
          awaitCounts vm (\c → jobsReady c == 1 && jobsFailed c == 1)
          tickOf vm >>= (`shouldBe` 4)
          grantOne control vm
          failure ← awaitFailure session "y"
          fmap fst (requestFailureOf failure) `shouldBe` Just "module"
          command session vm "x" "take" "k1" [] Nothing
          awaitNote session "x take k1 {status=success,value=table(late)}"
