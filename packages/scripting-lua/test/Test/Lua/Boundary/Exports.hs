-- | Export modules and captured behaviors: the opt-in facility that keeps the
-- table a module's chunk returned, and what an instance captured of a behavior
-- in it, as real Lua values of one VM.
--
-- Every example runs a real interpreter through the public owner. A module's
-- top-level run is counted by a binding it calls, so "ran once" is read from
-- what the application observed and not from the module's own claim. The hooks
-- of a capture are run through a driver module that takes them as the first
-- three arguments, which is how the instance layer runs them.
module Test.Lua.Boundary.Exports (spec) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM_, replicateM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Hetoimasia.Scripting.Lua.Internal.Export
  ( exportRecordCount
  , liveCaptureReferences
  , liveCaptureSlots
  , liveExportReferences
  )
import qualified Data.ByteString.Internal as ByteString (toForeignPtr0)
import Hetoimasia.Scripting.Lua.Internal.ExportTypes (CaptureHandle (..), ExportHandle (..))
import Hetoimasia.Scripting.Lua.Internal.Module
  ( Lead (..)
  , callEntryWith
  )
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerBudget, ownerGranted, ownerName, ownerRegistration)
  , defaultOwnerConfig
  , ownedHost
  , ownedInternalVm
  , withOwnedVm
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (probeReferenceSlot, stackDepth)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support

-- Building modules ------------------------------------------------------------------

-- | An export module under an identity, labelled by it.
exportOf ∷ ByteString → Text → ExportSource
exportOf identity body = ExportSource (ExportIdentity identity) (Text.pack (Char8.unpack identity)) (encodeUtf8 body)

-- | The text a module's chunk reports its top level with: one line of the
-- sample binding's log for each time it runs.
ran ∷ Text
ran = "sample.nothing()\n"

-- | How many times a top level has run, from what the binding logged.
runs ∷ Fixture → IO Int
runs fixture = length . filter (== "nothing") <$> logged fixture

-- | The table an outcome holds, or the example fails.
ready ∷ ExportOutcome → IO ExportHandle
ready = \case
  ExportReady handle → pure handle
  ExportFailed fault → expectationFailure ("the export failed: " <> show fault) >> error "unreachable"

-- | The fault an outcome holds, or the example fails.
failedWith ∷ ExportOutcome → IO BoundaryFault
failedWith = \case
  ExportFailed fault → pure fault
  ExportReady handle → expectationFailure ("the export was kept: " <> show handle) >> error "unreachable"

-- | The behavior a capture answers, or the example fails.
captured ∷ Either BehaviorProblem Captured → IO Captured
captured = \case
  Right capture → pure capture
  Left problem → expectationFailure ("the behavior was refused: " <> show problem) >> error "unreachable"

-- | The driver the examples run hooks through: the hook, the capture's self and
-- its facade first, then what the entry point declares.
driver ∷ ModuleSource
driver =
  ModuleSource
    (ModuleRef "driver" "1")
    ( encodeUtf8 . Text.unlines $
        [ "function call_init(hook, self, api, n) return hook(self, api) end"
        , "function call_update(hook, self, api, n) return hook(self, 0.5) end"
        , "function call_shutdown(hook, self, api, n, reason) return hook(self, reason) end"
        ]
    )
    [ EntryPoint "call_init" Required [SInteger] []
    , EntryPoint "call_update" Required [SInteger] []
    , EntryPoint "call_shutdown" Required [SInteger, SText] []
    ]

-- | Run a hook of a capture through the driver.
runHook ∷ OwnedVm → ModuleHandle → CaptureHandle → Hook → IO CallResult
runHook owned handle capture hook = case hook of
  HookInit → via "call_init" [VInteger 0]
  HookUpdate → via "call_update" [VInteger 0]
  HookShutdown → via "call_shutdown" [VInteger 0, VText "stopped"]
  where
    via entry arguments = callEntryWith (LeadCaptured handle entry capture hook) (ownedHost owned) handle (hookText hook) arguments
    hookText = \case
      HookInit → "init"
      HookUpdate → "update"
      HookShutdown → "shutdown"

-- | An owner over the sample registration with the driver loaded, granting the
-- sample namespace, and this configuration change.
withDriver ∷ Fixture → (VmConfig → VmConfig) → (OwnedVm → ModuleHandle → IO a) → IO a
withDriver fixture adjust body =
  withOwnerOf (adjust (sampleConfig fixture ["sample"])) $ \owned → do
    handle ← loadModule owned driver
    body owned handle

-- | The references an owner holds for exports and captures, with the registry
-- and stack the operations that made them were bound to leave alone.
data Holdings = Holdings
  { holdExports ∷ !Int
  , holdCaptures ∷ !Int
  , holdSlots ∷ ![Int]
  , holdRecords ∷ !Int
  , holdDepth ∷ !Int
  , holdSlot ∷ !Int
  }
  deriving (Eq, Show)

holdings ∷ OwnedVm → IO Holdings
holdings = readHoldings True

-- | The same reading, without the registry slot, which is taken by an unprotected
-- allocation that a budget that has run out would abort the process in: for the
-- examples that run out of memory on purpose.
readHoldings ∷ Bool → OwnedVm → IO Holdings
readHoldings withSlot owned = do
  let host = ownedHost owned
  Holdings
    <$> liveExportReferences host
    <*> liveCaptureReferences host
    <*> liveCaptureSlots host
    <*> exportRecordCount host
    <*> stackDepth (ownedInternalVm owned)
    <*> (if withSlot then fromIntegral <$> probeReferenceSlot (ownedInternalVm owned) else pure 0)

