{-# LANGUAGE OverloadedStrings #-}

-- | Waiters come and go and a job does not: a position once contributed is kept, a job nobody waits
-- for finishes and is cached, a failure is each request's own at its own position, and the boot
-- phase has no tick.
module Test.LuaEngine.Modules.Positions (spec) where

import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Loading (LoaderHooks (hookObserved), LoaderPlan (planHooks), noLoaderHooks)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (rdOutstanding))
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("m.lua", "fx.record('eval m') fx.block('m') return { id = 'm' }")
    , ("plain.lua", "fx.record('eval plain') return { id = 'plain' }")
    , ("bad.lua", "this is not lua")
    , ("util.lua", "return { id = 'util', lookup = function(p) return import(p) end }")
    , ("first.lua", "local second = import('second.lua') return { id = 'first', second = second }")
    , ("second.lua", "return { id = 'second' }")
    , ("broken_first.lua", "local second = import('broken_second.lua') return { id = 'broken_first' }")
    , ("broken_second.lua", "error('second is broken')")
    , (Char8.unpack (longName "1.lua"), "this is not lua")
    , (Char8.unpack (longName "2.lua"), "this is not lua")
    , ("imp_one.lua", "local d = import('" <> longName "1.lua" <> "') return { id = 'one', d = d }")
    , ("imp_two.lua", "local d = import('" <> longName "2.lua" <> "') return { id = 'two', d = d }")
    ]

-- | Two paths whose labels are the same once the diagnostic label's bound has cut them: they share
-- 144 bytes, in segments within the path's own bound. Both files are the same broken source, so each import fails with an equal fault.
longName ∷ ByteString → ByteString
longName suffix = Char8.concat (replicate 4 (Char8.replicate 35 'a' <> "/")) <> suffix

spec ∷ Spec
spec = describe "positions and waiters" $ do
  earliest
  noWaiters
  failures
  boot

earliest ∷ Spec
earliest = describe "the earliest position a request contributed" $ do
  it "is kept when the waiter that contributed it cancels: evaluation stays due then, and the other waiter still gets its own result" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 12 "m.lua"))
        command session vm "y" "start" "ky" [] (Just (fetchAt 10 "m.lua"))
        awaitNote session "x start kx started"
        awaitNote session "y start ky started"
        counts vm >>= \c → (jobsHeld c, waitersHeld c) `shouldBe` (1, 2)
        command session vm "y" "cancel" "ky" [] Nothing
        awaitNote session "y cancel ky cancelled"
        counts vm >>= \c → (jobsHeld c, waitersHeld c) `shouldBe` (1, 1)
        forM_ [1 .. 9 ∷ Int] (const (grantOne control vm))
        -- The job is evaluated at tick ten's boundary, which only the cancelled waiter's position
        -- put it at.
        awaitGate session "m"
        tickOf vm >>= (`shouldBe` 9)
        releaseGate session "m"
        grantOne control vm
        command session vm "y" "take" "ky" [] Nothing
        awaitNote session "y take ky {status=cancelled}"
        command session vm "x" "ready" "kx" [] Nothing
        awaitNote session "x ready kx false"
        grantOne control vm
        grantOne control vm
        command session vm "x" "take" "kx" [] Nothing
        awaitNote session "x take kx {status=success,value=table(m)}"
        countNotes session "eval m" >>= (`shouldBe` 1)
        readsStarted (ssProbe session) >>= (`shouldBe` 1)

  it "is kept when the instance that contributed it ends: evaluation stays due then, and the request of the instance that remains is answered at its own" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 12 "m.lua"))
        command session vm "y" "start" "ky" [] (Just (fetchAt 10 "m.lua"))
        awaitNote session "x start kx started"
        awaitNote session "y start ky started"
        stopInstance session vm "y"
        awaitCounts vm (\c → waitersHeld c == 1)
        forM_ [1 .. 9 ∷ Int] (const (grantOne control vm))
        awaitGate session "m"
        tickOf vm >>= (`shouldBe` 9)
        releaseGate session "m"
        grantOne control vm
        grantOne control vm
        grantOne control vm
        command session vm "x" "take" "kx" [] Nothing
        awaitNote session "x take kx {status=success,value=table(m)}"
        countNotes session "eval m" >>= (`shouldBe` 1)

  it "is not moved later by a waiter that asks for a later position after the one that set it cancelled" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 5 "m.lua"))
        command session vm "x" "cancel" "kx" [] Nothing
        awaitNote session "x cancel kx cancelled"
        command session vm "y" "start" "ky" [] (Just (fetchAt 9 "m.lua"))
        awaitNote session "y start ky started"
        forM_ [1 .. 4 ∷ Int] (const (grantOne control vm))
        awaitGate session "m"
        tickOf vm >>= (`shouldBe` 4)
        releaseGate session "m"

  it "orders independent roots by tick and sequence whatever order they were admitted in, and an earlier request moves a queued job up" $
    withSession fixedM1Profile (2, 8) realReader orderLayout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        -- Admitted late first, early last; "p" is promoted from the third place to the first.
        command session vm "x" "start" "kp" [] (Just (fetchAt 6 "p.lua"))
        command session vm "x" "start" "kq" [] (Just (fetchAt 4 "q.lua"))
        command session vm "x" "start" "kr" [] (Just (fetchAt 4 "r.lua"))
        awaitNote session "x start kr started"
        awaitFinished (ssProbe session) 3
        command session vm "x" "start" "kp2" [] (Just (fetchAt 2 "p.lua"))
        awaitNote session "x start kp2 started"
        counts vm >>= \c → (jobsHeld c, waitersHeld c) `shouldBe` (3, 4)
        forM_ [1 .. 5 ∷ Int] (const (grantOne control vm))
        history session >>= \seen → filter (Text.isPrefixOf "eval") seen `shouldBe` ["eval p", "eval q", "eval r"]
  where
    orderLayout =
      Layout
        [ ("p.lua", "fx.record('eval p') return { id = 'p' }")
        , ("q.lua", "fx.record('eval q') return { id = 'q' }")
        , ("r.lua", "fx.record('eval r') return { id = 'r' }")
        ]

