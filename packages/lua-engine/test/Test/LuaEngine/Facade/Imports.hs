{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Content addresses and imports (P-72 section 3, D-60, D-61, D-74): the lexical-root @import@ against
-- the instance-rooted requests, literal paths with NFC identity and exact case, unknown and disabled
-- roots, the immediate lookup of a hook, and the required failure a known failed import latches. The
-- resolver is also tested alone, over supplied import contexts, because production M1 enables only the game's
-- root and the fixtures that name another root enable nothing in production.
module Test.LuaEngine.Facade.Imports (spec) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content.Identity (contentKeyPath, contentKeyRoot, logicalPathBytes, rootKeyBytes)
import Control.Concurrent.STM (atomically)
import Hetoimasia.Content.Inventory (inventoryIdentityLimits, inventoryLimitsOf)
import Hetoimasia.LuaEngine.Modules (Counts (..), coordinatorCounts)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstanceFailure (failureError), InstancePhase (Active))
import Hetoimasia.Scripting.Lua.Owner (ExportIdentity (ExportIdentity), ImportContext (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Modules.Support (readsStarted)

-- | The content tree of the examples.
files ∷ [(FilePath, ByteString)]
files =
  [ ("lua/a.lua", "return {id = 'a'}")
  , ("lua/helper.lua", helper)
  , ("lua/pending.lua", "return {id = 'pending'}")
  , ("lua/bad.lua", "this is not lua (")
  , ("lua/caf\233.lua", "return {id = 'cafe'}")
  , ("lua/Case.lua", "return {id = 'case'}")
  , ("data.bin", "xx")
  ]

-- | A shared library that imports and requests with no root of its own to name.
helper ∷ ByteString
helper =
  luaMain
    [ "return {"
    , "  sibling = function() return import('lua/a.lua').id end,"
    , "  warns = function() warn('from the helper') end,"
    , "  request = function(api, root)"
    , "    if root then return api.content.data('data.bin', {root = root}) end"
    , "    return api.content.data('data.bin')"
    , "  end"
    , "}"
    ]

modulesTestRoot, otherRoot ∷ Text
modulesTestRoot = "modules-test"
otherRoot = "mod-b"

spec ∷ Spec
spec = describe "content addresses and imports" $ do
  describe "the lexical resolver" $ do
    it "takes the importing module's root by default, lets an explicit root override it, and refuses a root that is not an enabled identifier" $
      withWorld fixedM1Profile (Layout files) $ \world _ _ → do
        let session = wSession world
            limits = inventoryIdentityLimits (inventoryLimitsOf (ssInventory session))
            resolve enabled identity = lexicalResolver limits enabled (ImportContext identity "importer")
            fromRoot root path = ExportIdentity (ByteString.cons (fromIntegral (Text.length root)) (Text.encodeUtf8 (root <> path)))
            resolved enabled identity path root = do
              answer ← resolve enabled identity path root
              pure (either (Left . id) (\key → Right (Text.decodeUtf8 (rootKeyBytes (contentKeyRoot key)), Text.decodeUtf8 (logicalPathBytes (contentKeyPath key)))) answer)
            both = [modulesTestRoot, otherRoot]
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "lua/a.lua" Nothing >>= (`shouldBe` Right (modulesTestRoot, "lua/a.lua"))
        resolved both (fromRoot otherRoot "lua/x.lua") "lua/a.lua" Nothing >>= (`shouldBe` Right (otherRoot, "lua/a.lua"))
        resolved both (fromRoot otherRoot "lua/x.lua") "lua/a.lua" (Just modulesTestRoot) >>= (`shouldBe` Right (modulesTestRoot, "lua/a.lua"))
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "lua/a.lua" (Just otherRoot) >>= (`shouldBe` Right (otherRoot, "lua/a.lua"))
        -- a path is from the content root, not the importer's directory
        resolved both (fromRoot modulesTestRoot "deep/er/x.lua") "a.lua" Nothing >>= (`shouldBe` Right (modulesTestRoot, "a.lua"))
        -- a valid identifier the session does not enable
        resolved [modulesTestRoot] (fromRoot modulesTestRoot "lua/x.lua") "lua/a.lua" (Just otherRoot) >>= (`shouldSatisfy` isLeftWith "is not enabled")
        -- and a default root the importing module has that is no longer enabled
        resolved [modulesTestRoot] (fromRoot otherRoot "lua/x.lua") "lua/a.lua" Nothing >>= (`shouldSatisfy` isLeftWith "is not enabled")
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "lua/a.lua" (Just "Bad Root") >>= (`shouldSatisfy` isLeftWith "is not a content identifier")
        resolved both (ExportIdentity "") "lua/a.lua" Nothing >>= (`shouldSatisfy` isLeftWith "names no root")
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "lua/../a.lua" Nothing >>= (`shouldSatisfy` isLeftWith "not a content address")
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "lua\\a.lua" Nothing >>= (`shouldSatisfy` isLeftWith "not a content address")
        resolved both (fromRoot modulesTestRoot "lua/x.lua") "" Nothing >>= (`shouldSatisfy` isLeftWith "not a content address")

  describe "a shared library" $
    it "keeps the root it was loaded under when another instance's hook runs it, while its requests and warnings use the executing instance" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", user) : files)) $ \world control runtime →
        withFvm world runtime gameplayShape {shRoots = [modulesTestRoot, otherRoot]} $ \fvm → do
          spawned ← spawn world fvm otherRoot mainPath
          bootPath world fvm "lua/a.lua" >>= (`shouldBe` BootReady)
          tickBy control fvm 1
          out ← outLines world
          out
            `shouldBe` [ "import before it is loaded => false ; import: module_not_ready: modules-test:lua/a.lua"
                       , "request with the instance's default root => false ; hetoimasia_engine.content_data: root \"mod-b\" has no content in this session"
                       , "request naming the helper's root => true ; <handle> ; nil"
                       , "import once it is loaded => true ; a"
                       ]
          errLines world >>= (`shouldBe` ["lua warning role=gameplay content=mod-b instance=" <> spId spawned <> ": from the helper"])

  describe "the immediate lookup of a hook" $ do
    it "raises module_not_ready for an identity that was never asked for or is still pending, starting no work and allocating no identity" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", lookups) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
        _ ← spawn world fvm "modules-test" mainPath
        heldBefore ← atomically (coordinatorCounts (fvCoordinator fvm))
        readsBefore ← readsStarted (ssProbe (wSession world))
        tickBy control fvm 1
        out ← outLines world
        out
          `shouldBe` [ "never asked for => false ; import: module_not_ready: modules-test:lua/never.lua"
                     , "pending => false ; import: module_not_ready: modules-test:lua/pending.lua"
                     ]
        heldAfter ← atomically (coordinatorCounts (fvCoordinator fvm))
        -- the lookups added no identity: the request for the pending module made its job in init
        jobsHeld heldAfter `shouldBe` jobsHeld heldBefore
        readsStarted (ssProbe (wSession world)) >>= (`shouldSatisfy` (<= readsBefore + 1))
    it "latches a known failed import as the required failure of the instance that looked, even if it caught the error, and leaves a peer alone" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", failedLooker) : files)) $ \world _ runtime → withFvm world runtime gameplayShape $ \fvm → do
        bootPath world fvm "lua/bad.lua" >>= (`shouldSatisfy` isBootFailure)
        looker ← admitOnly world fvm "modules-test" mainPath
        failure ← settledFailure looker
        fmap fst (requestFailureOf failure) `shouldBe` Just "module"
        fmap (Text.isInfixOf "modules-test:lua/bad.lua" . snd) (requestFailureOf failure) `shouldBe` Just True
        outLines world >>= (`shouldSatisfy` any ("caught => false" `Text.isPrefixOf`))

  describe "an invalid import while a module is evaluated" $ do
    it "fails that load when the error is not caught, and does nothing else for it: no identity, no read" $
      withWorld fixedM1Profile (Layout (("lua/badimport.lua", luaMain ["import('lua/../x.lua')", "return {}"]) : files)) $ \world _ runtime → withFvm world runtime gameplayShape $ \fvm → do
        outcome ← bootPath world fvm "lua/badimport.lua"
        outcome `shouldSatisfy` isBootFailure
        -- only the module's own read happened
        readsStarted (ssProbe (wSession world)) >>= (`shouldBe` 1)
    it "leaves the load alone when the script catches an argument error, which fails nothing" $
      withWorld fixedM1Profile (Layout (("lua/caught.lua", luaMain ["local ok = pcall(import, 'lua/../x.lua')", "local ok2 = pcall(import, 'lua/a.lua', 'other')", "print('caught ' .. tostring(ok) .. ' ' .. tostring(ok2))", "return {}"]) : files)) $ \world _ runtime → withFvm world runtime gameplayShape $ \fvm → do
        bootPath world fvm "lua/caught.lua" >>= (`shouldBe` BootReady)
        outLines world >>= (`shouldBe` ["caught false false"])

  describe "literal paths" $ do
    it "names one identity by its NFC form, is exact about case, adds no extension and searches no other place" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", spellings) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
        spawned ← spawn world fvm "modules-test" mainPath
        tickBy control fvm 2
        out ← outLines world
        phase ← phaseOf spawned
        failure ← if phase == Just Active then pure Nothing else fmap (take 1500 . show . failureError) <$> settledFailure spawned
        (phase, out, failure)
          `shouldBe` ( Just Active
                     , [ "composed => success cafe"
                     , "decomposed => success cafe"
                     , "exact case => success case"
                     , "other case => failure not_found"
                     , "no extension => failure not_found"
                     , "with extension => success a"
                     , "beside the root => failure not_found"
                     ]
                     , Nothing
                     )
    it "refuses a malformed address before any provider is asked: nothing is read, no identity is allocated, no request is held" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", refusing) : files)) $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
        _ ← spawn world fvm "modules-test" mainPath
        heldBefore ← atomically (coordinatorCounts (fvCoordinator fvm))
        readsBefore ← readsStarted (ssProbe (wSession world))
        tickBy control fvm 1
        out ← outLines world
        length out `shouldBe` 8
        out `shouldSatisfy` all ("=> false ; " `Text.isInfixOf`)
        heldAfter ← atomically (coordinatorCounts (fvCoordinator fvm))
        jobsHeld heldAfter `shouldBe` jobsHeld heldBefore
        promisedHeld heldAfter `shouldBe` 0
        waitersHeld heldAfter `shouldBe` waitersHeld heldBefore
        readsStarted (ssProbe (wSession world)) >>= (`shouldBe` readsBefore)
  where
    user =
      luaMain $
        tryPrelude
          <> [ "local helper = import('lua/helper.lua')"
             , "return {"
             , "  gameplay = {"
             , "    every_ticks = 1,"
             , "    init = function(self, api)"
             , "      try('import before it is loaded', helper.sibling)"
             , "      try('request with the instance\\'s default root', helper.request, api)"
             , "      try('request naming the helper\\'s root', helper.request, api, 'modules-test')"
             , "      helper.warns()"
             , "    end,"
             , "    update = function(self, dt)"
             , "      if self.ran then return end self.ran = true"
             , "      try('import once it is loaded', helper.sibling)"
             , "    end"
             , "  },"
             , "  presentation = {}"
             , "}"
             ]
    lookups =
      luaMain $
        tryPrelude
          <> [ "return {"
             , "  gameplay = {"
             , "    every_ticks = 1,"
             , "    init = function(self, api)"
             , "      api.content.module('lua/pending.lua', {tick_offset = 5})"
             , "    end,"
             , "    update = function(self, dt)"
             , "      if self.ran then return end self.ran = true"
             , "      try('never asked for', function() return import('lua/never.lua') end)"
             , "      try('pending', function() return import('lua/pending.lua') end)"
             , "    end"
             , "  },"
             , "  presentation = {}"
             , "}"
             ]
    failedLooker =
      luaMain $
        tryPrelude
          <> [ "return {"
             , "  gameplay = {"
             , "    every_ticks = 1,"
             , "    init = function(self, api)"
             , "      try('caught', function() return import('lua/bad.lua') end)"
             , "    end,"
             , "    update = function() end"
             , "  },"
             , "  presentation = {}"
             , "}"
             ]
    spellings =
      luaMain $
        tryPrelude
          <> [ "local function describe(r)"
             , "  local result = api_take(r)"
             , "  if result.status == 'success' then return 'success ' .. result.value:match(\"id = '(%a+)'\") end"
             , "  return result.status .. ' ' .. (result.error and result.error.code or '')"
             , "end"
             , "return {"
             , "  gameplay = {"
             , "    every_ticks = 1,"
             , "    init = function(self, api)"
             , "      api_take = api.request.take"
             , "      local function ask(path) return api.content.data(path, {optional = true}) end"
             , "      self.asked = {"
             , "        {'composed', ask('lua/caf\\xc3\\xa9.lua')},"
             , "        {'decomposed', ask('lua/cafe\\xcc\\x81.lua')},"
             , "        {'exact case', ask('lua/Case.lua')},"
             , "        {'other case', ask('lua/case.lua')},"
             , "        {'no extension', ask('lua/a')},"
             , "        {'with extension', ask('lua/a.lua')},"
             , "        {'beside the root', ask('a.lua')},"
             , "      }"
             , "    end,"
             , "    update = function(self, dt)"
             , "      if self.ran then return end self.ran = true"
             , "      for _, asked in ipairs(self.asked) do print(asked[1] .. ' => ' .. describe(asked[2])) end"
             , "    end"
             , "  },"
             , "  presentation = {}"
             , "}"
             ]
    refusing =
      luaMain $
        tryPrelude
          <> [ "return {"
             , "  gameplay = {"
             , "    every_ticks = 1,"
             , "    update = function(self, dt)"
             , "      local api = self.api"
             , "      if self.ran then return end self.ran = true"
             , "      try('empty', function() return api.content.module('') end)"
             , "      try('dot-dot', function() return api.content.module('lua/../a.lua') end)"
             , "      try('backslash', function() return api.content.data('lua\\\\a.lua') end)"
             , "      try('absolute', function() return api.content.data('/data.bin') end)"
             , "      try('url', function() return api.content.module('https://example.test/a.lua') end)"
             , "      try('colon', function() return api.content.module('c:/a.lua') end)"
             , "      try('disabled root', function() return api.content.module('lua/a.lua', {root = 'mod-b'}) end)"
             , "      try('unknown root', function() return api.content.data('data.bin', {root = 'nowhere'}) end)"
             , "    end"
             , "  },"
             , "  presentation = {}"
             , "}"
             ]

isBootFailure ∷ BootOutcome → Bool
isBootFailure = \case
  BootFailed _ → True
  _ → False

isLeftWith ∷ Text → Either Text a → Bool
isLeftWith needle = either (needle `Text.isInfixOf`) (const False)
