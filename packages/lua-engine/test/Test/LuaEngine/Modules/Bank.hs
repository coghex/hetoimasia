{-# LANGUAGE OverloadedStrings #-}

-- | The source bank and the pool slots: prefetch may use only what the reserve leaves, the active
-- chain's next source always has its allowance, reads that do not fit wait among the admitted jobs
-- and never turn acceptance into busy, and the most ever held is read back, not inferred from the
-- work finishing.
module Test.LuaEngine.Modules.Bank (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.List (sort)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (Profile)
import Test.Hspec
import Test.LuaEngine.Modules.Support

-- | A module of exactly this many bytes that records its evaluation and returns its name.
sized ∷ Int → String → ByteString.ByteString
sized total name = body <> Char8.replicate (total - ByteString.length body) ' '
  where
    body = Char8.pack ("fx.record('eval " <> name <> "') return { id = '" <> name <> "' } --")

-- | A module of exactly this many bytes that imports a dependency.
importing ∷ Int → String → String → ByteString.ByteString
importing total name dependency = body <> Char8.replicate (total - ByteString.length body) ' '
  where
    body = Char8.pack ("local d = import('" <> dependency <> "') fx.record('eval " <> name <> "') return { id = '" <> name <> "', d = d } --")

layout ∷ Layout
layout =
  Layout $
    [ (name <> ".lua", sized 100 name) | name ← ["f1", "f2", "f3", "f4", "p1", "p2", "p3", "g1", "g2", "q1", "q2", "dep", "dep2", "r1", "r2"]
    ]
      <> [ ("main.lua", importing 100 "main" "dep.lua")
         , ("early.lua", importing 100 "early" "dep.lua")
         , ("late.lua", sized 100 "late")
         ]

-- | Each byte limit a bank example changes: a module of 100 bytes, a reserve of 100, a bank of 200
-- (so prefetch may hold 100), or whatever the example gives.
budget ∷ Word64 → Word64 → Profile
budget reserveBytes bankBytes = withSource 100 reserveBytes bankBytes

-- | The peaks the coordinator has read back.
peaks ∷ Vm → IO Peaks
peaks vm = peaksSeen <$> counts vm

isInfixOfText ∷ Text.Text → Text.Text → Bool
isInfixOfText = Text.isInfixOf

spec ∷ Spec
spec = describe "the source bank and the slots" $ do
  reserve
  slots
  workers

reserve ∷ Spec
reserve = describe "the reserve for the active chain" $ do
  it "gives the active chain's next source its allowance while unrelated prefetch fills the ordinary region" $
    withSession (budget 100 200) (4, 16) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) {optSlots = 4} $ \vm → do
        admitDriver session vm "x"
        forM_ ["main.lua", "dep.lua", "f1.lua"] (closeGate (ssProbe session))
        command session vm "x" "start" "km" [] (Just (fetch "main.lua"))
        command session vm "x" "start" "k1" [] (Just (fetch "f1.lua"))
        awaitNote session "x start k1 started"
        -- The head's read holds the whole ordinary region: the prefetch waits where it was admitted,
        -- and was accepted, not made busy.
        awaitStarted (ssProbe session) 1
        counts vm >>= \c → (bytesOrdinary c, bytesActive c, readsDeferred c, readsBegun c) `shouldBe` (100, 0, 1, 1)
        openGate (ssProbe session) "main.lua"
        -- The head is compiled and its bytes returned; the prefetch takes the room that frees; the
        -- dependency the head imports is read through the reserve, with the ordinary region full.
        awaitStarted (ssProbe session) 3
        awaitCounts vm (\c → bytesOrdinary c == 100 && bytesActive c == 100)
        counts vm >>= \c → readsDeferred c `shouldBe` 0
        -- The prefetch was started by the head's own sink and the dependency by the owner, a moment
        -- later: two workers may enter the reader in either order, so the pair is read as a set.
        startedPaths (ssProbe session) >>= \paths → (take 1 paths, sort (drop 1 paths)) `shouldBe` (["main.lua"], ["dep.lua", "f1.lua"])
        openGate (ssProbe session) "dep.lua"
        awaitCounts vm (\c → jobsReady c == 2 && bytesActive c == 0)
        history session >>= (`shouldSatisfy` (\seen → "eval dep" `elem` seen && "eval main" `elem` seen))
        openGate (ssProbe session) "f1.lua"
        awaitCounts vm (\c → jobsReady c == 3 && bytesOrdinary c == 0)
        peaks vm >>= \p → (peakTotal p, peakOrdinary p, peakActive p) `shouldBe` (200, 100, 100)
        counts vm >>= \c → slotsFree c `shouldBe` 4

  it "holds sources far ahead of their positions without starving the chain that is due, and starts the rest as room frees" $
    withSession (budget 100 200) (4, 16) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) {optSlots = 4} $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetchAt 3 "early.lua"))
        command session vm "x" "start" "k2" [] (Just (fetchAt 8 "late.lua"))
        awaitNote session "x start k2 started"
        -- The first source is read and held for its tick, filling the ordinary region; the second
        -- waits for room, accepted.
        awaitFinished (ssProbe session) 1
        counts vm >>= \c → (bytesOrdinary c, readsDeferred c, readsBegun c) `shouldBe` (100, 1, 1)
        forM_ [1, 2 ∷ Int] (const (grantOne control vm))
        -- Tick three is held for the first; its dependency is read through the reserve.
        awaitCounts vm (\c → jobsReady c == 2)
        peaks vm >>= \p → (peakTotal p <= 200, peakOrdinary p <= 100, peakActive p <= 100) `shouldBe` (True, True, True)
        awaitFinished (ssProbe session) 3
        awaitCounts vm (\c → readsDeferred c == 0 && bytesOrdinary c == 100)
        forM_ [3 .. 7 ∷ Int] (const (grantOne control vm))
        awaitCounts vm (\c → jobsReady c == 3)
        grantOne control vm
        command session vm "x" "take" "k1" [] Nothing
        awaitNote session "x take k1 {status=success,value=table(early)}"
        command session vm "x" "take" "k2" [] Nothing
        awaitNote session "x take k2 {status=success,value=table(late)}"
        awaitCounts vm (\c → bytesOrdinary c == 0 && bytesActive c == 0)

  it "fails a source over the module limit, or absent, as an accepted load without reserving a byte or starting a read" $
    withSession (budget 100 200) (2, 8) realReader bigLayout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        admitDriver session vm "w"
        command session vm "x" "start" "k1" [] (Just (fetch "big.lua"))
        command session vm "y" "start" "k2" [] (Just (fetch "missing.lua"))
        xFailure ← awaitFailure session "x"
        yFailure ← awaitFailure session "y"
        fmap snd (requestFailureOf xFailure) `shouldSatisfy` maybe False (isInfix "too_large")
        fmap snd (requestFailureOf yFailure) `shouldSatisfy` maybe False (isInfix "not_found")
        readsStarted (ssProbe session) >>= (`shouldBe` 0)
        peaks vm >>= \p → (peakTotal p, peakSlots p) `shouldBe` (0, 0)
        counts vm >>= \c → (jobsFailed c, bytesOrdinary c, bytesActive c) `shouldBe` (2, 0, 0)
        -- A module of exactly the limit is read.
        command session vm "w" "start" "k3" [] (Just (fetch "exact.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
  where
    bigLayout =
      Layout
        [ ("big.lua", sized 101 "big")
        , ("exact.lua", sized 100 "exact")
        ]
    isInfix needle text = needle `isInfixOfText` text

slots ∷ Spec
slots = describe "the slots the coordinator holds" $
  it "leaves the last slot to the active chain, so prefetch cannot occupy every read the chain could need" $
    withSession (budget 100 1000) (2, 16) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) {optSlots = 2} $ \vm → do
        admitDriver session vm "x"
        forM_ ["main.lua", "p1.lua", "dep.lua"] (closeGate (ssProbe session))
        command session vm "x" "start" "km" [] (Just (fetch "main.lua"))
        command session vm "x" "start" "k1" [] (Just (fetch "p1.lua"))
        command session vm "x" "start" "k2" [] (Just (fetch "p2.lua"))
        awaitNote session "x start k2 started"
        -- One slot is in use by the head's read; prefetch may not take the last, so both wait,
        -- accepted.
        awaitStarted (ssProbe session) 1
        counts vm >>= \c → (slotsFree c, readsDeferred c, readsBegun c) `shouldBe` (1, 2, 1)
        openGate (ssProbe session) "main.lua"
        -- The head's slot comes back and the first prefetch takes it; the head, compiled, imports a
        -- dependency, which takes the last: the second prefetch waits.
        awaitStarted (ssProbe session) 3
        awaitCounts vm (\c → bytesActive c == 100 && slotsFree c == 0)
        counts vm >>= \c → readsDeferred c `shouldBe` 1
        startedPaths (ssProbe session) >>= \paths → (take 1 paths, sort (drop 1 paths)) `shouldBe` (["main.lua"], ["dep.lua", "p1.lua"])
        openGate (ssProbe session) "dep.lua"
        openGate (ssProbe session) "p1.lua"
        awaitCounts vm (\c → jobsReady c == 4)
        peaks vm >>= \p → peakSlots p `shouldBe` 2
        counts vm >>= \c → slotsFree c `shouldBe` 2

workers ∷ Spec
workers = describe "the pool's workers" $
  it "reads a head root and then a dependency ahead of older unrelated prefetch queued behind busy workers" $
    withSession (budget 100 1000) (2, 16) realReader layout $ \session _ runtime →
      withVm session runtime "chain" (defaultOptions OnArrival) $ \vm →
        withVm session runtime "neighbour" (defaultOptions OnArrival) $ \other → do
          admitDriver session vm "x"
          admitDriver session other "o"
          forM_ ["g1.lua", "g2.lua", "q1.lua"] (closeGate (ssProbe session))
          -- The neighbour's reads occupy both workers, and an older read of its own waits behind them.
          command session other "o" "start" "kg1" [] (Just (fetch "g1.lua"))
          command session other "o" "start" "kg2" [] (Just (fetch "g2.lua"))
          awaitStarted (ssProbe session) 2
          command session other "o" "start" "kq1" [] (Just (fetch "q1.lua"))
          awaitNote session "o start kq1 started"
          command session vm "x" "start" "km" [] (Just (fetch "main.lua"))
          awaitNote session "x start km started"
          command session other "o" "start" "kq2" [] (Just (fetch "q2.lua"))
          awaitNote session "o start kq2 started"
          command session vm "x" "start" "kd" [] (Just (fetch "dep.lua"))
          awaitNote session "x start kd started"
          maxActive (ssProbe session) >>= (`shouldBe` 2)
          -- The chain waits for its head's source: that read, queued behind older prefetch, goes
          -- first when a worker frees.
          awaitCounts vm (\c → jobsNeeded c == 1)
          openGate (ssProbe session) "g1.lua"
          awaitStarted (ssProbe session) 4
          startedPaths (ssProbe session) >>= (`shouldBe` ["g1.lua", "g2.lua", "main.lua", "q1.lua"])
          -- The head imports the dependency, which is queued behind another neighbour read: it is
          -- the chain's next source now, and goes before it.
          awaitCounts vm (\c → jobsNeeded c == 2)
          openGate (ssProbe session) "g2.lua"
          awaitCounts vm (\c → jobsReady c == 2)
          startedPaths (ssProbe session) >>= (`shouldSatisfy` (\paths → take 5 paths == ["g1.lua", "g2.lua", "main.lua", "q1.lua", "dep.lua"]))
          maxActive (ssProbe session) >>= (`shouldBe` 2)
          openGate (ssProbe session) "q1.lua"
          awaitCounts other (\c → jobsReady c == 4)
