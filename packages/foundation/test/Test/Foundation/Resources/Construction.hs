-- | Examples for 'Hetoimasia.Foundation.Recovery.allocComponent', the scoped
-- constructor that selects a live component among composite alternatives.
--
-- Every example enters a real CPU scope through 'withScoped' and observes what
-- a caller can see: the 'Outcome' the continuation receives, the failure that
-- propagated with its origin, cleanup, and recovery evidence, and an ordered
-- trace of acquisitions, releases, policy steps, and continuation effects.
-- The component-convention examples use the synthetic journal of
-- "Test.Foundation.Resources.Journal"; the rest build small assemblies here so
-- each failure can be placed exactly.
--
-- Cancellation is coordinated with 'MVar's and 'threadStatus', never with a
-- sleep. 'boundedExample' only stops an example that has already hung.
module Test.Foundation.Resources.Construction (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , WhileHandling (WhileHandling)
  , annotateIO
  , evaluate
  , fromException
  , someExceptionContext
  , throw
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (failureCause)
  , FailureOrigin (..)
  , Operation
  , failureEvidenceInContext
  , operation
  , throwFailure
  )
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (..)
  , AttemptKind (..)
  , Disposition (..)
  , InvalidRecoveryPolicy (..)
  , Outcome (..)
  , Recovered (..)
  , RecoveryHistory (..)
  , RecoveryPolicy (..)
  , Strategy (..)
  , Unavailability (..)
  , allocComponent
  , recoveryHistoryInContext
  )
import Hetoimasia.Foundation.Resource
  ( Assembly
  , acquirePart
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , releaseRank
  , restoredStep
  , withScoped
  )
import System.Timeout (timeout)
import Test.Foundation.Resources.Journal
  ( JournalConfigFault (..)
  , JournalFault (..)
  , Store (..)
  , allocJournal
  , appendEntry
  , breakStage
  , journalCapacity
  , journalConfig
  , journalEntries
  , journalLive
  , journalOperation
  , journalStore
  , newRig
  , note
  , rigTrace
  , spillOperation
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  )

spec ∷ Spec
spec = describe "Scoped component construction" $ do
  describe "Component convention" $ do
    it "observes a configuration fault before any acquisition"
      testConfigurationFault
    it "reaches private state only through the handle"
      testPrivateStateThroughHandle

  describe "Policy and budget" $ do
    it "rejects an invalid policy before any effect"
      testInvalidPolicy
    it "exhausts one budget across alternatives without resetting it"
      testBudgetAcrossAlternatives

  describe "Selection" $ do
    it "selects the initial alternative with no history"
      testInitialSelection
    it "releases exactly a failed attempt's parts in declared order before the classifier and the next alternative"
      testRollbackBeforeNextAlternative
    it "keeps a fallback handle live for the whole consumer and runs the consumer once"
      testFallbackLiveForConsumer
    it "binds exhausted optional construction as unavailable data the consumer branches on"
      testOptionalUnavailable
    it "propagates required exhaustion with every earlier attempt's origin and cleanup evidence in order"
      testRequiredExhaustion

  describe "Failures that stop construction" $ do
    it "propagates an unrecognized failure unchanged"
      testUnrecognizedFailure
    it "propagates an attempt with cleanup evidence without classifying it"
      testCleanupEvidenceStops
    it "stops on a classifier failure, keeping the handled failure as context"
      testClassifierFailure

  describe "Cancellation" $ do
    it "escapes cancellation during construction with its rollback evidence"
      (boundedExample testCancelDuringConstruction)
    it "defers cancellation during rollback until every release is attempted, then escapes with its evidence"
      (boundedExample testCancelDuringRollback)
    it "releases every part when cancellation preempts the consumer at the protected handoff"
      (boundedExample testCancelAtHandoff)

  describe "After selection" $ do
    it "propagates a consumer failure with cleanup evidence and no further attempt"
      testConsumerFailure
    it "treats a lazy result forced in the consumer as a consumer failure"
      testLazyResultInConsumer
    it "fails with the final release's exception after a successful consumer, with no further attempt"
      testFinalReleaseFailure
    it "never restarts construction when the consumer of an unavailable value fails"
      testUnavailableConsumerFailure

-- Fixtures -------------------------------------------------------------------

-- | The failures the small assemblies here raise.
data Broken
  = Broken Int
  | Unknown
  deriving (Eq, Show)

instance Exception Broken

