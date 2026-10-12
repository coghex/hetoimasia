-- | A scene for each window (R2D-14): the handoff's per-window snapshots, their
-- independent revisions and latest-value replacement, the refusal of a window
-- the host does not hold, and the shared scene unchanged beside them.
module Test.GLFW.Owner.Scenes (spec) where

import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW
import Numeric.Natural (Natural)
import Test.GLFW.Owner.Fixture.Drive (awaitIdle, awaitRound, handedOver, pumpUntil)
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Scene (..))
import Test.GLFW.Owner.Fixture.Rig (Rig (..), countingClock, newRigWith, ownedHost, ownerSettings)
import Test.GLFW.Support (boundedExample, unexpected, windowNamed)
import Test.Hspec (Spec, it, shouldBe)

spec ∷ Spec
spec = do
  it "keeps a latest-value snapshot for each window, with revisions that rise independently, and hands each target its own window's scene"
    (boundedExample testPerWindowSnapshots)
  it "answers a window the host does not hold, or that has ended, with a result naming it, and changes nothing"
    (boundedExample testUnknownWindow)
  it "forgets the publication of a window the host has retired"
    (boundedExample testRetiredWindowForgotten)
  it "wakes an idle owner for a window's publication"
    (boundedExample testWindowPublicationWakes)
  it "keeps the shared scene as it was: published and stepped as one, with no window's scene, and per-window publication refused"
    (boundedExample testSharedModeUnchanged)
  it "refuses a shared scene in per-window mode, and every publication once the owner has quiesced"
    (boundedExample testRefusalsAndClosure)

-- | A host over two windows and an owner carrying a scene for each.
perWindowRig ∷ IO Rig
perWindowRig = do
  rig ← newRigWith (\config → config {ownerSceneMode = PerWindowScenes})
  clock ← countingClock
  let settings = ownerSettings clock
  pure rig {rigHostConfig = (defaultHostConfig [windowNamed "first", windowNamed "second"]) {hostCommandCapacity = hostCommandCapacity settings, hostCommandBudget = hostCommandBudget settings, hostEventBudget = hostEventBudget settings, hostIdleWait = hostIdleWait settings, hostClock = clock}}

-- | What the fake backend's step was last handed of the scenes.
recordScenes ∷ Rig → IO (TVar (Maybe (SceneMode, Map.Map WindowId (Scene, Natural), Natural)))
recordScenes rig = do
  seen ← newTVarIO Nothing
  script (fakeStep (rigFake rig)) $ \step → do
    atomically (writeTVar seen (Just (stepSceneMode step, stepWindowScenes step, stepSceneRevision step)))
    pure noStepWork
  pure seen

publishTo ∷ GraphicsOwner Scene → WindowId → Int → IO WindowScenePublication
publishTo owner window value = do
  scene ← prepare (Scene value)
  atomically (publishGraphicsWindowScene owner window scene)

testPerWindowSnapshots ∷ IO ()
testPerWindowSnapshots = do
  rig ← perWindowRig
  seen ← recordScenes rig
  (initial, afterFirst, scenes, stepped) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    (first, second) ← twoWindows host
    -- Before any publication every window holds the initial scene at revision
    -- zero.
    initial ← atomically (readGraphicsSceneRevisions owner)
    _ ← handedOver host owner first
    _ ← handedOver host owner second
    one ← publishTo owner first 1
    -- A later publication replaces the one the owner has not taken, and the
    -- revision rises by one for this window alone.
    two ← publishTo owner first 2
    other ← publishTo owner second 10
    afterFirst ← atomically (readGraphicsSceneRevisions owner)
    scenes ← atomically ((,) <$> readOwnerWindowSceneAt (ownerHandoff owner) first <*> readOwnerWindowSceneAt (ownerHandoff owner) second)
    -- The owner's step is handed each target's own window's scene: it waits
    -- for the step that took both publications, whichever round that is.
    atomically $ do
      current ← readTVar seen
      check (fmap (\(_, windows, _) → Map.map snd windows) current == Just (Map.fromList [(first, 2), (second, 1)]))
    stepped ← readTVarIO seen
    pure ((first, second, initial), (one, two, other, afterFirst), scenes, stepped)
  let (first, second, before) = initial
      (one, two, other, revisions) = afterFirst
  before `shouldBe` Map.fromList [(first, 0), (second, 0)]
  one `shouldBe` WindowScenePublished first 1
  two `shouldBe` WindowScenePublished first 2
  other `shouldBe` WindowScenePublished second 1
  revisions `shouldBe` Map.fromList [(first, 2), (second, 1)]
  scenes `shouldBe` ((Scene 2, 2), (Scene 10, 1))
  -- Nothing can publish the shared scene, so the step's stays the initial one.
  stepped `shouldBe` Just (PerWindowScenes, Map.fromList [(first, (Scene 2, 2)), (second, (Scene 10, 1))], 0)

