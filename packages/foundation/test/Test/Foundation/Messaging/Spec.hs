-- | Examples for 'Hetoimasia.Foundation.Messaging.Payload'.
--
-- Evaluation is observed through side effects inside each payload's own
-- 'NFData' instance — a counter, a gate — never through timing. Cancellation is
-- coordinated with 'MVar's, never with a sleep; 'boundedExample' only stops an
-- example that has already hung.
--
-- The channel examples live in "Test.Foundation.Messaging.Channel", the snapshot
-- examples in "Test.Foundation.Messaging.Snapshot", the bounded-turn example in
-- "Test.Foundation.Messaging.Turns", and the external-client examples
-- in "Test.Foundation.Messaging.Opacity". All are composed into this group, so @--match Messaging@ selects all of them.
module Test.Foundation.Messaging.Spec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , evaluate
  , fromException
  , throw
  , throwIO
  , tryWithContext
  )
import Control.Monad (void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , Operation
  , OperationContext (..)
  , failureEvidenceInContext
  , operation
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import System.IO.Error (ioeGetErrorString)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import qualified Test.Foundation.Messaging.Channel as Channel
import qualified Test.Foundation.Messaging.Opacity as Opacity
import qualified Test.Foundation.Messaging.Snapshot as Snapshot
import qualified Test.Foundation.Messaging.Turns as Turns
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
spec = describe "Messaging" $ do
  describe "Payload preparation" $ do
    it "raises a throwing thunk nested in a lazy field during preparation with its own type"
      testNestedFailure
    it "reads a prepared payload back unchanged and never evaluates it again"
      testNoReevaluation

  describe "Payload preparation failures" $ do
    it "keeps a typed engine failure's type, origin, and operation context"
      testEngineFailureContext
    it "keeps a native IOException's type and operation context"
      testNativeFailureContext
    it "ends a preparation cancelled from another thread by cancellation"
      (boundedExample testCancelledPreparation)

  Channel.spec
  Snapshot.spec
  Turns.spec
  Opacity.spec

-- Fixtures -------------------------------------------------------------------

-- | A strict record over a lazy list. The strictness annotations force the
-- list's first cons cell and nothing inside it, so weak head normal form never
-- reaches an element.
data Envelope = Envelope !Text ![Int]
  deriving (Eq, Show)

instance NFData Envelope where
  rnf (Envelope label values) = rnf label `seq` rnf values

-- | A payload whose 'NFData' instance counts how many times it runs.
data Counted = Counted (IORef Int) [Text]

instance NFData Counted where
  rnf (Counted evaluations names) = countEvaluation evaluations `seq` rnf names

countEvaluation ∷ IORef Int → ()
countEvaluation evaluations = unsafePerformIO (modifyIORef' evaluations (+ 1))
{-# NOINLINE countEvaluation #-}

-- | A payload whose evaluation reports that it started and then blocks until
-- released, so a cancellation can be delivered while preparation is known to
-- be running.
data Gated = Gated (MVar ()) (MVar ())

instance NFData Gated where
  rnf (Gated entered release) = holdEvaluation entered release

holdEvaluation ∷ MVar () → MVar () → ()
holdEvaluation entered release = unsafePerformIO (putMVar entered () >> takeMVar release)
{-# NOINLINE holdEvaluation #-}

-- | A producer's own nested failure.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | A component's own typed failure.
newtype EventRejected = EventRejected Int
  deriving (Eq, Show)

instance Exception EventRejected

-- | An element that raises a typed engine failure, with its origin, when it is
-- forced.
rejectedEvent ∷ Int → Int
rejectedEvent event =
  unsafePerformIO (throwFailure decoder decodeEvent [("event", "7")] (EventRejected event))
{-# NOINLINE rejectedEvent #-}

-- | An element that raises a native 'IOException' when it is forced.
unreadableEvent ∷ Int → Int
unreadableEvent event =
  unsafePerformIO (throwIO (userError ("event " <> show event <> " unreadable")))
{-# NOINLINE unreadableEvent #-}

messages, decoder ∷ Component
messages = unsafeComponent "test.messages"
decoder = unsafeComponent "test.decoder"

publishFrame, decodeEvent ∷ Operation
publishFrame = operation "publish-frame"
decodeEvent = operation "decode-event"

-- | Hand a handle to another holder through an 'MVar', as a transport would,
-- without any 'NFData' instance in scope for its payload.
relay ∷ Prepared a → IO (Prepared a)
relay prepared = do
  slot ← newEmptyMVar
  putMVar slot prepared
  takeMVar slot

expectContext ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
expectContext action = do
  outcome ← tryWithContext action
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected preparation to fail, but it returned a handle"

-- | The operation contexts a failure carries, without their boundary sites.
contextsOf ∷ FailureEvidence → [(Component, Operation, [(Text, Text)])]
contextsOf evidence =
  [ (contextComponent context, contextOperation context, contextIdentifiers context)
  | context ← failureContexts evidence
  ]

-- | Stop an example that has hung rather than letting the suite wait forever.
boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- Preparation ----------------------------------------------------------------

testNestedFailure ∷ Expectation
testNestedFailure = do
  let envelope = Envelope "frame" [1, throw Boom, 3]
  -- Weak head normal form, strict fields included, does not reach the element.
  void (evaluate envelope)
  ExceptionWithContext _ failure ← expectContext @Boom (prepare envelope)
  failure `shouldBe` Boom

testNoReevaluation ∷ Expectation
testNoReevaluation = do
  evaluations ← newIORef 0
  prepared ← prepare (Counted evaluations ["left", "right"])
  readIORef evaluations `shouldReturn` 1
  let Counted readRef readNames = preparedValue prepared
  (readRef == evaluations) `shouldBe` True
  readNames `shouldBe` ["left", "right"]
  forwarded ← relay prepared
  let Counted _ forwardedNames = preparedValue forwarded
  forwardedNames `shouldBe` ["left", "right"]
  let Counted _ rereadNames = preparedValue prepared
  rereadNames `shouldBe` ["left", "right"]
  readIORef evaluations `shouldReturn` 1
  -- The control: preparing the value again does run the instance again, so the
  -- counter would have seen any evaluation the reads above performed.
  void (prepare (preparedValue forwarded))
  readIORef evaluations `shouldReturn` 2

-- Failures -------------------------------------------------------------------

testEngineFailureContext ∷ Expectation
testEngineFailureContext = do
  ExceptionWithContext context failure ←
    expectContext @EventRejected $
      withOperationContext messages publishFrame [("frame", "12")] $
        prepare (Envelope "frame" [1, rejectedEvent 7])
  failure `shouldBe` EventRejected 7
  let evidence = failureEvidenceInContext context
  case failureCause evidence of
    EngineOrigin origin → do
      originComponent origin `shouldBe` decoder
      originOperation origin `shouldBe` decodeEvent
      originIdentifiers origin `shouldBe` [("event", "7")]
    NativeCause → expectationFailure ("expected an engine origin, but found " <> show evidence)
  contextsOf evidence `shouldBe` [(messages, publishFrame, [("frame", "12")])]

testNativeFailureContext ∷ Expectation
testNativeFailureContext = do
  ExceptionWithContext context failure ←
    expectContext @IOException $
      withOperationContext messages publishFrame [("frame", "13")] $
        prepare (Envelope "frame" [1, unreadableEvent 8])
  ioeGetErrorString failure `shouldBe` "event 8 unreadable"
  let evidence = failureEvidenceInContext context
  failureCause evidence `shouldBe` NativeCause
  contextsOf evidence `shouldBe` [(messages, publishFrame, [("frame", "13")])]

testCancelledPreparation ∷ Expectation
testCancelledPreparation = do
  entered ← newEmptyMVar
  release ← newEmptyMVar
  result ← newEmptyMVar
  producer ← forkIO $ do
    outcome ←
      tryWithContext @SomeException $
        withOperationContext messages publishFrame [] $
          void (prepare (Gated entered release))
    putMVar result outcome
  takeMVar entered
  killThread producer
  outcome ← takeMVar result
  -- Keeps the gate reachable until the cancellation was observed.
  void (tryPutMVar release ())
  case outcome of
    Left (ExceptionWithContext context cancellation) → do
      fromException cancellation `shouldBe` Just ThreadKilled
      failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []
    Right () → expectationFailure "expected the preparation to be cancelled"