spec ∷ Spec
spec = describe "export modules" $ do
  describe "evaluation" $ do
    it "keeps the one plain table a text chunk returns, and runs its top level once" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        first ← evaluateExport owned (exportOf "m" (ran <> "return { value = 1 }")) >>= ready
        again ← evaluateExport owned (exportOf "m" "error('never run')") >>= ready
        retrieved ← retrieveExport owned (ExportIdentity "m")
        retrieved `shouldBe` Just (ExportReady first)
        again `shouldBe` first
        runs fixture >>= (`shouldBe` 1)
        held ← holdings owned
        holdExports held `shouldBe` 1
        holdRecords held `shouldBe` 1
        retrieveExport owned (ExportIdentity "other") >>= (`shouldBe` Nothing)

    it "refuses everything but exactly one plain table, and the identity stays failed" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        let cases ∷ [(ByteString, Text, ExportShape)]
            cases =
              [ ("none", "", ExportNoResult)
              , ("nil", "return nil", ExportNil)
              , ("number", "return 1", ExportNotTable "number")
              , ("string", "return 'text'", ExportNotTable "string")
              , ("boolean", "return true", ExportNotTable "boolean")
              , ("function", "return function() end", ExportNotTable "function")
              , ("two", "return {}, {}", ExportMultiple)
              , ("trailing nil", "return {}, nil", ExportMultiple)
              , ("leading nil", "return nil, {}", ExportMultiple)
              , ("metatable", "return setmetatable({}, {})", ExportMetatable)
              , ("protected", "return setmetatable({}, { __metatable = false })", ExportMetatable)
              ]
        forM_ cases $ \(identity, body, shape) → do
          before ← runs fixture
          fault ← evaluateExport owned (exportOf identity (ran <> body)) >>= failedWith
          boundaryReason fault `shouldBe` ExportShapeRefused shape
          -- The top level called a binding before it returned.
          boundaryEffect fault `shouldBe` BindingRan
          boundaryOperation fault `shouldBe` EvaluateExport
          -- The same identity answers the same failure, with different bytes, and
          -- runs nothing again.
          again ← evaluateExport owned (exportOf identity (ran <> "return {}")) >>= failedWith
          again `shouldBe` fault
          retrieveExport owned (ExportIdentity identity) >>= (`shouldBe` Just (ExportFailed fault))
          runs fixture >>= (`shouldBe` (before + 1))
        held ← holdings owned
        holdExports held `shouldBe` 0
        holdRecords held `shouldBe` length cases

    it "reports a script error, a rejected chunk and bytecode as attributed protected failures" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        thrown ← evaluateExport owned (exportOf "thrown" (ran <> "error('exploded')")) >>= failedWith
        case boundaryReason thrown of
          ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "exploded"
          other → expectationFailure ("not a script failure: " <> show other)
        boundaryEffect thrown `shouldBe` BindingRan
        boundaryModule thrown `shouldBe` Just (ModuleRef "thrown" "export")
        boundaryTraceback thrown `shouldSatisfy` isJust
        rejected ← evaluateExport owned (exportOf "rejected" (ran <> "return {")) >>= failedWith
        boundaryReason rejected `shouldSatisfy` \case
          ScriptFailed ChunkRejected _ → True
          _ → False
        boundaryEffect rejected `shouldBe` NoEffect
        -- A precompiled chunk starts with the escape byte, and is refused as text
        -- only: nothing of it ran.
        binary ← evaluateExport owned (ExportSource (ExportIdentity "binary") "binary" (ByteString.pack [27] <> "Lua")) >>= failedWith
        boundaryReason binary `shouldSatisfy` \case
          ScriptFailed ChunkRejected (ErrorMessage message _) → "binary" `Text.isInfixOf` message
          _ → False
        boundaryEffect binary `shouldBe` NoEffect
        -- Of the three, only the error ran its top level.
        runs fixture >>= (`shouldBe` 1)
        again ← evaluateExport owned (exportOf "thrown" "return {}") >>= failedWith
        again `shouldBe` thrown

    it "gives each module a private environment that reads through to the owner's globals" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        _ ← evaluateExport owned (exportOf "first" (ran <> "leaked = 'first'\nreturn { seen = leaked }")) >>= ready
        _ ←
          evaluateExport
            owned
            ( exportOf
                "second"
                ( Text.unlines
                    [ "sample.set_value('second_sees_leak', leaked == nil and 0 or 1)"
                    , "sample.set_value('library', #('ab'):rep(2))"
                    , "return {}"
                    ]
                )
            )
            >>= ready
        state ← stateOf fixture
        Map.lookup "second_sees_leak" state `shouldBe` Just 0
        Map.lookup "library" state `shouldBe` Just 4
        -- Nor did the first module's global reach the owner's.
        run owned "assert(leaked == nil)"

    it "keeps the owner's filtered library out of the module before authored code runs" $ do
      let probe =
            Text.unlines
              [ "assert(load == nil and loadfile == nil and dofile == nil and collectgarbage == nil)"
              , "assert(string.dump == nil and math.random == nil and math.randomseed == nil)"
              , "assert(os == nil and io == nil and package == nil and require == nil and debug == nil)"
              , "assert(type(string.rep) == 'function' and type(coroutine.create) == 'function')"
              , "return {}"
              ]
          filtered = (vmProfileConfig LibraryProfileM1) {vmExports = [exportOf "probe" probe]}
      withOwnerOf filtered $ \owned →
        retrieveExport owned (ExportIdentity "probe") >>= \case
          Just (ExportReady _) → pure ()
          other → expectationFailure ("the module saw an excluded function: " <> show other)
      -- The same check against an unfiltered owner fails, so it checks something.
      fixture ← newFixture
      withDriver fixture id $ \owned _ →
        evaluateExport owned (exportOf "probe" probe) >>= failedWith >>= \fault →
          boundaryReason fault `shouldSatisfy` \case ScriptFailed CallFailed _ → True; _ → False

    it "is independent between owners: the same identity can fail in one and succeed in another" $ do
      first ← newFixture
      second ← newFixture
      withDriver first id $ \one _ → withDriver second id $ \two _ → do
        failing ← evaluateExport one (exportOf "shared" (ran <> "error('first only')")) >>= failedWith
        boundaryEffect failing `shouldBe` BindingRan
        kept ← evaluateExport two (exportOf "shared" (ran <> "return {}")) >>= ready
        exportHandleSlot kept `shouldSatisfy` (>= 0)
        runs first >>= (`shouldBe` 1)
        runs second >>= (`shouldBe` 1)
        -- And a handle of one is refused by the other.
        outcome ← try @BoundaryFault (captureBehavior one kept "gameplay" (FacadeValue (VRecord [])))
        fmap boundaryReason (either Just (const Nothing) outcome) `shouldBe` Just (ModuleRefused ExportHandleForeign)

  describe "identities and limits" $ do
    it "holds 256 identities by default, counts failed ones, and refuses the next before evaluating it" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        forM_ [1 .. 255 ∷ Int] $ \n →
          evaluateExport owned (exportOf (Char8.pack ("id" <> show n)) "return {}") >>= void'
        -- A failed identity is charged like any other.
        _ ← evaluateExport owned (exportOf "failed" "error('x')") >>= failedWith
        exportRecordCount' owned >>= (`shouldBe` 256)
        refused ← try @BoundaryFault (evaluateExport owned (exportOf "extra" (ran <> "return {}")))
        fmap boundaryReason (either Just (const Nothing) refused) `shouldBe` Just (ModuleRefused (TooManyExports 256))
        fmap boundaryEffect (either Just (const Nothing) refused) `shouldBe` Just NoEffect
        runs fixture >>= (`shouldBe` 0)
        retrieveExport owned (ExportIdentity "extra") >>= (`shouldBe` Nothing)
        exportRecordCount' owned >>= (`shouldBe` 256)
        -- Asking again for one that is held consumes nothing.
        again ← retrieveExport owned (ExportIdentity "id7")
        again `shouldSatisfy` isJust
        evaluateExport owned (exportOf "id7" "return {}") >>= void'
        exportRecordCount' owned >>= (`shouldBe` 256)

    it "does not count global-entry modules, or the module of an owner that holds many, against the export identities" $ do
      fixture ← newFixture
      let modules = [ModuleSource (ModuleRef (Text.pack ("legacy" <> show n)) "1") "x = 1" [] | n ← [1 .. 40 ∷ Int]]
          limits = ExportLimits {exportMaxSourceBytes = 1048576, exportMaxIdentities = 3}
      withDriver fixture (\config → config {vmModules = modules, vmExportLimits = limits}) $ \owned _ → do
        forM_ ["a", "b", "c"] $ \identity → evaluateExport owned (exportOf identity "return {}") >>= void'
        refused ← try @BoundaryFault (evaluateExport owned (exportOf "d" "return {}"))
        fmap boundaryReason (either Just (const Nothing) refused) `shouldBe` Just (ModuleRefused (TooManyExports 3))

    it "evaluates a source of exactly 1 MiB and records one byte more as a failed identity that never ran" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        let padded prefix = prefix <> ByteString.replicate (1048576 - ByteString.length prefix) 32
            exact = padded "return {}"
            over = padded (encodeUtf8 ran <> "return {}") <> " "
        ByteString.length exact `shouldBe` 1048576
        evaluateExport owned (ExportSource (ExportIdentity "exact") "exact" exact) >>= void'
        fault ← evaluateExport owned (ExportSource (ExportIdentity "over") "over" over) >>= failedWith
        boundaryReason fault `shouldBe` ModuleRefused (SourceTooLarge 1048576)
        boundaryEffect fault `shouldBe` NoEffect
        -- Never compiled or run, charged, and distinguishable from an evaluation
        -- failure.
        runs fixture >>= (`shouldBe` 0)
        exportRecordCount' owned >>= (`shouldBe` 2)
        evaluateExport owned (exportOf "over" "return {}") >>= failedWith >>= (`shouldBe` fault)
        liveExportReferences (ownedHost owned) >>= (`shouldBe` 1)

    it "retains an identity in storage of its own: a short slice of a large buffer pins nothing" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        let large = ByteString.replicate 1000000 97 <> "tail"
            slice = ByteString.take 8 large
            (original, _) = ByteString.toForeignPtr0 slice
        kept ← evaluateExport owned (ExportSource (ExportIdentity slice) "sliced" "return {}") >>= ready
        let ExportIdentity retained = exportHandleIdentity kept
            (copied, _) = ByteString.toForeignPtr0 retained
        retained `shouldBe` slice
        (copied == original) `shouldBe` False
        -- And what retrieval hands back is the retained copy, not the caller's.
        retrieveExport owned (ExportIdentity slice) >>= \case
          Just (ExportReady again) → let ExportIdentity bytes = exportHandleIdentity again in fst (ByteString.toForeignPtr0 bytes) == original `shouldBe` False
          other → expectationFailure ("not retrieved: " <> show other)

    it "refuses a new identity at a full ceiling with no record, and an oversized one while room remains" $ do
      fixture ← newFixture
      let limits = ExportLimits {exportMaxSourceBytes = 16, exportMaxIdentities = 2}
      withDriver fixture (\config → config {vmExportLimits = limits}) $ \owned _ → do
        _ ← evaluateExport owned (exportOf "one" "return {}") >>= ready
        oversized ← evaluateExport owned (exportOf "two" "return {}  --  more than sixteen") >>= failedWith
        boundaryReason oversized `shouldBe` ModuleRefused (SourceTooLarge 16)
        -- Full now: neither source is looked at.
        refused ← try @BoundaryFault (evaluateExport owned (exportOf "three" (ran <> "return {}")))
        fmap boundaryReason (either Just (const Nothing) refused) `shouldBe` Just (ModuleRefused (TooManyExports 2))
        exportRecordCount' owned >>= (`shouldBe` 2)

    it "keeps distinct identities distinct however long they are, and refuses an identity it would have to cut" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        let prefix = ByteString.replicate 4000 97
            one = prefix <> "1"
            two = prefix <> "2"
        a ← evaluateExport owned (ExportSource (ExportIdentity one) "long" "return { which = 1 }") >>= ready
        b ← evaluateExport owned (ExportSource (ExportIdentity two) "long" "return { which = 2 }") >>= ready
        exportHandleSlot a `shouldSatisfy` (/= exportHandleSlot b)
        retrieveExport owned (ExportIdentity one) >>= (`shouldBe` Just (ExportReady a))
        forM_ [ByteString.empty, ByteString.replicate 4097 98] $ \identity → do
          refused ← try @BoundaryFault (evaluateExport owned (ExportSource (ExportIdentity identity) "bad" "return {}"))
          fmap boundaryReason (either Just (const Nothing) refused) `shouldBe` Just (ModuleRefused (InvalidExportIdentity 4096))
        exportRecordCount' owned >>= (`shouldBe` 2)
        -- The label is bounded on its own: a long one is only cut for a reader.
        longLabel ← evaluateExport owned (ExportSource (ExportIdentity "labelled") (Text.replicate 400 "é") "error('x')") >>= failedWith
        fmap (ByteString.length . encodeUtf8 . moduleRefName) (boundaryModule longLabel) `shouldSatisfy` maybe False (<= 128)

  describe "behaviors" $ do
    it "captures a behavior and reports its hooks and its cadence fields as they read" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local function f() end"
                    , "return {"
                    , "  gameplay = { init = f, update = f, shutdown = f, every_ticks = 3 },"
                    , "  presentation = { update = f, every_seconds = 0.5 },"
                    , "  integer_seconds = { every_seconds = 2 },"
                    , "  float_ticks = { every_ticks = 1.0 },"
                    , "  string_ticks = { every_ticks = '3' },"
                    , "  empty = {},"
                    , "}"
                    ]
                )
            )
            >>= ready
        let shapeOf key = capturedShape <$> (captureBehavior owned export key (FacadeValue (VRecord [])) >>= captured)
        shapeOf "gameplay" >>= (`shouldBe` BehaviorShape True True True (FieldInteger 3) FieldAbsent)
        shapeOf "presentation" >>= (`shouldBe` BehaviorShape False True False FieldAbsent (FieldFloat 0.5))
        shapeOf "integer_seconds" >>= (`shouldBe` BehaviorShape False False False FieldAbsent (FieldInteger 2))
        shapeOf "float_ticks" >>= (`shouldBe` BehaviorShape False False False (FieldFloat 1.0) FieldAbsent)
        shapeOf "string_ticks" >>= (`shouldBe` BehaviorShape False False False (FieldOther "string") FieldAbsent)
        shapeOf "empty" >>= (`shouldBe` BehaviorShape False False False FieldAbsent FieldAbsent)

    it "extends nothing of a behavior that does not fit the schema: each refusal holds no reference" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local f = function() end"
                    , "return {"
                    , "  plain_number = 5,"
                    , "  with_meta = setmetatable({}, { __index = function() end }),"
                    , "  protected = setmetatable({}, { __metatable = false }),"
                    , "  unknown = { init = f, bogus = 1 },"
                    , "  numeric_key = { [1] = f },"
                    , "  boolean_key = { [true] = f },"
                    , "  bad_init = { init = 5 },"
                    , "  bad_update = { update = {} },"
                    , "  bad_shutdown = { shutdown = 'x' },"
                    , "  callable = { init = setmetatable({}, { __call = f }) },"
                    , "  wide = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10, k = 11 },"
                    , "}"
                    ]
                )
            )
            >>= ready
        before ← holdings owned
        let refused key = captureBehavior owned export key (FacadeValue (VRecord [("name", VText "facade")]))
        refused "absent" >>= (`shouldBe` Left BehaviorMissing)
        refused "plain_number" >>= (`shouldBe` Left (BehaviorNotTable "number"))
        refused "with_meta" >>= (`shouldBe` Left BehaviorHasMetatable)
        refused "protected" >>= (`shouldBe` Left BehaviorHasMetatable)
        refused "unknown" >>= (`shouldBe` Left (BehaviorUnknownKey "bogus"))
        refused "numeric_key" >>= (`shouldBe` Left (BehaviorNonTextKey "number"))
        refused "boolean_key" >>= (`shouldBe` Left (BehaviorNonTextKey "boolean"))
        refused "bad_init" >>= (`shouldBe` Left (BehaviorHookNotFunction HookInit "number"))
        refused "bad_update" >>= (`shouldBe` Left (BehaviorHookNotFunction HookUpdate "table"))
        refused "bad_shutdown" >>= (`shouldBe` Left (BehaviorHookNotFunction HookShutdown "string"))
        -- A table with a call metamethod is not a function.
        refused "callable" >>= (`shouldBe` Left (BehaviorHookNotFunction HookInit "table"))
        refused "wide" >>= (`shouldSatisfy` \case Left (BehaviorUnknownKey _) → True; _ → False)
        holdings owned >>= (`shouldBe` before)
        -- And none of them is a failure of the module that holds them.
        retrieveExport owned (ExportIdentity "m") >>= (`shouldBe` Just (ExportReady export))

    it "reads by raw access: no metamethod of the export table or anything it holds runs" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local exports"
                    , "exports = { gameplay = { init = function() setmetatable(exports, { __index = function() sample.nothing() end }) end } }"
                    , "return exports"
                    ]
                )
            )
            >>= ready
        first ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= captured
        -- Running the hook gives the export table an indexing metamethod; the
        -- selection of a role the table does not have must not call it.
        _ ← runHook owned handle (capturedHandle first) HookInit
        captureBehavior owned export "presentation" (FacadeValue (VRecord [])) >>= (`shouldBe` Left BehaviorMissing)
        captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= void'
        runs fixture >>= (`shouldBe` 0)

    it "does not take an invalid role the selection did not pick for a failure of the module or of another role" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local big = {}"
                    , "for i = 1, 5000 do big[i] = { i } end"
                    , "return {"
                    , "  gameplay = { init = function() end },"
                    , "  presentation = setmetatable({}, {}),"
                    , "  helpers = big,"
                    , "}"
                    ]
                )
            )
            >>= ready
        captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= void'
        captureBehavior owned export "presentation" (FacadeValue (VRecord [])) >>= (`shouldBe` Left BehaviorHasMetatable)
        retrieveExport owned (ExportIdentity "m") >>= (`shouldBe` Just (ExportReady export))

    it "captures the very functions: later replacement of the behavior's fields does not reach them" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local count = 0"
                    , "local behavior = {}"
                    , "behavior.init = function() count = count + 1; sample.set_value('init', count) end"
                    , "behavior.update = function() sample.set_value('update', 1) end"
                    , "behavior.shutdown = function() sample.set_value('shutdown', 1) end"
                    , "local exports = { gameplay = behavior }"
                    , "-- Replaces everything the capture was read from, from a behavior of its own."
                    , "exports.replacer = { init = function()"
                    , "  behavior.init = function() sample.set_value('replaced', 1) end"
                    , "  behavior.update = nil"
                    , "  behavior.every_ticks = 7"
                    , "  exports.gameplay = nil"
                    , "end }"
                    , "return exports"
                    ]
                )
            )
            >>= ready
        capture ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= captured
        _ ← runHook owned handle (capturedHandle capture) HookInit
        stateOf fixture >>= \state → Map.lookup "init" state `shouldBe` Just 1
        -- Replace everything the capture was read from: the capture is the
        -- original, and a later capture reads what is there now.
        replacer ← captureBehavior owned export "replacer" (FacadeValue (VRecord [])) >>= captured
        _ ← runHook owned handle (capturedHandle replacer) HookInit
        releaseBehavior owned (capturedHandle replacer)
        second ← captureBehavior owned export "gameplay" (FacadeValue (VRecord []))
        second `shouldBe` Left BehaviorMissing
        _ ← runHook owned handle (capturedHandle capture) HookInit
        state ← stateOf fixture
        -- Its upvalue is shared Lua state, so the original function sees its own
        -- count rise.
        Map.lookup "init" state `shouldBe` Just 2
        Map.lookup "replaced" state `shouldBe` Nothing
        _ ← runHook owned handle (capturedHandle capture) HookUpdate
        _ ← runHook owned handle (capturedHandle capture) HookShutdown
        stateOf fixture >>= \final → (Map.lookup "update" final, Map.lookup "shutdown" final) `shouldBe` (Just 1, Just 1)

    it "gives each capture a fresh self holding its own facade, and shares exports and their upvalues" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "m"
                ( Text.unlines
                    [ "local shared = { cycle = nil }"
                    , "shared.cycle = shared"
                    , "local selves = {}"
                    , "local count = 0"
                    , "return {"
                    , "  shared = shared,"
                    , "  gameplay = {"
                    , "    init = function(self, api)"
                    , "      count = count + 1"
                    , "      selves[#selves + 1] = self"
                    , "      sample.set_value('api_is_self_api_' .. count, rawequal(self.api, api) and 1 or 0)"
                    , "      sample.set_value('name_' .. count, api.name)"
                    , "      sample.set_value('cycle_' .. count, rawequal(shared.cycle, shared) and 1 or 0)"
                    , "      sample.set_value('distinct_' .. count, #selves == 1 and 1 or (rawequal(selves[1], selves[2]) and 0 or 1))"
                    , "      sample.set_value('distinct_api_' .. count, #selves == 1 and 1 or (rawequal(selves[1].api, selves[2].api) and 0 or 1))"
                    , "      sample.set_value('count_' .. count, count)"
                    , "    end,"
                    , "  },"
                    , "}"
                    ]
                )
            )
            >>= ready
        one ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [("name", VInteger 11)])) >>= captured
        two ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [("name", VInteger 22)])) >>= captured
        _ ← runHook owned handle (capturedHandle one) HookInit
        _ ← runHook owned handle (capturedHandle two) HookInit
        state ← stateOf fixture
        forM_ [1, 2 ∷ Int] $ \n → do
          Map.lookup ("api_is_self_api_" <> Text.pack (show n)) state `shouldBe` Just 1
          Map.lookup ("cycle_" <> Text.pack (show n)) state `shouldBe` Just 1
          Map.lookup ("distinct_" <> Text.pack (show n)) state `shouldBe` Just 1
          Map.lookup ("distinct_api_" <> Text.pack (show n)) state `shouldBe` Just 1
        Map.lookup "name_1" state `shouldBe` Just 11
        Map.lookup "name_2" state `shouldBe` Just 22
        -- The counter is an upvalue of the shared function: the second capture's
        -- run saw the first's.
        (Map.lookup "count_1" state, Map.lookup "count_2" state) `shouldBe` (Just 1, Just 2)

    it "installs self.api even when init is absent, and an absent hook runs nothing" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ←
          evaluateExport owned (exportOf "m" ("return { gameplay = { update = function(self, dt) sample.set_value('dt', #self.api.tag) end } }")) >>= ready
        capture ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [("tag", VText "abc")])) >>= captured
        shapeInit (capturedShape capture) `shouldBe` False
        runHook owned handle (capturedHandle capture) HookInit >>= (`shouldBe` EntryAbsent)
        runHook owned handle (capturedHandle capture) HookShutdown >>= (`shouldBe` EntryAbsent)
        _ ← runHook owned handle (capturedHandle capture) HookUpdate
        stateOf fixture >>= \state → Map.lookup "dt" state `shouldBe` Just 3

  describe "facades" $ do
    let services =
          exportOf
            "services"
            . Text.unlines
            $ [ "return {"
            , "  shared = { tag = 'shared' },"
            , "  build = function(context)"
            , "    local name = context.name"
            , "    return { name = name, ping = function() sample.set_value('ping_' .. name, 1) end }"
            , "  end,"
            , "  not_a_function = 5,"
            , "  not_a_table = 5,"
            , "  broken = function() error('builder failed') end,"
            , "  nothing = function() return 5 end,"
            , "  counted = function() sample.nothing() return {} end,"
            , "}"
            ]
        behavior =
          exportOf
            "behavior"
            . Text.unlines
            $ [ "return { gameplay = { init = function(self, api)"
            , "  sample.set_value('same_' .. tostring(api.name or api.tag), rawequal(self.api, api) and 1 or 0)"
            , "  if api.ping then api.ping() end"
            , "end }, other = { init = function() end }, bad = { bogus = 1 } }"
            ]
        withBoth body = do
          fixture ← newFixture
          withDriver fixture id $ \owned handle → do
            serviceHandle ← evaluateExport owned services >>= ready
            behaviorHandle ← evaluateExport owned behavior >>= ready
            body fixture owned handle serviceHandle behaviorHandle
    it "builds a function-bearing facade per capture, each closure bound to its own context, the same table as self.api" $
      withBoth $ \fixture owned handle serviceHandle behaviorHandle → do
        one ← captureBehavior owned behaviorHandle "gameplay" (FacadeBuilt serviceHandle "build" (VRecord [("name", VText "a")])) >>= captured
        two ← captureBehavior owned behaviorHandle "gameplay" (FacadeBuilt serviceHandle "build" (VRecord [("name", VText "b")])) >>= captured
        _ ← runHook owned handle (capturedHandle one) HookInit
        _ ← runHook owned handle (capturedHandle two) HookInit
        state ← stateOf fixture
        Map.lookup "ping_a" state `shouldBe` Just 1
        Map.lookup "ping_b" state `shouldBe` Just 1
        Map.lookup "same_a" state `shouldBe` Just 1
        Map.lookup "same_b" state `shouldBe` Just 1
        holdCaptures <$> holdings owned >>= (`shouldBe` 2)

    it "uses an existing facade table as it is, shared by every capture that names it" $
      withBoth $ \fixture owned handle serviceHandle behaviorHandle → do
        one ← captureBehavior owned behaviorHandle "gameplay" (FacadeField serviceHandle "shared") >>= captured
        _ ← runHook owned handle (capturedHandle one) HookInit
        stateOf fixture >>= \state → Map.lookup "same_shared" state `shouldBe` Just 1

    it "refuses a facade source that is missing, or the wrong type, or whose builder fails, and holds nothing" $
      withBoth $ \fixture owned _ serviceHandle behaviorHandle → do
        before ← holdings owned
        let faultOf' source = try @BoundaryFault (captureBehavior owned behaviorHandle "gameplay" source) >>= \case
              Left fault → pure (boundaryReason fault)
              Right other → expectationFailure ("not refused: " <> show (fmap capturedShape other)) >> error "unreachable"
        faultOf' (FacadeField serviceHandle "absent") >>= (`shouldBe` ModuleRefused (FacadeFieldMissing "absent"))
        faultOf' (FacadeField serviceHandle "build") >>= (`shouldBe` ModuleRefused (FacadeNotATable "function"))
        faultOf' (FacadeBuilt serviceHandle "not_a_function" VNil) >>= (`shouldBe` ModuleRefused (FacadeBuilderNotAFunction "number"))
        faultOf' (FacadeBuilt serviceHandle "nothing" VNil) >>= (`shouldBe` ModuleRefused (FacadeNotATable "number"))
        faultOf' (FacadeBuilt serviceHandle "broken" VNil) >>= \case
          ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "builder failed"
          other → expectationFailure ("not the builder's failure: " <> show other)
        -- A source of another owner is refused as any handle is.
        forged ← try @BoundaryFault (captureBehavior owned behaviorHandle "gameplay" (FacadeField serviceHandle {exportHandleSlot = exportHandleSlot serviceHandle + 100} "shared"))
        fmap boundaryReason (either Just (const Nothing) forged) `shouldBe` Just (ModuleRefused ExportHandleStale)
        -- Everything the refused captures made was let go.
        holdings owned >>= (`shouldBe` before)
        _ ← pure fixture
        pure ()

    it "refuses a copied facade that is not a table: nil and every scalar, before anything is captured" $
      withBoth $ \_ owned _ _ behaviorHandle → do
        before ← holdings owned
        forM_ [(VNil, "nil"), (VBoolean True, "boolean"), (VInteger 3, "number"), (VFloat 1.5, "number"), (VText "x", "string"), (VBytes "x", "string")] $ \(scalar, name) → do
          refused ← try @BoundaryFault (captureBehavior owned behaviorHandle "gameplay" (FacadeValue scalar))
          fmap boundaryReason (either Just (const Nothing) refused) `shouldBe` Just (ModuleRefused (FacadeNotATable name))
          fmap boundaryEffect (either Just (const Nothing) refused) `shouldBe` Just NoEffect
        -- A list is a table, and so is an empty record.
        _ ← captureBehavior owned behaviorHandle "gameplay" (FacadeValue (VList [VInteger 1])) >>= captured
        holdings owned >>= \after → holdCaptures after `shouldBe` holdCaptures before + 1

    it "attributes what a captured hook raises to the export module that holds it, not to the driver that calls it" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ←
          evaluateExport
            owned
            ( exportOf
                "attributed"
                ( Text.unlines
                    [ "return {"
                    , "  scripted = { init = function() error('scripted boom') end, update = function() error('update boom') end, shutdown = function() error('shutdown boom') end },"
                    , "  refused = { init = function() sample.add(1.5, 2) end, update = function() sample.add(1.5, 2) end, shutdown = function() sample.add(1.5, 2) end },"
                    , "}"
                    ]
                )
            )
            >>= ready
        let source = ModuleRef "attributed" "export"
            raised capture hook = try @BoundaryFault (runHook owned handle (capturedHandle capture) hook) >>= \case
              Left fault → pure fault
              Right other → expectationFailure ("the hook did not fail: " <> show other) >> error "unreachable"
        scripted ← captureBehavior owned export "scripted" (FacadeValue (VRecord [])) >>= captured
        refused ← captureBehavior owned export "refused" (FacadeValue (VRecord [])) >>= captured
        forM_ [(HookInit, "init"), (HookUpdate, "update"), (HookShutdown, "shutdown")] $ \(hook, entry) → do
          scriptFault ← raised scripted hook
          boundaryModule scriptFault `shouldBe` Just source
          boundaryEntry scriptFault `shouldBe` Just entry
          boundaryReason scriptFault `shouldSatisfy` \case ScriptFailed CallFailed (ErrorMessage message _) → Text.isInfixOf "boom" message; _ → False
          -- A binding refusal from the authored chunk is attributed to it as well: the chunk
          -- the call was made from is the module's own.
          bindingFault ← raised refused hook
          boundaryModule bindingFault `shouldBe` Just source
          boundaryEntry bindingFault `shouldBe` Just entry
          boundaryBinding bindingFault `shouldBe` Just ("sample", "add")

    it "runs no facade builder for a behavior that does not validate" $
      withBoth $ \fixture owned _ serviceHandle behaviorHandle → do
        captureBehavior owned behaviorHandle "bad" (FacadeBuilt serviceHandle "counted" VNil) >>= (`shouldBe` Left (BehaviorUnknownKey "bogus"))
        runs fixture >>= (`shouldBe` 0)
        _ ← captureBehavior owned behaviorHandle "other" (FacadeBuilt serviceHandle "counted" VNil) >>= captured
        runs fixture >>= (`shouldBe` 1)

  describe "a facade builder that catches a host failure" $ do
    it "raises the saved failure whenever the builder ran, whatever fails after it, at every allocation of the call" $ do
      results ← catchSweep
      -- Nothing was reported as an ordinary construction failure or a success once the
      -- host's callback had failed, and nothing was left held.
      take 5 [text | CatchTrial _ _ _ (Just text) ← results] `shouldBe` []
      let kinds = [kind | CatchTrial kind _ _ _ ← results]
      kinds `shouldSatisfy` elem CatchRaised
      kinds `shouldSatisfy` elem CatchFaulted

  describe "references" $ do
    it "holds a capture until it is released, releases once, and refuses a handle it no longer holds" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ← evaluateExport owned (exportOf "m" "return { gameplay = { init = function() end } }") >>= ready
        baseline ← holdings owned
        capture ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= captured
        mid ← holdings owned
        holdCaptures mid `shouldBe` 1
        holdSlots mid `shouldBe` [captureHandleSlot (capturedHandle capture)]
        releaseBehavior owned (capturedHandle capture)
        releaseBehavior owned (capturedHandle capture)
        after ← holdings owned
        after `shouldBe` baseline
        -- A released capture runs nothing, and is a refusal rather than an absent hook.
        outcome ← try @BoundaryFault (runHook owned handle (capturedHandle capture) HookInit)
        fmap boundaryReason (either Just (const Nothing) outcome) `shouldBe` Just (ModuleRefused CaptureHandleStale)
        -- Nor does a handle for a slot nothing ever held.
        forged ← try @BoundaryFault (runHook owned handle (CaptureHandle (captureHandleVm (capturedHandle capture)) 99999 (captureHandleSource (capturedHandle capture))) HookInit)
        fmap boundaryReason (either Just (const Nothing) forged) `shouldBe` Just (ModuleRefused CaptureHandleStale)
        holdings owned >>= (`shouldBe` baseline)

    it "refuses a handle another owner issued, and an export handle for a slot it does not hold" $ do
      first ← newFixture
      second ← newFixture
      withDriver first id $ \one handleOne → withDriver second id $ \two handleTwo → do
        exportOne ← evaluateExport one (exportOf "m" "return { gameplay = {} }") >>= ready
        exportTwo ← evaluateExport two (exportOf "m" "return { gameplay = {} }") >>= ready
        captureOne ← captureBehavior one exportOne "gameplay" (FacadeValue (VRecord [])) >>= captured
        foreignRelease ← try @BoundaryFault (releaseBehavior two (capturedHandle captureOne))
        fmap boundaryReason (either Just (const Nothing) foreignRelease) `shouldBe` Just (ModuleRefused CaptureHandleForeign)
        foreignRun ← try @BoundaryFault (runHook two handleTwo (capturedHandle captureOne) HookInit)
        fmap boundaryReason (either Just (const Nothing) foreignRun) `shouldBe` Just (ModuleRefused CaptureHandleForeign)
        -- The first is untouched.
        liveCaptureReferences (ownedHost one) >>= (`shouldBe` 1)
        forged ← try @BoundaryFault (captureBehavior two exportTwo {exportHandleSlot = exportHandleSlot exportTwo + 100} "gameplay" (FacadeValue (VRecord [])))
        fmap boundaryReason (either Just (const Nothing) forged) `shouldBe` Just (ModuleRefused ExportHandleStale)
        _ ← pure handleOne
        pure ()

    it "returns every reference and the registry to where they were after many constructions and ends" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned handle → do
        export ← evaluateExport owned (exportOf "m" "return { gameplay = { init = function(self, api) self.n = (self.n or 0) + 1 end, shutdown = function() end } }") >>= ready
        baseline ← holdings owned
        replicateM_ 200 $ do
          capture ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [("a", VInteger 1)])) >>= captured
          _ ← runHook owned handle (capturedHandle capture) HookInit
          _ ← runHook owned handle (capturedHandle capture) HookShutdown
          releaseBehavior owned (capturedHandle capture)
        holdings owned >>= (`shouldBe` baseline)

    it "refuses every use of a reference once the lifetime has ended" $ do
      fixture ← newFixture
      escaped ← newIORef Nothing
      withDriver fixture id $ \owned handle → do
        export ← evaluateExport owned (exportOf "m" "return { gameplay = {} }") >>= ready
        capture ← captureBehavior owned export "gameplay" (FacadeValue (VRecord [])) >>= captured
        writeIORef escaped (Just (owned, handle, export, capture))
      Just (owned, handle, export, capture) ← readIORef escaped
      let closed ∷ IO a → IO ()
          closed action = do
            outcome ← try @SomeException action
            case outcome of
              Left failure | Just (VmClosed _) ← fromException failure → pure ()
              other → expectationFailure ("not refused as closed: " <> either show (const "it succeeded") other)
      closed (evaluateExport owned (exportOf "n" "return {}"))
      closed (retrieveExport owned (ExportIdentity "m"))
      closed (captureBehavior owned export "gameplay" (FacadeValue (VRecord [])))
      closed (releaseBehavior owned (capturedHandle capture))
      closed (runHook owned handle (capturedHandle capture) HookInit)

  describe "failure" $ do
    it "raises a Haskell failure that reached a callback while the top level ran, and records the identity as failed" $ do
      fixture ← newFixture
      withDriver fixture id $ \owned _ → do
        before ← holdings owned
        outcome ← try @SomeException (evaluateExport owned (exportOf "escaping" "pcall(sample.fail, 'x')\nreturn {}"))
        case outcome of
          Left failure → fmap show (fromException failure ∷ Maybe IOError) `shouldSatisfy` isJust
          Right _ → expectationFailure "the callback's failure was swallowed by the script's pcall"
        after ← holdings owned
        -- The table was never kept, and the identity is charged and failed.
        holdExports after `shouldBe` holdExports before
        holdRecords after `shouldBe` holdRecords before + 1
        retrieveExport owned (ExportIdentity "escaping") >>= \found → fmap isFailed found `shouldBe` Just True

    it "survives memory running out at every allocation of an evaluation, a capture and a release" $ do
      window ← sweepWindow
      -- Nothing was left unbalanced by any budget of the window.
      take 5 (concatMap trialViolations window) `shouldBe` []
      let seen = concatMap trialTags window
      -- Memory ran out before an evaluation could start, which charges nothing, and
      -- and the operations also completed in other runs.
      forM_ ["evaluation not started", "evaluation kept", "capture refused", "capture kept", "released"] $ \expected →
        (expected, expected `elem` seen) `shouldBe` (expected, True)