testUnknownWindow ∷ IO ()
testUnknownWindow = do
  rig ← perWindowRig
  (ended, answer, before, after, revisions) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    (first, second) ← twoWindows host
    _ ← publishTo owner first 1
    _ ← publishTo owner second 2
    CloseStarted ← closeHostWindow host second
    pumpUntil host control "the second window's end" (notElem second <$> atomically (hostWindowIdentities host))
    scene ← prepare (Scene 3)
    -- Read in one transaction with the refused publication, so that nothing,
    -- not even the owner's pruning, can fall between the reads.
    (before, answer, after) ← atomically $ do
      held ← readOwnerWindowScenes (ownerHandoff owner)
      refused ← publishGraphicsWindowScene owner second scene
      later ← readOwnerWindowScenes (ownerHandoff owner)
      pure (held, refused, later)
    revisions ← atomically (readGraphicsSceneRevisions owner)
    pure (second, answer, before, after, (first, revisions))
  answer `shouldBe` WindowSceneUnknown ended
  -- Nothing changed: no window's publication or revision moved.
  after `shouldBe` before
  snd revisions `shouldBe` Map.fromList [(fst revisions, 1)]

testRetiredWindowForgotten ∷ IO ()
testRetiredWindowForgotten = do
  rig ← perWindowRig
  forgotten ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    (first, second) ← twoWindows host
    _ ← publishTo owner first 1
    _ ← publishTo owner second 2
    CloseStarted ← closeHostWindow host second
    pumpUntil host control "the second window's end" (notElem second <$> atomically (hostWindowIdentities host))
    -- The owner's next round prunes what the host no longer holds.
    status ← awaitIdle owner
    demand ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    _ ← awaitRound owner (statusRounds status)
    held ← atomically (readOwnerWindowScenes (ownerHandoff owner))
    pure (Map.member second held, Map.member first held)
  forgotten `shouldBe` (False, True)

testWindowPublicationWakes ∷ IO ()
testWindowPublicationWakes = do
  rig ← perWindowRig
  advanced ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    (first, _) ← twoWindows host
    _ ← handedOver host owner first
    idle ← awaitIdle owner
    published ← publishTo owner first 5
    published `shouldBe` WindowScenePublished first 1
    after ← awaitRound owner (statusRounds idle)
    pure (statusRounds after > statusRounds idle)
  advanced `shouldBe` True

testSharedModeUnchanged ∷ IO ()
testSharedModeUnchanged = do
  rig ← newRigWith id
  seen ← recordScenes rig
  (published, window, refused, stepped) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← firstWindow host
    _ ← handedOver host owner window
    scene ← prepare (Scene 4)
    published ← atomically (publishOwnerScene (ownerHandoff owner) scene)
    refused ← publishTo owner window 9
    _ ← awaitIdle owner
    stepped ← readTVarIO seen
    pure (published, window, refused, stepped)
  published `shouldBe` ScenePublication Published
  refused `shouldBe` WindowScenesNotEnabled window
  -- The step is handed the one scene and no window's.
  stepped `shouldBe` Just (SharedScene, Map.empty, 1)

testRefusalsAndClosure ∷ IO ()
testRefusalsAndClosure = do
  rig ← perWindowRig
  (refused, window, escaped) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    (first, _) ← twoWindows host
    scene ← prepare (Scene 6)
    refused ← atomically (publishOwnerScene (ownerHandoff owner) scene)
    pure (refused, first, (ownerHandoff owner, owner))
  refused `shouldBe` SceneRefusedPerWindow
  let (handoff, _) = escaped
  -- The exit has closed the handoff's publications.
  scene ← prepare (Scene 7)
  atomically (publishOwnerWindowScene handoff [window] window scene) >>= \case
    WindowSceneClosed named → named `shouldBe` window
    other → unexpected ("a window's scene was answered " <> show other <> " by a closed handoff")

twoWindows ∷ WindowHost → IO (WindowId, WindowId)
twoWindows host =
  atomically (hostWindowIdentities host) >>= \case
    first : second : _ → pure (first, second)
    _ → unexpected "the host created fewer than two windows"

firstWindow ∷ WindowHost → IO WindowId
firstWindow host =
  atomically (hostWindowIdentities host) >>= \case
    first : _ → pure first
    [] → unexpected "the host created no window"
