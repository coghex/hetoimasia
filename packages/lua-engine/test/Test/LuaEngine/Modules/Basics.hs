{-# LANGUAGE OverloadedStrings #-}

-- | One shared job per module: instances that name one identity join it, and are each handed the
-- very table the VM holds, after one read and one evaluation. Another VM has jobs of its own.
module Test.LuaEngine.Modules.Basics (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("a.lua", "fx.record('eval a') return { id = 'a', f = function() return 1 end }")
    , ("b.lua", "fx.record('eval b') return { id = 'b' }")
    , ("m.lua", "fx.record('eval m') fx.block('m') return { id = 'm' }")
    , ("bad.lua", "this is not lua")
    , ("cyc.lua", cyclic)
    , ("util.lua", "return { id = 'util', lookup = function(p) return import(p) end }")
    ]
  where
    cyclic =
      "local count = 0 local t = { id = 'cyc' } t.self = t t.bump = function() count = count + 1 return count end fx.record('eval cyc') return t"

evalsOf ∷ Session → IO [Text.Text]
evalsOf session = filter (Text.isPrefixOf "eval") <$> history session

spec ∷ Spec
spec = describe "a shared module job" $ do
  it "is joined by two instances, read and evaluated once, and answered with the very table" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "a"
        admitDriver session vm "b"
        closeGate (ssProbe session) "a.lua"
        command session vm "a" "start" "k" [] (Just (fetch "a.lua"))
        command session vm "b" "start" "k" [] (Just (fetch "a.lua"))
        awaitNote session "a start k started"
        awaitNote session "b start k started"
        awaitStarted (ssProbe session) 1
        reading ← counts vm
        (jobsHeld reading, waitersHeld reading, readsBegun reading) `shouldBe` (1, 2, 1)
        openGate (ssProbe session) "a.lua"
        command session vm "a" "settled_keep" "k" [("name", VText "ka")] Nothing
        command session vm "b" "settled_keep" "k" [("name", VText "kb")] Nothing
        awaitNote session "a keep k {status=success,value=table(a)}"
        awaitNote session "b keep k {status=success,value=table(a)}"
        command session vm "a" "same" "ka" [("other", VText "kb")] Nothing
        awaitNote session "a same ka true"
        evalsOf session >>= (`shouldBe` ["eval a"])
        readsStarted (ssProbe session) >>= (`shouldBe` 1)

  it "answers a later request from the cache with a fresh envelope each time and the same table, and a taken handle is spent for its own request alone" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "a"
        admitDriver session vm "b"
        command session vm "a" "start" "k1" [] (Just (fetch "a.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "a" "start" "k2" [] (Just (fetch "a.lua"))
        command session vm "b" "start" "k3" [] (Just (fetch "a.lua"))
        awaitNote session "b start k3 started"
        command session vm "a" "settled_env" "k1" [("name", VText "e1")] Nothing
        command session vm "a" "settled_env" "k2" [("name", VText "e2")] Nothing
        awaitNote session "a env k2 {status=success,value=table(a)}"
        command session vm "a" "same" "e1" [("other", VText "e2")] Nothing
        awaitNote session "a same e1 false"
        -- Taking spends only the handle that was taken.
        command session vm "a" "ptake" "k1" [] Nothing
        line ← lineStarting session "a ptake k1 error"
        line `shouldSatisfy` Text.isInfixOf "k1"
        command session vm "b" "settled_take" "k3" [] Nothing
        awaitNote session "b take k3 {status=success,value=table(a)}"
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        evalsOf session >>= (`shouldBe` ["eval a"])

  it "hands over functions, cycles and shared upvalues as the VM holds them, and a mutation is every instance's" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "a"
        admitDriver session vm "b"
        command session vm "a" "start" "k" [] (Just (fetch "cyc.lua"))
        command session vm "b" "start" "k" [] (Just (fetch "cyc.lua"))
        awaitNote session "b start k started"
        command session vm "a" "settled_keep" "k" [("name", VText "ka")] Nothing
        command session vm "b" "settled_keep" "k" [("name", VText "kb")] Nothing
        awaitNote session "b keep k {status=success,value=table(cyc)}"
        command session vm "a" "is_self" "ka" [("field", VText "self")] Nothing
        awaitNote session "a is_self ka true"
        command session vm "a" "call" "ka" [("field", VText "bump")] Nothing
        awaitNote session "a call ka 1"
        command session vm "b" "call" "kb" [("field", VText "bump")] Nothing
        awaitNote session "b call kb 2"
        command session vm "a" "set" "ka" [("field", VText "shared"), ("text", VText "yes")] Nothing
        awaitNote session "a set ka set"
        command session vm "b" "field" "kb" [("field", VText "shared")] Nothing
        awaitNote session "b field kb yes"

  it "is evaluated again, with its own table, by another VM" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "first" (defaultOptions OnArrival) $ \first →
        withVm session runtime "second" (defaultOptions OnArrival) $ \second → do
          admitDriver session first "a"
          admitDriver session second "b"
          command session first "a" "start" "k" [] (Just (fetch "a.lua"))
          command session second "b" "start" "k" [] (Just (fetch "a.lua"))
          awaitCounts first (\c → jobsReady c == 1)
          awaitCounts second (\c → jobsReady c == 1)
          evalsOf session >>= (`shouldBe` ["eval a", "eval a"])
          readsStarted (ssProbe session) >>= (`shouldBe` 2)
          counts first >>= \c → jobsHeld c `shouldBe` 1
          counts second >>= \c → jobsHeld c `shouldBe` 1

  it "is looked up by what is held and nothing else: ready, failed, or not ready, with no work, entry or position for a module that is not" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "a"
        admitDriver session vm "z"
        let lookupOf path = atomically (lookupImmediate (vmCoordinator vm) (moduleIdentity (key' session path)))
            describeLookup = \case
              ImmediateNotReady → "not_ready" ∷ Text.Text
              ImmediateReady _ → "ready"
              ImmediateFailed failure → "failed " <> failureCode failure
        lookupOf "a.lua" >>= (`shouldBe` "not_ready") . describeLookup
        counts vm >>= \c → (jobsHeld c, waitersHeld c, readsBegun c) `shouldBe` (0, 0, 0)
        -- A module the owner is running is not ready either, and asking changes nothing.
        command session vm "a" "start" "k1" [] (Just (fetch "m.lua"))
        awaitGate session "m"
        lookupOf "m.lua" >>= (`shouldBe` "not_ready") . describeLookup
        lookupOf "b.lua" >>= (`shouldBe` "not_ready") . describeLookup
        counts vm >>= \c → jobsHeld c `shouldBe` 1
        releaseGate session "m"
        awaitCounts vm (\c → jobsReady c == 1)
        lookupOf "m.lua" >>= (`shouldBe` "ready") . describeLookup
        command session vm "z" "start" "k2" [] (Just (fetch "bad.lua"))
        _ ← awaitFailure session "z"
        lookupOf "bad.lua" >>= (`shouldBe` "failed module_error") . describeLookup
        counts vm >>= \c → (jobsHeld c, jobsReady c, jobsFailed c) `shouldBe` (2, 1, 1)

  it "is the table a hook's import returns: the same one the request hands over" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "ui" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "a"
        command session vm "a" "start" "ku" [] (Just (fetch "util.lua"))
        command session vm "a" "start" "k1" [] (Just (fetch "a.lua"))
        awaitCounts vm (\c → jobsReady c == 2)
        command session vm "a" "settled_keep" "ku" [("name", VText "util")] Nothing
        command session vm "a" "settled_keep" "k1" [("name", VText "ta")] Nothing
        awaitNote session "a keep k1 {status=success,value=table(a)}"
        command session vm "a" "call_same" "util" [("field", VText "lookup"), ("text", VText "a.lua"), ("other", VText "ta")] Nothing
        awaitNote session "a call_same util true"

lineStarting ∷ Session → Text.Text → IO Text.Text
lineStarting session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → awaitHistory session (any (Text.isPrefixOf prefix)) >> lineStarting session prefix