-- Helpers ---------------------------------------------------------------------------

-- | How a capture under a tight budget ended.
data CatchKind = CatchRaised | CatchFaulted | CatchReturned
  deriving (Eq, Show)

-- | One budget's capture of a behavior with a builder that caught a host failure:
-- how it ended, whether the host's callback had run, and what was wrong, if anything.
data CatchTrial = CatchTrial CatchKind Bool Int (Maybe Text)

-- | The exports of the builder example. Neither names @api@ or @self@, so the strings
-- the capture attaches the facade with are made by the capture itself and can be the
-- allocation that fails.
catchSources ∷ (ExportSource, ExportSource)
catchSources =
  ( exportOf "services" "return { build = function(context) pcall(sample.fail, 'caught') return { a = 1, b = 2 } end }"
  , exportOf "carrier" "return { gameplay = { init = function(s, a) end } }"
  )

catchTrial ∷ Int → IO (Maybe CatchTrial)
catchTrial budget = do
  fixture ← newFixture
  built ← newIORef False
  let config =
        (defaultOwnerConfig libraries)
          { ownerBudget = Just budget
          , ownerRegistration = sampleRegistration fixture
          , ownerGranted = ["sample"]
          , ownerName = "tight"
          }
  outcome ← try @SomeException . withOwnedVm config $ \owned → do
    writeIORef built True
    let (services, carrier) = catchSources
        evaluated source = try @SomeException (evaluateExport owned source)
    first ← evaluated services
    second ← evaluated carrier
    case (first, second) of
      (Right (ExportReady serviceHandle), Right (ExportReady carrierHandle)) → do
        attempted ← try @SomeException (captureBehavior owned carrierHandle "gameplay" (FacadeBuilt serviceHandle "build" (VRecord [])))
        callbackRan ← elem "fail" <$> logged fixture
        left ← try @SomeException (liveCaptureReferences (ownedHost owned))
        let kept = either (const 0) id left
            kind = case attempted of
              Right _ → CatchReturned
              Left failure
                | isJust (fromException failure ∷ Maybe IOError) → CatchRaised
                | otherwise → CatchFaulted
            wrong = case (attempted, callbackRan) of
              (Right _, _) → Just "the capture returned although the host's callback had failed"
              (Left failure, True)
                | isJust (fromException failure ∷ Maybe IOError) → if kept /= 0 then Just "a capture was left held" else Nothing
                | otherwise → Just ("the host's failure was replaced by " <> Text.pack (take 80 (show failure)))
              (Left failure, False)
                | exhausted failure → if kept /= 0 then Just "a capture was left held" else Nothing
                | otherwise → Just ("unexpected failure " <> Text.pack (take 80 (show failure)))
        pure (Just (CatchTrial kind callbackRan kept wrong))
      _ → pure Nothing
  case outcome of
    Right trial → pure trial
    Left failure → do
      constructed ← readIORef built
      if constructed then throwIO failure else pure Nothing