noWaiters ∷ Spec
noWaiters = describe "a job nobody waits for" $ do
  it "finishes and is cached when every waiter has cancelled and taken its cancellation, and a later request uses that outcome" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "plain.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "plain.lua"))
        awaitNote session "x start k1 started"
        awaitStarted (ssProbe session) 1
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 cancelled"
        command session vm "x" "take" "k1" [] Nothing
        awaitNote session "x take k1 {status=cancelled}"
        -- The request's place is given back; the job, which nothing waits for, is not.
        awaitVmDiagnostic vm (\d → rdOutstanding d == 0)
        counts vm >>= \c → (jobsHeld c, jobsLive c, waitersHeld c) `shouldBe` (1, 1, 0)
        openGate (ssProbe session) "plain.lua"
        awaitCounts vm (\c → jobsReady c == 1)
        countNotes session "eval plain" >>= (`shouldBe` 1)
        command session vm "x" "start" "k2" [] (Just (fetch "plain.lua"))
        awaitNote session "x start k2 started"
        command session vm "x" "ready" "k2" [] Nothing
        awaitNote session "x ready k2 true"
        command session vm "x" "take" "k2" [] Nothing
        awaitNote session "x take k2 {status=success,value=table(plain)}"
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        countNotes session "eval plain" >>= (`shouldBe` 1)

  it "cannot be withdrawn from a request already answered: the cancel finds it settled, and the result is still the request's to take" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "plain.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 already_settled"
        command session vm "x" "take" "k1" [] Nothing
        awaitNote session "x take k1 {status=success,value=table(plain)}"

  it "holds its retained position on a logical owner with no waiter left, and finishes there" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetchAt 5 "m.lua"))
        awaitNote session "x start k1 started"
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 cancelled"
        command session vm "x" "take" "k1" [] Nothing
        awaitNote session "x take k1 {status=cancelled}"
        awaitVmDiagnostic vm (\d → rdOutstanding d == 0)
        forM_ [1 .. 4 ∷ Int] (const (grantOne control vm))
        awaitGate session "m"
        tickOf vm >>= (`shouldBe` 4)
        -- Tick five does not begin while the job holds it.
        grantStep vm
        tickOf vm >>= (`shouldBe` 4)
        releaseGate session "m"
        awaitTick control vm 5
        -- A request made now is delivered at its own position, from the cache.
        command session vm "x" "start" "k2" [] (Just (fetch "m.lua"))
        awaitNote session "x start k2 started"
        command session vm "x" "ready" "k2" [] Nothing
        awaitNote session "x ready k2 false"
        grantOne control vm
        command session vm "x" "ready" "k2" [] Nothing
        awaitNote session "x ready k2 true"
        readsStarted (ssProbe session) >>= (`shouldBe` 1)

  it "records one bounded diagnostic for a failure, fails no instance, and leaves the failure to a later request" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        closeGate (ssProbe session) "bad.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "bad.lua"))
        awaitNote session "x start k1 started"
        awaitStarted (ssProbe session) 1
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 cancelled"
        openGate (ssProbe session) "bad.lua"
        awaitCounts vm (\c → jobsFailed c == 1)
        awaitDiagnostics session 1
        diagnostics session >>= \seen → length seen `shouldBe` 1
        diagnostics session >>= \seen → seen `shouldSatisfy` all (\line → "code=module_error" `Text.isInfixOf` line && "path=bad.lua" `Text.isInfixOf` line)
        -- The instance that cancelled is healthy.
        command session vm "x" "lookup" "k0" [("path", VText "bad.lua")] Nothing
        awaitNote session "x lookup k0 failed module_error #bad.lua"
        -- A later request meets the cached failure as its own, and the diagnostic is not repeated.
        command session vm "y" "start" "k2" [] (Just (fetch "bad.lua"))
        failure ← awaitFailure session "y"
        fmap fst (requestFailureOf failure) `shouldBe` Just "module"
        -- The decision was taken once, with the outcome; the one diagnostic was written before this.
        counts vm >>= \c → jobsDiagnosed c `shouldBe` 1
        diagnostics session >>= \seen → length seen `shouldBe` 1
        readsStarted (ssProbe session) >>= (`shouldBe` 1)

