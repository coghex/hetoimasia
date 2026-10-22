-- | The M1 library profile (D-5, D-69): the filtered standard-library surface an
-- owner can select in place of an explicit list.
--
-- Everything here runs real Lua and reads what the scripts themselves can see,
-- through the public owner: a probe module whose entry points report, from inside
-- the VM, which excluded names are reachable and through which alias, and the
-- exact surface that is left. The same probe over a general owner proves it can
-- see what it looks for, so an empty report is a finding and not a blind spot.
--
-- The owners that share a process are sequenced with @MVar@s the examples hold,
-- and every wait is bounded; nothing here sleeps.
module Test.Lua.Owner.Profile (spec) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Bridge (evalChunk)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterAllocation, ownerAfterLibraries, ownerChunks, ownerProfile)
  , defaultOwnerConfig
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), filterLibraries, stackDepth, vmPhase)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryEffect, boundaryOperation, boundaryReason)
  , CallResult (Returned)
  , EntryPoint (EntryPoint)
  , Effect (NoEffect)
  , ErrorValue (ErrorMessage)
  , FaultKind (CallFailed)
  , FaultOperation (OpenLibraries)
  , FaultReason (ProfileWithLibraries, ScriptFailed)
  , Library
      ( LibraryBase
      , LibraryCoroutine
      , LibraryDebug
      , LibraryIo
      , LibraryMath
      , LibraryOs
      , LibraryPackage
      , LibraryString
      , LibraryTable
      )
  , LibraryProfile (LibraryProfileM1)
  , LuaFault (faultChunk, faultKind, faultValue)
  , ModuleRef (ModuleRef)
  , ModuleSource (ModuleSource)
  , OwnedVm
  , Requirement (Required)
  , VmConfig (vmInitialChunks, vmLibraries, vmLibraryProfile, vmModules)
  , callEntry
  , chunkName
  , evalOwned
  , loadedModule
  , vmConfig
  , vmProfileConfig
  , withVmOwner
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SText), Value (VText))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (logged, newFixture, sampleConfig)
import Test.Lua.Owner.Support
import Test.Lua.Support (Recorder, newRecorder, recorded, recordingCallback, withVm)
import Test.Support.Bounded (bounded)

-- | The libraries the profile owns, as an explicit list: what a general owner
-- over the same libraries opens, with nothing removed.
profileLibrarySet ∷ [Library]
profileLibrarySet = [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryCoroutine]

-- | Every library the host can open.
everyLibrary ∷ [Library]
everyLibrary = profileLibrarySet <> [LibraryPackage, LibraryIo, LibraryOs, LibraryDebug]

-- | @scan@: a local function that answers, as sorted text, every excluded name
-- the script can reach, and how: directly, through @rawget@, through @_G@ and
-- @_ENV@, through the string metatable's index and a string literal, and by
-- enumerating each library table. It is a local so that it adds nothing to the
-- globals the surface example lists.
scanSource ∷ Text
scanSource =
  Text.unlines
    [ "local function scan()"
    , "  local forbidden = {}"
    , "  for _, name in ipairs({'os', 'io', 'package', 'require', 'load', 'loadfile', 'dofile',"
    , "                         'debug', 'collectgarbage', 'dump', 'random', 'randomseed'}) do"
    , "    forbidden[name] = true"
    , "  end"
    , "  local found = {}"
    , "  local function check(label, value) if value ~= nil then found[#found + 1] = label end end"
    , "  for name in pairs(forbidden) do"
    , "    check('_G.' .. name, _G[name])"
    , "    check('rawget(_G).' .. name, rawget(_G, name))"
    , "    check('_ENV.' .. name, _ENV[name])"
    , "  end"
    , "  local meta = getmetatable('').__index"
    , "  check('string.dump', string.dump)"
    , "  check('rawget(string).dump', rawget(string, 'dump'))"
    , "  check('_G.string.dump', _G.string.dump)"
    , "  check('_ENV.string.dump', _ENV.string.dump)"
    , "  check('stringmeta.dump', meta.dump)"
    , "  check('literal.dump', ('').dump)"
    , "  check('math.random', math.random)"
    , "  check('math.randomseed', math.randomseed)"
    , "  check('rawget(math).random', rawget(math, 'random'))"
    , "  check('rawget(math).randomseed', rawget(math, 'randomseed'))"
    , "  check('_G.math.random', _G.math.random)"
    , "  check('_G.math.randomseed', _G.math.randomseed)"
    , "  for _, entry in ipairs({{'_G', _G}, {'string', string}, {'math', math}, {'table', table},"
    , "                          {'coroutine', coroutine}, {'stringmeta', meta}}) do"
    , "    for key in pairs(entry[2]) do"
    , "      if forbidden[key] then check('enumerated ' .. entry[1] .. '.' .. key, true) end"
    , "    end"
    , "  end"
    , "  table.sort(found)"
    , "  return table.concat(found, ',')"
    , "end"
    ]

