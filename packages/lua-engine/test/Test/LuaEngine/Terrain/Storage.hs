{-# LANGUAGE OverloadedStrings #-}

-- | The storage calls of the terrain facade (TRA-23) over the production backed service: @open@'s options, @status@, @grow_storage@
-- and @retry_storage@. What a script may hand them and what each rejection is; who may call them, in which role and phase; and what a
-- status says, compared with the service's own accounting at the same moment.
module Test.LuaEngine.Terrain.Storage (spec, MiB, mib) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (CountLimit (RequestsPerInstance, RequestsPerVm), fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain (noTerrainHooks)
import Hetoimasia.Terrain.Runtime (defaultConfig, noProbe)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)
import Test.LuaEngine.Terrain.Seam
import Test.LuaEngine.Terrain.Support

type MiB = Integer

mib ∷ Integer → Integer
mib n = n * 1024 * 1024

-- | Lua the storage examples share: @MIB@.
storagePrelude ∷ [Text]
storagePrelude = ["local MIB = 1024 * 1024"]

-- | Rejections of the decode layer and the permanent checks of the storage calls: ordinary errors, raised before anything is
-- admitted. @A@ is the caller's creator lease of @main@ and @B@ its own attachment to it.
decodeCases ∷ [Case]
decodeCases =
  [ Case "open: four arguments" "api.terrain.open('o', DEF, nil, nil)" (Refused ["expected 3 values, found 4"])
  , Case "open: colon call" "api.terrain:open('o', DEF, {})" (Refused ["terrain_open"])
  , Case "open: options a number" "api.terrain.open('o', DEF, 5)" (Refused ["expected record"])
  , Case "open: an unknown option" "api.terrain.open('o', DEF, { storage = 64 * MIB })" (Refused ["storage"])
  , Case "open: an unknown option beside storage_bytes" "api.terrain.open('o', DEF, { storage_bytes = 64 * MIB, path = 'x' })" (Refused ["path"])
  , Case "open: storage_bytes an integral float" "api.terrain.open('o', DEF, { storage_bytes = 67108864.0 })" (Refused ["a float where an integer is declared"])
  , Case "open: storage_bytes a numeric string" "api.terrain.open('o', DEF, { storage_bytes = '67108864' })" (Refused ["expected integer"])
  , Case "open: storage_bytes a boolean" "api.terrain.open('o', DEF, { storage_bytes = true })" (Refused ["expected integer"])
  , Case "open: storage_bytes a function" "api.terrain.open('o', DEF, { storage_bytes = function() end })" (Refused ["function"])
  , Case "open: storage_bytes negative" "api.terrain.open('o', DEF, { storage_bytes = -64 * MIB })" (Refused ["below the 64 MiB minimum"])
  , Case "open: storage_bytes zero" "api.terrain.open('o', DEF, { storage_bytes = 0 })" (Refused ["below the 64 MiB minimum"])
  , Case "open: storage_bytes 64 MiB less 1 MiB" "api.terrain.open('o', DEF, { storage_bytes = 63 * MIB })" (Refused ["below the 64 MiB minimum"])
  , Case "open: storage_bytes 64 MiB less 1" "api.terrain.open('o', DEF, { storage_bytes = 64 * MIB - 1 })" (Refused ["below the 64 MiB minimum"])
  , Case "open: storage_bytes not whole MiB" "api.terrain.open('o', DEF, { storage_bytes = 64 * MIB + 1 })" (Refused ["whole number of MiB"])
  , Case "open: storage_bytes a page past whole MiB" "api.terrain.open('o', DEF, { storage_bytes = 64 * MIB + 4096 })" (Refused ["whole number of MiB"])
  , Case "open: storage_bytes math.maxinteger" "api.terrain.open('o', DEF, { storage_bytes = math.maxinteger })" (Refused ["whole number of MiB"])
  , Case "open: storage_bytes math.mininteger" "api.terrain.open('o', DEF, { storage_bytes = math.mininteger })" (Refused ["below the 64 MiB minimum"])
  , Case "open: options with a metatable" "api.terrain.open('o', DEF, setmetatable({}, { __index = function() hit = true end, __pairs = function() hit = true end }))" (Refused ["metatable"])
  , Case "open: options a cycle" "(function() local o = {} o.storage_bytes = o return api.terrain.open('o', DEF, o) end)()" (Refused ["contains itself"])
  , Case "status: no arguments" "api.terrain.status()" (Refused ["expected 1 values, found 0"])
  , Case "status: an extra argument" "api.terrain.status(A, nil)" (Refused ["expected 1 values, found 2"])
  , Case "status: colon call" "api.terrain:status(A)" (Refused ["expected 1 values, found 2"])
  , Case "status: a string" "api.terrain.status('x')" (Refused ["expected capability"])
  , Case "status: a table" "api.terrain.status({})" (Refused ["expected capability"])
  , Case "status: a pick authority" "api.terrain.status(TEST_PICK(1))" (Refused ["expected a terrain_arena handle"])
  , Case "grow: no size" "api.terrain.grow_storage(A)" (Refused ["expected 2 values, found 1"])
  , Case "grow: an extra argument" "api.terrain.grow_storage(A, 128 * MIB, nil)" (Refused ["expected 2 values, found 3"])
  , Case "grow: colon call" "api.terrain:grow_storage(A, 128 * MIB)" (Refused ["expected 2 values, found 3"])
  , Case "grow: an integral float" "api.terrain.grow_storage(A, 134217728.0)" (Refused ["a float where an integer is declared"])
  , Case "grow: a numeric string" "api.terrain.grow_storage(A, '134217728')" (Refused ["expected integer"])
  , Case "grow: a boolean" "api.terrain.grow_storage(A, true)" (Refused ["expected integer"])
  , Case "grow: nil" "api.terrain.grow_storage(A, nil)" (Refused ["expected integer"])
  , Case "grow: negative" "api.terrain.grow_storage(A, -128 * MIB)" (Refused ["below the 64 MiB minimum"])
  , Case "grow: zero" "api.terrain.grow_storage(A, 0)" (Refused ["below the 64 MiB minimum"])
  , Case "grow: 64 MiB less 1 MiB" "api.terrain.grow_storage(A, 63 * MIB)" (Refused ["below the 64 MiB minimum"])
  , Case "grow: not whole MiB" "api.terrain.grow_storage(A, 128 * MIB + 1)" (Refused ["whole number of MiB"])
  , Case "grow: math.maxinteger" "api.terrain.grow_storage(A, math.maxinteger)" (Refused ["whole number of MiB"])
  , Case "grow: a string handle" "api.terrain.grow_storage('x', 128 * MIB)" (Refused ["expected capability"])
  , Case "grow: the caller's own attachment" "api.terrain.grow_storage(B, 128 * MIB)" (Refused ["only the arena's creator lease may grow its storage"])
  , Case "retry: no arguments" "api.terrain.retry_storage()" (Refused ["expected 1 values, found 0"])
  , Case "retry: an extra argument" "api.terrain.retry_storage(A, nil)" (Refused ["expected 1 values, found 2"])
  , Case "retry: a string" "api.terrain.retry_storage('x')" (Refused ["expected capability"])
  , Case "retry: the caller's own attachment" "api.terrain.retry_storage(B)" (Refused ["only the arena's creator lease may retry its storage"])
  ]

-- | Opens @main@, attaches to it, runs every case, and then shows that no refused call kept a place of the request bank.
decodeScript ∷ Script
decodeScript =
  script
    { scPrelude = terrainPrelude <> storagePrelude <> ["hit = false", "local A, B"]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then A = t.value self.q = api.terrain.attach('main') self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    B = t.value self.s = 2"
        ]
          <> map (("    " <>) . caseLua) decodeCases
          <> [ "    print('trap', hit)"
             , "    local taken = 0"
             , "    for i = 1, 16 do if api.terrain.status(A) ~= nil then taken = taken + 1 end end"
             , "    print('places after the refusals', taken)"
             , "    print('done')"
             , "  end"
             , "end"
             ]
    }

