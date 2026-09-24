{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-6's verdict: pure assertions over what "Test.Vulkan.Proof.Diagnostics"
-- observed, computed after the capture lifetime — and so after its
-- @vkDestroyInstance@ — has ended.
--
-- A session that stopped fails every example with the reason it stopped.
module Test.Vulkan.Proof.DiagnosticsSpec (spec) where

import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import Hetoimasia.Foundation.Log (LogEntry (..))
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  , VerdictIssue (..)
  , verdictIssues
  )
import Hetoimasia.GPU.Vulkan.Native.Diagnostics (NativeFfiConfiguration (..))
import Test.Vulkan.Proof.Diagnostics
import Test.Vulkan.Proof.Interop (Provenance (..))

spec ∷ DiagnosticsOutcome → Spec
spec outcome = describe "VK-6 validation capture" $ do
  it "established every step of its session" $
    onFacts outcome (\_ → pure ())

  it "installed a C callback from the executable's own image, and no Haskell callback" $
    onFacts outcome $ \facts → do
      -- A Haskell callback is an adjustor thunk in memory the runtime
      -- allocated, which no loaded image contains; the production callback is
      -- code linked into this executable.
      fmap Text.unpack facts.factsCallback.provenanceImage `shouldBe` Just (Text.unpack facts.factsExecutable)
      facts.factsFfi.ffiHaskellCallbacks `shouldBe` []

  it "heard instance creation through the create-info chain" $
    onFacts outcome $ \facts →
      reportsIn facts creationPhase `shouldSatisfy` (> 0)

  it "delivered a message from inside a genuine unsafe import" $
    onFacts outcome $ \facts → do
      reportsIn facts submitPhase `shouldBe` 1
      idsIn facts submitPhase `shouldBe` [submittedMessageId]

  it "latched the validation error an unsafe recording call provoked, from inside that call" $
    onFacts outcome $ \facts → do
      errorsIn facts recordingPhase `shouldSatisfy` (> 0)
      idsIn facts recordingPhase `shouldSatisfy` elem provokedValidationId
      facts.factsVerdict.verdictStatus.statusErrorLatched `shouldBe` True

  it "heard vkDestroyInstance after the explicit messenger was destroyed, and delivered it" $
    onFacts outcome $ \facts → do
      reportsIn facts destructionPhase `shouldSatisfy` (> 0)
      length (entriesIn facts destructionPhase) `shouldBe` fromIntegral (reportsIn facts destructionPhase)

  it "counted every delivery in its final verdict" $
    onFacts outcome $ \facts → do
      let verdict = facts.factsVerdict
          counters = verdict.verdictStatus.statusCounters
          reported = sum (map (.phaseReports) facts.factsPhases)
      counters.countOffered `shouldBe` reported
      counters.countAdmitted `shouldBe` reported
      verdict.verdictDelivered `shouldBe` reported
      verdict.verdictUndelivered `shouldBe` 0
      fromIntegral facts.factsLoggedEntries `shouldBe` reported
      consumed verdict.verdictConsumer `shouldBe` True

  it "found no error but the one it provoked" $
    onFacts outcome $ \facts → do
      verdictIssues facts.factsVerdict `shouldBe` [ErrorLatched]
      let errorIds =
            [ Map.findWithDefault "" "message.id" entry.entryFields
            | reports ← facts.factsPhases
            , entry ← reports.phaseEntries
            , Map.lookup "severity" entry.entryFields == Just "error"
            ]
      errorIds `shouldSatisfy` (not . null)
      for_ errorIds (`shouldBe` provokedValidationId)

  it "records the FFI configuration the toolchain pin qualified" $
    onFacts outcome $ \facts → do
      Just (onOff facts.factsFfi.ffiBindingSafeForeignCalls) `shouldBe` facts.factsPinnedSafeForeignCalls
      Just (onOff facts.factsFfi.ffiBindingDarwinLibDirs) `shouldBe` facts.factsPinnedDarwinLibDirs
      facts.factsUnsafeImports `shouldBe` unsafeImportNames
  where
    onOff enabled = if enabled then "on" else "off"
    consumed = \case
      ConsumerCompleted → True
      _ → False

onFacts ∷ DiagnosticsOutcome → (DiagnosticsFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  DiagnosticsStopped reason _ _ →
    expectationFailure ("the VK-6 capture session stopped: " <> Text.unpack reason)
  DiagnosticsProved facts → assertion facts

phase ∷ DiagnosticsFacts → Text → [PhaseReports]
phase facts name = filter ((== name) . (.phaseName)) facts.factsPhases

reportsIn ∷ DiagnosticsFacts → Text → Integer
reportsIn facts name = sum (map (toInteger . (.phaseReports)) (phase facts name))

errorsIn ∷ DiagnosticsFacts → Text → Integer
errorsIn facts name = sum (map (toInteger . (.phaseErrors)) (phase facts name))

entriesIn ∷ DiagnosticsFacts → Text → [LogEntry]
entriesIn facts name = concatMap (.phaseEntries) (phase facts name)

idsIn ∷ DiagnosticsFacts → Text → [Text]
idsIn facts name = mapMaybe (Map.lookup "message.id" . (.entryFields)) (entriesIn facts name)