failures ∷ Spec
failures = describe "a required failure" $ do
  it "is each request's own, at its own position, even when it is never read" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 3 "bad.lua"))
        command session vm "y" "start" "ky" [] (Just (fetchAt 6 "bad.lua"))
        awaitNote session "x start kx started"
        awaitNote session "y start ky started"
        grantOne control vm
        grantOne control vm
        -- The job fails before tick three begins; neither request is due.
        awaitCounts vm (\c → jobsFailed c == 1)
        tickOf vm >>= (`shouldBe` 2)
        -- Requests wait for the job: no diagnostic was decided, so none can be written.
        counts vm >>= \c → jobsDiagnosed c `shouldBe` 0
        diagnostics session >>= (`shouldBe` [])
        grantOne control vm
        xFailure ← awaitFailure session "x"
        fmap fst (requestFailureOf xFailure) `shouldBe` Just "module"
        -- The other request is still pending: it fails at its own position.
        command session vm "y" "ready" "ky" [] Nothing
        awaitNote session "y ready ky false"
        forM_ [4 .. 6 ∷ Int] (const (grantOne control vm))
        yFailure ← awaitFailure session "y"
        fmap fst (requestFailureOf yFailure) `shouldBe` Just "module"

  it "is not delivered to a request cancelled before its position, though the failure was held for it from the moment it came" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "kx" [] (Just (fetchAt 3 "broken_first.lua"))
        command session vm "y" "start" "ky" [] (Just (fetchAt 6 "broken_second.lua"))
        awaitNote session "x start kx started"
        awaitNote session "y start ky started"
        forM_ [1, 2 ∷ Int] (const (grantOne control vm))
        awaitCounts vm (\c → jobsFailed c == 2)
        grantOne control vm
        void (awaitFailure session "x")
        forM_ [4, 5 ∷ Int] (const (grantOne control vm))
        -- The failure has been held for the second request since tick three; its cancel wins.
        command session vm "y" "cancel" "ky" [] Nothing
        awaitNote session "y cancel ky cancelled"
        grantOne control vm
        command session vm "y" "take" "ky" [] Nothing
        awaitNote session "y take ky {status=cancelled}"
        command session vm "y" "lookup" "k0" [("path", VText "broken_second.lua")] Nothing
        awaitNote session "y lookup k0 failed module_error #broken_second.lua"

  it "latches nothing when no instance's code is running: a task that caught the error is not an instance" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "ku" [] (Just (fetch "util.lua"))
        awaitNote session "x start ku started"
        command session vm "x" "keep" "ku" [("name", VText "util")] Nothing
        awaitNote session "x keep ku {status=success,value=table(util)}"
        command session vm "y" "start" "kb" [] (Just (fetch "bad.lua"))
        _ ← awaitFailure session "y"
        runLookTask vm "util" "bad.lua"
        awaitHistory session (elem "task looked false")
        -- The task caught the error and nothing was failed for it: the instance that holds the module still answers.
        command session vm "x" "lookup" "k0" [("path", VText "bad.lua")] Nothing
        awaitNote session "x lookup k0 failed module_error #bad.lua"

  it "stays an ordinary, catchable error for a plan that does not opt in: only the coordinator makes the failure required" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      -- The plan as any generic caller has it: the coordinator's hooks, and the default for the observed lookup.
      withVm session runtime "ui" (defaultOptions OnArrival) {optPlan = \plan → plan {planHooks = (planHooks plan) {hookObserved = hookObserved noLoaderHooks}}} $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "ku" [] (Just (fetch "util.lua"))
        awaitNote session "x start ku started"
        command session vm "x" "keep" "ku" [("name", VText "util")] Nothing
        awaitNote session "x keep ku {status=success,value=table(util)}"
        command session vm "y" "start" "kb" [] (Just (fetch "bad.lua"))
        _ ← awaitFailure session "y"
        command session vm "x" "call" "util" [("field", VText "lookup"), ("text", VText "bad.lua")] Nothing
        line ← lineStartingWith session "x call util error"
        line `shouldSatisfy` Text.isInfixOf "failed"
        -- Caught, and the instance goes on: it still answers the next command.
        command session vm "x" "lookup" "k0" [("path", VText "bad.lua")] Nothing
        awaitNote session "x lookup k0 failed module_error #bad.lua"

  it "is told apart by identity when two modules fail with the same label and the same fault" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        -- Each importer's failure names the content that failed for it, not the first with an equal fault.
        forM_ [("imp_one.lua", "1.lua"), ("imp_two.lua", "2.lua")] $ \(importer, failing) → do
          outcome ← bootNow session vm importer >>= awaitBootOutcome
          case outcome of
            BootFailed failure → do
              failurePath failure `shouldBe` Text.pack (Char8.unpack (longName failing))
              failureCode failure `shouldBe` "module_error"
            other → expectationFailure ("expected the boot load to fail, found " <> show other)

  it "is classified by its cause, with the content that failed, however many modules import it" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "broken_first.lua"))
        failure ← awaitFailure session "x"
        case requestFailureOf failure of
          Just (endpoint, why) → do
            endpoint `shouldBe` "module"
            why `shouldSatisfy` Text.isInfixOf "module_error"
            why `shouldSatisfy` Text.isInfixOf "broken_second.lua"
          Nothing → expectationFailure ("expected a request failure, found " <> show failure)

  it "fails the instance whose code looked it up, even when that code caught the error, and only that instance" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        admitDriver session vm "z"
        command session vm "x" "start" "ku" [] (Just (fetch "util.lua"))
        awaitNote session "x start ku started"
        command session vm "x" "keep" "ku" [("name", VText "util")] Nothing
        awaitNote session "x keep ku {status=success,value=table(util)}"
        -- A failure is cached by a request nobody reads; the hook's import raises, caught or not,
        -- and the coordinator's lookup reports the same failure.
        command session vm "y" "start" "kb" [] (Just (fetch "bad.lua"))
        _ ← awaitFailure session "y"
        command session vm "x" "call" "util" [("field", VText "lookup"), ("text", VText "bad.lua")] Nothing
        -- The call catches the error it was raised as, and the script goes on, so the failure that
        -- ends the instance is not the script's to launder into a success.
        line ← lineStartingWith session "x call util error"
        line `shouldSatisfy` Text.isInfixOf "failed"
        failure ← awaitFailure session "x"
        case requestFailureOf failure of
          Just (endpoint, why) → do
            endpoint `shouldBe` "module"
            why `shouldSatisfy` Text.isInfixOf "module_error"
            why `shouldSatisfy` Text.isInfixOf "bad.lua"
          Nothing → expectationFailure ("expected the instance to fail with the module's failure, found " <> show failure)
        -- The other instance is untouched, and the identity still reads as the failure it is.
        command session vm "z" "lookup" "k0" [("path", VText "bad.lua")] Nothing
        awaitNote session "z lookup k0 failed module_error #bad.lua"
        command session vm "z" "lookup" "k0" [("path", VText "plain.lua")] Nothing
        awaitNote session "z lookup k0 not_ready #plain.lua"