-- | The first authored code of an owner with an initial chunk: it records what it
-- could reach in @BOOT@, a global the probe module reads through its environment.
bootChunk ∷ ByteString
bootChunk = Text.encodeUtf8 (scanSource <> "BOOT = scan()\n")

probeRef ∷ ModuleRef
probeRef = ModuleRef "probe" "1"

-- | The probe module. @LOADED@ is what its own top-level code could reach as it
-- loaded, which is the first authored code of an owner with no initial chunk.
probeModule ∷ ModuleSource
probeModule =
  ModuleSource
    probeRef
    ( Text.encodeUtf8 . Text.unlines $
        [ scanSource
        , "local LOADED = scan()"
        , "function at_load() return LOADED end"
        , "function at_boot() return BOOT or 'no boot chunk' end"
        , "function now() return scan() end"
        , "function ping() return 'pong' end"
        , "function surface()"
        , "  local lines = {}"
        , "  for _, entry in ipairs({{'_G', _G}, {'string', string}, {'table', table}, {'math', math},"
        , "                          {'coroutine', coroutine}}) do"
        , "    local keys = {}"
        , "    for key in pairs(entry[2]) do"
        , "      -- Uppercase names are this fixture's own globals, not the library's."
        , "      if not tostring(key):match('^%u+$') then keys[#keys + 1] = tostring(key) end"
        , "    end"
        , "    table.sort(keys)"
        , "    lines[#lines + 1] = entry[1] .. ': ' .. table.concat(keys, ' ')"
        , "  end"
        , "  return table.concat(lines, '\\n')"
        , "end"
        , "function caught()"
        , "  local ok1, message1 = pcall(function() return load('return 1') end)"
        , "  local ok2, message2 = pcall(math.random)"
        , "  local ok3, message3 = pcall(function() return string.dump(print) end)"
        , "  return table.concat({tostring(ok1), tostring(message1), tostring(ok2), tostring(message2),"
        , "                       tostring(ok3), tostring(message3), tostring(1 + 1)}, '\\n')"
        , "end"
        , "function uncaught() return math.random(1, 6) end"
        , "function permitted()"
        , "  local out = {}"
        , "  local function add(value) out[#out + 1] = tostring(value) end"
        , "  add(string.format('%d-%s', 7, 'x'))"
        , "  add(('abc'):upper())"
        , "  add(string.rep('ab', 3, '-'))"
        , "  add((('hello'):gsub('l', 'L')))"
        , "  add(table.concat({1, 2, 3}, '+'))"
        , "  local sorted = {3, 1, 2}"
        , "  table.sort(sorted)"
        , "  add(table.concat(sorted))"
        , "  add(select('#', table.unpack({1, 2, 3})))"
        , "  add(math.floor(3.7))"
        , "  add(math.max(1, 9, 4))"
        , "  add(math.tointeger(8.0))"
        , "  add(math.sqrt(16))"
        , "  add(math.huge > 1)"
        , "  add(7 // 2)"
        , "  add(next({}))"
        , "  add(setmetatable({}, {__index = function(_, key) return key .. '!' end}).x)"
        , "  local generator = coroutine.wrap(function() for n = 1, 3 do coroutine.yield(n) end end)"
        , "  add(generator() + generator() + generator())"
        , "  local worker = coroutine.create(function() error('inside') end)"
        , "  local resumed = coroutine.resume(worker)"
        , "  add(coroutine.status(worker))"
        , "  add(resumed)"
        , "  return table.concat(out, '|')"
        , "end"
        ]
    )
    ( [ EntryPoint name Required [] [SText]
      | name ← ["at_load", "at_boot", "now", "ping", "surface", "caught", "permitted"]
      ]
        <> [EntryPoint "uncaught" Required [] [SInteger]]
    )

