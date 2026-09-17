-- | Examples for parsing logging configuration values and for resolving a
-- startup filter from them.
module Test.Engine.Logging.Configuration (spec) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Monad (forM_, void)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log
import Test.Engine.Logging.Support
  ( fixedMetadata
  , gameComponent
  , gpuComponent
  , luaComponent
  , newCollector
  , testComponent
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldReturn
  , shouldStartWith
  )

spec ∷ Spec
spec = do
  describe "Configuration parsing" $ do
    it "accepts every level spelling and rejects the rest" testParseLevel
    it "parses exact per-component overrides" testParseOverrides
    it "rejects a malformed override list" testParseOverridesRejected
    it "parses the Debug selection and collapses repeats" testParseDebug
    it "rejects a malformed Debug selection" testParseDebugRejected
    it "quotes and escapes a rejected value in its message" testParseEscaping
  describe "Startup configuration" $ do
    it "keeps every default when no variable is present" testResolveDefaults
    it "assembles the filter from all three variables" testResolveAll
    it "names the variable an invalid value came from" testResolveInvalid
    it "leaves the master and source switches programmatic" testResolveProgrammatic
    it "consults each variable exactly once and nothing afterwards" testResolveOnce

-- | The variable names the console application chooses, used by the
-- injected-lookup assembly cases. The console's child-process startup examples
-- state the same names beside their own suite.
consoleVariables ∷ LogVariables
consoleVariables = LogVariables
  { variableGlobalLevel = "HETOIMASIA_LOG_LEVEL"
  , variableComponentLevels = "HETOIMASIA_LOG_LEVELS"
  , variableDebug = "HETOIMASIA_DEBUG"
  }

-- | A rejection must carry the text that identifies what was wrong, because
-- that message is the whole startup diagnostic.
rejects ∷ Show a ⇒ (Text → Either Text a) → (Text, Text) → Expectation
rejects parse (value, expected) = case parse value of
  Right accepted →
    expectationFailure ("accepted " <> show value <> " as " <> show accepted)
  Left reason → Text.unpack reason `shouldContain` Text.unpack expected

testParseLevel ∷ IO ()
testParseLevel = do
  forM_ accepted $ \(value, level) → parseLogLevel value `shouldBe` Right level
  forM_ rejected (rejects parseLogLevel)
  where
    -- Spellings are case-insensitive and surrounding whitespace is trimmed;
    -- "warn" and "warning" are the same level.
    accepted =
      [ ("info", Info)
      , ("INFO", Info)
      , ("Warn", Warning)
      , ("warning", Warning)
      , ("error", Error)
      , ("debug", Debug)
      , (" info ", Info)
      ]
    -- An empty value is an error rather than the default.
    rejected = [("verbose", "verbose"), ("warnings", "warnings"), ("", "required")]

testParseOverrides ∷ IO ()
testParseOverrides = do
  parseComponentLevels "gpu.vulkan=warn,lua=info"
    `shouldBe` Right (Map.fromList [(gpuComponent, Warning), (luaComponent, Info)])
  -- Whitespace around an entry, a name, and a value is trimmed.
  parseComponentLevels " gpu.vulkan = warn "
    `shouldBe` Right (Map.fromList [(gpuComponent, Warning)])

testParseOverridesRejected ∷ IO ()
testParseOverridesRejected = forM_ rejected (rejects parseComponentLevels)
  where
    rejected =
      [ ("gpu.vulkan=warn,gpu.vulkan=info", "appears twice")
      , ("gpu.vulkan", "expected component=level")
      , ("Gpu.Vulkan=warn", "Gpu.Vulkan")
      , ("gpu vulkan=warn", "gpu vulkan")
      , ("gpu.vulkan=warn,", "an entry is empty")
      , ("lua=verbose", "expected debug, info")
      , ("", "required")
      ]

testParseDebug ∷ IO ()
testParseDebug = do
  parseDebugSelection "none" `shouldBe` Right DebugNone
  parseDebugSelection "all" `shouldBe` Right DebugAll
  parseDebugSelection "gpu.vulkan,lua"
    `shouldBe` Right (DebugComponents (Set.fromList [gpuComponent, luaComponent]))
  -- A repeated component is one selection, not an error.
  parseDebugSelection "gpu.vulkan,gpu.vulkan"
    `shouldBe` Right (DebugComponents (Set.fromList [gpuComponent]))

testParseDebugRejected ∷ IO ()
testParseDebugRejected = forM_ rejected (rejects parseDebugSelection)
  where
    -- The selectors are exactly lowercase and never mix with component names.
    rejected =
      [ ("all,gpu.vulkan", "cannot be combined")
      , ("NONE", "lowercase")
      , ("All", "lowercase")
      , ("gpu.vulkan,", "an entry is empty")
      , ("", "required")
      ]