-- | A caller's own annotation, used to prove existing context is kept.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

widgets ∷ Component
widgets = unsafeComponent "test.widgets"

loadWidget ∷ Operation
loadWidget = operation "load-widget"

cachedWidget ∷ Operation
cachedWidget = operation "cached-widget"

-- | Fail an attempt with an engine origin naming it.
failAttempt ∷ Int → IO a
failAttempt number =
  throwFailure widgets loadWidget [("attempt", Text.pack (show number))] (Broken number)

newTrace ∷ IO (IORef [Text])
newTrace = newIORef []

record ∷ IORef [Text] → Text → IO ()
record trace entry = atomicModifyIORef' trace (\entries → (entries <> [entry], ()))

newCounter ∷ IO (IORef Int)
newCounter = newIORef 0

bump ∷ IORef Int → IO Int
bump counter = atomicModifyIORef' counter (\n → (n + 1, n + 1))

counted ∷ IORef Int → (AttemptFailure → IO b) → AttemptFailure → IO b
counted counter classifier failure = bump counter >> classifier failure

policy
  ∷ Disposition
  → Int
  → (AttemptFailure → IO (Maybe (Strategy (Assembly a))))
  → RecoveryPolicy (Assembly a)
policy disposition budget classifier =
  RecoveryPolicy
    { policyDisposition = disposition
    , policyBudget = budget
    , policyClassifier = classifier
    , policyWait = \_ → pure ()
    }

-- | Recognize 'Broken' with one strategy and nothing else.
recognizeBroken ∷ Strategy a → AttemptFailure → IO (Maybe (Strategy a))
recognizeBroken strategy failure = pure $ case failureOf failure of
  Just (Broken _) → Just strategy
  _ → Nothing

failureOf ∷ Exception e ⇒ AttemptFailure → Maybe e
failureOf failure = case attemptException failure of
  ExceptionWithContext _ exception → fromException exception

contextOf ∷ AttemptFailure → ExceptionContext
contextOf failure = case attemptException failure of
  ExceptionWithContext context _ → context

-- | Two parts, released in acquisition order because that is the order their
-- ranks declare, then a final restored step. Every effect is traced under the
-- assembly's name, and the assembly's value is that name.
staged ∷ IORef [Text] → Text → IO () → Assembly Text
staged trace name finish = do
  acquirePart (name <> " first") (releaseRank 0)
    (record trace (name <> ": acquire first"))
    (\() → record trace (name <> ": release first"))
  acquirePart (name <> " second") (releaseRank 1)
    (record trace (name <> ": acquire second"))
    (\() → record trace (name <> ": release second"))
  restoredStep finish
  pure name

-- | Run @action@, requiring it to fail with the given type.
expectContext ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
expectContext action = do
  outcome ← tryWithContext action
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected construction to propagate a failure, but it returned"

expectAvailable ∷ Outcome a → IO (Recovered a)
expectAvailable (Available recovered) = pure recovered
expectAvailable (Unavailable reason) = fail ("expected an available component, found " <> show reason)

attemptOrigin ∷ ExceptionContext → Maybe [(Text, Text)]
attemptOrigin context = case failureCause (failureEvidenceInContext context) of
  EngineOrigin origin → Just (originIdentifiers origin)
  NativeCause → Nothing

attemptLabel ∷ Int → Maybe [(Text, Text)]
attemptLabel number = Just [("attempt", Text.pack (show number))]

stageLabel ∷ Text → Maybe [(Text, Text)]
stageLabel name = Just [("stage", name)]

handledFailures ∷ ExceptionContext → [SomeException]
handledFailures context = [handled | WhileHandling handled ← getExceptionAnnotations context]

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- | Wait until a thread is blocked delivering an exception, or has finished.
awaitPendingThrow ∷ ThreadId → IO ThreadStatus
awaitPendingThrow target = do
  status ← threadStatus target
  case status of
    ThreadBlocked BlockedOnException → pure status
    ThreadFinished → pure status
    ThreadDied → pure status
    _ → yield *> awaitPendingThrow target

-- Component convention -------------------------------------------------------

testConfigurationFault ∷ Expectation
testConfigurationFault = do
  rig ← newRig
  consumed ← newCounter
  outcome ←
    try @JournalConfigFault $
      withScoped
        ( do
            config ← liftIO (either throwIO pure (journalConfig 0))
            allocJournal rig Required 2 config
        )
        (\_ → void (bump consumed))
  outcome `shouldBe` Left (NonPositiveCapacity 0)
  rigTrace rig `shouldReturn` []
  readIORef consumed `shouldReturn` 0
  fmap journalCapacity (journalConfig 2) `shouldBe` Right 2