catchSweep ∷ IO [CatchTrial]
catchSweep = go (16000 ∷ Int) (0 ∷ Int) []
  where
    go budget raisedInARow gathered
      | raisedInARow >= 40 || budget > 90000 = pure gathered
      | otherwise = do
          found ← catchTrial budget
          case found of
            Nothing → go (budget + 1) raisedInARow gathered
            Just trial@(CatchTrial kind _ _ _) → go (budget + 1) (if kind == CatchRaised then raisedInARow + 1 else 0) (trial : gathered)

void' ∷ Applicative f ⇒ a → f ()
void' _ = pure ()

isFailed ∷ ExportOutcome → Bool
isFailed = \case
  ExportFailed _ → True
  ExportReady _ → False

exportRecordCount' ∷ OwnedVm → IO Int
exportRecordCount' = exportRecordCount . ownedHost

-- | What one byte budget made of the operations under sweep.
data Trial = Trial
  { trialBudget ∷ !Int
  , trialTags ∷ ![Text]
    -- ^ What happened: how far the operations got and where memory ran out.
  , trialViolations ∷ ![Text]
    -- ^ What an operation left unbalanced: a reference, a record, the stack.
  }

-- | The source the operations evaluate: one behavior with every hook and a cadence.
sweepSource ∷ Text
sweepSource = "return { gameplay = { init = function() end, update = function() end, every_ticks = 2 } }"

