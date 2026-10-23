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
    ]

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
