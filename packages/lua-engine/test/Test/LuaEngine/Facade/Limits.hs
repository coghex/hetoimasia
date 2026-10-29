{-# LANGUAGE OverloadedStrings #-}

-- | The bounds the facade formats with (D-71, D-74): each is checked against the least its own format needs, and a
-- profile below it is refused by the profile's own validation (round 10: the facade's second check is a guard that no
-- validated profile reaches). Every example is a pair of boundary values: the least that is allowed, which keeps the
-- format end to end on real Lua, and one below it, which is refused with the name of the limit, the value given and the
-- least.
module Test.LuaEngine.Facade.Limits (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile
  ( AnyLimit (LimitBytes, LimitCount)
  , ByteLimit (CopiedValueBytes, DataBytes, InstanceIdBytes, MessageBytes, PathBytes, PrintWarnBytes, RoleFailureRecordBytes, SceneInputBytes, TracebackBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements, InstancesPerVm, LuaIntegerMaximum, SceneDepth, SceneSprites)
  , ProfileError (LimitBelowMinimum)
  , ProfileSpec (..)
  , bytesLimit
  , failureTextBytes
  , fixedM1Profile
  , minimumStatusBytes
  , minimumStatusDepth
  , minimumStatusElements
  , profileSpec
  , validateProfile
  )
import Hetoimasia.Scripting.Lua.Value (Value (VBoolean, VRecord, VText))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (bytesOf, counts, smaller)

files ∷ [(FilePath, ByteString)]
files = [("data.bin", "xx")]

-- | What the profile's own validation says of the fixed profile with these byte limits changed.
validation ∷ [(ByteLimit, Word64)] → Either ProfileError ()
validation changes = () <$ validateProfile base {specBytes = \limit → maybe (specBytes base limit) Bytes (lookup limit changes)}
  where
    base = profileSpec fixedM1Profile

-- | The most text one failure may hold under the fixed profile's failure bounds and this identity bound.
failureTextsOf ∷ Int → Int
failureTextsOf idBytes = failureTextBytes (bound MessageBytes) (bound TracebackBytes) idBytes (bound PathBytes) (bound RoleFailureRecordBytes)

-- | A fixed-profile byte bound, as a machine integer.
bound ∷ ByteLimit → Int
bound limit = let Bytes n = bytesLimit fixedM1Profile limit in fromIntegral n

-- | How the host counts a copied value: five bytes for a table and for a text with its length, one for a boolean, and
-- the same five and the key's length for each key; a table is an element and so is each value in it; a flat table is
-- one level deep. Written out here, independently of the derivation it checks.
measured ∷ Value → (Int, Int, Int)
measured = \case
  VBoolean _ → (1, 0, 1)
  VText text → (5 + ByteString.length (Text.encodeUtf8 text), 0, 1)
  VRecord entries →
    let inner = [(5 + ByteString.length (Text.encodeUtf8 key) + bytes, depth, elements) | (key, value) ← entries, let (bytes, depth, elements) = measured value]
     in (5 + sum [bytes | (bytes, _, _) ← inner], 1 + maximum (0 : [depth | (_, depth, _) ← inner]), 1 + sum [elements | (_, _, elements) ← inner])
  other → error ("not a value the status record holds: " <> show other)

-- | The largest status record the fixed profile's bounds admit: both roles failed, every optional field of each failure present
-- and every text at its own bound, the longest phase and the longest schema words.
maximalStatus ∷ StatusSample
maximalStatus = StatusSample True (Just role) (Just role)
  where
    role = RoleSample True "stopping" (Just failure)
    failure =
      FailureSample
        { sfCode = "state_unavailable"
        , sfMessage = Text.replicate (bound MessageBytes) "m"
        , sfRole = "presentation"
        , sfStage = "shutdown"
        , sfContentId = Just (Text.replicate 64 "c")
        , sfInstanceId = Just (Text.replicate 128 "i")
        , sfPath = Just (Text.replicate (bound PathBytes) "p")
        , sfTraceback = Just (Text.replicate (bound TracebackBytes) "t")
        }

spec ∷ Spec
spec = describe "the bounds the facade formats with" $ do
  it "has the least of each bound it formats with, in the profile's own validation: the three the facade checks are the three validation enforces" $ do
    validation [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes)] `shouldBe` Right ()
    validation [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes), (PrintWarnBytes, fromIntegral (minimumPrintWarnBytes minimumInstanceIdBytes))] `shouldBe` Right ()
  describe "InstanceIdBytes" $ do
    it "is refused one below the first identity the session issues" $
      validation [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes - 1)]
        `shouldBe` Left (LimitBelowMinimum (LimitBytes InstanceIdBytes) (fromIntegral minimumInstanceIdBytes - 1) (fromIntegral minimumInstanceIdBytes))
    it "at the least, makes a facade whose first instance is named inst-1, and refuses an identity that does not fit when it is declared" $ do
      minimumInstanceIdBytes `shouldBe` 6
      withOneIn Gameplay (bytesOf [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes)]) script {scInit = ["print(api.instance_id)"]} files $ \world _ fvm _ → do
        outLines world >>= (`shouldBe` ["inst-1"])
        -- inst-1 is spawned and a VM holds two instances; identities are issued in order and never reused, so the
        -- ninth is the last of six bytes (inst-9) and the tenth (inst-10, seven bytes) does not fit
        declared ← mapM (const (declareInstance (fvFacade fvm) "modules-test")) [2 .. 10 ∷ Int]
        map (either Just (const Nothing)) declared
          `shouldBe` [Nothing] <> replicate 7 (Just (TooManyInstances 2)) <> [Just (IdTooLong 7)]
  describe "PrintWarnBytes" $ do
    let least = minimumPrintWarnBytes minimumInstanceIdBytes
        profileAt n = bytesOf [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes), (PrintWarnBytes, fromIntegral n)]
        -- an entry module whose label is longer than the 128 bytes the host keeps of it, so that its prefix is the longest
        segment character = replicate 200 character
        entry = "lua/" <> segment 'a' <> "/" <> segment 'b' <> ".lua"
        prefix = "lua warning role=presentation module=" <> Text.take 128 ("modules-test:" <> Text.pack entry) <> ": "
    it "is refused one below the longest prefix, the marker and a line end" $
      validation [(InstanceIdBytes, fromIntegral minimumInstanceIdBytes), (PrintWarnBytes, fromIntegral least - 1)]
        `shouldBe` Left (LimitBelowMinimum (LimitBytes PrintWarnBytes) (fromIntegral least - 1) (fromIntegral least))
    it "has a least that is the longest prefix a warning takes, the marker and a line end, and the profile's own bound holds it" $ do
      Text.length prefix + 4 `shouldBe` least
      least `shouldSatisfy` (<= 4096)
    it "at the least, keeps the format end to end: every line of a cut warning, from a hook and from a module, begins with the whole prefix and ends within the bound" $
      withWorld (profileAt least) (Layout ((entry, scriptSource script {scPrelude = ["warn(string.rep('m', 2000) .. '\\nnext')"], scInit = ["warn(string.rep('h', 2000) .. '\\nnext')"]}) : files)) $ \world _ runtime →
        withFvm world runtime presentationShape $ \fvm → do
          _ ← spawn world fvm "modules-test" (Char8.pack entry)
          err ← errLines world
          let hookPrefix = "lua warning role=presentation content=modules-test instance=inst-1: "
          length err `shouldSatisfy` (>= 2)
          -- the module's warning, at the longest prefix there is
          case err of
            moduleLines : _ → moduleLines `shouldSatisfy` Text.isPrefixOf prefix
            [] → expectationFailure "the module wrote nothing"
          -- every line begins with one of the two prefixes, whole
          err `shouldSatisfy` all (\line → prefix `Text.isPrefixOf` line || hookPrefix `Text.isPrefixOf` line)
          -- each call is within the bound, and the cut one ends in the marker
          let calls = [line | line ← err, "..." `Text.isSuffixOf` line]
          length calls `shouldBe` 2
          sum [ByteString.length (Text.encodeUtf8 line) + 1 | line ← takeWhile (prefix `Text.isPrefixOf`) err] `shouldSatisfy` (<= least)
  describe "the limits for which positive is enough" $ do
    it "makes a facade over a VM of one instance: the second declaration is refused with that bound" $
      withOneIn Gameplay (counts [(InstancesPerVm, 1)]) script {scInit = ["print(api.instance_id)"]} files $ \world _ fvm _ → do
        outLines world >>= (`shouldBe` ["inst-1"])
        declareInstance (fvFacade fvm) "modules-test" >>= \declared → either Just (const Nothing) declared `shouldBe` Just (TooManyInstances 1)
    it "makes a facade whose tick ceiling is one: tick 0 is read, as the first tick a wait or a request can reach" $
      withOneIn Gameplay (counts [(LuaIntegerMaximum, 1)]) script {scInit = ["print(api.time.tick())"]} files $ \world _ _ _ →
        outLines world >>= (`shouldBe` ["0"])
  describe "CopiedValueBytes" $ do
    let idBytes = minimumInstanceIdBytes
        printBytes = minimumPrintWarnBytes idBytes
        -- the fixed profile's failure bounds are kept, so the status record is the largest one they admit
        least = minimumCopiedValueBytes idBytes printBytes (failureTextsOf idBytes)
        profileAt n =
          bytesOf
            [ (InstanceIdBytes, fromIntegral idBytes)
            , (PrintWarnBytes, fromIntegral printBytes)
            , (CopiedValueBytes, fromIntegral n)
            , (DataBytes, 64)
            , (SceneInputBytes, 64)
            ]
    it "has a least that is the largest of what the facade makes cross, each with the header the host adds: one print or warn's text, an identity, the context record and the status record" $ do
      -- with a failure that holds nothing but its schema's words: 171 bytes of output and a five-byte header; the context record
      -- needs only 142; an identity needs 11; the status record of two such failures is 565
      minimumCopiedValueBytes 6 171 37 `shouldBe` 565
      -- the default output bound dominates at its own size once the failures are short, and the status record when they are not
      minimumCopiedValueBytes 128 4096 37 `shouldBe` 4101
      minimumCopiedValueBytes 128 100 37 `shouldBe` 565
      minimumCopiedValueBytes 128 100 8192 `shouldBe` 491 + 2 * 8192
    it "has a context record whose least is what the host counts for it, written out by hand: 142 at the smallest identity bound, 264 at the largest" $ do
      minimumContextBytes minimumInstanceIdBytes `shouldBe` 142
      minimumContextBytes 128 `shouldBe` 264
    it "is refused one below the largest crossing the facade makes, the status record included" $
      validation [(InstanceIdBytes, fromIntegral idBytes), (PrintWarnBytes, fromIntegral printBytes), (CopiedValueBytes, fromIntegral least - 1), (DataBytes, 64), (SceneInputBytes, 64)]
        `shouldBe` Left (LimitBelowMinimum (LimitBytes CopiedValueBytes) (fromIntegral least - 1) (fromIntegral least))
    it "is refused one below the output a call may carry, at a bound where only that is short of the context record" $
      -- a record of 142 fits in 150; the longest print, at the smallest output bound, and its header does not
      validation [(InstanceIdBytes, fromIntegral idBytes), (PrintWarnBytes, fromIntegral printBytes), (CopiedValueBytes, 150), (DataBytes, 64), (SceneInputBytes, 64)]
        `shouldBe` Left (LimitBelowMinimum (LimitBytes CopiedValueBytes) 150 (fromIntegral least))
    it "at the least, keeps every crossing inside it: the longest print and warn are cut and written, and what a script passes in that cannot cross is an ordinary error that leaves the instance well" $
      withOneIn Gameplay (profileAt least) script
        { scInit =
            [ "print(string.rep('p', 5000))"
            , "warn(string.rep('w', 5000))"
            , "print(api.role, api.content_id, api.instance_id)"
            , "print((select(2, pcall(api.content.module, string.rep('a', 600)))) ~= nil)"
            , "print((select(2, pcall(import, string.rep('b', 600)))) ~= nil)"
            ]
        , scUpdate = ["print('alive')"]
        }
        files
        $ \world control fvm _ → do
          tickBy control fvm 1
          out ← outLines world
          err ← errLines world
          -- the longest print: cut to the bound, ending in the marker
          case out of
            first : _ → do
              Text.length first + 1 `shouldBe` printBytes
              first `shouldSatisfy` Text.isSuffixOf "..."
            [] → expectationFailure "nothing was printed"
          err `shouldSatisfy` (not . null)
          err `shouldSatisfy` all (Text.isPrefixOf "lua warning role=gameplay content=modules-test instance=inst-1: ")
          out `shouldSatisfy` elem "gameplay\tmodules-test\tinst-1"
          -- the oversize path and the oversize import were refused as errors the script caught, and the instance went on
          out `shouldSatisfy` (\found → length (filter (== "true") found) == 2)
          out `shouldSatisfy` elem "alive"
  describe "the status record" $ do
    it "has a least written out by hand: 491 bytes with no text, 565 at the smallest failure bound, a failure's text counted twice, three levels deep and thirty values" $ do
      minimumStatusBytes 0 `shouldBe` 491
      minimumStatusBytes 37 `shouldBe` 565
      minimumStatusBytes 16384 `shouldBe` 491 + 2 * 16384
      minimumStatusDepth `shouldBe` 3
      minimumStatusElements `shouldBe` 30
    it "is the host's own count of the largest status record the fixed profile's bounds admit, to the byte, the level and the value" $
      measured (statusValue maximalStatus) `shouldBe` (minimumStatusBytes (failureTextsOf 128), minimumStatusDepth, minimumStatusElements)
    it "leaves the fixed profile as it was: it holds the largest status record with room to spare" $ do
      bound CopiedValueBytes `shouldSatisfy` (> minimumStatusBytes (failureTextsOf 128))
      validation [] `shouldBe` Right ()
    it "is refused one below at each of the three limits: the bytes of the largest record, its depth and its values" $ do
      let atBytes n = [(CopiedValueBytes, fromIntegral n), (DataBytes, 64), (SceneInputBytes, 64)]
      validation (atBytes (minimumStatusBytes (failureTextsOf 128))) `shouldBe` Right ()
      validation (atBytes (minimumStatusBytes (failureTextsOf 128) - 1))
        `shouldBe` Left (LimitBelowMinimum (LimitBytes CopiedValueBytes) (fromIntegral (minimumStatusBytes (failureTextsOf 128)) - 1) (fromIntegral (minimumStatusBytes (failureTextsOf 128))))
      countValidation [(CopiedValueDepth, 3), (SceneDepth, 3)] `shouldBe` Right ()
      countValidation [(CopiedValueDepth, 2), (SceneDepth, 2)] `shouldBe` Left (LimitBelowMinimum (LimitCount CopiedValueDepth) 2 3)
      countValidation [(CopiedValueElements, 30), (SceneSprites, 1)] `shouldBe` Right ()
      countValidation [(CopiedValueElements, 29), (SceneSprites, 1)] `shouldBe` Left (LimitBelowMinimum (LimitCount CopiedValueElements) 29 30)
    it "at the least of all three, lets a presentation script read the largest status record the profile's bounds admit: the host copies it whole" $
      withWorld
        ( smaller
            [(CopiedValueDepth, 3), (CopiedValueElements, 30), (SceneDepth, 3), (SceneSprites, 1)]
            [(CopiedValueBytes, fromIntegral (minimumStatusBytes (failureTextsOf 128))), (DataBytes, 64), (SceneInputBytes, 64)]
        )
        (Layout [("lua/main.lua", scriptSource script {scInit = ["local s = api.session.status()", "local f = s.presentation.failure", "print('read ' .. #f.message .. ' ' .. #f.traceback .. ' ' .. #f.path .. ' ' .. #f.instance_id .. ' ' .. #f.content_id .. ' ' .. tostring(s.gameplay.failed))"]})])
        $ \world _ runtime → do
          setStatus world maximalStatus
          withFvm world runtime presentationShape $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            outLines world >>= (`shouldBe` ["read " <> Text.pack (show (bound MessageBytes)) <> " " <> Text.pack (show (bound TracebackBytes)) <> " " <> Text.pack (show (bound PathBytes)) <> " 128 64 true"])
  where
    countValidation changes = () <$ validateProfile base {specCounts = \limit → maybe (specCounts base limit) Count (lookup limit changes)}
    base = profileSpec fixedM1Profile