-- | The facade the sweep captures with: large enough that building it takes more
-- memory than the garbage a failing allocation can collect, so that room can run
-- out in the capture itself.
sweepFacade ∷ FacadeSource
sweepFacade = FacadeValue (VRecord [("name", VText "facade"), ("items", VList (map VInteger [1 .. 300]))])

-- | An owner of this budget over the sample registration, run over a body. A
-- budget the owner could not be built under is 'Nothing': not the operations'.
withBudget ∷ Int → (OwnedVm → IO (Maybe Trial)) → IO (Maybe Trial)
withBudget budget body = do
  fixture ← newFixture
  built ← newIORef False
  let config =
        (defaultOwnerConfig libraries)
          { ownerBudget = Just budget
          , ownerRegistration = sampleRegistration fixture
          , ownerGranted = ["sample"]
          , ownerName = "tight"
          }
  outcome ← try @SomeException . withOwnedVm config $ \owned → do
    writeIORef built True
    body owned
  case outcome of
    Right trial → pure trial
    Left failure → do
      constructed ← readIORef built
      -- Any failure after construction is a failure of the example.
      if constructed then throwIO failure else pure Nothing

-- | Whether memory running out, as the host reports it, is what failed.
exhausted ∷ SomeException → Bool
exhausted failure = isJust (fromException failure ∷ Maybe BoundaryFault) || isJust (fromException failure ∷ Maybe LuaFault)

