{-# LANGUAGE OverloadedStrings #-}

-- | Whose a facade is (P-72 section 2): two instances of one VM have distinct self, api, metadata and
-- handles; a facade or a handle passed through a shared export grants nothing; what a script writes into
-- its own copies changes no attribution, grant or captured hook; and a facade kept by a module does not
-- waive the module phase.
module Test.LuaEngine.Facade.Ownership (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support

-- | A shared export the instances leave their facades and handles in.
share ∷ (FilePath, ByteString)
share = ("lua/share.lua", luaMain ["return {apis = {}, handles = {}, selves = {}}"])

files ∷ [(FilePath, ByteString)]
files =
  [ share
  , ("data.bin", "xx")
  , ("lua/late.lua", luaMain lateModule)
  ]

-- | A module evaluated after the facade was kept in the shared export: every service it reaches for is refused.
lateModule ∷ [Text]
lateModule =
  tryPrelude
    <> [ "local share = import('lua/share.lua')"
       , "local api = share.apis[1]"
       , "try('late tick', function() return api.time.tick() end)"
       , "try('late tick_seconds', function() return api.time.tick_seconds() end)"
       , "try('late seconds', function() return api.time.seconds() end)"
       , "try('late wait_ticks', function() return api.time.wait_ticks(1) end)"
       , "try('late wait_seconds', function() return api.time.wait_seconds(1) end)"
       , "try('late yield', function() return api.time.yield() end)"
       , "try('late content', function() return api.content.data('data.bin') end)"
       , "try('late module', function() return api.content.module('lua/main.lua') end)"
       , "try('late ready', function() return api.request.ready(share.handles[1]) end)"
       , "try('late take', function() return api.request.take(share.handles[1]) end)"
       , "try('late cancel', function() return api.request.cancel(share.handles[1]) end)"
       , "try('late wait', function() return api.request.wait(share.handles[1]) end)"
       , "try('late warn', function() warn('late module warning') end)"
       , "return {}"
       ]

spec ∷ Spec
spec = describe "ownership" $ do
  it "gives two instances of one VM distinct self, api, metadata and handles, and refuses what one passes the other" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource twins) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
      first ← spawn world fvm "modules-test" mainPath
      second ← spawn world fvm "modules-test" mainPath
      spId first `shouldNotBe` spId second
      tickBy control fvm 1
      out ← outLines world
      let named prefix = [Text.drop (Text.length prefix) line | line ← out, prefix `Text.isPrefixOf` line]
      named "identity " `shouldMatchList` ["inst-1 gameplay modules-test", "inst-2 gameplay modules-test"]
      named "distinct " `shouldBe` ["api=false self=false content=false handle=false"]
      -- the second instance, reaching for the first's facade and handle
      named "other facade module => " `shouldSatisfy` all ("false ; " `Text.isPrefixOf`)
      named "other facade module => " `shouldSatisfy` all ("this facade belongs to another instance" `Text.isInfixOf`)
      named "other facade tick => " `shouldSatisfy` all ("this facade belongs to another instance" `Text.isInfixOf`)
      named "other facade request => " `shouldSatisfy` all ("this facade belongs to another instance" `Text.isInfixOf`)
      named "own facade, other handle => " `shouldSatisfy` all ("false ; " `Text.isPrefixOf`)
      named "own facade, other handle => " `shouldSatisfy` all ("data_request" `Text.isInfixOf`)
      named "own handle => " `shouldBe` ["true ; true"]
  it "keeps the engine's attribution, grants and captured hooks when a script overwrites its own copies" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", overwriting) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
      spawned ← spawn world fvm "modules-test" mainPath
      tickBy control fvm 1
      outLines world >>= (`shouldBe` ["saved call answered 2 values", "captured update ran, not the replacement", "own facade still works: false"])
      errLines world >>= (`shouldBe` ["lua warning role=gameplay content=modules-test instance=" <> spId spawned <> ": after the edits"])
  it "gives an instance without an init its api all the same, and the same table to init and self.api" $ do
    withOne Gameplay fixedM1Profile script {scHasInit = False, scUpdate = ["print('no init: ' .. api.role .. ' ' .. tostring(rawequal(self.api, api)) .. ' ' .. tostring(api.time.tick()))"]} $ \world control fvm _ → do
      tickBy control fvm 1
      outLines world >>= (`shouldBe` ["no init: gameplay true 1"])
    withOne Gameplay fixedM1Profile script {scInit = ["print('same: ' .. tostring(rawequal(api, self.api)) .. ' ' .. tostring(self.api == api))"]} $ \world _ _ _ →
      outLines world >>= (`shouldBe` ["same: true true"])
  it "refuses a facade a module kept when its top level later reaches for it, whatever authority it had in a hook" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", keeper) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      tickBy control fvm 2
      out ← outLines world
      let refused = [line | line ← out, "late " `Text.isPrefixOf` line, not ("late warn" `Text.isPrefixOf` line)]
      length refused `shouldBe` 12
      refused `shouldSatisfy` all (\line → "=> false ; " `Text.isInfixOf` line && "services are not available while a module is evaluated" `Text.isInfixOf` line)
      [line | line ← out, "late warn" `Text.isPrefixOf` line] `shouldBe` ["late warn => true"]
      errLines world >>= (`shouldBe` ["lua warning role=gameplay module=modules-test:lua/late.lua: late module warning"])
  where
    keeper =
      luaMain
        [ "local share = import('lua/share.lua')"
        , "return {"
        , "  gameplay = {"
        , "    every_ticks = 1,"
        , "    init = function(self, api)"
        , "      share.apis[1] = api"
        , "      share.handles[1] = api.content.data('data.bin')"
        , "      api.content.module('lua/late.lua')"
        , "    end,"
        , "    update = function() end"
        , "  },"
        , "  presentation = {}"
        , "}"
        ]
    overwriting =
      luaMain
        [ "local M"
        , "M = {"
        , "  gameplay = {"
        , "    every_ticks = 1,"
        , "    init = function(self, api)"
        , "      local saved = api.content.data"
        , "      api.role, api.instance_id, api.content_id = 'presentation', 'inst-99', 'elsewhere'"
        , "      api.content = nil"
        , "      self.api = nil"
        , "      print('saved call answered ' .. select('#', saved('data.bin')) .. ' values')"
        , "      warn('after the edits')"
        , "      M.gameplay.update = function() print('the replacement ran') end"
        , "    end,"
        , "    update = function(self, dt)"
        , "      print('captured update ran, not the replacement')"
        , "      print('own facade still works: ' .. tostring(self.api ~= nil))"
        , "    end"
        , "  },"
        , "  presentation = {}"
        , "}"
        , "return M"
        ]
    twins =
      script
        { scPrelude = ["local share = import('lua/share.lua')"]
        , scInit =
            [ "share.apis[#share.apis + 1] = api"
            , "share.selves[#share.selves + 1] = self"
            , "share.handles[#share.handles + 1] = api.content.data('data.bin')"
            , "print('identity ' .. api.instance_id .. ' ' .. api.role .. ' ' .. api.content_id)"
            ]
        , scUpdate =
            [ "if self.ran or #share.apis < 2 then return end self.ran = true"
            , "if api.instance_id ~= share.apis[2].instance_id then return end"
            , "local other, mine = share.apis[1], share.apis[2]"
            , "print('distinct api=' .. tostring(rawequal(other, mine)) .. ' self=' .. tostring(rawequal(share.selves[1], share.selves[2])) .. ' content=' .. tostring(rawequal(other.content, mine.content)) .. ' handle=' .. tostring(rawequal(share.handles[1], share.handles[2])))"
            , "try('other facade module', function() return other.content.module('lua/main.lua') end)"
            , "try('other facade tick', function() return other.time.tick() end)"
            , "try('other facade request', function() return other.request.ready(share.handles[1]) end)"
            , "try('own facade, other handle', function() return mine.request.ready(share.handles[1]) end)"
            , "try('own handle', function() return mine.request.ready(share.handles[2]) end)"
            ]
        }