profiled ∷ [(Text, ByteString)] → VmConfig
profiled chunks =
  (vmProfileConfig LibraryProfileM1)
    { vmInitialChunks = [(chunkName name, source) | (name, source) ← chunks]
    , vmModules = [probeModule]
    }

general ∷ [Library] → [(Text, ByteString)] → VmConfig
general libraries chunks =
  (vmConfig libraries)
    { vmInitialChunks = [(chunkName name, source) | (name, source) ← chunks]
    , vmModules = [probeModule]
    }

-- | Call one of the probe module's entry points that answers text.
report ∷ OwnedVm → Text → IO Text
report owned name = do
  handle ← loadedModule owned probeRef >>= maybe (expectationFailure "the probe module was not loaded" >> error "unreachable") pure
  callEntry owned handle name [] >>= \case
    Returned [VText text] → pure text
    other → expectationFailure ("unexpected answer: " <> show other) >> error "unreachable"

-- | The surface the profile leaves, byte-sorted, one library per line. Lua's own
-- names for the libraries it keeps, less the capabilities the profile removes.
expectedSurface ∷ Text
expectedSurface =
  Text.intercalate
    "\n"
    [ "_G: _G _VERSION assert coroutine error getmetatable ipairs math next pairs pcall print rawequal rawget rawlen rawset select setmetatable string table tonumber tostring type warn xpcall"
    , "string: byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper"
    , "table: concat insert move pack remove sort unpack"
    , "math: abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger modf pi rad sin sqrt tan tointeger type ult"
    , "coroutine: close create isyieldable resume running status wrap yield"
    ]