-- | What an operation recorded about itself, and how it checks what it left.
data Notes = Notes
  { noteTag ∷ Text → IO ()
  , noteExpect ∷ Text → Bool → IO ()
  , noteSettled ∷ Text → Holdings → IO ()
  }

newNotes ∷ OwnedVm → Holdings → IO (Notes, IO ([Text], [Text]))
newNotes owned before = do
  tags ← newIORef []
  violations ← newIORef []
  let expect label condition = unless condition (modifyTags violations label)
      settled label wanted = do
        now ← try @SomeException (readHoldings False owned)
        case now of
          -- The count itself could not run: nothing to compare.
          Left _ → modifyTags tags (label <> ": unread")
          Right held → do
            expect (label <> ": exports " <> Text.pack (show (holdExports held))) (holdExports held == holdExports wanted)
            expect (label <> ": captures " <> Text.pack (show (holdCaptures held))) (holdCaptures held == holdCaptures wanted)
            expect (label <> ": slots") (length (holdSlots held) == holdCaptures wanted)
            expect (label <> ": records " <> Text.pack (show (holdRecords held))) (holdRecords held == holdRecords wanted)
            expect (label <> ": stack") (holdDepth held == holdDepth before)
  pure (Notes (modifyTags tags) expect settled, (,) <$> readIORef tags <*> readIORef violations)