testPrivateStateThroughHandle ∷ Expectation
testPrivateStateThroughHandle = do
  rig ← newRig
  config ← either throwIO pure (journalConfig 2)
  observed ←
    withScoped ((,) <$> allocJournal rig Required 1 config <*> allocJournal rig Required 1 config) $
      \(first, second) → do
        left ← recoveredValue <$> expectAvailable first
        right ← recoveredValue <$> expectAvailable second
        appendEntry left "one"
        appendEntry left "two"
        -- The configured capacity is enforced through the handle.
        full ← try (appendEntry left "three")
        entries ← (,) <$> journalEntries left <*> journalEntries right
        pure (full, entries)
  observed `shouldBe` (Left (JournalFull 2), (["one", "two"], []))

-- Policy and budget ----------------------------------------------------------

testInvalidPolicy ∷ Expectation
testInvalidPolicy = do
  effects ← newCounter
  trace ← newTrace
  let invalid budget =
        RecoveryPolicy
          { policyDisposition = Optional
          , policyBudget = budget
          , policyClassifier = \_ → bump effects >> pure (Just Retry)
          , policyWait = \_ → void (bump effects)
          }
      construct budget =
        try $
          withScoped (allocComponent loadWidget (invalid budget) (staged trace "initial" (void (bump effects))))
            (\_ → void (bump effects))
  zero ← construct 0
  negative ← construct (-2)
  either Just (const Nothing) zero `shouldBe` Just (NonPositiveBudget 0)
  either Just (const Nothing) negative `shouldBe` Just (NonPositiveBudget (-2))
  readIORef effects `shouldReturn` 0
  readIORef trace `shouldReturn` []
  rig ← newRig
  config ← either throwIO pure (journalConfig 1)
  journal ← try (withScoped (allocJournal rig Optional 0 config) (\_ → note rig "consumer"))
  either Just (const Nothing) journal `shouldBe` Just (NonPositiveBudget 0)
  rigTrace rig `shouldReturn` []

testBudgetAcrossAlternatives ∷ Expectation
testBudgetAcrossAlternatives = do
  trace ← newTrace
  originals ← newCounter
  fallbacks ← newCounter
  classified ← newCounter
  consumed ← newCounter
  let fallback = staged trace "fallback" (bump fallbacks >> failAttempt 3)
      classifier failure = do
        _ ← bump classified
        pure . Just $ case attemptKind failure of
          InitialAttempt → Retry
          RetryAttempt → Fallback cachedWidget (pure fallback)
          -- The alternative changes back; the budget must not reset.
          FallbackAttempt _ → Retry
  ExceptionWithContext context failure ←
    expectContext @Broken $
      withScoped
        (allocComponent loadWidget (policy Required 3 classifier) (staged trace "initial" (bump originals >>= failAttempt)))
        (\_ → void (bump consumed))
  failure `shouldBe` Broken 3
  readIORef originals `shouldReturn` 2
  readIORef fallbacks `shouldReturn` 1
  readIORef classified `shouldReturn` 3
  readIORef consumed `shouldReturn` 0
  map (map attemptKind . historyAttempts) (recoveryHistoryInContext context)
    `shouldBe` [[InitialAttempt, RetryAttempt]]

-- Selection ------------------------------------------------------------------

testInitialSelection ∷ Expectation
testInitialSelection = do
  rig ← newRig
  config ← either throwIO pure (journalConfig 1)
  (store, kind, earlier) ←
    withScoped (allocJournal rig Required 3 config) $ \outcome → do
      recovered ← expectAvailable outcome
      note rig "consumer"
      pure (journalStore (recoveredValue recovered), recoveredBy recovered, length (recoveredFailures recovered))
  (store, kind, earlier) `shouldBe` (MemoryStore, InitialAttempt, 0)
  rigTrace rig
    `shouldReturn` [ "memory: acquire index"
                   , "memory: acquire store"
                   , "memory: bind"
                   , "consumer"
                   , "memory: release store"
                   , "memory: release index"
                   ]