spec ∷ Spec
spec = describe "the M1 library profile" $ do
  describe "the excluded capabilities" $ do
    it "are unreachable by every alias from the first initial chunk, the module's own load and later" $
      withVmOwner (profiled [("boot", bootChunk)]) $ \owned → do
        report owned "at_boot" >>= (`shouldBe` "")
        report owned "at_load" >>= (`shouldBe` "")
        report owned "now" >>= (`shouldBe` "")

    it "are unreachable from a module loaded with no initial chunk before it" $
      withVmOwner (profiled []) $ \owned → do
        report owned "at_boot" >>= (`shouldBe` "no boot chunk")
        report owned "at_load" >>= (`shouldBe` "")
        report owned "now" >>= (`shouldBe` "")

    it "are reachable to the same probe in a general owner, so an empty report is a finding" $ do
      found ← withVmOwner (general everyLibrary [("boot", bootChunk)]) $ \owned → do
        atBoot ← report owned "at_boot"
        atLoad ← report owned "at_load"
        atBoot `shouldBe` atLoad
        pure atBoot
      let reachable = Text.splitOn "," found
      forM_
        [ "_G.os", "_G.io", "_G.package", "_G.require", "_G.load", "_G.loadfile", "_G.dofile", "_G.debug"
        , "_G.collectgarbage", "rawget(_G).load", "_ENV.load", "string.dump", "rawget(string).dump"
        , "_G.string.dump", "_ENV.string.dump", "stringmeta.dump", "literal.dump", "math.random"
        , "math.randomseed", "rawget(math).random", "_G.math.random", "enumerated _G.load"
        , "enumerated string.dump", "enumerated stringmeta.dump", "enumerated math.random"
        ]
        (\label → (label, label `elem` reachable) `shouldBe` (label, True))

    it "leave exactly the documented standard-library surface" $
      withVmOwner (profiled []) $ \owned → report owned "surface" >>= (`shouldBe` expectedSurface)

  describe "calling a removed function" $ do
    it "is an ordinary error a script can catch, and permitted computation goes on" $
      withVmOwner (profiled []) $ \owned → do
        answer ← Text.splitOn "\n" <$> report owned "caught"
        case answer of
          [ok1, message1, ok2, message2, ok3, message3, after] → do
            (ok1, ok2, ok3, after) `shouldBe` ("false", "false", "false", "2")
            message1 `shouldSatisfy` Text.isInfixOf "attempt to call a nil value (global 'load')"
            message2 `shouldSatisfy` Text.isInfixOf "attempt to call a nil value"
            message3 `shouldSatisfy` Text.isInfixOf "attempt to call a nil value (field 'dump')"
          _ → expectationFailure ("unexpected report: " <> show answer)
        report owned "ping" >>= (`shouldBe` "pong")

    it "uncaught, is the existing attributed Lua fault of the call, and leaves the owner usable" $
      withVmOwner (profiled []) $ \owned → do
        handle ← loadedModule owned probeRef >>= maybe (expectationFailure "no probe" >> error "unreachable") pure
        outcome ← try @BoundaryFault (callEntry owned handle "uncaught" [])
        case outcome of
          Left fault → case boundaryReason fault of
            ScriptFailed CallFailed (ErrorMessage message _) →
              message `shouldSatisfy` Text.isInfixOf "attempt to call a nil value (field 'random')"
            other → expectationFailure ("not an ordinary script failure: " <> show other)
          Right answer → expectationFailure ("the call to a removed function succeeded: " <> show (answer :: CallResult))
        report owned "ping" >>= (`shouldBe` "pong")
        report owned "permitted" >>= (`shouldSatisfy` (not . Text.null))

    it "in an initial chunk ends construction with that chunk's Lua fault" $ do
      outcome ← try @LuaFault (withVmOwner (profiled [("first", "local ok = load('return 1')")]) (\_ → pure ()))
      case outcome of
        Left fault → do
          faultKind fault `shouldBe` CallFailed
          faultChunk fault `shouldBe` "first"
          case faultValue fault of
            ErrorMessage message _ → message `shouldSatisfy` Text.isInfixOf "attempt to call a nil value (global 'load')"
            other → expectationFailure ("unexpected error value: " <> show other)
        Right () → expectationFailure "an initial chunk called a removed function and construction succeeded"

  describe "permitted computation" $
    it "keeps the base, string, table, math and coroutine libraries working" $
      withVmOwner (profiled []) $ \owned →
        report owned "permitted"
          >>= (`shouldBe` "7-x|ABC|ab-ab-ab|heLLo|1+2+3|123|3|3|9|8|4.0|true|3|nil|x!|6|dead|false")

  describe "opt-in compatibility" $ do
    it "leaves a general owner over the same libraries as it was" $
      withVmOwner (general profileLibrarySet [("boot", bootChunk)]) $ \owned → do
        found ← Text.splitOn "," <$> report owned "now"
        sort found
          `shouldBe` sort
            [ "_G.load", "rawget(_G).load", "_ENV.load", "_G.loadfile", "rawget(_G).loadfile", "_ENV.loadfile"
            , "_G.dofile", "rawget(_G).dofile", "_ENV.dofile", "_G.collectgarbage", "rawget(_G).collectgarbage"
            , "_ENV.collectgarbage", "string.dump", "rawget(string).dump", "_G.string.dump", "_ENV.string.dump"
            , "stringmeta.dump", "literal.dump", "math.random", "math.randomseed", "rawget(math).random"
            , "rawget(math).randomseed", "_G.math.random", "_G.math.randomseed", "enumerated _G.load"
            , "enumerated _G.loadfile", "enumerated _G.dofile", "enumerated _G.collectgarbage"
            , "enumerated string.dump", "enumerated stringmeta.dump", "enumerated math.random"
            , "enumerated math.randomseed"
            ]

    it "leaves the empty-library configuration with no standard library" $
      withVmOwner
        (vmConfig [])
          { vmInitialChunks =
              [(chunkName "bare", "if load ~= nil or os ~= nil or string ~= nil or print ~= nil or pcall ~= nil then error('opened') end")]
          }
        (\_ → pure ())

    it "leaves the debug library an explicit list opens as it was, without sethook" $
      withVmOwner
        (vmConfig [LibraryBase, LibraryDebug])
          { vmInitialChunks =
              [(chunkName "debug", "if debug.traceback == nil or debug.getinfo == nil or debug.sethook ~= nil then error('changed') end")]
          }
        (\_ → pure ())

    it "installs a granted namespace in a profiled owner, after the filtering" $ do
      fixture ← newFixture
      let config = (sampleConfig fixture ["other"]) {vmLibraries = [], vmLibraryProfile = Just LibraryProfileM1}
      withVmOwner config $ \owned → do
        evalOwned owned (chunkName "grant") "assert(other.ping() == 'pong' and load == nil and string.dump == nil)"
        logged fixture >>= (`shouldSatisfy` elem "ping")

  describe "independent owners" $
    forM_ [(True, "the general owner closes first"), (False, "the profiled owner closes first")] $ \(generalFirst, label) →
      it ("do not change each other's surface while both are live and after either closes: " <> label) $ do
        generalSide ← startSide True
        profiledSide ← startSide False
        forM_ [generalSide, profiledSide] (bounded . takeMVar . sideReady)
        let order = if generalFirst then [generalSide, profiledSide] else [profiledSide, generalSide]
        forM_ order $ \side → do
          putMVar (sideGo side) ()
          outcome ← bounded (takeMVar (sideOutcome side))
          either (const (expectationFailure "an owner failed")) pure outcome
        -- Each owner checked its own surface before the other closed and after.
        recorded (sideChecks generalSide) >>= (`shouldBe` ["ok", "ok"])
        recorded (sideChecks profiledSide) >>= (`shouldBe` ["ok", "ok"])

  describe "selecting a profile with an explicit library list" $ do
    it "is refused at construction through the public owner, naming both" $ do
      outcome ← try @BoundaryFault (withVmOwner ((vmProfileConfig LibraryProfileM1) {vmLibraries = [LibraryIo]}) (\_ → pure ()))
      case outcome of
        Left fault → do
          boundaryReason fault `shouldBe` ProfileWithLibraries LibraryProfileM1 [LibraryIo]
          boundaryOperation fault `shouldBe` OpenLibraries
          boundaryEffect fault `shouldBe` NoEffect
        Right () → expectationFailure "a profile and an explicit library were both accepted"

    it "runs no authored code, closes the VM and leaves the extra library unopened" $ do
      vmRef ← newCaptured
      bodyRan ← newIORef False
      checks ← newRecorder
      let config =
            (defaultOwnerConfig [LibraryOs, LibraryDebug])
              { ownerProfile = Just LibraryProfileM1
              , ownerAfterAllocation = capture vmRef
              , ownerAfterLibraries = \vm → recordingCallback vm checks "after-libraries"
              , ownerChunks = [(chunkName "authored", "after_libraries()")]
              }
      outcome ← runOwner config (\_ → writeIORef bodyRan True)
      case outcome of
        Left failure → do
          fmap boundaryReason (causeOf failure)
            `shouldBe` Just (ProfileWithLibraries LibraryProfileM1 [LibraryOs, LibraryDebug])
          evidenceLabels failure `shouldBe` []
        Right () → expectationFailure "the conflicting configuration was accepted"
      readIORef bodyRan >>= (`shouldBe` False)
      recorded checks >>= (`shouldBe` [])
      captured vmRef >>= \case
        Nothing → expectationFailure "the VM was never constructed"
        Just vm → vmPhase vm >>= (`shouldBe` Closed)

    it "is not refused when the explicit list is empty" $
      withVmOwner ((vmProfileConfig LibraryProfileM1) {vmLibraries = []}) (\_ → pure ())

  describe "a failure of the filtering itself" $
    it "is a Lua fault attributed to the profile, restores the stack and leaves the VM usable" $
      withVm [LibraryBase] $ \vm → do
        before ← stackDepth vm
        outcome ← try @LuaFault (filterLibraries vm LibraryProfileM1)
        case outcome of
          Left fault → do
            faultKind fault `shouldBe` CallFailed
            faultChunk fault `shouldBe` "profile LibraryProfileM1"
            case faultValue fault of
              ErrorMessage message _ → message `shouldSatisfy` Text.isInfixOf "found no string library to filter"
              other → expectationFailure ("unexpected error value: " <> show other)
          Right () → expectationFailure "the filtering succeeded without the libraries it filters"
        stackDepth vm >>= (`shouldBe` before)
        evalChunk vm (chunkName "after") "assert(type(print) == 'function')"

  describe "installation order" $
    it "filters before the after-libraries step, so a step that installs callbacks sees the filtered surface" $ do
      seen ← newIORef Nothing
      let config =
            (defaultOwnerConfig [])
              { ownerProfile = Just LibraryProfileM1
              , ownerAfterLibraries = \vm → do
                  installCallback vm "mark" (writeIORef seen (Just True) >> pure NoResult) (pure ())
              , ownerChunks = [(chunkName "order", "if load == nil and string.dump == nil and math.random == nil then mark() end")]
              }
      outcome ← runOwner config (\_ → pure ())
      either (const (expectationFailure "construction failed")) pure outcome
      readIORef seen >>= (`shouldBe` Just True)

