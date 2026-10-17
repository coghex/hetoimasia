-- | Policy (requirement 4) and looped and one-shot work (requirement 6): the
-- FIFO default, a test policy chosen at creation that changes only the next
-- choice, a refused choice, and a policy that tries to starve a class.
module Test.LuaRuntime.Scheduler.Policy (spec) where

import Control.Concurrent.STM (atomically, writeTVar)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId (TaskId), TaskName (TaskName))
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support

spec ∷ Spec
spec = describe "scheduling policy" $ do
  describe "the FIFO default" $ do
    it "serves ready peers in the order they were admitted, and a yielded task goes behind them" $ do
      rig ← newRig
      mapM_ (\name → admit rig name OrdinaryClass OneShot >> script rig name [yielded name, yielded name]) ["a", "b", "c"]
      _ ← turnsUntilIdle rig 10
      ran rig >>= (`shouldBe` ["a", "b", "c", "a", "b", "c", "a", "b", "c"])

    it "is the policy a scheduler is made with" $ do
      policyName fifoPolicy `shouldBe` "fifo"

  describe "a policy chosen at creation" $ do
    it "changes only which ready task runs next: the same work, completed and counted the same, in another order" $ do
      let work rig = do
            mapM_ (\name → admit rig name OrdinaryClass OneShot >> script rig name [yielded name, yielded name]) ["a", "b", "c"]
            _ ← turnsUntilIdle rig 10
            (,) <$> ran rig <*> diagnostics rig
      (fifoOrder, fifoCounts) ← newRig >>= work
      (newestOrder, newestCounts) ← newRigWith defaultOptions {optPolicy = newestFirst} >>= work
      fifoOrder `shouldBe` ["a", "b", "c", "a", "b", "c", "a", "b", "c"]
      newestOrder `shouldBe` ["c", "c", "c", "b", "b", "b", "a", "a", "a"]
      let counted d = (diagAdmitted d, diagCompleted d, diagYielded d, diagSegmentsByClass d)
      counted newestCounts `shouldBe` counted fifoCounts
      diagRefusedChoices newestCounts `shouldBe` 0

    it "leaves admission and capacity with the runtime: the caps hold under the test policy" $ do
      rig ← newRigWith defaultOptions {optPolicy = newestFirst, optBounds = defaultBounds {boundRetainedResults = 2}}
      _ ← admit rig "a" OrdinaryClass OneShot
      _ ← admit rig "b" OrdinaryClass OneShot
      atomically (admitTask (rigScheduler rig) (taskSpec "c" OrdinaryClass OneShot)) >>= (`shouldBe` AdmitRefused (AdmitFull RetainedResults 2))

  describe "a choice that is not a ready task of the class being served" $ do
    it "is refused, counted and never run: the oldest ready task of the class runs instead" $ do
      let unknown = TaskId scope (TaskName 999)
      rig ← newRigWith defaultOptions {optPolicy = Policy "unknown" (const unknown)}
      mapM_ (\name → admit rig name OrdinaryClass OneShot >> script rig name [yielded name, yielded name]) ["a", "b", "c"]
      _ ← turnsUntilIdle rig 10
      ran rig >>= (`shouldBe` ["a", "b", "c", "a", "b", "c", "a", "b", "c"])
      diagRefusedChoices <$> diagnostics rig >>= (`shouldBe` 9)

    it "refuses a waiting task, and never runs it while it waits" $ do
      rig ← newRigWith defaultOptions {optPolicy = Policy "the first" (const (taskIdAt 0))}
      first ← admit rig "waiter" OrdinaryClass OneShot
      _ ← admit rig "worker" OrdinaryClass Looped
      script rig "waiter" [waitTicks "waiter" 5]
      loop rig "worker"
      _ ← turn rig
      -- The first choice is the one task that is ready; every choice after it names
      -- the task that is waiting.
      ran rig >>= (`shouldBe` ["waiter", "worker", "worker", "worker"])
      phase rig first >>= (`shouldBe` Just PhaseWaiting)
      diagRefusedChoices <$> diagnostics rig >>= (`shouldBe` 3)

  describe "a policy that tries to starve a class" $ do
    let starving rig = do
          mapM_ (\(name, serviceClass) → admit rig name serviceClass Looped >> loop rig name) [("control", ControlClass), ("ordinary", OrdinaryClass), ("background", BackgroundClass)]
        quanta = Quanta (Quantum 2) (Quantum 2) (Quantum 1)
        starvingOptions = defaultOptions {optPolicy = alwaysControl, optBounds = defaultBounds {boundQuanta = quanta}}

    it "serves every live class its quantum each pass, and counts the refusals" $ do
      rig ← newRigWith starvingOptions
      starving rig
      runSegments rig 10
        >>= (`shouldBe` ["control", "control", "ordinary", "ordinary", "background", "control", "control", "ordinary", "ordinary", "background"])
      counts ← diagnostics rig
      diagSegmentsByClass counts `shouldBe` [(ControlClass, 4), (OrdinaryClass, 4), (BackgroundClass, 2)]
      -- Every opportunity of the ordinary and background classes was one the
      -- policy tried to spend on the control class.
      diagRefusedChoices counts `shouldBe` 6

    it "serves control requests and stop between segments, before it is asked again" $ do
      rig ← newRigWith starvingOptions
      _ ← admit rig "control" ControlClass Looped
      ordinary ← admit rig "ordinary" OrdinaryClass Looped
      loop rig "ordinary"
      ticket ← newIORefTicket
      script
        rig
        "control"
        [ do
            answer ← atomically (requestControl (rigScheduler rig) ordinary RequestPause)
            case answer of
              ControlAccepted accepted → writeTicket ticket accepted
              other → expectRefused other
            yielded "control"
        , yielded "control"
        , atomically (writeTVar (rigStop rig) True) >> yielded "control"
        ]
      first ← turn rig
      -- The pause was applied at the boundary after the segment that asked for it,
      -- so the ordinary task, which the policy never stopped serving, never ran.
      ran rig >>= (`shouldBe` ["control", "control"])
      turnEnd first `shouldBe` TurnPassComplete
      phase rig ordinary >>= (`shouldBe` Just PhasePaused)
      second ← turn rig
      -- Stop was requested inside the third segment, and nothing started after it.
      ran rig >>= (`shouldBe` ["control", "control", "control"])
      turnEnd second `shouldBe` TurnStopRequested
      readTicket ticket >>= \accepted → atomically (pollControl accepted) >>= (`shouldSatisfy` \case Just (ControlSettlement ControlApplied Nothing) → True; _ → False)

  describe "looped and one-shot work" $ do
    it "appends a newly admitted one-shot at the tail of its class under the default policy" $ do
      rig ← newRig
      _ ← admit rig "loop-1" OrdinaryClass Looped
      _ ← admit rig "loop-2" OrdinaryClass Looped
      _ ← admit rig "once" OrdinaryClass OneShot
      loop rig "loop-1"
      loop rig "loop-2"
      script rig "once" [yielded "once", yielded "once"]
      runSegments rig 6 >>= (`shouldBe` ["loop-1", "loop-2", "once", "loop-1", "loop-2", "once"])

    it "places it where the selected policy says, and nowhere is that fixed outside the policy" $ do
      rig ← newRigWith defaultOptions {optPolicy = oneShotsFirst}
      _ ← admit rig "loop-1" OrdinaryClass Looped
      _ ← admit rig "loop-2" OrdinaryClass Looped
      _ ← admit rig "once" OrdinaryClass OneShot
      loop rig "loop-1"
      loop rig "loop-2"
      script rig "once" [yielded "once", yielded "once"]
      runSegments rig 6 >>= (`shouldBe` ["once", "once", "once", "loop-1", "loop-2", "loop-1"])

  describe "task identity" $ do
    it "is the engine's: tasks with the same name have different identities, and a name is no authority" $ do
      rig ← newRig
      first ← admit rig "same" OrdinaryClass Looped
      second ← admit rig "same" OrdinaryClass Looped
      first `shouldSatisfy` (/= second)
      -- No operation takes a name. The nearest thing is an identity that carries the
      -- name's number in another scope, which is another owner's and is refused.
      let elsewhere = TaskId (scope {keyEpoch = firstEpoch, keySession = SessionId 2}) (TaskName 0)
      atomically (requestControl (rigScheduler rig) elsewhere RequestStop) >>= \case
        ControlUnknownTarget → pure ()
        other → expectRefused (describeAnswer other)
      phase rig first >>= (`shouldBe` Just PhaseReady)

    it "carries the optional name and the entry point to the host, bounded" $ do
      rig ← newRig
      let long = Text.replicate 300 "n"
      _ ← admitSpec rig (taskSpec "named" OrdinaryClass OneShot) {specName = Just long, specEntry = long}
      _ ← admitSpec rig (taskSpec "anonymous" OrdinaryClass OneShot) {specName = Nothing}
      seen ← newIORefList
      let host =
            (rigHost rig)
              { hostRun = \run → do
                  recordSeen seen (runName run, runEntry run)
                  pure (ReportCompleted (runCursor run))
              }
      _ ← serviceTurn (rigScheduler rig) host
      readSeen seen >>= \case
        [(Just name, entry), (Nothing, entry')] → do
          Text.length name `shouldBe` 128
          Text.length entry `shouldBe` 128
          entry' `shouldBe` "anonymous"
        other → fail ("unexpected hosts calls: " <> show other)

-- The policies the examples try ---------------------------------------------------

-- | Newest first among the servable: the opposite of the default.
newestFirst ∷ Policy
newestFirst = Policy "newest" $ \view → case reverse (servable view) of
  candidate : _ → candidateTask candidate
  [] → candidateTask (NonEmpty.head (viewReady view))

-- | One-shots before looped work, oldest first among each.
oneShotsFirst ∷ Policy
oneShotsFirst = Policy "one-shots first" $ \view →
  case [candidate | candidate ← servable view, candidateKind candidate == OneShot] <> servable view of
    candidate : _ → candidateTask candidate
    [] → candidateTask (NonEmpty.head (viewReady view))

-- | A policy that tries to spend every opportunity on the control class.
alwaysControl ∷ Policy
alwaysControl = Policy "always control" $ \view →
  case [candidate | candidate ← NonEmpty.toList (viewReady view), candidateClass candidate == ControlClass] of
    candidate : _ → candidateTask candidate
    [] → candidateTask (NonEmpty.head (viewReady view))

describeAnswer ∷ ControlAnswer → Text
describeAnswer = \case
  ControlAccepted _ → "accepted"
  ControlFull → "full"
  ControlClosed → "closed"
  ControlUnknownTarget → "unknown target"

-- Small mutable cells -------------------------------------------------------------

newIORefTicket ∷ IO (IORef (Maybe ControlTicket))
newIORefTicket = newIORef Nothing

writeTicket ∷ IORef (Maybe ControlTicket) → ControlTicket → IO ()
writeTicket cell = writeIORef cell . Just

readTicket ∷ IORef (Maybe ControlTicket) → IO ControlTicket
readTicket cell = readIORef cell >>= maybe (fail "the request was not accepted") pure

newIORefList ∷ IO (IORef [(Maybe Text, Text)])
newIORefList = newIORef []

recordSeen ∷ IORef [(Maybe Text, Text)] → (Maybe Text, Text) → IO ()
recordSeen cell seen = modifyIORef' cell (<> [seen])

readSeen ∷ IORef [(Maybe Text, Text)] → IO [(Maybe Text, Text)]
readSeen = readIORef