-- | The accepted forms of @open@, each opened, its allowance read through its status, and released: the two-argument form, @nil@,
-- an empty record, an absent or nil @storage_bytes@, the explicit minimum, and options changed after the call (the copy is what
-- was asked for).
acceptedOpens ∷ Script
acceptedOpens =
  stepsScript
    "DEF"
    storagePrelude
    ( concat
        [ [ Step (name <> " opened") ("return " <> call) "return 'ok'"
          , Step (name <> " status") ("return api.terrain.status(V['" <> name <> " opened'])") "return v.storage.reserved_bytes"
          , Step (name <> " released") ("api.terrain.release(V['" <> name <> " opened']) return nil") "return 'ok'"
          ]
        | (name, call) ←
            [ ("two", "api.terrain.open('two', DEF)")
            , ("nil", "api.terrain.open('nil', DEF, nil)")
            , ("empty", "api.terrain.open('empty', DEF, {})")
            , ("absent", "api.terrain.open('absent', DEF, { storage_bytes = nil })")
            , ("minimum", "api.terrain.open('minimum', DEF, { storage_bytes = 64 * MIB })")
            , ("larger", "api.terrain.open('larger', DEF, { storage_bytes = 96 * MIB })")
            , ("copied", "(function() local o = { storage_bytes = 80 * MIB } local r = api.terrain.open('copied', DEF, o) o.storage_bytes = 128 * MIB return r end)()")
            ]
        ]
    )

