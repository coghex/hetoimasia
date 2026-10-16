-- | Registered bindings called from Lua: what crosses, what is refused, and what
-- a script cannot hide.
--
-- Every example runs a chunk in an owner built over the sample registration, and
-- reads what happened from the bindings' own log and from the fault the owner's
-- operation raised. A chunk that ends without a fault ran every assertion it
-- contains.
module Test.Lua.Boundary.Bindings (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, fromException, try)
import Data.IORef (readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (..)
  , Effect (..)
  , FaultOperation (CallBinding)
  , FaultReason (..)
  , VmConfig (vmLibraries, vmValueLimits)
  )
import Hetoimasia.Scripting.Lua.Registration (BindingKind (..), commandReasonLimit)
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support

-- | An owner of the sample registration granted @sample@ whose crossings are
-- bounded by these limits.
limited ∷ Fixture → Int → Int → Int → VmConfig
limited fixture bytes depth elements =
  (sampleConfig fixture ["sample"]) {vmValueLimits = either (error . show) id (valueLimits bytes depth elements)}

-- | The refusal a chunk raises, with the fault around it.
refused ∷ Fixture → Text → IO (BoundaryFault, ValueRefusal)
refused fixture source = withOwner fixture ["sample"] $ \owned → do
  fault ← runFault owned source
  case refusal fault of
    Just found → pure (fault, found)
    Nothing → expectationFailure ("not a refusal of a value: " <> show (reasonOf fault)) >> error "unreachable"

ruleOf ∷ Fixture → Text → IO ValueRule
ruleOf fixture source = refusalRule . snd <$> refused fixture source