testRollbackBeforeNextAlternative ∷ Expectation
testRollbackBeforeNextAlternative = do
  trace ← newTrace
  let classifier failure = do
        record trace "classify"
        recognizeBroken
          (Fallback cachedWidget (record trace "select" >> pure (staged trace "fallback" (pure ()))))
          failure
      waiting number = record trace ("wait " <> Text.pack (show number))
      construction =
        allocComponent loadWidget ((policy Required 2 classifier) {policyWait = waiting}) $
          staged trace "initial" (failAttempt 1)
  name ←
    withScoped construction $ \outcome → do
      recovered ← expectAvailable outcome
      record trace ("consumer " <> recoveredValue recovered)
      pure (recoveredValue recovered)
  name `shouldBe` "fallback"
  readIORef trace
    `shouldReturn` [ "initial: acquire first"
                   , "initial: acquire second"
                   , "initial: release first"
                   , "initial: release second"
                   , "classify"
                   , "wait 2"
                   , "select"
                   , "fallback: acquire first"
                   , "fallback: acquire second"
                   , "consumer fallback"
                   , "fallback: release first"
                   , "fallback: release second"
                   ]

testFallbackLiveForConsumer ∷ Expectation
testFallbackLiveForConsumer = do
  rig ← newRig
  breakStage rig "memory: acquire store"
  config ← either throwIO pure (journalConfig 4)
  consumed ← newCounter
  (store, kind, earlier, liveAtStart, liveAtEnd, entries) ←
    withScoped (allocJournal rig Required 3 config) $ \outcome → do
      _ ← bump consumed
      recovered ← expectAvailable outcome
      let journal = recoveredValue recovered
      note rig "consumer start"
      liveAtStart ← journalLive journal
      appendEntry journal "first"
      appendEntry journal "second"
      entries ← journalEntries journal
      liveAtEnd ← journalLive journal
      note rig "consumer end"
      pure
        ( journalStore journal
        , recoveredBy recovered
        , map attemptKind (recoveredFailures recovered)
        , liveAtStart
        , liveAtEnd
        , entries
        )
  (store, kind, earlier) `shouldBe` (SpillStore, FallbackAttempt spillOperation, [InitialAttempt])
  (liveAtStart, liveAtEnd, entries) `shouldBe` (True, True, ["first", "second"])
  readIORef consumed `shouldReturn` 1
  rigTrace rig
    `shouldReturn` [ "memory: acquire index"
                   , "memory: acquire store"
                   , "memory: release index"
                   , "spill: acquire index"
                   , "spill: acquire store"
                   , "spill: bind"
                   , "consumer start"
                   , "consumer end"
                   , "spill: release store"
                   , "spill: release index"
                   ]

testOptionalUnavailable ∷ Expectation
testOptionalUnavailable = do
  rig ← newRig
  breakStage rig "memory: acquire store"
  breakStage rig "spill: acquire store"
  config ← either throwIO pure (journalConfig 1)
  consumed ← newCounter
  observed ←
    withScoped (allocJournal rig Optional 2 config) $ \outcome → do
      _ ← bump consumed
      case outcome of
        Available _ → pure Nothing
        Unavailable reason → do
          note rig "consumer unavailable"
          pure $
            Just
              ( unavailableOperation reason
              , attemptNumber (unavailableReason reason)
              , attemptKind (unavailableReason reason)
              , attemptOrigin (contextOf (unavailableReason reason))
              , map attemptKind (unavailableEarlier reason)
              , map (attemptOrigin . contextOf) (unavailableEarlier reason)
              )
  observed
    `shouldBe` Just
      ( journalOperation
      , 2
      , FallbackAttempt spillOperation
      , stageLabel "spill: acquire store"
      , [InitialAttempt]
      , [stageLabel "memory: acquire store"]
      )
  readIORef consumed `shouldReturn` 1
  -- Rollback finished before the consumer, and nothing is released after it.
  rigTrace rig
    `shouldReturn` [ "memory: acquire index"
                   , "memory: acquire store"
                   , "memory: release index"
                   , "spill: acquire index"
                   , "spill: acquire store"
                   , "spill: release index"
                   , "consumer unavailable"
                   ]

