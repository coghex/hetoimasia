{-# LANGUAGE OverloadedStrings #-}

-- | The exact common adapter (LFE-7): what a request-producing call answers, the four operations
-- on a request and their records, the busy answer, handles, phases and the lease a texture request
-- reserves, over real instances and a controlled provider.
module Test.LuaEngine.Request.Contract (spec) where

import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (CountLimit (..), fixedM1Profile)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaEngine.Request.Profiles
import Test.LuaEngine.Request.Support

spec ∷ Spec
spec = describe "the exact common adapter" $ do
  describe "a request-producing call" $ do
    it "answers the request and nil when accepted, and nil and a busy record when a bank is full: data, never an error" $ do
      withRig (counts [(RequestsPerInstance, 2)]) 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "busy" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        command rig owner "i" "start" "b"
        awaitNote rig "cmd start b started"
        command rig owner "i" "start" "c"
        line ← lineStarting rig "cmd start c "
        line `shouldBe` "cmd start c busy:busy:request capacity is not available: the instance holds all 2 of its request places"
        submissionCount rig >>= (`shouldBe` 2)
        d ← diagnostics owner
        (rdAdmitted d, rdBusy d, rdRefused d) `shouldBe` (2, 1, 0)
        -- The invocation was no worse for it.
        command rig owner "i" "ready" "a"
        awaitNote rig "cmd ready a false"

    it "refuses nothing at the fixed profile's 16 per instance and answers busy at the 17th" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "sixteen" OnArrival
        admitDriver rig owner "i"
        -- One at a time: the instance's queue of commands is not what is being tried.
        mapM_
          ( \n → do
              command rig owner "i" "start" ("r" <> Text.pack (show n))
              awaitHistory rig (\seen → length (filter (Text.isPrefixOf "cmd start ") seen) == n)
          )
          [1 .. 17 ∷ Int]
        seen ← history rig
        length (filter (Text.isSuffixOf " started") seen) `shouldBe` 16
        length (filter (Text.isInfixOf "busy:busy:") seen) `shouldBe` 1
        submissionCount rig >>= (`shouldBe` 16)

    it "reaches the 64 per VM through a profile whose instance bound is below it, with two instances" $ do
      withRig (counts [(RequestsPerInstance, 2), (RequestsPerVm, 3)]) 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "vm" OnArrival
        admitDriver rig owner "i"
        admitDriver rig owner "j"
        command rig owner "i" "start" "a"
        command rig owner "i" "start" "b"
        awaitStarts rig 2
        command rig owner "j" "start" "a"
        awaitStarts rig 3
        command rig owner "j" "start" "b"
        line ← lineStarting rig "cmd start b busy"
        line `shouldSatisfy` Text.isInfixOf "the VM holds all 3 of its request places"

  describe "the operations on a request" $ do
    it "answer exactly the variants of the schema, with only the fields of each" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        setAsk rig (\held → held {askNecessityOf = OptionalRequest})
        owner ← startRig rig runtime "variants" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        commandWith rig owner "i" "start" "b" (Just "window") Nothing
        commandWith rig owner "i" "start" "c" (Just "data") Nothing
        commandWith rig owner "i" "start" "d" (Just "data") Nothing
        awaitStarts rig 4
        -- Pending: nothing taken, nothing but the status. Ready consumes nothing.
        command rig owner "i" "take" "a"
        awaitNote rig "cmd take a {status=pending}"
        command rig owner "i" "ready" "a"
        awaitNote rig "cmd ready a false"
        answerData rig 0 7 >>= (`shouldBe` ReplySettled)
        answerWindowFailure rig 1 >>= (`shouldBe` ReplySettled)
        answerContentFailure rig 2 "not_found" >>= (`shouldBe` ReplySettled)
        command rig owner "i" "ready" "a"
        awaitNote rig "cmd ready a true"
        command rig owner "i" "ready" "a"
        command rig owner "i" "take" "a"
        awaitNote rig "cmd take a {status=success,value={size=7}}"
        command rig owner "i" "take" "b"
        -- A window failure has no root and no path; a content failure has both.
        awaitNote rig "cmd take b {error={code=window_error,message=the display refused the window},status=failure}"
        command rig owner "i" "take" "c"
        awaitNote rig "cmd take c {error={code=not_found,message=could not read not_found,path=images/quad.png,root=assets},status=failure}"
        command rig owner "i" "cancel" "d"
        awaitNote rig "cmd cancel d cancelled"
        command rig owner "i" "take" "d"
        awaitNote rig "cmd take d {status=cancelled}"

    it "answer already_settled to a cancel that came second, and cancelled to the one that won" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "cancels" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        command rig owner "i" "start" "b"
        awaitStarts rig 2
        answerData rig 0 1 >>= (`shouldBe` ReplySettled)
        command rig owner "i" "cancel" "a"
        awaitNote rig "cmd cancel a already_settled"
        command rig owner "i" "cancel" "b"
        awaitNote rig "cmd cancel b cancelled"
        command rig owner "i" "take" "b"
        awaitNote rig "cmd take b {status=cancelled}"

    it "hand a fresh record each time, so mutating one alters nothing" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "fresh" OnArrival
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        command rig owner "i" "mutate" "a"
        awaitNote rig "cmd mutate a {status=pending}"
        answerData rig 0 3 >>= (`shouldBe` ReplySettled)
        command rig owner "i" "take" "a"
        awaitNote rig "cmd take a {status=success,value={size=3}}"

    it "wait without a result and without consuming" $ do
      withRig fixedM1Profile 4 $ \rig control runtime → do
        owner ← startRig rig runtime "waits" AtAssignedTick
        admitDriver rig owner "i"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        command rig owner "i" "wait" "a"
        awaitNote rig "waiting a"
        answerData rig 0 5 >>= (`shouldBe` ReplyHeld)
        grantOne control owner
        awaitNote rig "cmd wait a 0"
        command rig owner "i" "take" "a"
        awaitNote rig "cmd take a {status=success,value={size=5}}"

    it "refuse a wait in init and in shutdown before waiting, and a request in shutdown, as ordinary errors" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "phases" OnArrival
        admitModule rig owner "p" "phaser"
        line ← lineStarting rig "init wait "
        line `shouldSatisfy` Text.isInfixOf "false request.wait: wait is not available in init"
        stopInstance rig owner "p"
        waited ← lineStarting rig "shutdown wait "
        waited `shouldSatisfy` Text.isInfixOf "false request.wait: wait is not available in shutdown"
        asked ← lineStarting rig "shutdown start "
        asked `shouldSatisfy` Text.isInfixOf "false fixture.data: request refused: the owner is no longer taking requests"

  describe "handles" $ do
    it "belong to the instance that asked: another instance of the VM is refused with an ordinary error" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        owner ← startRig rig runtime "foreign" OnArrival
        admitDriver rig owner "i"
        admitDriver rig owner "j"
        command rig owner "i" "start" "a"
        awaitNote rig "cmd start a started"
        command rig owner "i" "stash" "a"
        awaitNote rig "cmd stash a stashed"
        command rig owner "j" "pother" "x"
        line ← lineStarting rig "cmd pother x "
        line `shouldSatisfy` Text.isInfixOf "error request.take: "
        line `shouldSatisfy` Text.isInfixOf "ended"
        submissionCount rig >>= (`shouldBe` 1)

  describe "a texture request" $ do
    it "reserves a lease with the request, builds the resource into it when the provider replies, and leaves it live after the take" $ do
      withRig fixedM1Profile 4 $ \rig _ runtime → do
        pool ← newPool 2
        setAsk rig (\held → held {askCreditsOf = [poolCredit "pixels" False pool]})
        owner ← startRig rig runtime "texture" OnArrival
        admitDriver rig owner "i"
        commandWith rig owner "i" "start" "a" (Just "texture") Nothing
        awaitNote rig "cmd start a started"
        leaseSummary rig "i" >>= \summary → (summaryCharged summary, summaryLive summary) `shouldBe` (1, 0)
        poolLeft pool >>= (`shouldBe` 1)
        answerTexture rig 0 "quad" >>= (`shouldBe` ReplyAdoption)
        awaitNote rig "acquire quad"
        command rig owner "i" "wait" "a"
        awaitNote rig "cmd wait a 0"
        command rig owner "i" "take_use" "a"
        line ← lineStarting rig "cmd take_use a "
        line `shouldBe` "cmd take_use a {status=success,value={height=2,texture=<userdata>,width=4}} quad"
        awaitDiagnostic owner (\d → rdHeld d == 0)
        poolLog pool >>= (`shouldBe` ["pixels CreditSettled"])
        historyHas rig "release quad" >>= (`shouldBe` False)
        leaseSummary rig "i" >>= \summary → (summaryCharged summary, summaryLive summary) `shouldBe` (1, 1)
        command rig owner "i" "use" "a"
        awaitNote rig "cmd use a quad"
  where
    historyHas rig entry = (entry `elem`) <$> history rig