spec ∷ Spec
spec = describe "bindings called from Lua" $ do
  describe "what crosses" $ do
    it "validates arguments, runs the action and returns validated results" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → run owned "sample.set_value('sum', sample.add(2, 3))"
      stateOf fixture >>= (`shouldBe` Map.fromList [("sum", 5)])
      logged fixture >>= (`shouldBe` ["add", "set_value"])

    it "keeps every 64-bit integer exact and every float a float" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned →
        run
          owned
          ( Text.unlines
              [ "assert(sample.echo_integer(math.mininteger) == math.mininteger)"
              , "assert(sample.echo_integer(math.maxinteger) == math.maxinteger)"
              , "assert(sample.echo_integer(9007199254740993) == 9007199254740993)"
              , "assert(math.type(sample.echo_number(3)) == 'integer')"
              , "assert(math.type(sample.echo_number(3.0)) == 'float')"
              , "assert(sample.echo_number(1/0) == 1/0)"
              , "local nan = sample.echo_number(0/0)"
              , "assert(nan ~= nan)"
              , "assert(math.type(sample.echo_float(2.5)) == 'float')"
              ]
          )

    it "refuses an integral float where an integer is declared, and an integer where a float is" $ do
      fixture ← newFixture
      ruleOf fixture "sample.echo_integer(1.0)" >>= (`shouldBe` RuleFloatForInteger)
      ruleOf fixture "sample.echo_float(1)" >>= (`shouldBe` RuleWrongType "float" "integer")
      logged fixture >>= (`shouldBe` [])

    it "distinguishes byte strings from text and refuses invalid UTF-8 where text is declared" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned →
        run
          owned
          ( Text.unlines
              [ "assert(sample.echo_bytes('\\xff\\x00abc') == '\\xff\\x00abc')"
              , "assert(sample.echo_text('h\\u{e9}llo') == 'h\\u{e9}llo')"
              , "assert(sample.echo_text('') == '')"
              ]
          )
      ruleOf fixture "sample.echo_text('\\xff')" >>= (`shouldBe` RuleInvalidUtf8)
      -- Overlong, surrogate and truncated sequences are not UTF-8 either.
      ruleOf fixture "sample.echo_text('\\xc0\\x80')" >>= (`shouldBe` RuleInvalidUtf8)
      ruleOf fixture "sample.echo_text('\\xed\\xa0\\x80')" >>= (`shouldBe` RuleInvalidUtf8)
      ruleOf fixture "sample.echo_text('\\xe2\\x82')" >>= (`shouldBe` RuleInvalidUtf8)

    it "requires exactly the declared number of values" $ do
      fixture ← newFixture
      ruleOf fixture "sample.add(1)" >>= (`shouldBe` RuleArity 2 1)
      ruleOf fixture "sample.add(1, 2, 3)" >>= (`shouldBe` RuleArity 2 3)
      ruleOf fixture "sample.nothing(nil)" >>= (`shouldBe` RuleArity 0 1)
      withOwner fixture ["sample"] $ \owned → run owned "sample.nothing(); sample.echo_any3(1, 'a', nil)"

    it "reads lists, nested lists and records, and refuses what is not one" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned →
        run
          owned
          ( Text.unlines
              [ "local list = sample.echo_list({1, 2.5, 3})"
              , "assert(#list == 3 and list[2] == 2.5 and math.type(list[3]) == 'integer')"
              , "assert(#sample.echo_list({}) == 0)"
              , "local nested = sample.echo_nested({{1, 2}, {3}})"
              , "assert(nested[1][2] == 2 and nested[2][1] == 3)"
              , "local record = sample.echo_record({name = 'n', count = 7})"
              , "assert(record.name == 'n' and record.count == 7 and record.note == nil)"
              , "assert(sample.echo_record({name = 'n', count = 7, note = 'x'}).note == 'x')"
              ]
          )
      ruleOf fixture "sample.echo_list({1, 2, nil, 4})" >>= (`shouldBe` RuleNotASequence)
      ruleOf fixture "sample.echo_list({[1] = 1, x = 2})" >>= (`shouldBe` RuleNotASequence)
      ruleOf fixture "sample.echo_list({[2] = 1})" >>= (`shouldBe` RuleNotASequence)
      ruleOf fixture "sample.echo_list({1, 'two'})" >>= (`shouldBe` RuleWrongType "number" "string")
      ruleOf fixture "sample.echo_record({name = 'n'})" >>= (`shouldBe` RuleMissingField "count")
      ruleOf fixture "sample.echo_record({name = 'n', count = 1, extra = 2})" >>= (`shouldBe` RuleUnknownField "extra")
      ruleOf fixture "sample.echo_record({name = 'n', count = 1, [1] = 2})" >>= (`shouldBe` RuleNotARecord)
      ruleOf fixture "sample.echo_record({name = 'n', count = 1.5})" >>= (`shouldBe` RuleFloatForInteger)
      ruleOf fixture "sample.echo_record(5)" >>= (`shouldBe` RuleWrongType "record" "integer")

    it "says where in a value a refusal is" $ do
      fixture ← newFixture
      (_, found) ← refused fixture "sample.echo_record({name = 'n', count = 'one'})"
      refusalPath found `shouldBe` [AtField "count"]
      refusalIndex found `shouldBe` 1
      (_, listed) ← refused fixture "sample.echo_nested({{1}, {2, 3.5}})"
      refusalPath listed `shouldBe` [AtIndex 2, AtIndex 2]

  describe "a nil in a table" $ do
    it "refuses a result that Lua could not keep, with a typed reason, rather than dropping it" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        list ← runFault owned "sample.nil_list()"
        fmap refusalRule (refusal list) `shouldBe` Just RuleNilInTable
        fmap refusalPath (refusal list) `shouldBe` Just [AtIndex 2]
        fmap refusalSide (refusal list) `shouldBe` Just Results
        boundaryEffect list `shouldBe` BindingRan
        required ← runFault owned "sample.nil_field()"
        fmap refusalRule (refusal required) `shouldBe` Just RuleNilInTable
        fmap refusalPath (refusal required) `shouldBe` Just [AtField "a"]
        -- Inspection of nil fields is bounded like any other value: an endless
        -- record of them is refused at the element limit.
        endless ← runFault owned "sample.endless_nil()"
        fmap refusalRule (refusal endless) `shouldBe` Just (RuleElementLimit 4096)
        -- An optional field that is nil is simply absent.
        run owned "local r = sample.nil_optional(); assert(r.a == 1 and r.b == nil and next(r, 'a') == nil)"

  describe "what is refused without being read" $ do
    it "refuses a table carrying a metatable without consulting any metamethod" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        fault ←
          runFault
            owned
            ( Text.unlines
                [ "touched = {}"
                , "local function touch(name) return function() touched[name] = true; return nil end end"
                , "local guarded = setmetatable({1, 2}, {"
                , "  __index = touch('index'), __len = touch('len'), __pairs = touch('pairs'),"
                , "  __newindex = touch('newindex'), __eq = touch('eq'), __tostring = touch('tostring'),"
                , "  __call = touch('call'), __gc = touch('gc'), __close = touch('close') })"
                , "local ok = pcall(sample.echo_list, guarded)"
                , "assert(ok == false)"
                , "assert(next(touched) == nil)"
                , "sample.set_value('after', 1)"
                ]
            )
        fmap refusalRule (refusal fault) `shouldBe` Just RuleMetatable
      -- The script ran on past the refused call, and nothing ran for it.
      stateOf fixture >>= (`shouldBe` Map.fromList [("after", 1)])
      logged fixture >>= (`shouldBe` ["set_value"])

    it "refuses even an empty metatable, so a copy never depends on one" $ do
      fixture ← newFixture
      ruleOf fixture "sample.echo_list(setmetatable({1}, {}))" >>= (`shouldBe` RuleMetatable)

    it "refuses a table that contains itself" $ do
      fixture ← newFixture
      ruleOf fixture "local t = {}; t[1] = t; sample.echo_list(t)" >>= (`shouldBe` RuleCycle)
      ruleOf fixture "local a, b = {}, {}; a[1] = b; b[1] = a; sample.echo_nested(a)" >>= (`shouldBe` RuleCycle)
      -- Sharing is not a cycle.
      withOwner fixture ["sample"] $ \owned → run owned "local s = {1}; assert(#sample.echo_nested({s, s}) == 2)"

    it "refuses a function, a coroutine, a light userdata and a foreign userdata with a typed reason" $ do
      fixture ← newFixture
      let config = (limited fixture 65536 8 4096) {vmLibraries = [minBound .. maxBound]}
          reason source = withOwnerOf config $ \owned → fmap refusalRule . refusal <$> runFault owned source
      reason "sample.echo_list({print})" >>= (`shouldBe` Just (RuleUnsupportedType "function"))
      reason "sample.echo_list({function() end})" >>= (`shouldBe` Just (RuleUnsupportedType "function"))
      reason "sample.echo_list({io.stdout})" >>= (`shouldBe` Just (RuleUnsupportedType "userdata"))
      -- The registry's main thread is a coroutine value.
      reason "sample.echo_list({debug.getregistry()[1]})" >>= (`shouldBe` Just (RuleUnsupportedType "thread"))
      reason
        "for k in pairs(debug.getregistry()) do if type(k) == 'userdata' then sample.echo_list({k}) end end"
        >>= (`shouldBe` Just (RuleUnsupportedType "light userdata"))
      reason "sample.echo_record({name = print, count = 1})" >>= (`shouldBe` Just (RuleUnsupportedType "function"))

    it "refuses a table key that is neither an integer nor a string" $ do
      fixture ← newFixture
      ruleOf fixture "sample.echo_record({name = 'n', count = 1, [1.5] = 2})" >>= (`shouldBe` RuleKeyType)
      ruleOf fixture "sample.echo_record({name = 'n', count = 1, [true] = 2})" >>= (`shouldBe` RuleKeyType)

  describe "the limits" $ do
    let refusing fixture bytes depth elements source = withOwnerOf (limited fixture bytes depth elements) $ \owned →
          fmap refusalRule . refusal <$> runFault owned source
        accepting fixture bytes depth elements source = withOwnerOf (limited fixture bytes depth elements) $ \owned → run owned source
        listOf n = "sample.echo_list({" <> Text.intercalate "," (replicate n "1") <> "})"

    it "accepts a copy at the element limit and refuses one past it" $ do
      fixture ← newFixture
      -- A list of n numbers is n + 1 values: the table and its items.
      accepting fixture 65536 8 11 (listOf 10)
      refusing fixture 65536 8 11 (listOf 11) >>= (`shouldBe` Just (RuleElementLimit 11))

    it "accepts a copy at the byte limit and refuses one past it" $ do
      fixture ← newFixture
      -- A list of n integers is 5 + 18n bytes.
      accepting fixture 59 8 4096 (listOf 3)
      refusing fixture 59 8 4096 (listOf 4) >>= (`shouldBe` Just (RuleBytesLimit 59))
      -- A string is 5 and its length.
      accepting fixture 15 8 4096 "sample.echo_text(('x'):rep(10))"
      refusing fixture 15 8 4096 "sample.echo_text(('x'):rep(11))" >>= (`shouldBe` Just (RuleBytesLimit 15))

    it "accepts a copy at the depth limit and refuses one past it" $ do
      fixture ← newFixture
      accepting fixture 65536 2 4096 "sample.echo_nested({{1}})"
      refusing fixture 65536 2 4096 "sample.echo_list({{{1}}})" >>= (`shouldBe` Just (RuleDepthLimit 2))
      accepting fixture 65536 1 4096 (listOf 3)
      refusing fixture 65536 1 4096 "sample.echo_nested({{1}})" >>= (`shouldBe` Just (RuleDepthLimit 1))

    it "stops reading at a limit, however large the input is" $ do
      fixture ← newFixture
      withOwnerOf (limited fixture 65536 8 100) $ \owned → do
        fault ← runFault owned "local t = {}; for i = 1, 200000 do t[i] = i end; sample.echo_list(t)"
        case refusal fault of
          Just found → do
            refusalRule found `shouldBe` RuleElementLimit 100
            -- The element limit bounds the values visited by itself plus one.
            refusalVisited found `shouldSatisfy` (<= 101)
          Nothing → expectationFailure "not a refusal"
      withOwnerOf (limited fixture 1000 8 4096) $ \owned → do
        fault ← runFault owned "sample.echo_text(('x'):rep(50 * 1000 * 1000))"
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleBytesLimit 1000)
      -- Deeply nested input is refused at the depth limit, not walked.
      withOwnerOf (limited fixture 65536 4 4096) $ \owned → do
        fault ← runFault owned "local t = {}; for i = 1, 100000 do t = {t} end; sample.echo_list(t)"
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleDepthLimit 4)

    it "bounds results by the same limits, after the action has run" $ do
      fixture ← newFixture
      accepting fixture 65536 8 11 "assert(#sample.make_list(10) == 10)"
      fault ← withOwnerOf (limited fixture 65536 8 11) $ \owned → runFault owned "sample.make_list(11)"
      fmap refusalRule (refusal fault) `shouldBe` Just (RuleElementLimit 11)
      fmap refusalSide (refusal fault) `shouldBe` Just Results
      boundaryEffect fault `shouldBe` BindingRan
      logged fixture >>= (`shouldSatisfy` ("make_list" `elem`))
      -- A result far past the limits is refused after visiting what they allow, not
      -- after building it: this list is a hundred million values.
      huge ← withOwnerOf (limited fixture 65536 8 11) $ \owned → runFault owned "sample.make_list(100000000)"
      fmap refusalRule (refusal huge) `shouldBe` Just (RuleElementLimit 11)
      byBytes ← withOwnerOf (limited fixture 15 8 4096) $ \owned → runFault owned "sample.make_text(11)"
      fmap refusalRule (refusal byBytes) `shouldBe` Just (RuleBytesLimit 15)
      accepting fixture 15 8 4096 "assert(#sample.make_text(10) == 10)"
      byDepth ← withOwnerOf (limited fixture 65536 1 4096) $ \owned → runFault owned "sample.make_nested()"
      fmap refusalRule (refusal byDepth) `shouldBe` Just (RuleDepthLimit 1)

  describe "a refusal is a fault of the call" $ do
    it "raises a typed failure naming the binding, argument and rule even when the script caught it" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        fault ←
          runFault
            owned
            "local ok, marker = pcall(sample.add, 1.5, 2); assert(ok == false); sample.set_value('survived', 1)"
        boundaryOperation fault `shouldBe` CallBinding
        boundaryBinding fault `shouldBe` Just ("sample", "add")
        boundaryOwner fault `shouldBe` "sample owner"
        -- The chunk the script called from, not the binding's own name, and a
        -- bounded traceback from there; no module is running.
        boundaryChunk fault `shouldBe` "example"
        boundaryModule fault `shouldBe` Nothing
        boundaryEntry fault `shouldBe` Nothing
        fmap (Text.isInfixOf "example:1") (boundaryTraceback fault) `shouldBe` Just True
        fmap refusalSide (refusal fault) `shouldBe` Just Arguments
        fmap refusalIndex (refusal fault) `shouldBe` Just 1
        fmap refusalRule (refusal fault) `shouldBe` Just RuleFloatForInteger
      stateOf fixture >>= (`shouldBe` Map.fromList [("survived", 1)])
      logged fixture >>= (`shouldBe` ["set_value"])

    it "never runs the action for a refused argument, and runs it before a refused result" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        before ← runFault owned "sample.add('a', 2)"
        boundaryEffect before `shouldBe` LuaRan
        logged fixture >>= (`shouldBe` [])
        after ← runFault owned "sample.wrong_result()"
        boundaryEffect after `shouldBe` BindingRan
        fmap refusalSide (refusal after) `shouldBe` Just Results
        fmap refusalRule (refusal after) `shouldBe` Just (RuleWrongType "integer" "text")
        logged fixture >>= (`shouldBe` ["wrong_result"])
        short ← runFault owned "sample.short_result()"
        fmap refusalRule (refusal short) `shouldBe` Just (RuleArity 2 1)

    it "records that an earlier action ran when a later argument is refused" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        fault ← runFault owned "sample.set_value('a', 1); sample.add('x', 1)"
        boundaryEffect fault `shouldBe` BindingRan
        stateOf fixture >>= (`shouldBe` Map.fromList [("a", 1)])

    it "leaves the owner usable after a fault caught inside its body" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        _ ← runFault owned "sample.add(1.5, 2)"
        run owned "sample.set_value('again', sample.add(1, 2))"
      stateOf fixture >>= (`shouldBe` Map.fromList [("again", 3)])

  describe "binding kinds" $ do
    it "answers acceptance or a bounded rejection as data" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned →
        run
          owned
          ( Text.unlines
              [ "local accepted, reason = sample.submit('go')"
              , "assert(accepted == true and reason == nil)"
              , "local rejected, why = sample.submit('bad')"
              , "assert(rejected == false and why == 'not allowed')"
              ]
          )
      logged fixture >>= (`shouldBe` ["submit", "submit"])

    it "refuses a rejection past the reason bound as a fault of the result" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        fault ← runFault owned "sample.submit('huge')"
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleBytesLimit commandReasonLimit)
        boundaryEffect fault `shouldBe` BindingRan

    it "classifies asynchronous and lifecycle bindings and refuses a call as not yet supported, under pcall too" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        asynchronous ← runFault owned "sample.spawn_async('x')"
        boundaryReason asynchronous `shouldBe` NotYetSupported AsynchronousNativeRequest
        lifecycle ← runFault owned "sample.stop()"
        boundaryReason lifecycle `shouldBe` NotYetSupported LifecycleOperation
        caught ← runFault owned "local ok = pcall(sample.spawn_async, 'x'); assert(ok == false); sample.set_value('after', 1)"
        boundaryReason caught `shouldBe` NotYetSupported AsynchronousNativeRequest
        boundaryEffect caught `shouldBe` LuaRan
      -- Neither action ran, in any of the three calls.
      logged fixture >>= (`shouldBe` ["set_value"])

    it "runs only the bindings of the namespaces an owner is granted" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → run owned "assert(sample == nil and other == nil)"
      withOwner fixture ["other"] $ \owned → run owned "assert(sample == nil); assert(other.ping() == 'pong')"
      withOwner fixture ["sample"] $ \owned → run owned "assert(other == nil); assert(type(sample.add) == 'function')"
      withOwner fixture ["sample", "other"] $ \owned → run owned "assert(other.ping() == 'pong' and sample.add(1, 1) == 2)"

    it "does not install a binding that is not eligible for the direct path" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → run owned "assert(sample.hidden == nil)"

  describe "handles" $ do
    it "hands a script an opaque capability that it can pass back and copy but not forge" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned →
        run
          owned
          ( Text.unlines
              [ "local t = sample.ticket(7)"
              , "assert(type(t) == 'userdata')"
              , "assert(tostring(t) == '<handle>')"
              , "assert(getmetatable(t) == false)"
              , "assert(sample.redeem(t) == true)"
              , "local copy = t"
              , "assert(sample.redeem(copy) == true)"
              , "assert(t == sample.ticket(7) and t ~= sample.ticket(8))"
              , "local list = sample.redeem_two({t, copy})"
              , "assert(list == 2)"
              ]
          )

    it "refuses an imitated handle: a number, a table with the same fields, copied contents" $ do
      fixture ← newFixture
      _ ← grantTicket fixture 7
      ruleOf fixture "sample.redeem(7)" >>= (`shouldBe` RuleWrongType "capability ticket" "integer")
      ruleOf fixture "sample.redeem({type = 'ticket', key = 7})" >>= (`shouldBe` RuleWrongType "capability ticket" "table")
      ruleOf fixture "sample.redeem('ticket:7')" >>= (`shouldBe` RuleWrongType "capability ticket" "string")
      ruleOf fixture "local t = sample.ticket(7); sample.redeem(tostring(t))" >>= (`shouldBe` RuleWrongType "capability ticket" "string")
      logged fixture >>= (`shouldSatisfy` notElem "redeem")

    it "refuses a handle of another type" $ do
      fixture ← newFixture
      (_, found) ← refused fixture "sample.redeem_badge(sample.ticket(1))"
      refusalRule found `shouldBe` RuleHandleType "badge" "ticket"
      logged fixture >>= (`shouldSatisfy` notElem "redeem_badge")

    it "runs the application's own liveness check at every use, before the action" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        run owned "held = sample.ticket(7); assert(sample.redeem(held))"
        retire fixture 7
        fault ← runFault owned "sample.redeem(held)"
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleRetiredHandle "ticket")
        -- The action ran once, for the use before the retirement.
        logged fixture >>= (`shouldBe` ["ticket", "redeem"])
      withOwner fixture ["sample"] $ \owned → do
        _ ← grantTicket fixture 1
        _ ← grantTicket fixture 2
        run owned "a = sample.ticket(1); b = sample.ticket(2)"
        retire fixture 2
        fault ← runFault owned "sample.redeem_two({a, b})"
        fmap refusalPath (refusal fault) `shouldBe` Just [AtIndex 2]

  describe "the VM an action runs under" $ do
    it "refuses an action that runs Lua on its own VM or closes it with VmReentered" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        writeIORef (fixtureSelf fixture) (Just owned)
        run owned "sample.reenter()"
        readIORef (fixtureAttempt fixture) >>= (`shouldBe` Just "reentered")
        writeIORef (fixtureAttempt fixture) Nothing
        run owned "sample.close_self()"
        readIORef (fixtureAttempt fixture) >>= (`shouldBe` Just "reentered")
        -- The attempts changed nothing: the owner still runs Lua.
        run owned "assert(attempted == nil); sample.set_value('after', 1)"
      stateOf fixture >>= (`shouldBe` Map.fromList [("after", 1)])

    it "refuses an action that uses another owner's VM with VmNotOwned" $ do
      fixture ← newFixture
      ready ← newEmptyMVar
      release ← newEmptyMVar
      finished ← newEmptyMVar
      _ ← forkIO $ do
        withOwner fixture [] $ \other → do
          writeIORef (fixtureOther fixture) (Just other)
          putMVar ready ()
          takeMVar release
        putMVar finished ()
      takeMVar ready
      withOwner fixture ["sample"] $ \owned → do
        run owned "sample.trespass()"
        readIORef (fixtureAttempt fixture) >>= (`shouldBe` Just "not owned")
      putMVar release ()
      takeMVar finished

    it "re-raises a Haskell failure from the action at the owner's boundary with its own type, under pcall too" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        outcome ← try @SomeException (run owned "local ok = pcall(sample.fail, 'x'); assert(ok == false)")
        case outcome of
          Left failure | Just userError' ← fromException failure → show (userError' ∷ IOError) `shouldBe` "user error (the action failed)"
          other → expectationFailure ("not the action's own failure: " <> show other)
        -- Owned state afterwards is usable.
        run owned "sample.set_value('after', 1)"
      logged fixture >>= (`shouldBe` ["fail", "set_value"])
