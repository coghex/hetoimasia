{-# LANGUAGE OverloadedRecordDot #-}

-- | R2D-14's native case (@r2d14-window-scenes@): a scene for each of two
-- windows, published, adopted and released through the production host, on
-- private roots in a child process of its own.
--
-- The production composition — 'withVulkanOwnerHost' over the loader
-- integration, with the validation layer and synchronization validation — is
-- configured with 'PerWindowScenes' and a test renderer that clears each
-- window's frame to a colour taken from the scene it was handed: scene 1 is
-- red, 2 green and 3 blue. Nothing but a publication asks for a frame, and
-- the examples count frames from the owner's own frame events, never from a
-- picture; no screen is captured.
--
-- 1. Both windows are handed over, and the loop turned until each has a
--    presenting generation. Each adopted the initial scene, as revision 0,
--    and presented nothing.
-- 2. A scene is published for the first window alone. Its target presents a
--    frame and the second window's presents none: the owner round that made
--    the frame is allowed to end before the second window is touched.
-- 3. A scene is published for the second window, which presents it. Both
--    windows now show revision 1.
-- 4. In one transaction, a second revision is published for the second
--    window and a release request is made. The request waits for revision 2
--    of the second window, which the owner has not yet taken, and runs only
--    after the owner has adopted it; the second window then presents it.
-- 5. The loop finishes and the host exits through D-33.
--
-- The case asserts the order of the log it kept of the frames, the scene
-- lifecycle and the request, that every Vulkan call ran on the graphics
-- owner's thread, and a verdict, read after the last callback, with no issue
-- at all.
module Test.GPU.Vulkan.Native.WindowScenes
  ( ScenesOutcome (..)
  , runWindowScenes
  , windowScenesSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (elemIndex, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Session (Backend)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), WindowId, hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , ActionTicket
  , ClearColor (..)
  , FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , SceneLifecycle (..)
  , SceneMode (..)
  , VulkanAction (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , WindowScenePublication (..)
  , clearRenderer
  , handOverVulkanTarget
  , publishVulkanWindowScene
  , readReadiness
  , readVulkanAction
  , readVulkanGenerations
  , requestVulkanRelease
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (TargetCondition (..), TargetGenerationsView (..))
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , OwnerStatus (..)
  , ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowIdentities
  , publishGraphicsWindowScene
  , readOwnerStatusNow
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | The scene of each colour: 1 is red, 2 green, 3 blue, and anything else
-- (the initial scene is 0) black.
colourOf ∷ Int → ClearColor
colourOf = \case
  1 → ClearColor 1 0 0 1
  2 → ClearColor 0 1 0 1
  3 → ClearColor 0 0 1 1
  _ → ClearColor 0 0 0 1

-- | What the case kept, in the order it happened, on the threads it happened
-- on.
data Entry
  = Frame !FrameEvent !Natural
    -- ^ A frame event, with the owner's completed rounds when it was reported.
  | Adopted !WindowId !Natural !Int
  | Released !WindowId !Natural
  | Marker !Text
  | RequestRan
  deriving (Eq, Show)

-- | What the case saw.
data ScenesFacts = ScenesFacts
  { factsLog ∷ ![Entry]
  , factsRendered ∷ ![(AttachmentId, Int, Natural)]
    -- ^ For each frame the renderer recorded: its target, the scene it was
    -- handed, and the revision the frame carries.
  , factsAttachments ∷ !(AttachmentId, AttachmentId)
  , factsWindows ∷ !(WindowId, WindowId)
  , factsPublications ∷ ![WindowScenePublication]
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data ScenesOutcome
  = ScenesFailed !Text
  | ScenesRecorded !ScenesFacts

-- | The phase the loop's update opportunity is in.
data Phase
  = Preparing
  | PublishedFirst
    -- ^ A scene was published for the first window; the frame it asked for,
    -- and the end of the owner round that made it, are awaited.
  | PublishedSecond
  | Requested !(ActionTicket ())
  | Done

-- | Run the case on the calling thread, which must be the process main thread.
runWindowScenes ∷ Maybe Backend → Journal → IO ScenesOutcome
runWindowScenes backend journal = do
  heading journal "R2D-14: a scene for each of two windows, adopted and released through the production host"
  started ← getCurrentTime
  recorded ← newIORef []
  entries ← newTVarIO []
  rendered ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  factsHeld ← newIORef Nothing
  owner ← newTVarIO Nothing
  initial ← prepare 0
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let window name = (hiddenTestWindowConfig name 160 120) {windowVisible = True}
      host = requestingBackend backend (defaultHostConfig [window "hetoimasia R2D-14 first", window "hetoimasia R2D-14 second"])
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      keep entry = atomically (modifyTVar' entries (<> [entry]))
      rounds = readTVar owner >>= maybe (pure 0) (fmap statusRounds . readOwnerStatusNow)
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets initial)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver recorded
          , vulkanFrameObserver = \event → atomically (rounds >>= \at → modifyTVar' entries (<> [Frame event at]))
          , vulkanSceneMode = PerWindowScenes
          , vulkanSceneLifecycle =
              SceneLifecycle
                { sceneAdopted = \at revision scene → keep (Adopted at revision scene)
                , sceneReleased = \at revision → keep (Released at revision)
                }
          , -- A frame is cleared to the colour of the scene its window was
            -- handed, whichever window it is.
            vulkanRenderer = VulkanRenderer $ \scene frame construction recorder → do
              atomically (modifyTVar' rendered (<> [(requestAttachment frame, scene, requestSceneRevision frame)]))
              renderScene (clearRenderer (\held _ → colourOf held)) scene frame construction recorder
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          "vulkan-native-r2d14-window-scenes"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control entries owner keep factsHeld)
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  logs ← readTVarIO logged
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← logs, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (ScenesFailed (Text.pack (displayException failure)))
    Right () →
      readIORef factsHeld >>= \case
        Nothing → pure (ScenesFailed "the loop returned without its facts")
        Just partial → do
          -- Read once the host has exited, so its retirement is in the log.
          final ← readTVarIO entries
          seen ← readTVarIO rendered
          note journal ("presented " <> tshow (length [() | Frame (FramePresented {}) _ ← final]) <> " frames; " <> tshow (length [() | Released {} ← final]) <> " scene revisions released")
          pure . ScenesRecorded $
            partial
              { factsLog = final
              , factsRendered = seen
              , factsCalls = calls
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              }
  where
    body vulkan control entries owner keep factsHeld = do
      main ← myThreadId
      let controller = vulkanController vulkan
          windowHost = vulkanWindowHost vulkan
          graphics = vulkanGraphicsOwner vulkan
      atomically (writeTVar owner (Just graphics))
      readiness ← awaitWithin 10 "the owner's startup" $
        readReadiness controller >>= \case
          RootsPending → pure Nothing
          other → pure (Just other)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      windows ← atomically (hostWindowIdentities windowHost)
      (first, second) ← case windows of
        [one, two] → pure (one, two)
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not two")
      let handOver window =
            handOverVulkanTarget vulkan window RequiredTarget >>= \case
              VulkanTargetHandedOver service → pure service
              other → stopWith ("a window was not handed over: " <> tshow other)
      firstService ← handOver first
      secondService ← handOver second
      forM_ [firstService, secondService] $ \service → do
        standing ← awaitWithin 10 "a target's admission" $
          readTargetStanding graphics (graphicsAttachment service) >>= \case
            Just TargetConstructing → pure Nothing
            Nothing → pure Nothing
            Just other → pure (Just other)
        when (standing /= TargetUsable) (stopWith ("a target was not admitted: " <> tshow standing))
      let one = graphicsAttachment firstService
          two = graphicsAttachment secondService
          presents attachment = length . filter (presentedTo attachment) <$> readTVarIO entries
          presentedTo attachment = \case
            Frame (FramePresented at _ _ _) _ → at == attachment
            _ → False
          presenting service =
            atomically (maybe False ((== Presenting) . viewCondition) <$> readVulkanGenerations controller (graphicsAttachment service))
          publish window value = do
            scene ← prepare value
            publishVulkanWindowScene vulkan window scene
          completedRounds = atomically (statusRounds <$> readOwnerStatusNow graphics)
      publications ← newTVarIO []
      phase ← newTVarIO Preparing
      deadline ← addUTCTime 20 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) $ do
          counts ← (,) <$> presents one <*> presents two
          note journal ("the composed loop reached its deadline having presented " <> tshow counts)
          stopWith "the composed loop did not finish within 20 seconds"
        current ← readTVarIO phase
        case current of
          Preparing → do
            ready ← (&&) <$> presenting firstService <*> presenting secondService
            adopted ← length . filter (\case Adopted {} → True; _ → False) <$> readTVarIO entries
            when (ready && adopted >= 2) $ do
              keep (Marker "published the first window's scene")
              published ← publish first 1
              atomically (modifyTVar' publications (<> [published]))
              note journal ("published scene 1 for the first window: " <> tshow published)
              atomically (writeTVar phase PublishedFirst)
          PublishedFirst → do
            log' ← readTVarIO entries
            -- The frame of the first window's scene, and the end of the owner
            -- round that presented it: nothing else of that round is still to
            -- come when the second window is next touched.
            let after = dropWhile (/= Marker "published the first window's scene") log'
                presentedAt = [at | Frame (FramePresented target _ _ _) at ← after, target == one]
            case presentedAt of
              at : _ → do
                finishedRound ← completedRounds
                when (finishedRound > at) $ do
                  keep (Marker "published the second window's scene")
                  published ← publish second 2
                  atomically (modifyTVar' publications (<> [published]))
                  note journal ("published scene 2 for the second window: " <> tshow published)
                  atomically (writeTVar phase PublishedSecond)
              [] → pure ()
          PublishedSecond → do
            secondCount ← presents two
            when (secondCount >= 1) $ do
              keep (Marker "made the release request with the second window's second revision")
              scene ← prepare 3
              -- The publication and the request are one fact: the request
              -- waits for the revision the owner has not yet taken.
              (published, ticket) ← atomically $ do
                p ← publishGraphicsWindowScene graphics second scene
                t ← requestVulkanRelease vulkan (VulkanAction (\_ → keep RequestRan))
                pure (p, t)
              held ← either (\refusal → stopWith ("the release request was refused: " <> tshow refusal)) pure ticket
              atomically (modifyTVar' publications (<> [published]))
              note journal ("published scene 3 for the second window and requested a release: " <> tshow published)
              atomically (writeTVar phase (Requested held))
          Requested ticket → do
            outcome ← atomically (readVulkanAction ticket)
            secondCount ← presents two
            case outcome of
              Just (ActionReturned ()) | secondCount >= 2 → atomically (writeTVar phase Done)
              Just (ActionReturned ()) → pure ()
              Just _ → stopWith "the release request did not return"
              Nothing → pure ()
          Done → pure ()
        ended ← readTVarIO phase
        case ended of
          Done → do
            final ← readTVarIO publications
            writeIORef factsHeld . Just $
              ScenesFacts
                { factsLog = []
                , factsRendered = []
                , factsAttachments = (one, two)
                , factsWindows = (first, second)
                , factsPublications = final
                , factsCalls = []
                , factsMainThread = main
                , factsVerdict = Nothing
                , factsErrors = []
                , factsSeconds = 0
                }
            pure (FinishWith ())
          _ → pure (ContinueWith NoUpdateDemand)
    quiet = recordingLogger (\_ → pure ())

-- | The record's section.
windowScenesSection ∷ ScenesOutcome → [Text]
windowScenesSection = \case
  ScenesFailed reason → ["", "## The window scenes case did not complete", "", reason]
  ScenesRecorded facts →
    [ ""
    , "## A scene for each of two windows"
    , ""
    , "- publications: " <> tshow (factsPublications facts)
    , "- frames presented to the first window: " <> tshow (presentedBy facts (fst (factsAttachments facts)))
    , "- frames presented to the second window: " <> tshow (presentedBy facts (snd (factsAttachments facts)))
    , "- scenes handed to the renderer (target, scene, revision): " <> tshow (factsRendered facts)
    , "- scene lifecycle: " <> tshow [entry | entry ← factsLog facts, isLifecycle entry]
    , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
    , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
    , "- error reports: " <> tshow (length (factsErrors facts))
    , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
    ]
  where
    isLifecycle = \case
      Adopted {} → True
      Released {} → True
      RequestRan → True
      _ → False

presentedBy ∷ ScenesFacts → AttachmentId → Int
presentedBy facts attachment = length [() | Frame (FramePresented at _ _ _) _ ← factsLog facts, at == attachment]

vulkanCalls ∷ ScenesFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ ScenesOutcome → Spec
spec outcome = describe "R2D-14 a scene for each window" $ do
  it "adopted the initial scene for each window as revision 0, and presented nothing for it" $
    on outcome $ \facts → do
      let (first, second) = factsWindows facts
          beforeFirstPublication = takeWhile (/= Marker "published the first window's scene") (factsLog facts)
      [(at, revision, scene) | Adopted at revision scene ← beforeFirstPublication] `shouldSatisfy` \adopted ->
        (first, 0, 0) `elem` adopted && (second, 0, 0) `elem` adopted
      [() | Frame (FramePresented {}) _ ← beforeFirstPublication] `shouldBe` []

  it "presented a frame to the first window for its publication and none to the second, whose own publication then presented to it" $
    on outcome $ \facts → do
      let (one, two) = factsAttachments facts
          log' = factsLog facts
          between = takeWhile (/= Marker "published the second window's scene") (dropWhile (/= Marker "published the first window's scene") log')
          presentedIn entries = [at | Frame (FramePresented at _ _ _) _ ← entries]
      presentedIn between `shouldBe` [one]
      [(at, revision) | Frame (FramePresentRequested at _ _ revision) _ ← between] `shouldBe` [(one, 1)]
      presentedBy facts two `shouldSatisfy` (>= 2)

  it "cleared each window's frames to the colour of the scene its window was handed" $
    on outcome $ \facts → do
      let (one, two) = factsAttachments facts
          shown = [(at, scene) | (at, scene, _) ← factsRendered facts, scene /= 0]
      [scene | (at, scene) ← shown, at == one] `shouldSatisfy` all (== 1)
      [scene | (at, scene) ← shown, at == two] `shouldSatisfy` all (`elem` [2, 3])
      (one, 1) `elem` shown `shouldBe` True
      (two, 2) `elem` shown `shouldBe` True
      (two, 3) `elem` shown `shouldBe` True

  it "ran the release request made while the second window showed revision 1 only after the second window adopted revision 2" $
    on outcome $ \facts → do
      let (_, second) = factsWindows facts
          log' = factsLog facts
          requested = elemIndex (Marker "made the release request with the second window's second revision") log'
          adopted = elemIndex (Adopted second 2 3) log'
          ran = elemIndex RequestRan log'
      adopted `shouldSatisfy` (/= Nothing)
      ran `shouldSatisfy` (/= Nothing)
      requested `shouldSatisfy` (/= Nothing)
      -- It could not have run before the owner took the revision it waited for,
      -- which was published in the transaction that requested it.
      requested < adopted `shouldBe` True
      adopted < ran `shouldBe` True
      factsPublications facts `shouldSatisfy` (\held → WindowScenePublished second 2 `elem` held)

  it "released each adopted revision once, in adoption order for each window" $
    on outcome $ \facts → do
      let (first, second) = factsWindows facts
          log' = factsLog facts
          adoptedBy window = [revision | Adopted at revision _ ← log', at == window]
          releasedBy window = [revision | Released at revision ← log', at == window]
      -- Each window's adoptions were all released, by the host's exit at the
      -- latest, and in the order they were adopted.
      releasedBy first `shouldBe` adoptedBy first
      releasedBy second `shouldBe` adoptedBy second

  it "made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread" $
    on outcome $ \facts → do
      let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
      length threads `shouldBe` 1
      threads `shouldSatisfy` notElem (factsMainThread facts)
      [call.callHaskellThread | call ← factsCalls facts, call.callName == "glfwCreateWindowSurface"] `shouldSatisfy` all (== factsMainThread facts)

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome $ \facts → do
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      ScenesFailed reason → const (expectationFailure (Text.unpack reason))
      ScenesRecorded facts → ($ facts)

-- ---------------------------------------------------------------------------
-- Helpers

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Wait for the transaction to answer something, for at most this many
-- seconds.
awaitWithin ∷ Double → Text → STM (Maybe a) → IO a
awaitWithin seconds what transaction = do
  expired ← registerDelay (round (seconds * 1000000))
  atomically ((transaction >>= maybe retry (pure . Just)) `orElse` (Nothing <$ (readTVar expired >>= check)))
    >>= maybe (stopWith (what <> " did not happen within " <> tshow seconds <> " seconds")) pure

recordingLogger ∷ (LogEntry → IO ()) → Logger
recordingLogger keep =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink keep)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