-- | The creator's storage calls and its own attachment's, in one role: status through either lease, growth larger, equal and smaller,
-- two growths in one update, retry on a ready arena, and the attachment's refusals.
creatorSteps ∷ Script
creatorSteps =
  stepsScript
    "DEF"
    storagePrelude
    [ Step "status" "return api.terrain.status(A)" "return show(v)"
    , Step "attached" "return api.terrain.attach('main')" "return 'ok'"
    , Step "status through the attachment" "return api.terrain.status(V['attached'])" "return show(v)"
    , Step "attachment grow" "try('attachment grow', api.terrain.grow_storage, V['attached'], 96 * MIB) return nil" "return 'ok'"
    , Step "attachment retry" "try('attachment retry', api.terrain.retry_storage, V['attached']) return nil" "return 'ok'"
    , Step "grow" "return api.terrain.grow_storage(A, 96 * MIB)" "return show(v)"
    , Step "grow equal" "return api.terrain.grow_storage(A, 96 * MIB)" "return show(v)"
    , Step "grow smaller" "return api.terrain.grow_storage(A, 80 * MIB)" "return 'ok'"
    , Step "grow smaller unread" "api.terrain.grow_storage(A, 80 * MIB) return nil" "return 'ok'"
    , Step "two growths" "local first = api.terrain.grow_storage(A, 128 * MIB) local second = api.terrain.grow_storage(A, 112 * MIB) V.second = second return first" "return show(v)"
    , Step "the second growth" "return V.second" "return show(v)"
    , Step "retry ready" "return api.terrain.retry_storage(A)" "return show(v)"
    , Step "retry ready unread" "api.terrain.retry_storage(A) return nil" "return 'ok'"
    , Step "status after" "return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.state"
    , Step "attachment released" "print('attachment release', api.terrain.release(V['attached'])) return nil" "return 'ok'"
    , Step "released attachment status" "try('released attachment status', api.terrain.status, V['attached']) return nil" "return 'ok'"
    , Step "creator released" "print('creator release', api.terrain.release(A)) return nil" "return 'ok'"
    , Step "released creator calls" "try('released creator status', api.terrain.status, A) try('released creator grow', api.terrain.grow_storage, A, 256 * MIB) try('released creator retry', api.terrain.retry_storage, A) return nil" "return 'ok'"
    ]

