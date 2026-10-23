{-# LANGUAGE OverloadedStrings #-}

-- | One shared job per module: instances that name one identity join it, and are each handed the
-- very table the VM holds, after one read and one evaluation.
module Test.LuaEngine.Modules.Basics (spec) where

import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("a.lua", "fx.record('eval a') return { id = 'a', f = function() return 1 end }")
    , ("b.lua", "fx.record('eval b') return { id = 'b' }")
    ]

spec ∷ Spec
spec = describe "a shared module job" $ do
  it "is joined by two instances, read and evaluated once, and answered with the very table" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
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
        (countJobs reading, countWaiters reading, countReadsStarted reading) `shouldBe` (1, 2, 1)
        openGate (ssProbe session) "a.lua"
        command session vm "a" "keep" "k" [("name", textValue "ka")] Nothing
        command session vm "b" "keep" "k" [("name", textValue "kb")] Nothing
        awaitNote session "a keep k {status=success,value=table(a)}"
        awaitNote session "b keep k {status=success,value=table(a)}"
        command session vm "a" "same" "ka" [("other", textValue "kb")] Nothing
        awaitNote session "a same ka true"
        countNotes session "eval a" >>= (`shouldBe` 1)
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        _ ← pure (control, runtime)
        pure ()
  where
    textValue = VText