testRequiredExhaustion ∷ Expectation
testRequiredExhaustion = do
  rig ← newRig
  breakStage rig "memory: acquire store"
  breakStage rig "spill: acquire store"
  config ← either throwIO pure (journalConfig 1)
  ExceptionWithContext context failure ←
    expectContext @JournalFault $
      withScoped (allocJournal rig Required 3 config) (\_ → note rig "consumer")
  -- The latest failure is primary, with its own origin and no cleanup evidence.
  failure `shouldBe` StageBroken "memory: acquire store"
  attemptOrigin context `shouldBe` stageLabel "memory: acquire store"
  length (cleanupFailuresInContext context) `shouldBe` 0
  case recoveryHistoryInContext context of
    [history] → do
      historyOperation history `shouldBe` journalOperation
      map attemptNumber (historyAttempts history) `shouldBe` [1, 2]
      map attemptKind (historyAttempts history) `shouldBe` [InitialAttempt, FallbackAttempt spillOperation]
      map (attemptOrigin . contextOf) (historyAttempts history)
        `shouldBe` [stageLabel "memory: acquire store", stageLabel "spill: acquire store"]
      map (length . cleanupFailuresInContext . contextOf) (historyAttempts history) `shouldBe` [0, 0]
    other → expectationFailure ("expected one recovery history, found " <> show other)
  -- Three attempts across both alternatives, each rolled back, and no consumer.
  rigTrace rig
    `shouldReturn` [ "memory: acquire index"
                   , "memory: acquire store"
                   , "memory: release index"
                   , "spill: acquire index"
                   , "spill: acquire store"
                   , "spill: release index"
                   , "memory: acquire index"
                   , "memory: acquire store"
                   , "memory: release index"
                   ]

-- Failures that stop construction --------------------------------------------

testUnrecognizedFailure ∷ Expectation
testUnrecognizedFailure = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  let raise = throwFailure widgets loadWidget [("attempt", "1")] Unknown
  ExceptionWithContext context failure ←
    expectContext @Broken $
      withScoped
        ( allocComponent loadWidget (policy Optional 3 (counted classified (recognizeBroken Retry))) $
            staged trace "initial" (annotateIO (Marker "kept") raise)
        )
        (\_ → void (bump consumed))
  failure `shouldBe` Unknown
  attemptOrigin context `shouldBe` attemptLabel 1
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "kept"]
  length (recoveryHistoryInContext context) `shouldBe` 0
  length (handledFailures context) `shouldBe` 0
  readIORef classified `shouldReturn` 1
  readIORef consumed `shouldReturn` 0
  readIORef trace
    `shouldReturn` [ "initial: acquire first"
                   , "initial: acquire second"
                   , "initial: release first"
                   , "initial: release second"
                   ]

testCleanupEvidenceStops ∷ Expectation
testCleanupEvidenceStops = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  let construction = do
        acquirePart "cache" (releaseRank 0) (record trace "acquire cache") $ \() → do
          record trace "release cache"
          ioError (userError "cache release failed")
        acquirePart "buffer" (releaseRank 1) (record trace "acquire buffer") (\() → record trace "release buffer")
        restoredStep (failAttempt 1)
  ExceptionWithContext context failure ←
    expectContext @Broken $
      withScoped
        (allocComponent loadWidget (policy Optional 3 (counted classified (recognizeBroken Retry))) construction)
        (\_ → void (bump consumed))
  failure `shouldBe` Broken 1
  attemptOrigin context `shouldBe` attemptLabel 1
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["cache"]
  readIORef classified `shouldReturn` 0
  readIORef consumed `shouldReturn` 0
  readIORef trace `shouldReturn` ["acquire cache", "acquire buffer", "release cache", "release buffer"]

testClassifierFailure ∷ Expectation
testClassifierFailure = do
  trace ← newTrace
  consumed ← newCounter
  let classifier _ = ioError (userError "classifier broke")
  ExceptionWithContext context failure ←
    expectContext @IOException $
      withScoped
        (allocComponent loadWidget (policy Required 3 classifier) (staged trace "initial" (failAttempt 1)))
        (\_ → void (bump consumed))
  show failure `shouldBe` "user error (classifier broke)"
  readIORef consumed `shouldReturn` 0
  readIORef trace
    `shouldReturn` [ "initial: acquire first"
                   , "initial: acquire second"
                   , "initial: release first"
                   , "initial: release second"
                   ]
  case handledFailures context of
    [handled] → do
      fromException handled `shouldBe` Just (Broken 1)
      attemptOrigin (someExceptionContext handled) `shouldBe` attemptLabel 1
    other → expectationFailure ("expected one handled failure, found " <> show other)

-- Cancellation ---------------------------------------------------------------