boot ∷ Spec
boot = describe "boot loads" $ do
  it "complete or fail with no tick, no waiter and no request, and share the identity cache" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "logical" (defaultOptions AtAssignedTick) $ \vm → do
        good ← bootNow session vm "first.lua"
        awaitBootOutcome good >>= (`shouldBe` BootReady)
        tickOf vm >>= (`shouldBe` 0)
        counts vm >>= \c → (jobsHeld c, jobsReady c, waitersHeld c) `shouldBe` (2, 2, 0)
        bad ← bootNow session vm "broken_first.lua"
        outcome ← awaitBootOutcome bad
        case outcome of
          BootFailed failure → do
            failureCode failure `shouldBe` "module_error"
            failurePath failure `shouldBe` "broken_second.lua"
          other → expectationFailure ("expected a boot failure, found " <> show other)
        tickOf vm >>= (`shouldBe` 0)
        -- Nothing was asked of a request place, and no diagnostic is written for a boot failure: it was
        -- decided with the outcome that no diagnostic is owed.
        counts vm >>= \c → jobsDiagnosed c `shouldBe` 0
        diagnostics session >>= (`shouldBe` [])
        vmDiagnostics vm >>= \d → rdOutstanding d `shouldBe` 0
        -- A boot load of a module already cached answers from the cache.
        again ← bootNow session vm "first.lua"
        awaitBootOutcome again >>= (`shouldBe` BootReady)
        readsStarted (ssProbe session) >>= (`shouldBe` 4)

lineStartingWith ∷ Session → Text.Text → IO Text.Text
lineStartingWith session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → awaitHistory session (any (Text.isPrefixOf prefix)) >> lineStartingWith session prefix
