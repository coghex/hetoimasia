-- | Examples for scoped context, breadcrumbs, and source attribution.
module Test.Engine.Logging.Context (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  )
import Hetoimasia.Foundation.Log
import Test.Engine.Logging.Support (fixedMetadata, newCollector, testComponent)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "Logger context" $ do
    it "resolves field precedence and breadcrumb order" testContextPrecedence
    it "keeps concurrent worker context and thread identity separate" testConcurrentContext
  describe "Logger source attribution" $ do
    it "reports the call site outside a wrapper" testSourceThroughWrapper
    it "reports no location when the source switch is off" testSourceDisabled

testContextPrecedence ∷ IO ()
testContextPrecedence = do
  (sink, collected) ← newCollector
  let root = mkLoggerWith defaultLogFilter fixedMetadata sink
      outer = withBreadcrumb "startup" (withFields [("service", "engine"), ("scope", "outer")] root)
      inner = withBreadcrumb "worker" (withFields [("scope", "inner")] outer)
  logInfo inner testComponent "inherited" []
  logInfo inner testComponent "overridden" [("scope", "event")]
  -- Deriving never mutates the parent.
  logInfo outer testComponent "parent" []
  entries ← collected
  map entryFields entries `shouldBe`
    [ fields [("service", "engine"), ("scope", "inner")]
    , fields [("service", "engine"), ("scope", "event")]
    , fields [("service", "engine"), ("scope", "outer")]
    ]
  map entryBreadcrumbs entries `shouldBe`
    [ ["startup", "worker"]
    , ["startup", "worker"]
    , ["startup"]
    ]
  where
    fields ∷ [(Text, Text)] → Map Text Text
    fields = Map.fromList

testConcurrentContext ∷ IO ()
testConcurrentContext = do
  (sink, collected) ← newCollector
  -- Real thread identities, so the two workers must report different ones.
  let root = withFields [("service", "engine")] (mkLogger defaultLogFilter sink)
  startOne ← newEmptyMVar
  startTwo ← newEmptyMVar
  doneOne ← newEmptyMVar
  doneTwo ← newEmptyMVar
  let worker name start done = void . forkIO $ do
        takeMVar start
        identity ← myThreadId
        logInfo (withFields [("worker", name)] root) testComponent "tick" []
        -- The same numeric identity 'systemMetadata' reports, derived here
        -- independently of the logger.
        putMVar done (Text.dropWhile (not . isDigit) (Text.pack (show identity)))
  worker "one" startOne (doneOne ∷ MVar Text)
  worker "two" startTwo (doneTwo ∷ MVar Text)
  putMVar startOne ()
  putMVar startTwo ()
  threadOne ← takeMVar doneOne
  threadTwo ← takeMVar doneTwo
  threadOne `shouldNotBe` threadTwo
  entries ← collected
  map entryMessage entries `shouldBe` ["tick", "tick"]
  let observed name = [(entryFields entry, entryThread entry)
                      | entry ← entries
                      , Map.lookup "worker" (entryFields entry) == Just name]
  observed "one" `shouldBe`
    [(Map.fromList [("service", "engine"), ("worker", "one")], threadOne)]
  observed "two" `shouldBe`
    [(Map.fromList [("service", "engine"), ("worker", "two")], threadTwo)]

-- | A wrapper declaring the call-stack constraint. The entry it emits must be
-- attributed to this function's own caller, which it returns for comparison.
logThroughWrapper ∷ HasCallStack ⇒ Logger → IO (Maybe SourceLocation)
logThroughWrapper logger = do
  logInfo logger testComponent "through wrapper" []
  pure (outermostSite callStack)

-- | The contract's attribution rule, computed independently of the logger.
outermostSite ∷ CallStack → Maybe SourceLocation
outermostSite stack = case reverse (getCallStack stack) of
  [] → Nothing
  ((name, location) : _) → Just SourceLocation
    { sourceFile = Text.pack (srcLocFile location)
    , sourceLine = srcLocStartLine location
    , sourceFunction = Text.pack name
    }

testSourceThroughWrapper ∷ IO ()
testSourceThroughWrapper = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter fixedMetadata sink
  expected ← logThroughWrapper logger
  expected `shouldSatisfy` (/= Nothing)
  entries ← collected
  -- The outer frame, not the `logInfo` call inside the wrapper.
  map (fmap sourceFunction . entrySource) entries `shouldBe` [Just "logThroughWrapper"]
  map entrySource entries `shouldBe` [expected]

testSourceDisabled ∷ IO ()
testSourceDisabled = do
  (sink, collected) ← newCollector
  let logger = mkLoggerWith defaultLogFilter { filterSource = False } fixedMetadata sink
  void (logThroughWrapper logger)
  entries ← collected
  map entrySource entries `shouldBe` [Nothing]
