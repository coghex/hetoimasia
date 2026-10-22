{-# LANGUAGE OverloadedStrings #-}

-- | A required request's failure through the adapter, and a provider's defect: the latch is the
-- host's, the codes and bounds are the profile's and the service's, and a defect is never an
-- envelope.
module Test.LuaEngine.Request.Failure (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), Profile, fixedM1Profile)
import Hetoimasia.Scripting.Lua.Admission (ProviderDefect)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VList, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaEngine.Request.Profiles
import Test.LuaEngine.Request.Support

-- | A defect an example sends, with the profile that makes it one.
data Defect = Defect
  { dfLabel ∷ String
  , dfWhat ∷ Text.Text
  , dfProfile ∷ Profile
  , dfReply ∷ ProviderReply
  }

spec ∷ Spec
spec = describe "failure" $ do
  it "fails the instance of a required request at its eligible settlement, whether or not it was read, naming the request" $ do
    withRig fixedM1Profile 4 $ \rig _ runtime → do
      owner ← startRig rig runtime "required" OnArrival
      admitDriver rig owner "i"
      command rig owner "i" "start" "a"
      awaitNote rig "cmd start a started"
      answerContentFailure rig 0 "io_error" >>= (`shouldBe` ReplySettled)
      failure ← awaitFailure rig "i"
      requestFailureOf failure `shouldBe` Just ("data", "(fixture) io_error: could not read io_error")

  it "is a result for the script when the request is optional, and fails nobody" $ do
    withRig fixedM1Profile 4 $ \rig _ runtime → do
      setAsk rig (\held → held {askNecessityOf = OptionalRequest})
      owner ← startRig rig runtime "optional" OnArrival
      admitDriver rig owner "i"
      command rig owner "i" "start" "a"
      awaitNote rig "cmd start a started"
      answerContentFailure rig 0 "not_found" >>= (`shouldBe` ReplySettled)
      command rig owner "i" "take" "a"
      awaitNote rig "cmd take a {error={code=not_found,message=could not read not_found,path=images/quad.png,root=assets},status=failure}"
      d ← diagnostics owner
      rdLatched d `shouldBe` 0

  it "is not cleared by a caught misuse or a late cancel: the instance goes on to the end of its call and then fails" $ do
    withRig fixedM1Profile 4 $ \rig _ runtime → do
      owner ← startRig rig runtime "latched" OnArrival
      admitDriver rig owner "i"
      command rig owner "i" "start" "a"
      awaitNote rig "cmd start a started"
      command rig owner "i" "late" "a"
      awaitGate rig "a"
      answerContentFailure rig 0 "not_found" >>= (`shouldBe` ReplySettled)
      openGate rig "a"
      awaitNote rig "cmd late a already_settled false false"
      failure ← awaitFailure rig "i"
      fmap fst (requestFailureOf failure) `shouldBe` Just "data"

  describe "a provider's defect" $ do
    forM_ defects $ \defect →
      it ("is fatal and never an envelope: " <> dfLabel defect) $ do
        ExceptionWithContext _ failure ← fatalRig (dfProfile defect) 4 $ \rig control runtime → do
          setAsk rig (\held → held {askNecessityOf = OptionalRequest})
          owner ← startRig rig runtime "defect" OnArrival
          admitDriver rig owner "i"
          commandWith rig owner "i" "start" "a" (Just (dfWhat defect)) Nothing
          awaitNote rig "cmd start a started"
          answerWith rig 0 (dfReply defect) >>= (`shouldBe` ReplyDefective)
          _ ← awaitEnd control owner
          pure ()
        (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)
  where
    defects =
      [ Defect "a failure whose code the service does not supply" "data" fixedM1Profile (ProviderExpected (ExpectedFailure "mystery" "m" Nothing Nothing))
      , Defect "a failure with no code" "data" fixedM1Profile (ProviderFailure "no code")
      , Defect
          "a path over the profile's path bound"
          "data"
          (smaller [(PathSegments, 8)] [(PathBytes, 8), (PathSegmentBytes, 8)])
          (ProviderExpected (ExpectedFailure "not_found" "m" Nothing (Just (Text.replicate 9 "p"))))
      , Defect
          "a text over the copied-value byte bound"
          "text"
          (bytesOf [(CopiedValueBytes, 64), (DataBytes, 64), (SceneInputBytes, 64)])
          (ProviderResult (VText (Text.replicate 200 "x")))
      , Defect
          "a list whose value fits the byte bound but whose complete success record does not"
          "ints"
          (bytesOf [(CopiedValueBytes, 64), (DataBytes, 64), (SceneInputBytes, 64)])
          (ProviderResult (VList [VInteger 1, VInteger 2]))
      , Defect
          "a failure whose complete record passes the byte bound"
          "data"
          (bytesOf [(CopiedValueBytes, 64), (DataBytes, 64), (SceneInputBytes, 64)])
          (ProviderExpected (ExpectedFailure "not_found" "m" Nothing Nothing))
      , Defect
          "a list over the copied-value element bound"
          "ints"
          (counts [(SceneSprites, 1), (CopiedValueElements, 12)])
          (ProviderResult (VList (map VInteger [1 .. 30])))
      , Defect
          "a list nested past the copied-value depth bound"
          "nested"
          (counts [(CopiedValueDepth, 1), (SceneDepth, 1)])
          (ProviderResult (VList [VList [VInteger 1]]))
      ]
