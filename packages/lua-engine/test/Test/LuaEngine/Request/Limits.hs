{-# LANGUAGE OverloadedStrings #-}

-- | The profile's numeric ceilings, message bound and the permanent refusals an adapter's argument
-- check carries, said apart from a bank that is merely full.
module Test.LuaEngine.Request.Limits (spec) where

import Control.Monad (replicateM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), fixedM1Profile)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaEngine.Request.Profiles
import Test.LuaEngine.Request.Support

spec ∷ Spec
spec = describe "limits" $ do
  describe "the numeric ceiling" $ do
    it "is the profile's: a tick and offset past it are an ordinary Lua error, the sum that reaches it is accepted, and the offset is read as positive" $ do
      withRig (counts [(LuaIntegerMaximum, 40)]) 4 $ \rig control runtime → do
        owner ← startRig rig runtime "ceiling" AtAssignedTick
        admitDriver rig owner "i"
        replicateM_ 10 (grantOne control owner)
        commandWith rig owner "i" "pstart" "a" Nothing (Just 31)
        awaitNote rig "cmd pstart a error fixture.data: request refused: the tick and offset pass the ceiling of 40"
        commandWith rig owner "i" "pstart" "b" Nothing (Just 0)
        awaitNote rig "cmd pstart b error fixture.data: request refused: the tick offset is not a positive integer"
        commandWith rig owner "i" "pstart" "c" Nothing (Just (-3))
        awaitNote rig "cmd pstart c error fixture.data: request refused: the tick offset is not a positive integer"
        submissionCount rig >>= (`shouldBe` 0)
        commandWith rig owner "i" "pstart" "d" Nothing (Just 30)
        awaitNote rig "cmd pstart d started"
        handed ← handedAt rig 0
        fmap dueTick (infoDue (hdInfo handed)) `shouldBe` Just 40

    it "makes the request numbers a ceiling too: the one past it is an ordinary Lua error with no work" $ do
      withRig (counts [(LuaIntegerMaximum, 2)]) 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "numbers" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        command rig owner "i" "start" "b"
        awaitStarts rig 2
        command rig owner "i" "pstart" "c"
        awaitNote rig "cmd pstart c error fixture.data: request refused: every request number up to 2 has been issued"
        submissionCount rig >>= (`shouldBe` 2)

  describe "the diagnostic bound" $ do
    it "cuts a failure message at a character, visibly, to the profile's message bound" $ do
      withRig (bytesOf [(MessageBytes, 16)]) 4 $ \rig _ runtime → do
        setAsk rig (\held → held {askNecessityOf = OptionalRequest})
        owner ← startRig rig runtime "message" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        _ ← answerContentFailure rig 0 "not_found"
        command rig owner "i" "take" "a"
        line ← lineStarting rig "cmd take a "
        -- "could not read not_found" is twenty-four bytes; sixteen keeps thirteen and a mark.
        line `shouldSatisfy` Text.isInfixOf "message=could not rea...,"

    it "bounds the busy answer's message by the same bound" $ do
      withRig (smaller [(RequestsPerInstance, 1)] [(MessageBytes, 24)]) 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "busy message" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        command rig owner "i" "start" "b"
        line ← lineStarting rig "cmd start b busy"
        line `shouldBe` "cmd start b busy:busy:request capacity is n..."

  describe "a service's own permanent refusal" $ do
    it "is an ordinary Lua error said apart from busy: a second window is refused even when every bank has room" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        setAsk rig (\held → held {askWindowsHeld = Just 1})
        owner ← startRig rig runtime "second window" OnArrival
        admitDriver rig owner "i"
        commandWith rig owner "i" "pstart" "w" (Just "window") Nothing
        awaitNote rig "cmd pstart w error fixture.window: a second window is not allowed"
        submissionCount rig >>= (`shouldBe` 0)
        d ← diagnostics owner
        (rdBusy d, rdAdmitted d) `shouldBe` (0, 0)
        -- Whereas a full bank is data, from the same call.
        setAsk rig (\held → held {askWindowsHeld = Nothing})
        commandWith rig owner "i" "pstart" "w" (Just "window") Nothing
        awaitNote rig "cmd pstart w started"

    it "and a credit that has no room is busy, naming the bank, and is not that refusal" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        pool ← newPool 0
        setAsk rig (\held → held {askCreditsOf = [poolCredit "pixels" False pool]})
        owner ← startRig rig runtime "credit busy" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        line ← lineStarting rig "cmd start a "
        line `shouldBe` "cmd start a busy:busy:request capacity is not available: the provider has no room in pixels"
        poolLeft pool >>= (`shouldBe` 0)
        poolLog pool >>= (`shouldBe` [])