-- | What the creator's steps print, in either role, over an arena of 64 MiB.
creatorExpected ∷ [Text]
creatorExpected =
  [ "status\tsuccess\t" <> readyStatus 64
  , "attached\tsuccess\tok"
  , "status through the attachment\tsuccess\t" <> readyStatus 64
  , "attachment grow => false ; hetoimasia_engine.terrain_grow_storage: only the arena's creator lease may grow its storage"
  , "attachment retry => false ; hetoimasia_engine.terrain_retry_storage: only the arena's creator lease may retry its storage"
  , "grow\tsuccess\t{changed=true,reserved_bytes=" <> bytes 96 <> ",storage={state=ready}}"
  , "grow equal\tsuccess\t{changed=false,reserved_bytes=" <> bytes 96 <> ",storage={state=ready}}"
  , "grow smaller\tfailure\tstorage_size_not_increased"
  , "two growths\tsuccess\t{changed=true,reserved_bytes=" <> bytes 128 <> ",storage={state=ready}}"
  , "the second growth\tfailure\tstorage_size_not_increased"
  , "retry ready\tsuccess\t{changed=false,cleared={},discovery={state=idle},remaining={},storage={state=ready},until_closed={}}"
  , "status after\tsuccess\t" <> bytes 128 <> " ready"
  , "attachment release\tdone"
  , "released attachment status => false ; hetoimasia_engine.terrain_status: argument 1: a terrain_arena handle that has ended"
  , "creator release\tdone"
  , "released creator status => false ; hetoimasia_engine.terrain_status: argument 1: a terrain_arena handle that has ended"
  , "released creator grow => false ; hetoimasia_engine.terrain_grow_storage: argument 1: a terrain_arena handle that has ended"
  , "released creator retry => false ; hetoimasia_engine.terrain_retry_storage: argument 1: a terrain_arena handle that has ended"
  , "done"
  ]
  where
    bytes = Text.pack . show . mib
    readyStatus n = "{content_revision=0,discovery={pending_items=0,state=idle},knowledge_revision=0,storage={pending_reclaim_bytes=0,pending_reserved_bytes=0,reserved_bytes=" <> bytes n <> ",state=ready,used_bytes=<used>}}"

-- | The lines of a run with each status's used bytes replaced by @<used>@: what a fresh arena's store holds is the store's own figure,
-- compared separately with the service's.
masked ∷ [Text] → [Text]
masked = map mask
  where
    mask line = case Text.breakOn "used_bytes=" line of
      (front, rest) | not (Text.null rest) → front <> "used_bytes=<used>" <> Text.dropWhile (`elem` ['0' .. '9']) (Text.drop 11 rest)
      _ → line

-- | Two instances: the first opens @shared@ and shares its handle and its @api.terrain@; the second, its request bank full, uses the
-- first's handle with its own facade and with the first's captured one, and its own attachment.
foreignStorage ∷ Script
foreignStorage =
  script
    { scPrelude = terrainPrelude <> storagePrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('shared', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.h = t.value SHARED.terrain = api.terrain self.s = 1 end end"
        , "else"
        , "  if self.s == 0 and SHARED.h then self.q = api.terrain.attach('shared') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      local b = t.value"
        , "      self.r1 = api.terrain.status(b) self.r2 = api.terrain.status(b)"
        , "      print('bank full', select('#', api.terrain.status(b)))"
        , "      try('foreign status', api.terrain.status, SHARED.h)"
        , "      try('foreign grow', api.terrain.grow_storage, SHARED.h, 128 * MIB)"
        , "      try('foreign retry', api.terrain.retry_storage, SHARED.h)"
        , "      try('captured status', function() return SHARED.terrain.status(SHARED.h) end)"
        , "      try('captured grow', function() return SHARED.terrain.grow_storage(SHARED.h, 128 * MIB) end)"
        , "      try('attachment grow under pressure', api.terrain.grow_storage, b, 128 * MIB)"
        , "      try('attachment retry under pressure', api.terrain.retry_storage, b)"
        , "      print('done') self.s = 2"
        , "    end"
        , "  end"
        , "end"
        ]
    }