testCancelDuringConstruction ∷ Expectation
testCancelDuringConstruction = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  entered ← newEmptyMVar
  never ← newEmptyMVar
  result ← newEmptyMVar
  let construction = do
        acquirePart "cache" (releaseRank 0) (record trace "acquire cache") $ \() → do
          record trace "release cache"
          ioError (userError "cache release failed")
        -- A blocking acquisition stays cancellable under the assembly's mask.
        acquirePart "blocked" (releaseRank 1)
          (annotateIO (Marker "blocked") (putMVar entered () >> takeMVar never))
          (\() → record trace "release blocked")
      policy' = policy Optional 3 (counted classified (\_ → pure (Just Retry)))
  worker ←
    forkIO $
      tryWithContext (withScoped (allocComponent loadWidget policy' construction) (\_ → void (bump consumed)))
        >>= putMVar result
  takeMVar entered
  killThread worker
  outcome ← takeMVar result
  void (tryPutMVar never ())
  case outcome of
    Right () → expectationFailure "expected construction to be cancelled"
    Left (ExceptionWithContext context cancellation) → do
      fromException cancellation `shouldBe` Just ThreadKilled
      (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "blocked"]
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["cache"]
      length (recoveryHistoryInContext context) `shouldBe` 0
  readIORef classified `shouldReturn` 0
  readIORef consumed `shouldReturn` 0
  -- Only the part that was acquired is released, and no attempt follows.
  readIORef trace `shouldReturn` ["acquire cache", "release cache"]

testCancelDuringRollback ∷ Expectation
testCancelDuringRollback = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  insideRelease ← newEmptyMVar
  killerSlot ← newEmptyMVar
  killerStatus ← newEmptyMVar
  killerDone ← newEmptyMVar
  result ← newEmptyMVar
  let construction = do
        acquirePart "first" (releaseRank 0) (record trace "acquire first") $ \() → do
          record trace "first start"
          putMVar insideRelease ()
          killer ← readMVar killerSlot
          status ← awaitPendingThrow killer
          putMVar killerStatus status
          record trace "first end"
          ioError (userError "first release failed")
        acquirePart "second" (releaseRank 1) (record trace "acquire second") (\() → record trace "second")
        restoredStep (failAttempt 1)
      alternative = Fallback cachedWidget (record trace "select" >> pure (pure ()))
      policy' = policy Optional 3 (counted classified (recognizeBroken alternative))
  runner ←
    forkIO $
      tryWithContext (withScoped (allocComponent loadWidget policy' construction) (\_ → void (bump consumed)))
        >>= putMVar result
  -- The rollback has started, so the thread is uninterruptibly masked.
  takeMVar insideRelease
  killer ← forkIO (throwTo runner ThreadKilled *> putMVar killerDone ())
  putMVar killerSlot killer
  -- The cancellation was delivered, which cannot happen before rollback ends.
  takeMVar killerDone
  -- While the release was still running, the sender was still waiting on it.
  takeMVar killerStatus `shouldReturn` ThreadBlocked BlockedOnException
  outcome ← takeMVar result
  case outcome of
    Right () → expectationFailure "expected construction to be cancelled"
    Left (ExceptionWithContext context cancellation) → do
      fromException cancellation `shouldBe` Just ThreadKilled
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["first"]
      case handledFailures context of
        [handled] → fromException handled `shouldBe` Just (Broken 1)
        other → expectationFailure ("expected one handled failure, found " <> show other)
  readIORef trace `shouldReturn` ["acquire first", "acquire second", "first start", "first end", "second"]
  readIORef classified `shouldReturn` 0
  readIORef consumed `shouldReturn` 0

testCancelAtHandoff ∷ Expectation
testCancelAtHandoff = do
  trace ← newTrace
  classified ← newCounter
  observedStatus ← newIORef ThreadRunning
  killerDone ← newEmptyMVar
  result ← newEmptyMVar
  let construction = do
        acquirePart "first" (releaseRank 0) (record trace "acquire first") $ \() → do
          record trace "release first"
          ioError (userError "first release failed")
        acquirePart "last" (releaseRank 1)
          -- Leave a cancellation pending as construction completes. Masked
          -- uninterruptibly here, it cannot be delivered inside construction.
          ( uninterruptibleMask_ $ do
              self ← myThreadId
              killer ← forkIO (throwTo self ThreadKilled *> putMVar killerDone ())
              awaitPendingThrow killer >>= writeIORef observedStatus
              record trace "acquire last"
          )
          (\() → record trace "release last")
      consumer _ = record trace "consumer"
  _ ←
    forkIO $
      tryWithContext
        ( withScoped
            (allocComponent loadWidget (policy Optional 3 (counted classified (\_ → pure (Just Retry)))) construction)
            consumer
        )
        >>= putMVar result
  takeMVar killerDone
  outcome ← takeMVar result
  readIORef observedStatus `shouldReturn` ThreadBlocked BlockedOnException
  case outcome of
    Right () → expectationFailure "expected the handoff to be cancelled"
    Left (ExceptionWithContext context cancellation) → do
      fromException cancellation `shouldBe` Just ThreadKilled
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["first"]
  -- The consumer's first effect was preempted, every part was released, and
  -- no new attempt started after selection.
  readIORef trace `shouldReturn` ["acquire first", "acquire last", "release first", "release last"]
  readIORef classified `shouldReturn` 0

-- After selection ------------------------------------------------------------

testConsumerFailure ∷ Expectation
testConsumerFailure = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  let construction = do
        acquirePart "cache" (releaseRank 0) (record trace "acquire cache") $ \() → do
          record trace "release cache"
          ioError (userError "cache release failed")
        pure ()
  ExceptionWithContext context failure ←
    expectContext @Broken $
      withScoped
        (allocComponent loadWidget (policy Optional 3 (counted classified (recognizeBroken Retry))) construction)
        (\_ → bump consumed >> throwIO (Broken 99) ∷ IO ())
  failure `shouldBe` Broken 99
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["cache"]
  length (recoveryHistoryInContext context) `shouldBe` 0
  readIORef consumed `shouldReturn` 1
  readIORef classified `shouldReturn` 0
  readIORef trace `shouldReturn` ["acquire cache", "release cache"]

testLazyResultInConsumer ∷ Expectation
testLazyResultInConsumer = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  let construction = do
        acquirePart "cache" (releaseRank 0) (record trace "acquire cache") (\() → record trace "release cache")
        -- Construction succeeds; the value throws only when it is forced.
        pure (throw (Broken 7) ∷ Int)
  failure ←
    try $
      withScoped
        (allocComponent loadWidget (policy Required 3 (counted classified (recognizeBroken Retry))) construction)
        ( \outcome → do
            _ ← bump consumed
            recovered ← expectAvailable outcome
            evaluate (recoveredValue recovered + 1)
        )
  failure `shouldBe` Left (Broken 7)
  readIORef consumed `shouldReturn` 1
  readIORef classified `shouldReturn` 0
  readIORef trace `shouldReturn` ["acquire cache", "release cache"]

testFinalReleaseFailure ∷ Expectation
testFinalReleaseFailure = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  let construction = do
        acquirePart "cache" (releaseRank 0) (record trace "acquire cache") $ \() → do
          record trace "release cache"
          ioError (userError "cache release failed")
        acquirePart "buffer" (releaseRank 1) (record trace "acquire buffer") (\() → record trace "release buffer")
  ExceptionWithContext context failure ←
    expectContext @IOException $
      withScoped
        (allocComponent loadWidget (policy Required 3 (counted classified (\_ → pure (Just Retry)))) construction)
        (\_ → bump consumed >> pure (5 ∷ Int))
  show failure `shouldBe` "user error (cache release failed)"
  map cleanupFailureLabel (cleanupFailuresInContext context) `shouldBe` ["cache"]
  readIORef consumed `shouldReturn` 1
  readIORef classified `shouldReturn` 0
  readIORef trace `shouldReturn` ["acquire cache", "acquire buffer", "release cache", "release buffer"]

testUnavailableConsumerFailure ∷ Expectation
testUnavailableConsumerFailure = do
  trace ← newTrace
  classified ← newCounter
  consumed ← newCounter
  failure ←
    try $
      withScoped
        ( allocComponent loadWidget (policy Optional 1 (counted classified (recognizeBroken Retry))) $
            staged trace "initial" (failAttempt 1)
        )
        ( \outcome → do
            _ ← bump consumed
            case outcome of
              Unavailable _ → throwIO (Broken 42)
              Available _ → pure ()
        )
  failure `shouldBe` Left (Broken 42)
  readIORef consumed `shouldReturn` 1
  readIORef classified `shouldReturn` 1
  readIORef trace
    `shouldReturn` [ "initial: acquire first"
                   , "initial: acquire second"
                   , "initial: release first"
                   , "initial: release second"
                   ]