-- | An evaluation, then a capture and a release, under this byte budget of the
-- interpreter's allocator.
trialAt ∷ Int → IO (Maybe Trial)
trialAt budget = withBudget budget $ \owned → do
  start ← try @SomeException (readHoldings False owned)
  case start of
    Left _ → pure Nothing
    Right before → do
      (notes, readNotes) ← newNotes owned before
      evaluated ← try @SomeException (evaluateExport owned (exportOf "m" sweepSource))
      case evaluated of
        Left failure
          | exhausted failure → do
              noteTag notes "evaluation not started"
              -- Nothing ran, so nothing is charged, and the identity can be asked
              -- for again.
              noteSettled notes "after a thrown evaluation" before
          | otherwise → throwIO failure
        Right (ExportFailed _) → do
          noteTag notes "evaluation failed"
          -- Started and failed: the identity is charged, and nothing is held.
          noteSettled notes "after a failed evaluation" before {holdRecords = holdRecords before + 1}
        Right (ExportReady export) → do
          noteTag notes "evaluation kept"
          let kept = before {holdExports = holdExports before + 1, holdRecords = holdRecords before + 1}
          noteSettled notes "after an evaluation" kept
          captureAndRelease notes owned export kept
      Just . (\(tags, violations) → Trial budget tags violations) <$> readNotes