-- | One owner of the independence example: what it checked, and how to reach it.
data Side = Side
  { sideChecks ∷ !Recorder
  , sideReady ∷ !(MVar ())
  , sideGo ∷ !(MVar ())
  , sideOutcome ∷ !(MVar (Outcome ()))
  }

-- | Start an owner on a thread of its own, general or profiled. It checks its own
-- surface once its construction is done and again when it is released, and notes
-- each result with the callback that reports it.
startSide ∷ Bool → IO Side
startSide isGeneral = do
  checks ← newRecorder
  ready ← newEmptyMVar
  go ← newEmptyMVar
  let base = if isGeneral then defaultOwnerConfig profileLibrarySet else (defaultOwnerConfig []) {ownerProfile = Just LibraryProfileM1}
      present = if isGeneral then "~=" else "=="
      config =
        base
          { ownerAfterLibraries = \vm → recordingCallback vm checks "ok" >> recordingCallback vm checks "bad"
          , ownerChunks =
              [ ( chunkName "check"
                , Text.encodeUtf8 . Text.unlines $
                    [ "function check()"
                    , "  local same = load " <> present <> " nil and dofile " <> present <> " nil and collectgarbage " <> present <> " nil"
                    , "  if same and string.dump " <> present <> " nil and math.random " <> present <> " nil then ok() else bad() end"
                    , "end"
                    ]
                )
              ]
          }
  (_, outcome) ← ownerThread config $ \owned → do
    evalOwned owned (chunkName "before") "check()"
    putMVar ready ()
    takeMVar go
    evalOwned owned (chunkName "after") "check()"
  pure (Side checks ready go outcome)