-- | The phases: a module whose top level a hook started reaches for a kept facade; the hooks' own calls in shutdown. The creator keeps
-- its facade in a shared module.
phases ∷ Script
phases =
  script
    { scPrelude = terrainPrelude <> storagePrelude <> ["local share = import('lua/share.lua')"]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value share.api = api share.arena = t.value"
        , "    self.m = api.content.module('lua/late.lua') self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  if settle(api, self.m) then print('ready') self.s = 2 end"
        , "end"
        ]
    , scShutdown =
        [ "try('shutdown status', api.terrain.status, self.arena)"
        , "try('shutdown grow', api.terrain.grow_storage, self.arena, 128 * MIB)"
        , "try('shutdown retry', api.terrain.retry_storage, self.arena)"
        , "print('shutdown release', api.terrain.release(self.arena))"
        ]
    }

lateModule ∷ (FilePath, ByteString)
lateModule =
  ( "lua/late.lua"
  , luaMain $
      tryPrelude
        <> [ "local share = import('lua/share.lua')"
           , "try('top-level status', function() return share.api.terrain.status(share.arena) end)"
           , "try('top-level grow', function() return share.api.terrain.grow_storage(share.arena, 128 * 1024 * 1024) end)"
           , "try('top-level retry', function() return share.api.terrain.retry_storage(share.arena) end)"
           , "try('top-level open', function() return share.api.terrain.open('late', { materials = {}, layers = {} }, { storage_bytes = 64 * 1024 * 1024 }) end)"
           , "return {}"
           ]
  )