-- | A capture of the behavior, and its release, checked against what each answered.
captureAndRelease ∷ Notes → OwnedVm → ExportHandle → Holdings → IO ()
captureAndRelease notes owned export kept = do
  attempted ← try @SomeException (captureBehavior owned export "gameplay" sweepFacade)
  case attempted of
    Left failure
      | exhausted failure → do
          noteTag notes "capture refused"
          noteSettled notes "after a refused capture" kept
      | otherwise → throwIO failure
    Right (Left problem) → noteExpect notes ("a valid behavior was refused: " <> Text.pack (show problem)) False
    Right (Right capture) → do
      noteTag notes "capture kept"
      noteSettled notes "after a capture" kept {holdCaptures = 1}
      released ← try @SomeException (releaseBehavior owned (capturedHandle capture))
      case released of
        Left _ → noteTag notes "release refused"
        Right () → do
          noteTag notes "released"
          noteSettled notes "after a release" kept

-- | Capture under a budget that leaves this much room after the evaluation:
-- the evaluation's own garbage is what a failing allocation collects, so room is
-- taken from the capture by a string the script keeps.
ballastAt ∷ Int → Int → IO (Maybe Trial)
ballastAt budget ballast = withBudget budget $ \owned → do
  start ← try @SomeException (readHoldings False owned)
  case start of
    Left _ → pure Nothing
    Right before → do
      (notes, readNotes) ← newNotes owned before
      evaluated ← try @SomeException (evaluateExport owned (exportOf "m" sweepSource))
      case evaluated of
        Right (ExportReady export) → do
          let kept = before {holdExports = holdExports before + 1, holdRecords = holdRecords before + 1}
          filled ← try @SomeException (run owned ("collectgarbage(); ballast = string.rep('x', " <> Text.pack (show ballast) <> ")"))
          case filled of
            Left failure
              | exhausted failure → noteTag notes "ballast refused"
              | otherwise → throwIO failure
            Right () → captureAndRelease notes owned export kept
        _ → noteTag notes "evaluation unavailable"
      Just . (\(tags, violations) → Trial budget tags violations) <$> readNotes

modifyTags ∷ IORef [Text] → Text → IO ()
modifyTags ref note = readIORef ref >>= writeIORef ref . (note :)

-- | Every byte budget of the window in which the operations run out of memory:
-- found by a coarse walk to the first budget the owner can be built under, and
-- then one byte at a time, so every allocation of the operations is the one that
-- fails in some run, until they complete a run of times in a row. Then the same
-- walk over the room a capture is left with, by a script's string, so the
-- capture's own allocations are the ones that fail.
sweepWindow ∷ IO [Trial]
sweepWindow = do
  first ← firstBuilt [0, 64 ..]
  evaluation ← collect (max 0 (first - 64)) (0 ∷ Int) []
  let enough = minimum (maxBound : [trialBudget trial | trial ← evaluation, "evaluation kept" `elem` trialTags trial])
  capture ← mapM (ballastAt (enough + 2000)) [0 .. 3000]
  pure (evaluation <> [trial | Just trial ← capture])
  where
    firstBuilt (budget : rest) = trialAt budget >>= maybe (firstBuilt rest) (const (pure budget))
    firstBuilt [] = pure 0
    collect budget completed gathered
      | completed >= 24 = pure gathered
      | budget > 400000 = pure gathered
      | otherwise = do
          found ← trialAt budget
          case found of
            Nothing → collect (budget + 1) completed gathered
            Just trial →
              let done = "released" `elem` trialTags trial
               in collect (budget + 1) (if done then completed + 1 else 0) (trial : gathered)
