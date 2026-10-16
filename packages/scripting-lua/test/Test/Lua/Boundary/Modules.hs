-- | Application-owned modules and their entry points.
--
-- The application supplies source under a name and a version, declares which
-- entry points it has and which of them must be there, and calls them with
-- bounded values. The host reads nothing from disk. Each module runs in an
-- environment of its own.
module Test.Lua.Boundary.Modules (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration (maxArity)
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support

-- | A module of this name and version with this source and these entry points.
moduleOf ∷ Text → Text → Text → [EntryPoint] → ModuleSource
moduleOf name version source = ModuleSource (ModuleRef name version) (encodeUtf8 source)

required ∷ Text → [Schema] → [Schema] → EntryPoint
required name = EntryPoint name Required

optional ∷ Text → [Schema] → [Schema] → EntryPoint
optional name = EntryPoint name Optional

-- | The fault an operation raises.
faulted ∷ IO a → IO BoundaryFault
faulted action = do
  outcome ← try @BoundaryFault action
  case outcome of
    Left fault → pure fault
    Right _ → expectationFailure "no fault was raised" >> error "unreachable"

-- | A module with an arithmetic entry point and ways to disturb it.
calculator ∷ ModuleSource
calculator =
  moduleOf
    "calc"
    "1"
    ( Text.unlines
        [ "function add(a, b) return a + b end"
        , "function swap(a, b) return b, a end"
        , "function drop() add = nil end"
        , "function corrupt() add = 5 end"
        , "function boom() error('exploded') end"
        , "function table_error() error({code = 1}) end"
        , "function nil_error() error(nil) end"
        , "function str_error() error(setmetatable({}, {__tostring = function() touched = true end})) end"
        , "function wrong() return 'text' end"
        , "function two() return 1, 2 end"
        , "function counter_touched() return touched == true end"
        ]
    )
    [ required "add" [SInteger, SInteger] [SInteger]
    , required "swap" [SInteger, SInteger] [SInteger, SInteger]
    , required "drop" [] []
    , required "corrupt" [] []
    , required "boom" [] []
    , required "table_error" [] []
    , required "nil_error" [] []
    , required "str_error" [] []
    , required "wrong" [] [SInteger]
    , required "two" [] [SInteger]
    , required "counter_touched" [] [SBoolean]
    , optional "on_tick" [SInteger] []
    ]

spec ∷ Spec
spec = describe "application-owned modules" $ do
  describe "loading" $ do
    it "loads at initialization and from the body, under an identity, from supplied source" $ do
      fixture ← newFixture
      let config = (sampleConfig fixture ["sample"]) {vmModules = [calculator]}
      withOwnerOf config $ \owned → do
        later ← loadModule owned (moduleOf "later" "2" "function ping() return 'pong' end" [required "ping" [] [SText]])
        callEntry owned later "ping" [] >>= (`shouldBe` Returned [VText "pong"])

    it "refuses a second load under the same identity, and loads another version" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        _ ← loadModule owned (moduleOf "m" "1" "x = 1" [])
        duplicate ← faulted (loadModule owned (moduleOf "m" "1" "x = 2" []))
        boundaryReason duplicate `shouldBe` ModuleRefused DuplicateModule
        boundaryEffect duplicate `shouldBe` NoEffect
        boundaryModule duplicate `shouldBe` Just (ModuleRef "m" "1")
        _ ← loadModule owned (moduleOf "m" "2" "x = 3" [])
        _ ← loadModule owned (moduleOf "n" "1" "x = 4" [])
        pure ()

    it "gives each module an environment of its own, reading through to the owner's libraries and grants" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        first ←
          loadModule
            owned
            ( moduleOf
                "first"
                "1"
                ( Text.unlines
                    [ "leaked = 'first'"
                    , "function seen() return leaked, other == nil, sample.add(2, 3), ('ab'):rep(2) end"
                    , "function sees_second() return second_global == nil end"
                    ]
                )
                [ required "seen" [] [SText, SBoolean, SInteger, SText]
                , required "sees_second" [] [SBoolean]
                ]
            )
        second ← loadModule owned (moduleOf "second" "1" "second_global = 1\nfunction sees_first() return leaked == nil end" [required "sees_first" [] [SBoolean]])
        callEntry owned first "seen" [] >>= (`shouldBe` Returned [VText "first", VBoolean True, VInteger 5, VText "abab"])
        -- Global assignments are private to the module that made them.
        callEntry owned first "sees_second" [] >>= (`shouldBe` Returned [VBoolean True])
        callEntry owned second "sees_first" [] >>= (`shouldBe` Returned [VBoolean True])
        run owned "assert(leaked == nil and second_global == nil)"

    it "keeps the same source loaded in two owners apart" $ do
      fixture ← newFixture
      let counter = moduleOf "counter" "1" "local n = 0\nfunction bump() n = n + 1; return n end" [required "bump" [] [SInteger]]
      withOwner fixture [] $ \a → withOwner fixture [] $ \b → do
        ha ← loadModule a counter
        hb ← loadModule b counter
        _ ← callEntry a ha "bump" []
        callEntry a ha "bump" [] >>= (`shouldBe` Returned [VInteger 2])
        callEntry b hb "bump" [] >>= (`shouldBe` Returned [VInteger 1])

    it "refuses an identity or a source that does not fit, before anything runs" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        let refusedAs source expected = do
              fault ← faulted (loadModule owned source)
              boundaryReason fault `shouldBe` ModuleRefused expected
              boundaryEffect fault `shouldBe` NoEffect
              boundaryTraceback fault `shouldBe` Nothing
            plain name version = moduleOf name version "x = 1" []
        plain "" "1" `refusedAs` InvalidModuleIdentity
        plain "m" "" `refusedAs` InvalidModuleIdentity
        plain "a\nb" "1" `refusedAs` InvalidModuleIdentity
        plain (Text.replicate (maxIdentityLength + 1) "n") "1" `refusedAs` InvalidModuleIdentity
        _ ← loadModule owned (plain (Text.replicate maxIdentityLength "n") (Text.replicate maxIdentityLength "v"))
        let big count = ModuleSource (ModuleRef "big" (Text.pack (show count))) (padded count) []
        _ ← loadModule owned (big maxSourceBytes)
        big (maxSourceBytes + 1) `refusedAs` SourceTooLarge maxSourceBytes
        moduleOf "e" "1" "x = 1" [required "bad name" [] []] `refusedAs` InvalidEntryName "bad name"
        moduleOf "e" "1" "x = 1" [required "go" [] [], optional "go" [] []] `refusedAs` DuplicateEntry "go"
        moduleOf "e" "1" "x = 1" [required "go" (replicate (maxArity + 1) SInteger) []] `refusedAs` EntryArityTooLarge "go" (maxArity + 1)
        moduleOf "e" "1" "x = 1" [required "go" [] (replicate (maxArity + 1) SInteger)] `refusedAs` EntryArityTooLarge "go" (maxArity + 1)
        moduleOf "e" "1" "x = 1" [required "go" [SCapability "undeclared"] []] `refusedAs` EntrySchemaRefused "go"
        moduleOf "e" "1" "x = 1" [required "go" [SRecord [("a", SInteger), ("a", SInteger)]] []] `refusedAs` EntrySchemaRefused "go"
        let entries count = [optional (Text.pack ("e" <> show i)) [] [] | i ← [1 .. count ∷ Int]]
        _ ← loadModule owned (moduleOf "many" "1" "x = 1" (entries maxEntries))
        moduleOf "many" "2" "x = 1" (entries (maxEntries + 1)) `refusedAs` TooManyEntries maxEntries

    it "bounds how many modules one owner holds" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        mapM_ (\i → loadModule owned (moduleOf "m" (Text.pack (show i)) "x = 1" [])) [1 .. maxModules]
        fault ← faulted (loadModule owned (moduleOf "m" "over" "x = 1" []))
        boundaryReason fault `shouldBe` ModuleRefused (TooManyModules maxModules)

    it "refuses a precompiled chunk and a syntax error without running anything" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        binary ← faulted (loadModule owned (ModuleSource (ModuleRef "bin" "1") "\ESCLuaT00" []))
        boundaryEffect binary `shouldBe` NoEffect
        case boundaryReason binary of
          ScriptFailed ChunkRejected _ → pure ()
          other → expectationFailure ("not a rejected chunk: " <> show other)
        syntax ← faulted (loadModule owned (moduleOf "syn" "1" "this is not lua" []))
        boundaryEffect syntax `shouldBe` NoEffect
        boundaryChunk syntax `shouldBe` "syn@1"
        case boundaryReason syntax of
          ScriptFailed ChunkRejected (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "syn@1"
          other → expectationFailure ("not a rejected chunk: " <> show other)

    it "fails a module whose source raises, naming module and chunk, with a bounded traceback" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        fault ← faulted (loadModule owned (moduleOf "raises" "3" "local function inner() error('at load') end\ninner()" []))
        boundaryOperation fault `shouldBe` LoadModule
        boundaryModule fault `shouldBe` Just (ModuleRef "raises" "3")
        boundaryEffect fault `shouldBe` LuaRan
        case boundaryReason fault of
          ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "at load"
          other → expectationFailure ("not a raised error: " <> show other)
        case boundaryTraceback fault of
          Just traceback → do
            traceback `shouldSatisfy` Text.isInfixOf "inner"
            Text.length traceback `shouldSatisfy` (<= 2048)
          Nothing → expectationFailure "no traceback was captured"
        -- The module was not kept, and the owner goes on.
        run owned "ok = true"

    it "ends the lifetime when an initial module fails, closing the VM and never entering the body" $ do
      fixture ← newFixture
      entered ← newIORef False
      let config = (sampleConfig fixture []) {vmModules = [moduleOf "bad" "1" "error('init')" []]}
      outcome ← try @SomeException (withOwnerOf config (\_ → writeIORef entered True))
      case outcome of
        Left failure | Just fault ← fromException failure → boundaryModule fault `shouldBe` Just (ModuleRef "bad" "1")
        other → expectationFailure ("not the module's fault: " <> show other)
      readIORef entered >>= (`shouldBe` False)

  describe "entry points" $ do
    it "fails a load when a required entry point is not defined, naming module and entry" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        missing ← faulted (loadModule owned (moduleOf "m" "1" "function other() end" [required "go" [] []]))
        boundaryReason missing `shouldBe` EntryMissing False
        boundaryEntry missing `shouldBe` Just "go"
        boundaryModule missing `shouldBe` Just (ModuleRef "m" "1")
        wrongKind ← faulted (loadModule owned (moduleOf "m" "2" "go = 5" [required "go" [] []]))
        boundaryReason wrongKind `shouldBe` EntryMissing True
        -- Optional entry points may be absent or may be there.
        _ ← loadModule owned (moduleOf "m" "3" "x = 1" [optional "go" [] []])
        _ ← loadModule owned (moduleOf "m" "4" "function go() end" [optional "go" [] []])
        pure ()

    it "calls an entry point with bounded values and answers bounded values" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        callEntry owned handle "add" [VInteger 40, VInteger 2] >>= (`shouldBe` Returned [VInteger 42])
        callEntry owned handle "swap" [VInteger 1, VInteger 2] >>= (`shouldBe` Returned [VInteger 2, VInteger 1])
        callEntry owned handle "add" [VInteger maxBound, VInteger 0] >>= (`shouldBe` Returned [VInteger maxBound])

    it "carries text, bytes, floats, lists, records and nil both ways" $ do
      fixture ← newFixture
      let schemas =
            [ SText
            , SBytes
            , SFloat
            , SList SNumber
            , SRecord [("name", SText), ("tags", SList SText), ("note", SOptional SText)]
            , SOptional SInteger
            ]
          values =
            [ VText "h\233llo"
            , VBytes (ByteString.pack [255, 0, 1])
            , VFloat 2.5
            , VList [VInteger 1, VFloat 2.5]
            , VRecord [("name", VText "n"), ("tags", VList [VText "a", VText "b"]), ("note", VNil)]
            , VNil
            ]
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned (moduleOf "echo" "1" "function echo(...) return ... end" [required "echo" schemas schemas])
        callEntry owned handle "echo" values >>= (`shouldBe` Returned values)

    it "answers an explicit absent result for a missing optional entry point, running nothing" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        callEntry owned handle "on_tick" [VInteger 1] >>= (`shouldBe` EntryAbsent)

    it "makes a required entry point that has gone missing a fault, never an absent answer" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        _ ← callEntry owned handle "drop" []
        fault ← faulted (callEntry owned handle "add" [VInteger 1, VInteger 2])
        boundaryReason fault `shouldBe` EntryMissing False
        boundaryEntry fault `shouldBe` Just "add"
        boundaryEffect fault `shouldBe` NoEffect

    it "makes an entry point that is present and not a function a fault, required or optional" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        _ ← callEntry owned handle "corrupt" []
        fault ← faulted (callEntry owned handle "add" [VInteger 1, VInteger 2])
        boundaryReason fault `shouldBe` EntryNotAFunction
        other ← loadModule owned (moduleOf "opt" "1" "on_tick = 5" [optional "on_tick" [] []])
        optionalFault ← faulted (callEntry owned other "on_tick" [])
        boundaryReason optionalFault `shouldBe` EntryNotAFunction

    it "finds entry points by raw access, so no lookup metamethod can supply or hide one" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        let source =
              Text.unlines
                [ "seen = false"
                , "setmetatable(_ENV, {__index = function(_, key) seen = true; return function() return 1 end end})"
                ]
        supplied ← faulted (loadModule owned (moduleOf "lookup" "1" source [required "ghost" [] [SInteger]]))
        boundaryReason supplied `shouldBe` EntryMissing False
        handle ← loadModule owned (moduleOf "lookup" "2" source [optional "ghost" [] [SInteger]])
        callEntry owned handle "ghost" [] >>= (`shouldBe` EntryAbsent)

    it "refuses an entry point the module was not declared to have, and a foreign handle" $ do
      fixture ← newFixture
      withOwner fixture [] $ \a → withOwner fixture [] $ \b → do
        handle ← loadModule a calculator
        undeclared ← faulted (callEntry a handle "undeclared" [])
        boundaryReason undeclared `shouldBe` ModuleRefused (EntryUndeclared "undeclared")
        foreign' ← faulted (callEntry b handle "add" [VInteger 1, VInteger 2])
        boundaryReason foreign' `shouldBe` ModuleRefused ModuleHandleForeign
        boundaryEffect foreign' `shouldBe` NoEffect

    it "refuses a handle once its owner's lifetime has ended" $ do
      fixture ← newFixture
      escaped ← newIORef Nothing
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        writeIORef escaped (Just (owned, handle))
      Just (owned, handle) ← readIORef escaped
      outcome ← try @VmClosed (callEntry owned handle "add" [VInteger 1, VInteger 2])
      either (const True) (const False) outcome `shouldBe` True
      loaded ← try @VmClosed (loadModule owned (moduleOf "late" "1" "x = 1" []))
      either (const True) (const False) loaded `shouldBe` True

  describe "refused values and failing entry points" $ do
    it "refuses arguments before anything runs, with no effect" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        let refusedWith arguments expected = do
              fault ← faulted (callEntry owned handle "add" arguments)
              fmap refusalRule (refusal fault) `shouldBe` Just expected
              fmap refusalSide (refusal fault) `shouldBe` Just Arguments
              boundaryEffect fault `shouldBe` NoEffect
              boundaryTraceback fault `shouldBe` Nothing
        [VInteger 1] `refusedWith` RuleArity 2 1
        [VInteger 1, VInteger 2, VInteger 3] `refusedWith` RuleArity 2 3
        [VInteger 1, VFloat 2] `refusedWith` RuleFloatForInteger
        [VInteger 1, VText "2"] `refusedWith` RuleWrongType "integer" "text"

    it "bounds the arguments by the owner's limits" $ do
      fixture ← newFixture
      let config = (sampleConfig fixture []) {vmValueLimits = either (error . show) id (valueLimits 23 4 3)}
      withOwnerOf config $ \owned → do
        handle ← loadModule owned (moduleOf "l" "1" "function f(list) return #list end" [required "f" [SList SInteger] [SInteger]])
        callEntry owned handle "f" [VList [VInteger 1]] >>= (`shouldBe` Returned [VInteger 1])
        fault ← faulted (callEntry owned handle "f" [VList [VInteger 1, VInteger 2]])
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleBytesLimit 23)
        boundaryEffect fault `shouldBe` NoEffect

    it "refuses results that do not conform, after Lua ran" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        wrong ← faulted (callEntry owned handle "wrong" [])
        fmap refusalSide (refusal wrong) `shouldBe` Just Results
        fmap refusalRule (refusal wrong) `shouldBe` Just (RuleWrongType "integer" "string")
        boundaryEffect wrong `shouldBe` LuaRan
        two ← faulted (callEntry owned handle "two" [])
        fmap refusalRule (refusal two) `shouldBe` Just (RuleArity 1 2)

    it "reports a failing entry point with its owner, module, entry, chunk and a bounded traceback" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        fault ← faulted (callEntry owned handle "boom" [])
        boundaryOwner fault `shouldBe` "sample owner"
        boundaryOperation fault `shouldBe` CallEntry
        boundaryModule fault `shouldBe` Just (ModuleRef "calc" "1")
        boundaryEntry fault `shouldBe` Just "boom"
        boundaryChunk fault `shouldBe` "calc@1"
        boundaryEffect fault `shouldBe` LuaRan
        case boundaryReason fault of
          ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "exploded"
          other → expectationFailure ("not the script's error: " <> show other)
        case boundaryTraceback fault of
          Just traceback → traceback `shouldSatisfy` Text.isInfixOf "calc@1:5"
          Nothing → expectationFailure "no traceback"
        -- The module and the owner are usable afterwards.
        callEntry owned handle "add" [VInteger 1, VInteger 1] >>= (`shouldBe` Returned [VInteger 2])

    it "reports a non-string error value by its type and runs none of its metamethods" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned calculator
        table ← faulted (callEntry owned handle "table_error" [])
        boundaryReason table `shouldBe` ScriptFailed CallFailed (ErrorOpaque "table")
        nothing ← faulted (callEntry owned handle "nil_error" [])
        boundaryReason nothing `shouldBe` ScriptFailed CallFailed (ErrorOpaque "nil")
        described ← faulted (callEntry owned handle "str_error" [])
        boundaryReason described `shouldBe` ScriptFailed CallFailed (ErrorOpaque "table")
        callEntry owned handle "counter_touched" [] >>= (`shouldBe` Returned [VBoolean False])

    it "bounds the traceback it captures" $ do
      fixture ← newFixture
      withOwner fixture [] $ \owned → do
        handle ← loadModule owned (moduleOf "deep" "1" "local function down(n) if n == 0 then error('bottom') end; down(n - 1); return 1 end\nfunction go() down(500) end" [required "go" [] []])
        fault ← faulted (callEntry owned handle "go" [])
        case boundaryTraceback fault of
          Just traceback → Text.length traceback `shouldSatisfy` (<= 2048)
          Nothing → expectationFailure "no traceback"

    it "raises a binding's fault even when the entry point caught it and returned normally" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        handle ←
          loadModule
            owned
            (moduleOf "caught" "1" "function go() local ok = pcall(sample.add, 1.5, 2); return ok end" [required "go" [] [SBoolean]])
        fault ← faulted (callEntry owned handle "go" [])
        boundaryOperation fault `shouldBe` CallBinding
        boundaryBinding fault `shouldBe` Just ("sample", "add")
        fmap refusalRule (refusal fault) `shouldBe` Just RuleFloatForInteger
        -- It says which module and entry point the script was running, the chunk
        -- it called from, and where.
        boundaryModule fault `shouldBe` Just (ModuleRef "caught" "1")
        boundaryEntry fault `shouldBe` Just "go"
        boundaryChunk fault `shouldBe` "caught@1"
        case boundaryTraceback fault of
          Just traceback → traceback `shouldSatisfy` Text.isInfixOf "caught@1:1"
          Nothing → expectationFailure "no traceback"

    it "says a binding's action had run when an entry point fails after it" $ do
      fixture ← newFixture
      withOwner fixture ["sample"] $ \owned → do
        handle ← loadModule owned (moduleOf "after" "1" "function go() sample.set_value('k', 1); error('late') end" [required "go" [] []])
        fault ← faulted (callEntry owned handle "go" [])
        boundaryEffect fault `shouldBe` BindingRan
      stateOf fixture >>= (`shouldBe` Map.fromList [("k", 1)])

-- | A module source of exactly this many bytes: a statement and a comment.
padded ∷ Int → ByteString
padded count = base <> ByteString.replicate (count - ByteString.length base) 0x20
  where
    base = "x = 1 --"