testParseEscaping ∷ IO ()
testParseEscaping = do
  -- A rejected value is quoted and escaped the way the record layout escapes
  -- text, so nothing a value carries can split the diagnostic or forge a line.
  forM_ rejections $ \(parse, value) → case parse value of
    Right accepted → expectationFailure ("accepted " <> show value <> ": " <> accepted)
    Left reason → do
      Text.unpack reason `shouldContain` "\"bad\\nforged\""
      Text.lines reason `shouldBe` [reason]
  where
    forged = "bad\nforged"
    -- Each parser reports through the same helper, including the component
    -- rejection an override list propagates.
    rejections =
      [ (fmap show . parseLogLevel, forged)
      , (fmap show . parseComponentLevels, forged <> "=warn")
      , (fmap show . parseDebugSelection, forged)
      , (fmap show . mkComponent, forged)
      ]

-- | A lookup over a fixed table, with no environment behind it at all.
tableLookup ∷ [(Text, Text)] → Text → IO (Maybe Text)
tableLookup table name = pure (lookup name table)

-- | The resolved configuration, failing the example with the reason instead.
expectResolved ∷ Either Text LogFilter → IO LogFilter
expectResolved = either reject pure
  where
    reject reason = do
      expectationFailure ("startup rejected a valid configuration: " <> Text.unpack reason)
      -- Unreachable: 'expectationFailure' throws.
      pure defaultLogFilter

testResolveDefaults ∷ IO ()
testResolveDefaults =
  -- An absent variable keeps its default, so an empty environment resolves to
  -- exactly the default filter.
  resolveLogFilter consoleVariables (tableLookup []) defaultLogFilter
    `shouldReturn` Right defaultLogFilter

testResolveAll ∷ IO ()
testResolveAll = do
  resolved ← resolveLogFilter consoleVariables (tableLookup table) defaultLogFilter
  resolved `shouldBe` Right defaultLogFilter
    { filterGlobalLevel = Warning
    , filterComponentLevels = Map.fromList [(gpuComponent, Error), (gameComponent, Debug)]
    , filterDebug = DebugComponents (Set.fromList [gpuComponent])
    }
  where
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "Warn")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=error, game.world=debug ")
      , ("HETOIMASIA_DEBUG", "gpu.vulkan")
      ]

testResolveInvalid ∷ IO ()
testResolveInvalid = forM_ invalid $ \(name, value) → do
  -- Each variable is invalid while the other two are absent, so only the one
  -- under test can be the variable the message names.
  resolved ← resolveLogFilter consoleVariables (tableLookup [(name, value)]) defaultLogFilter
  case resolved of
    Right accepted → expectationFailure ("startup accepted " <> show value <> ": " <> show accepted)
    Left reason → Text.unpack reason `shouldStartWith` (Text.unpack name <> ": ")
  where
    invalid =
      [ ("HETOIMASIA_LOG_LEVEL", "verbose")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=warn,gpu.vulkan=info")
      , ("HETOIMASIA_DEBUG", "All")
      ]

testResolveProgrammatic ∷ IO ()
testResolveProgrammatic = forM_ [False, True] $ \switch → do
  -- No variable controls the master or source switch: whatever the base
  -- configuration set, the resolved one keeps.
  let base = defaultLogFilter { filterEnabled = switch, filterSource = switch }
  configuration ←
    resolveLogFilter consoleVariables (tableLookup table) base >>= expectResolved
  filterEnabled configuration `shouldBe` switch
  filterSource configuration `shouldBe` switch
  filterGlobalLevel configuration `shouldBe` Error
  where
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "error")
      , ("HETOIMASIA_LOG_LEVELS", "lua=info")
      , ("HETOIMASIA_DEBUG", "all")
      ]

testResolveOnce ∷ IO ()
testResolveOnce = do
  -- Acquisition consults each supported variable exactly once, in order, and
  -- consults nothing else.
  (valid, configuration) ← consult table
  valid `shouldBe` names
  -- Logging through the resolved filter reads no variable again: the filter is
  -- a value and the logger holds no lookup.
  (sink, collected) ← newCollector
  let logger = mkLoggerWith configuration fixedMetadata sink
  logInfo logger testComponent "after startup" []
  logDebug logger gpuComponent "detail" []
  (length <$> collected) `shouldReturn` 2
  consulted ← consult table
  fst consulted `shouldBe` names
  -- An invalid value does not short-circuit acquisition either: every lookup
  -- happens before any value is parsed.
  rejectedLookups ← newMVar ([] ∷ [Text])
  void $ resolveLogFilter consoleVariables (recording rejectedLookups broken) defaultLogFilter
  (reverse <$> readMVar rejectedLookups) `shouldReturn` names
  where
    names = ["HETOIMASIA_LOG_LEVEL", "HETOIMASIA_LOG_LEVELS", "HETOIMASIA_DEBUG"]
    table =
      [ ("HETOIMASIA_LOG_LEVEL", "info")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=debug")
      , ("HETOIMASIA_DEBUG", "gpu.vulkan")
      ]
    broken = [("HETOIMASIA_LOG_LEVEL", "verbose")]

    recording seen values name = do
      modifyMVar_ seen (pure . (name :))
      pure (lookup name values)

    consult values = do
      seen ← newMVar []
      configuration ←
        resolveLogFilter consoleVariables (recording seen values) defaultLogFilter
          >>= expectResolved
      (,) <$> (reverse <$> readMVar seen) <*> pure configuration
