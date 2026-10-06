{-# LANGUAGE OverloadedRecordDot #-}

-- | The instance scopes of VK-6's capture session and of the
-- synchronization-validation hazard, exercised headlessly.
--
-- Each example drives the fixture's own 'instanceScope', the one its native
-- session runs, over injected operations in place of the native layer, so an
-- identifiable body failure and an identifiable destruction failure can be
-- produced together. The examples that need a diagnostic lifetime run the
-- production 'withDiagnosticCapture' under the fixture's own configuration,
-- with the destruction behind 'afterLastCallback' as the native package's
-- quiescing destroy puts it, so a raising destruction fails before any
-- quiescence is recorded. They open no window, make no native call, and need
-- no @HETOIMASIA_NATIVE_SESSION@:
--
-- > bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --match "instance scope"
--
-- No Vulkan destruction is made to fail: what these assert is how the scope
-- preserves exceptions, which is the same whatever raised them.
module Test.GPU.Vulkan.Native.InstanceScopeSpec (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (Exception, ExceptionWithContext (..), SomeException, annotateIO, displayException, fromException, someExceptionContext, throwIO, try)
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogFilter (..)
  , LogLevel (Info)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Resource
  ( cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailures
  , withResourceLabelled
  )
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig
  , CapturePhase (..)
  , DiagnosticVerdict (..)
  , afterLastCallback
  , capturePhase
  , diagnosticVerdict
  , withDiagnosticCapture
  )
import qualified Test.GPU.Vulkan.Native.Hazard as Hazard
import Test.GPU.Vulkan.Native.InstanceScope (InstanceOps (..))
import qualified Test.Vulkan.Proof.Diagnostics as Diagnostics

-- | One fixture's instance scope, and how its session reports a stop.
data Fixture = Fixture
  { fixtureName ∷ String
  , fixtureScope ∷ ∀ inst msgr q r. InstanceOps inst msgr q → (inst → IO r) → IO (r, q)
  , fixtureInstanceLabel ∷ Text
  , fixtureMessengerLabel ∷ Text
  , fixtureConfig ∷ CaptureConfig
  , fixtureStopped ∷ SomeException → Maybe (Text, Maybe DiagnosticVerdict)
    -- ^ The stopped session's reason and verdict.
  }

fixtures ∷ [Fixture]
fixtures =
  [ Fixture
      { fixtureName = "VK-6's capture session"
      , fixtureScope = Diagnostics.instanceScope
      , fixtureInstanceLabel = Diagnostics.instanceLabel
      , fixtureMessengerLabel = Diagnostics.messengerLabel
      , fixtureConfig = Diagnostics.sessionConfig
      , fixtureStopped = \failure → case Diagnostics.stoppedSession failure [] of
          Diagnostics.DiagnosticsStopped reason verdict _ → Just (reason, verdict)
          Diagnostics.DiagnosticsProved _ → Nothing
      }
  , Fixture
      { fixtureName = "the synchronization hazard"
      , fixtureScope = Hazard.instanceScope
      , fixtureInstanceLabel = Hazard.instanceLabel
      , fixtureMessengerLabel = Hazard.messengerLabel
      , fixtureConfig = Hazard.hazardCaptureConfig
      , fixtureStopped = \failure → case Hazard.stoppedSession failure [] of
          Hazard.HazardStopped reason verdict _ → Just (reason, verdict)
          Hazard.HazardRecorded _ → Nothing
      }
  ]

-- | The body's own failure, and the context it carries.
newtype BodyFailure = BodyFailure Text
  deriving (Eq, Show)

instance Exception BodyFailure

newtype Marker = Marker Text
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

-- | What the injected @vkDestroyInstance@ raises.
newtype DestroyFailure = DestroyFailure Text
  deriving (Eq, Show)

instance Exception DestroyFailure

bodyFailure ∷ BodyFailure
bodyFailure = BodyFailure "the body's own failure, injected"

bodyMarker ∷ Marker
bodyMarker = Marker "annotated inside the body"

destroyFailure ∷ DestroyFailure
destroyFailure = DestroyFailure "vkDestroyInstance raised, injected"

data Event
  = InstanceCreated
  | MessengerCreated
  | ChildCreated
  | ChildDestroyed
  | MessengerDestroyed
  | InstanceDestroyed
  deriving (Eq, Show)

-- | Every native step a scope that created its instance takes, in order: the
-- body's child, then the explicit messenger, then the instance.
everyStep ∷ [Event]
everyStep = [InstanceCreated, MessengerCreated, ChildCreated, ChildDestroyed, MessengerDestroyed, InstanceDestroyed]

data Body = Succeeds | Fails

-- | The injected operations. The instance's destruction runs the given
-- quiescing wrapper around a destroy that records itself and raises
-- 'destroyFailure' when asked, so the wrapper's evidence follows only a
-- destroy that returned.
injected ∷ IORef [Event] → Bool → (IO () → IO q) → InstanceOps Text Text q
injected events raising quiesce =
  InstanceOps
    { instanceCreate = record events InstanceCreated >> pure "instance"
    , instanceDestroy = \_ → quiesce $ do
        record events InstanceDestroyed
        when raising (throwIO destroyFailure)
    , messengerCreate = \_ → record events MessengerCreated >> pure "messenger"
    , messengerDestroy = \_ _ → record events MessengerDestroyed
    }

-- | A body with one child of its own, which fails inside that child when
-- asked to, annotating its failure there.
body ∷ IORef [Event] → Body → Text → IO Text
body events outcome _ =
  withResourceLabelled "an injected child" (record events ChildCreated) (\_ → record events ChildDestroyed) $ \_ →
    case outcome of
      Succeeds → pure "the body's result"
      Fails → annotateIO bodyMarker (throwIO bodyFailure)

record ∷ IORef [Event] → Event → IO ()
record events event = modifyIORef' events (<> [event])

spec ∷ Spec
spec = describe "A native fixture's instance scope" $
  mapM_ fixtureSpec fixtures

-- The scope is read with its selector rather than a record dot, because a
-- field with a type of its own quantifiers has no 'HasField' instance.
fixtureSpec ∷ Fixture → Spec
fixtureSpec fixture = describe fixture.fixtureName $ do
  describe "over injected operations" $ do
    it "returns the body's result and the destruction's evidence when everything succeeds" $ do
      (events, outcome) ← scoped Succeeds False
      either (const Nothing) Just outcome `shouldBe` Just ("the body's result", "quiesced")
      events `shouldBe` everyStep

    it "rethrows the body's failure, with its context and nothing retained, when the body fails and the destruction returns" $ do
      (events, outcome) ← scoped Fails False
      failure ← failed outcome
      fromException failure `shouldBe` Just bodyFailure
      annotations failure `shouldBe` [bodyMarker]
      retained failure `shouldBe` []
      events `shouldBe` everyStep

    it "rethrows the body's failure, with its context, and keeps the destruction's failure beside it, when both fail" $ do
      (events, outcome) ← scoped Fails True
      failure ← failed outcome
      fromException failure `shouldBe` Just bodyFailure
      annotations failure `shouldBe` [bodyMarker]
      retained failure `shouldBe` [(fixture.fixtureInstanceLabel, Just destroyFailure)]
      events `shouldBe` everyStep

    it "fails with the destruction's failure, retained under its label, and returns neither result nor evidence, when only the destruction fails" $ do
      (events, outcome) ← scoped Succeeds True
      failure ← failed outcome
      fromException failure `shouldBe` Just destroyFailure
      retained failure `shouldBe` [(fixture.fixtureInstanceLabel, Just destroyFailure)]
      events `shouldBe` everyStep

    it "keeps a messenger destruction's failure under the messenger's label, and still destroys the instance once" $ do
      events ← newIORef []
      let ops = (injected events False (\destroy → destroy >> pure ())) {messengerDestroy = \_ _ → record events MessengerDestroyed >> throwIO destroyFailure}
      outcome ← try @SomeException (fixtureScope fixture ops (body events Fails))
      failure ← failed outcome
      fromException failure `shouldBe` Just bodyFailure
      retained failure `shouldBe` [(fixture.fixtureMessengerLabel, Just destroyFailure)]
      readIORef events `shouldReturn` everyStep

    it "runs neither the body nor a destruction when the instance is never created" $ do
      events ← newIORef []
      let ops = (injected events False (\destroy → destroy >> pure ())) {instanceCreate = throwIO (userError "vkCreateInstance raised, injected")}
      outcome ← try @SomeException (fixtureScope fixture ops (body events Succeeds))
      either (Just . displayException) (const Nothing) outcome `shouldBe` Just "user error (vkCreateInstance raised, injected)"
      readIORef events `shouldReturn` []

  describe "inside the production diagnostic lifetime" $ do
    it "is quiescent, and returns the body's result, when everything succeeds" $ do
      (events, phases, outcome) ← captured Succeeds False
      case outcome of
        Left failure → expectationFailure ("the lifetime raised " <> displayException failure)
        Right (result, verdict) → do
          result `shouldBe` "the body's result"
          verdict.verdictQuiescent `shouldBe` True
      events `shouldBe` everyStep
      phases `shouldBe` [PhaseCapturing]

    it "stops for the body's failure, with its verdict attached, quiescent when the destruction returned while it unwound" $ do
      (events, phases, outcome) ← captured Fails False
      failure ← failed outcome
      fromException failure `shouldBe` Just bodyFailure
      annotations failure `shouldBe` [bodyMarker]
      retained failure `shouldBe` []
      fmap (.verdictQuiescent) (diagnosticVerdict failure) `shouldBe` Just True
      stoppedFor failure `shouldBe` Just (Text.pack (displayException bodyFailure), show (diagnosticVerdict failure))
      events `shouldBe` everyStep
      phases `shouldBe` [PhaseCapturing]

    it "stops for the body's failure, not the destruction's, and is not quiescent, when both fail" $ do
      (events, phases, outcome) ← captured Fails True
      failure ← failed outcome
      fromException failure `shouldBe` Just bodyFailure
      annotations failure `shouldBe` [bodyMarker]
      retained failure `shouldBe` [(fixture.fixtureInstanceLabel, Just destroyFailure)]
      fmap (.verdictQuiescent) (diagnosticVerdict failure) `shouldBe` Just False
      stoppedFor failure `shouldBe` Just (Text.pack (displayException bodyFailure), show (diagnosticVerdict failure))
      fmap fst (stoppedFor failure) `shouldNotBe` Just (Text.pack (displayException destroyFailure))
      events `shouldBe` everyStep
      phases `shouldBe` [PhaseCapturing]

    it "stops for the destruction's failure, and is not quiescent, when only the destruction fails" $ do
      (events, phases, outcome) ← captured Succeeds True
      failure ← failed outcome
      fromException failure `shouldBe` Just destroyFailure
      retained failure `shouldBe` [(fixture.fixtureInstanceLabel, Just destroyFailure)]
      fmap (.verdictQuiescent) (diagnosticVerdict failure) `shouldBe` Just False
      stoppedFor failure `shouldBe` Just (Text.pack (displayException destroyFailure), show (diagnosticVerdict failure))
      events `shouldBe` everyStep
      phases `shouldBe` [PhaseCapturing]
  where
    -- The stopped session's reason, and its verdict as the record shows it.
    stoppedFor failure = fmap show <$> fixture.fixtureStopped failure

    -- The scope alone, with a token for evidence.
    scoped ∷ Body → Bool → IO ([Event], Either SomeException (Text, Text))
    scoped outcome raising = do
      events ← newIORef []
      result ← try (fixtureScope fixture (injected events raising (\destroy → destroy >> pure "quiesced")) (body events outcome))
      (,result) <$> readIORef events

    -- The scope as the session's body, in the fixture's own lifetime, with the
    -- destruction behind 'afterLastCallback'. Each destruction also records
    -- the lifetime's phase it ran in.
    captured ∷ Body → Bool → IO ([Event], [CapturePhase], Either SomeException (Text, DiagnosticVerdict))
    captured outcome raising = do
      events ← newIORef []
      phases ← newIORef []
      let logger = mkLogger quiet (callbackSink (\_ → pure ()))
          session capture =
            fixtureScope fixture
              ( injected events raising $ \destroy → do
                  atomically (capturePhase capture) >>= \phase → modifyIORef' phases (<> [phase])
                  afterLastCallback capture destroy
              )
              (body events outcome)
      result ← try (withDiagnosticCapture fixture.fixtureConfig logger session)
      (,,result) <$> readIORef events <*> readIORef phases

    quiet =
      LogFilter
        { filterEnabled = True
        , filterGlobalLevel = Info
        , filterComponentLevels = Map.empty
        , filterDebug = DebugAll
        , filterSource = False
        }

annotations ∷ SomeException → [Marker]
annotations = getExceptionAnnotations . someExceptionContext

-- | Each retained cleanup failure's label and, when it is one, the injected
-- destruction failure it carries.
retained ∷ SomeException → [(Text, Maybe DestroyFailure)]
retained failure =
  [ (cleanupFailureLabel entry, fromException exception)
  | entry ← cleanupFailures failure
  , let ExceptionWithContext _ exception = cleanupFailureException entry
  ]

-- | The failure an example expects, or a failed example naming what the scope
-- returned instead.
failed ∷ Show a ⇒ Either SomeException a → IO SomeException
failed = either pure (\result → throwIO (userError ("expected a failure, but the scope returned " <> show result)))