-- | An instance with a request bank of two: it fills the bank and asks each storage call, then waits while the example stops the
-- session and asks again.
storageUnderPressure ∷ Script
storageUnderPressure =
  script
    { scPrelude =
        terrainPrelude
          <> storagePrelude
          <> [ "local function busy(label, ...)"
             , "  local res = table.pack(...)"
             , "  print(label, res.n, res[1] == nil, res[2] and res[2].code)"
             , "end"
             ]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    local A = t.value self.a = A"
        , "    self.r1 = api.terrain.status(A) self.r2 = api.terrain.status(A)"
        , "    busy('status', api.terrain.status(A))"
        , "    busy('grow', api.terrain.grow_storage(A, 128 * MIB))"
        , "    busy('retry', api.terrain.retry_storage(A))"
        , "    busy('open with storage', api.terrain.open('second', DEF, { storage_bytes = 64 * MIB }))"
        , "    print('busy done') self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local ok, r = pcall(api.terrain.grow_storage, self.a, 128 * MIB)"
        , "  if not ok then print('stopping', string.find(tostring(r), 'stopping', 1, true) ~= nil, string.find(tostring(r), 'busy', 1, true) ~= nil) self.s = 2 end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain storage calls" $ do
  it "refuses every malformed storage argument, option, arity and authority as an ordinary error before admission, with no request, name, credit or native work" $ do
    faults ← newFaults
    withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource decodeScript)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          checkCases decodeCases printed
          printed `shouldContain` ["trap\tfalse"]
          -- every refusal was before admission: all sixteen places are free for the statuses that follow
          printed `shouldContain` ["places after the refusals\t16"]
          -- nothing reached the service or its backend: the one arena, its two leases, and the one file of main
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
          limitHeld (rgService rig) "leases" `shouldReturn` 2
          (length . filter isCreate <$> nativeOps faults) `shouldReturn` 1

  it "accepts the two-argument open, nil, an empty record, an absent storage_bytes and the minimum as the service's own allowance, a larger one exactly, and copies the options at the call" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource acceptedOpens)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          let own = Text.pack (show (mib 64))
          mapM_ (\name → printed `shouldContain` [name <> " status\tsuccess\t" <> own]) ["two", "nil", "empty", "absent", "minimum"]
          printed `shouldContain` ["larger status\tsuccess\t" <> Text.pack (show (mib 96))]
          printed `shouldContain` ["copied status\tsuccess\t" <> Text.pack (show (mib 80))]

  describe "the creator and its attachment" $
    mapM_
      ( \(role, over, drive) →
          it ("status through either lease, growth larger, equal, smaller and superseded, an idempotent retry, and the attachment's refusals, from a " <> role <> " creator") $
            withRig $ \rig →
              withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource creatorSteps)]) $ \world control runtime →
                withFvm world runtime (over rig) $ \fvm → do
                  _ ← spawn world fvm "modules-test" mainPath
                  pumpUntil world (drive world control fvm >> (elem "done" <$> outLines world))
                  printed ← outLines world
                  masked printed `shouldBe` creatorExpected
      )
      [ ("presentation", presentationOver, \world _ _ → advanceClock world 2000000000)
      , ("gameplay", gameplayOver, \_ control fvm → tickBy control fvm 1)
      ]

  it "refuses another instance's handle and a captured facade as ordinary errors, and an attachment's growth and retry, never busy, with the caller's bank full" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 4)]) (Layout [("lua/main.lua", scriptSource foreignStorage)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          printed
            `shouldContain` [ "bank full\t2"
                            , "foreign status => false ; hetoimasia_engine.terrain_status: the arena belongs to another instance"
                            , "foreign grow => false ; hetoimasia_engine.terrain_grow_storage: the arena belongs to another instance"
                            , "foreign retry => false ; hetoimasia_engine.terrain_retry_storage: the arena belongs to another instance"
                            ]
          printed `shouldSatisfy` any (\l → "captured status => false" `Text.isPrefixOf` l && not ("busy" `Text.isInfixOf` l))
          printed `shouldSatisfy` any (\l → "captured grow => false" `Text.isPrefixOf` l && not ("busy" `Text.isInfixOf` l))
          printed
            `shouldContain` [ "attachment grow under pressure => false ; hetoimasia_engine.terrain_grow_storage: only the arena's creator lease may grow its storage"
                            , "attachment retry under pressure => false ; hetoimasia_engine.terrain_retry_storage: only the arena's creator lease may retry its storage"
                            ]

  it "refuses the storage calls at a module's top level and in shutdown, where release still answers" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource phases), ("lua/share.lua", luaMain ["return {}"]), lateModule]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "ready"
          stopSpawned spawned
          untilPrinted world "shutdown release\tdone"
          printed ← outLines world
          let refused label = printed `shouldSatisfy` any (\l → (label <> " => false ; ") `Text.isPrefixOf` l && not ("busy" `Text.isInfixOf` l))
          mapM_ refused ["top-level status", "top-level grow", "top-level retry", "top-level open"]
          printed
            `shouldContain` [ "shutdown status => false ; hetoimasia_engine.terrain_status: a terrain status is not available in shutdown"
                            , "shutdown grow => false ; hetoimasia_engine.terrain_grow_storage: a terrain storage growth is not available in shutdown"
                            , "shutdown retry => false ; hetoimasia_engine.terrain_retry_storage: a terrain storage retry is not available in shutdown"
                            ]

  it "answers a full request bank with exactly nil and busy for each storage call with nothing reaching the service, and a stopping session with an ordinary error" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource storageUnderPressure)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "busy done"
          printed ← outLines world
          printed `shouldContain` ["status\t2\ttrue\tbusy", "grow\t2\ttrue\tbusy", "retry\t2\ttrue\tbusy", "open with storage\t2\ttrue\tbusy"]
          -- nothing reached the service: one arena, its allowance unchanged
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
          setAdmission world AdmissionStopping
          untilPrinted world "stopping\ttrue\tfalse"
          setAdmission world AdmissionOpen
