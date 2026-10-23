{-# LANGUAGE OverloadedStrings #-}

-- | Content requests and the operations on them (P-72 sections 3 to 5, P-73, D-52 to D-59): the four
-- results and what each omits, a wait that consumes nothing, cancellation, the exact export table a module
-- request returns against the fresh record around it, bytes kept as they are, the busy answer as data, a
-- stopping session as an error, and the timing and failure rules of the layers underneath.
module Test.LuaEngine.Facade.Requests (spec) where

import Control.Concurrent.STM (atomically)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Modules (Counts (..), coordinatorCounts)
import Hetoimasia.LuaEngine.Profile (CountLimit (RequestsPerInstance, RequestsPerVm), fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)

-- | A sorted list of a table's keys, for the examples to print.
keysLua ∷ [Text]
keysLua =
  [ "local function keys(t)"
  , "  local out = {}"
  , "  for k in pairs(t) do out[#out + 1] = tostring(k) end"
  , "  table.sort(out)"
  , "  return table.concat(out, ',')"
  , "end"
  ]

files ∷ [(FilePath, ByteString)]
files =
  [ ("lua/a.lua", "print('a evaluated')\nreturn {id = 'a'}")
  , ("data.bin", "xx")
  , ("bin.dat", ByteString.pack [0, 255, 254, 0xEF, 0xBB, 0xBF, 13, 10, 0, 65])
  , ("empty.dat", "")
  ]

spec ∷ Spec
spec = describe "requests" $ do
  it "hands exactly the fields of each result, keeps a pending take unconsumed, and lets a cancellation win only before the request settles" $
    withOneIn Gameplay fixedM1Profile
      script
        { scPrelude = keysLua
        , scInit =
            [ "self.m = api.content.module('lua/a.lua')"
            , "self.d = api.content.data('data.bin')"
            , "self.o = api.content.data('missing.bin', {optional = true})"
            , "self.c = api.content.data('data.bin')"
            , "self.late = api.content.data('data.bin', {tick_offset = 3})"
            ]
        , scUpdate =
            [ "if self.ran then return end self.ran = true"
            , "print('pending ' .. show(api.request.take(self.late)) .. ' ready ' .. tostring(api.request.ready(self.late)))"
            , "local m = api.request.take(self.m)"
            , "print('module ' .. keys(m) .. ' ' .. m.status .. ' ' .. m.value.id)"
            , "local d = api.request.take(self.d)"
            , "print('data ' .. keys(d) .. ' ' .. d.status .. ' ' .. #d.value)"
            , "local o = api.request.take(self.o)"
            , "print('optional ' .. keys(o) .. ' / ' .. keys(o.error) .. ' ' .. o.status .. ' ' .. o.error.code .. ' ' .. o.error.root .. ' ' .. o.error.path)"
            , "print('cancel settled ' .. api.request.cancel(self.c))"
            , "print('take after a late cancel ' .. show(api.request.take(self.c).status))"
            , "print('cancel pending ' .. api.request.cancel(self.late))"
            , "local k = api.request.take(self.late)"
            , "print('cancelled ' .. keys(k) .. ' ' .. k.status)"
            , "try('take after consuming the cancellation', api.request.take, self.late)"
            ]
        }
      files
      $ \world control fvm _ → do
        tickBy control fvm 1
        outLines world
          >>= ( `shouldBe`
                  [ "a evaluated"
                  , "pending {status=pending} ready false"
                  , "module status,value success a"
                  , "data status,value success 2"
                  , "optional error,status / code,message,path,root failure not_found modules-test missing.bin"
                  , "cancel settled already_settled"
                  , "take after a late cancel success"
                  , "cancel pending cancelled"
                  , "cancelled status cancelled"
                  , "take after consuming the cancellation => false ; hetoimasia_engine.take_data: argument 1: a data_request handle that has ended"
                  ]
              )
  it "consumes nothing by waiting, and returns no values from it" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit = ["self.r = api.content.data('data.bin')"]
        , scUpdate =
            [ "if self.ran then return end self.ran = true"
            , "print('waited, ' .. select('#', api.request.wait(self.r)) .. ' results')"
            , "print('ready ' .. tostring(api.request.ready(self.r)) .. ' ' .. tostring(api.request.ready(self.r)))"
            , "print(api.request.take(self.r).status)"
            ]
        }
      files
      $ \world control fvm _ → do
        tickBy control fvm 2
        outLines world >>= (`shouldBe` ["waited, 0 results", "ready true true", "success"])
  it "returns the cached export table itself inside a fresh record, one evaluation for any number of requests" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit = ["self.one = api.content.module('lua/a.lua')", "self.two = api.content.module('lua/a.lua')"]
        , scUpdate =
            [ "if self.ran then return end self.ran = true"
            , "local one, two = api.request.take(self.one), api.request.take(self.two)"
            , "print('records differ ' .. tostring(one ~= two) .. ', values equal ' .. tostring(rawequal(one.value, two.value)) .. ', imported equal ' .. tostring(rawequal(one.value, import('lua/a.lua'))))"
            , "one.status = 'edited'"
            , "one.value.extra = 'shared state'"
            , "print('the value is shared state: ' .. tostring(import('lua/a.lua').extra) .. ' ' .. tostring(two.value.extra))"
            ]
        }
      files
      $ \world control fvm _ → do
        tickBy control fvm 1
        outLines world
          >>= ( `shouldBe`
                  [ "a evaluated"
                  , "records differ true, values equal true, imported equal true"
                  , "the value is shared state: shared state shared state"
                  ]
              )
  it "returns the bytes of a file exactly, an empty file as an empty string, and an optional missing file as a failure record" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit = ["self.bin = api.content.data('bin.dat')", "self.empty = api.content.data('empty.dat')", "self.gone = api.content.data('gone.dat', {optional = true})"]
        , scUpdate =
            [ "if self.ran then return end self.ran = true"
            , "local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end"
            , "print('bytes ' .. hex(api.request.take(self.bin).value))"
            , "local e = api.request.take(self.empty)"
            , "print('empty ' .. type(e.value) .. ' ' .. #e.value)"
            , "print('fallback ' .. api.request.take(self.gone).error.code)"
            ]
        }
      files
      $ \world control fvm _ → do
        tickBy control fvm 1
        outLines world >>= (`shouldBe` ["bytes 00fffeefbbbf0d0a0041", "empty string 0", "fallback not_found"])
  it "holds a result until its assigned tick, and settles a presentation request when its read arrives" $ do
    withOneIn Gameplay fixedM1Profile
      script
        { scInit = ["self.r = api.content.data('data.bin', {tick_offset = 3})"]
        , scUpdate = ["print('tick ' .. api.time.tick() .. ' ready ' .. tostring(api.request.ready(self.r)))"]
        }
      files
      $ \world control fvm _ → do
        tickBy control fvm 3
        outLines world >>= (`shouldBe` ["tick 1 ready false", "tick 2 ready false", "tick 3 ready true"])
    withOneIn Presentation fixedM1Profile
      script
        { scInit = ["self.r = api.content.data('data.bin')"]
        , scUpdate = ["if self.ran then return end self.ran = true", "api.request.wait(self.r)", "print('arrived ' .. api.request.take(self.r).status)"]
        }
      files
      $ \world _ _ _ → do
        advanceClockPast world
        pumpUntil world (elem "arrived success" <$> outLines world)
  describe "admission" $ do
    it "answers busy as data when a bank is full, with no handle and no work, and succeeds again once the place is back" $
      withOneIn Gameplay (counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)])
        script
          { scInit =
              [ "self.first = api.content.data('data.bin')"
              , "local second, refusal = api.content.data('data.bin')"
              , "print('second ' .. tostring(second) .. ' ' .. refusal.code .. ' ' .. tostring(#refusal.message > 0 and #refusal.message <= 2048))"
              ]
          , scUpdate =
              [ "if self.ran then return end self.ran = true"
              , "api.request.take(self.first)"
              , "local again, refusal = api.content.data('data.bin')"
              , "print('again ' .. tostring(again ~= nil) .. ' ' .. tostring(refusal))"
              ]
          }
        files
        $ \world control fvm _ → do
          held ← atomically (coordinatorCounts (fvCoordinator fvm))
          waitersHeld held `shouldBe` 0
          tickBy control fvm 1
          outLines world >>= (`shouldBe` ["second nil busy true", "again true nil"])
    it "refuses a request of a stopping or closed session as an ordinary error and never as busy" $
      withOneIn Gameplay fixedM1Profile
        script
          { scUpdate =
              [ "try('data', function() return api.content.data('data.bin') end)"
              , "try('module', function() return api.content.module('lua/a.lua') end)"
              ]
          }
        files
        $ \world control fvm _ → do
          setAdmission world AdmissionStopping
          tickBy control fvm 1
          setAdmission world AdmissionClosed
          tickBy control fvm 1
          setAdmission world AdmissionOpen
          out ← outLines world
          length out `shouldBe` 4
          take 2 out `shouldSatisfy` all ("session is stopping: no request starts" `Text.isInfixOf`)
          drop 2 out `shouldSatisfy` all ("session is closed: no request starts" `Text.isInfixOf`)
          out `shouldSatisfy` all ("=> false ; " `Text.isInfixOf`)
          out `shouldSatisfy` all (not . ("busy" `Text.isInfixOf`))
  describe "failure" $ do
    it "fails the instance for a required request's expected failure whether or not it was read, even after a cancel that came too late" $
      withOneIn Gameplay fixedM1Profile
        script
          { scInit = ["self.r = api.content.data('missing.bin')", "print('caught misuse ' .. tostring(pcall(api.content.module)))"]
          , scUpdate = ["print('update ran')"]
          }
        files
        $ \world control fvm spawned → do
          tickBy control fvm 1
          failure ← settledFailure spawned
          fmap fst (requestFailureOf failure) `shouldBe` Just "data"
          outLines world >>= (`shouldBe` ["caught misuse false"])
          phaseOf spawned >>= (`shouldSatisfy` (/= Just Active))
  where
    advanceClockPast world = advanceClock world 2000000000
