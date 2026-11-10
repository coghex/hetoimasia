{-# LANGUAGE OverloadedStrings #-}

-- | The graphics facade (LFE-21) on a real @runSession@: the production injection ('graphicsInjection') installs the
-- UI-only graphics calls into the roles' VMs of a real session, with @noHarness@, over a real content root, manifest,
-- boot checkpoint, read pool, supervised owners, request admission, instance leases, texture pipeline and window
-- provider.
--
-- Injected, and it says so: the texture owner (the fake owner), the windows (the window fake) and the host's answer to
-- a publication and its ledger (the scene host model). The evidence is ordering, ownership and the session's
-- own policy, never a frame; the real GPU is the native suite's subgroup of the same name.
--
-- Nothing sleeps. A scenario knows what has happened by blocking in STM on a reading, and every thread it starts
-- terminates before the example returns, a failed assertion in it included.
module Test.LuaEngine.Graphics.Facade (spec) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (SomeException, finally, fromException, throwIO, try)
import Control.Monad (forM_, forever, unless, void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.LuaEngine.Boot (bootCheckpoint)
import Hetoimasia.LuaEngine.Facade (OutputFailure (..), OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Facade (GraphicsInjection (..), GraphicsServices (..))
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), defaultIssuedMemory, emptyIssued, graphicsInjection, issuedSize, issuerOf, rememberIssued)
import Hetoimasia.LuaEngine.Graphics.Scene (GraphicsScene (..), PublishHooks (..), noPublishHooks, scenePublisherOver)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Fault (FaultFatal))
import Hetoimasia.LuaEngine.Graphics.Window.Port (CreateOutcome (..), Port (..), WindowToken (..), fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), Bytes (Bytes), Count (Count), CountLimit (PngAxisMaximum, PngPixels, RequestsPerInstance), Profile, ProfileSpec (..), profileSpec, validateProfile)
import Hetoimasia.LuaEngine.Scene (SceneContent (..), SceneRect (..), SceneSprite (..), TextureUse (..))
import Hetoimasia.LuaEngine.Texture (TexturePipeline, TextureView (..), sessionNominal)
import qualified Data.Set as Set
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Render.TwoD.Vulkan.Textures (newTextures)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
import Test.LuaEngine.Graphics.FacadeScripts (isClear, manifestFor, quadExample)
import qualified Test.LuaEngine.Graphics.Fake as Fake
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Rig (Rig (..), bounded, withRig)
import Test.LuaEngine.Graphics.Work (WorkReading, assertBoundedWork, readWork)
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)

-- | Everything a scenario drives.
data FS = FS
  { fsSession ∷ !Session
  , fsRig ∷ !Rig
  , fsWindows ∷ !WF.Fake
  , fsModel ∷ !Model
  , fsProvider ∷ !(WindowProvider Int)
  , fsOut ∷ !(TVar [Text])
  -- ^ What the roles printed, oldest first.
  , fsGate ∷ !(MVar ())
  -- ^ Held by the output sink's first line when the example asked for it: the authored output parks the role's @init@.
  , fsPipeline ∷ !TexturePipeline
  -- ^ The session's texture pipeline, for its banks' readings.
  }

-- | How an example shapes the session.
data Shape = Shape
  { shapeEntry ∷ !ByteString
  , shapeBoth ∷ !Bool
  , shapeParkOutput ∷ !Bool
  , shapeWindow ∷ !WF.FakeConfig
  , shapeTexture ∷ !Fake.FakeConfig
  , shapeProfile ∷ !Profile
  , shapeCreateScript ∷ ![CreateOutcome]
  -- ^ What the window fake's creations answer, in order, set before the session starts.
  , shapeHooks ∷ !PublishHooks
  , shapeSinkFails ∷ !Bool
  -- ^ The authored output sink raises on its first line.
  , shapeProviderHooks ∷ !ProviderHooks
  , shapeSession ∷ !(Maybe (IORef (Maybe Session)))
  -- ^ Where the session's handle is left, to be read after the session's call raised (the record outlives the call).
  , shapeAlter ∷ !(GraphicsServices → GraphicsServices)
  -- ^ A fault injected into the services the composition makes (a registration that is refused).
  , shapeRecord ∷ !(Maybe (IORef [Text]))
  -- ^ Where the fake texture owner's log is left when the run ends, for an example whose rig raises on its way out.
  , shapeInject ∷ ![Fake.Injection]
  -- ^ Faults the fake texture owner injects, taken by the next calls of their kinds.
  , shapeFiles ∷ ![(FilePath, ByteString)]
  -- ^ Content the example adds to the root beside the manifest, the entry and @images/quad.png@.
  }

defaultShape ∷ ByteString → Shape
defaultShape entry = Shape entry True False WF.defaultFakeConfig Fake.defaultFakeConfig compositionProfile [] noPublishHooks False noProviderHooks Nothing id Nothing [] []

-- | The fixed M1 profile with these counts changed, so that a bank is full after a few requests.
profileWith ∷ [(CountLimit, Word64)] → Profile
profileWith changes = profileOver changes []

-- | The fixed M1 profile with these counts and byte limits changed, validated.
profileOver ∷ [(CountLimit, Word64)] → [(ByteLimit, Word64)] → Profile
profileOver changes byteChanges = either (error . ("the profile was refused: " <>) . show) id (validateProfile edited)
  where
    base = profileSpec compositionProfile
    edited =
      base
        { specCounts = \limit → maybe (specCounts base limit) Count (lookup limit changes)
        , specBytes = \limit → maybe (specBytes base limit) Bytes (lookup limit byteChanges)
        }

-- | A profile whose every texture reserves exactly the 4,096-byte minimum charge (a pixel limit of 1,024 reserves
-- 4,096 bytes of output), with room for exactly two of them in an instance and four in the session. A request's charge is
-- then 4,096 bytes whether it is pending or its decode has run, so the bank is full at two whatever the timing.
twoTextures ∷ Profile
twoTextures = profileOver [(PngPixels, 1024), (PngAxisMaximum, 32)] [(TextureBytesPerUiInstance, 8192), (TextureBytesPerSession, 16384)]

spec ∷ Spec
spec = describe "graphics facade" $ do
  it "remembers the issuing instance of only the most recent handles, however many textures are loaded and released" $ do
    let issued = foldl' (\held key → rememberIssued 4 key "inst-1" held) emptyIssued [1 .. 100000]
    issuedSize issued `shouldBe` 4
    issuerOf 100000 issued `shouldBe` Just "inst-1"
    issuerOf 99997 issued `shouldBe` Just "inst-1"
    issuerOf 99996 issued `shouldBe` Nothing
    issuedSize (rememberIssued defaultIssuedMemory 7 "inst-2" emptyIssued) `shouldBe` 1
    -- the documented default
    defaultIssuedMemory `shouldBe` 4096
    let full = foldl' (\held key → rememberIssued defaultIssuedMemory key "inst-1" held) emptyIssued [1 .. 10000]
    issuedSize full `shouldBe` 4096
    issuerOf 5904 full `shouldBe` Nothing
    issuerOf 5905 full `shouldBe` Just "inst-1"

  it "carries the image kind a script asked for through the production injection to the owner: data allocates and registers linear, the default stays sRGB, and the incompatible combination is an ordinary error that reaches no owner" $ do
    (attempted, logged) ←
      runFacadeLogged ((defaultShape imageKinds) {shapeBoth = False, shapeFiles = [("images/normals.png", Png.solid 2 2 (128, 128, 255, 255))]}) $ \fs → do
        let expectLine wanted =
              timeout 4000000 (awaitLine fs wanted) >>= \case
                Just () → pure ()
                Nothing → readTVarIO (fsOut fs) >>= \seen → assertFailure ("no line " <> show wanted <> "; the script printed " <> show seen)
        expectLine "combination\tfalse\ttrue"
        expectLine "taken\t3"
        Fake.awaitEvent (rigFake (fsRig fs)) "registered 2 "
        requestStop (fsSession fs) StopQuit
    outcome ← either (\failure → assertFailure ("the session raised: " <> show failure <> "; the owner saw " <> show logged)) pure attempted
    outVerdict outcome `shouldBe` VerdictSuccess
    -- Three requests reached the owner, not four: the refused combination was decided before any admission.
    let allocations = filter (Text.isPrefixOf "allocated ") logged
        registrations = filter (Text.isPrefixOf "registered ") logged
    length allocations `shouldBe` 3
    length (filter (Text.isSuffixOf " linear") allocations) `shouldBe` 2
    length (filter (Text.isSuffixOf " linear") registrations) `shouldBe` 2
    length (filter (not . Text.isSuffixOf " linear") allocations) `shouldBe` 1

  it "runs the common-entry quad example through the production injection, taking each request once and publishing then releasing" $ do
    outcome ← runFacade (defaultShape quadExample) $ \fs → do
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      scene ← latestScene (fsModel fs) firstWindow >>= maybe (assertFailure "no scene was published") pure
      expectQuad scene
      -- The scene is accepted and adopted, and Lua released its texture right after publishing it: the adopted scene
      -- keeps the image registered, and the release has not run.
      releasedCount fs `shouldReturn` 0
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outRetired outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "completes the example when the texture completes before the window" $ do
    outcome ← runFacade ((defaultShape quadExample) {shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldAdmit]}}) $ \fs → do
      Fake.awaitEvent (rigFake (fsRig fs)) "upload completed 0"
      WF.release (fsWindows fs) WF.HoldAdmit
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "completes the example when the window completes before the texture" $ do
    outcome ← runFacade ((defaultShape quadExample) {shapeTexture = Fake.defaultFakeConfig {Fake.fcInitialHolds = [Fake.HoldUploadFinish]}}) $ \fs → do
      WF.awaitFake (fsWindows fs) ((>= 1) . WF.readingAttached)
      Fake.release (rigFake (fsRig fs)) Fake.HoldUploadFinish
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "latches an unread clean window-creation refusal as required_request at the request stage, from a real session role" $ do
    outcome ← runFacade ((defaultShape unreadOpen) {shapeBoth = False, shapeCreateScript = [CreateRefusedClean "the display refused the window"]}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]

  it "latches a caught clean window-creation refusal the same way: the role, parked in its authored output, takes the exact window_error record after the refusal settled, catches the error it raises over it, and the instance still fails" $ do
    outcome ←
      runFacade
        ( (defaultShape caughtOpen)
            { shapeBoth = False
            , shapeParkOutput = True
            , shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldCreate]}
            , shapeCreateScript = [CreateRefusedClean "the display refused the window"]
            }
        )
        $ \fs → do
          -- The role is parked in its authored output with the creation command held: let the refusal settle while the
          -- invocation is still running, wait for the provider to have answered and retired it, and resume that segment.
          WF.awaitEvent (fsWindows fs) "issue create"
          WF.release (fsWindows fs) WF.HoldCreate
          atomically (providerReading (fsProvider fs) >>= \found → unless (readingAcquisitions found == 0) retry)
          void (tryPutMVar (fsGate fs) ())
          -- The acknowledgement is the role's own print after it took and caught: the whole record, no root or path.
          awaitLine fs "caught\tfalse\twindow_error\ttrue\ttrue\tthe display refused the window"
          atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]

  it "keeps the window refusal as the role's and the engine report's primary when the update that was running took it and raised it uncaught, and accounts that script error once as a secondary" $ do
    outcome ←
      runFacade
        ( (defaultShape raisedOpen)
            { shapeBoth = False
            , shapeParkOutput = True
            , shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldCreate]}
            , shapeCreateScript = [CreateRefusedClean "the display refused the window"]
            }
        )
        $ \fs → do
          -- The update is parked inside its authored output, so its invocation is running: its line is recorded before
          -- it parks. Only then does the refusal settle, while that invocation runs, and the segment resume.
          awaitLine fs "parked"
          WF.awaitEvent (fsWindows fs) "issue create"
          WF.release (fsWindows fs) WF.HoldCreate
          atomically (providerReading (fsProvider fs) >>= \found → unless (readingAcquisitions found == 0) retry)
          void (tryPutMVar (fsGate fs) ())
          atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]
    fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just RequiredRequest
    fmap eeStage (erPrimary (outEngine outcome)) `shouldBe` Just OnRequest
    -- The script's own error is the one secondary of the engine report, once, and none is omitted.
    map eeCode (erSecondary (outEngine outcome)) `shouldBe` [LuaError]
    map (Text.isInfixOf "the display refused the window" . eeMessage) (erSecondary (outEngine outcome)) `shouldBe` [True]
    erOmitted (outEngine outcome) `shouldBe` 0

  it "routes a genuine native close with the startup gate closed to the session's stop, which Lua cannot veto" $ do
    outcome ← runFacade ((defaultShape parkedOpen) {shapeBoth = False, shapeParkOutput = True}) $ \fs → do
      -- The role's init is parked in its authored output, so the startup gate is closed; its window is pending.
      WF.awaitFake (fsWindows fs) ((>= 1) . WF.readingAttached)
      WF.nativeClose (fsWindows fs) 1
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (outQuit found) retry)
      void (tryPutMVar (fsGate fs) ())
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []
    outRetired outcome `shouldBe` True

  it "refuses a publication a stop overtakes between its check and its commit, whole, and keeps the previous scene" $ do
    entered ← newEmptyMVar
    proceed ← newEmptyMVar
    calls ← newIORef (0 ∷ Int)
    let hooks =
          noPublishHooks
            { hookBeforeCommit = do
                -- The first publication passes; the second is held with its authority checked and every pin taken.
                n ← atomicModifyIORef' calls (\held → (held + 1, held + 1))
                if n >= 2 then putMVar entered () >> readMVar proceed else pure ()
            }
    outcome ← runFacade ((defaultShape publishRace) {shapeBoth = False, shapeHooks = hooks}) $ \fs → do
      awaitLine fs "first"
      void (adoptNow (fsModel fs) firstWindow)
      previous ← latestScene (fsModel fs) firstWindow
      -- The second publication is inside its commit's seam: the stop is requested now, and only then let go.
      takeMVar entered
      requestStop (fsSession fs) StopQuit
      putMVar proceed ()
      awaitLine fs "second\tfalse\ttrue"
      publishedRevision (fsModel fs) firstWindow `shouldReturn` 1
      latestScene (fsModel fs) firstWindow `shouldReturn` previous
      fmap graphicsContent previous `shouldSatisfy` maybe False (\content -> length (sceneSprites content) == 1)
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "answers busy from a full texture byte bank while the window, whose own slot is free, is accepted, starts no native work for the refused request, and accepts the explicit retry after actual reclamation" $ do
    outcome ← runFacade ((defaultShape textureBank) {shapeBoth = False, shapeProfile = twoTextures}) $ \fs → do
      awaitLine fs "banks\ttrue\tbusy\ttrue\ttrue"
      awaitLine fs "retry\ttrue\ttrue"
      -- Three requests ever reached the native owner: the two accepted and the retry; the refused one started nothing.
      Fake.awaitEvent (rigFake (fsRig fs)) "allocated 2 "
      allocated ← length . filter (Text.isPrefixOf "allocated ") <$> Fake.events (rigFake (fsRig fs))
      allocated `shouldBe` 3
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "answers a texture request naming bytes, never the lease capacity, when the bank is full of retained textures and the window holds its lease: 8,192 bytes at a 4,096-byte reservation, two one-pixel textures and a window" $ do
    outcome ← runFacade ((defaultShape heldWindowBank) {shapeBoth = False, shapeProfile = twoTextures}) $ \fs → do
      awaitLine fs "bound\tbusy\ttrue\ttrue"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  -- The thousand-texture scenario is run once, observed, and read by both examples that follow: the first for the contract the issue
  -- keeps whole, the second for the work it did, which it compares with the same scenario at a quarter of the size.
  beforeAll (runFacadeObserved (pixelShape 1000) (pixelScenario 1000)) $ do
    it "retains a thousand one-pixel textures at once in one instance through the production facade: each is charged the 4 KiB minimum, nothing is refused on a count, and every byte comes back when they are released" $ \(result, _, _) → do
      outcome ← either throwIO pure result
      outVerdict outcome `shouldBe` VerdictSuccess
      outFailures outcome `shouldBe` []

    it "does work linear in the textures an instance retains and releases: no pump evaluation or fake operation looks at what is retained or came before, at 250 and 1000 one-pixel textures" $ \(largeResult, largeLogged, large) → do
      (smallResult, smallLogged, small) ← runFacadeObserved (pixelShape 250) (pixelScenario 250)
      forM_ [largeResult, smallResult] $ \result → do
        outcome ← either throwIO pure result
        outVerdict outcome `shouldBe` VerdictSuccess
        outFailures outcome `shouldBe` []
      -- What the scenario did, read from the fake owner's own log and never from a counter: each texture is allocated, registered and
      -- released once, and the owner has seen each upload.
      forM_ [(250, smallLogged), (1000, largeLogged)] $ \(n, logged) →
        [length (filter (Text.isPrefixOf prefix) logged) | prefix ← ["allocated ", "registered ", "released ", "upload admitted "]] `shouldBe` replicate 4 n
      -- At each site the most one operation or pump evaluation charged is a constant that does not depend on the size, the units of the
      -- operations that committed for each texture are bounded the same way, and the total at 1000 is at most six times the total at
      -- 250: see 'assertBoundedWork'.
      assertBoundedWork [(250, small), (1000, large)]

  it "answers busy from the common request places for a window request whose own slot is free, with no native window made, and accepts the explicit retry once a place is returned" $ do
    outcome ← runFacade ((defaultShape requestBank) {shapeBoth = False, shapeParkOutput = True, shapeProfile = profileWith [(RequestsPerInstance, 2)]}) $ \fs → do
      -- The role is parked in its authored output at the busy acknowledgement, so nothing can retry yet: no native
      -- window was made for the refused request.
      awaitLine fs "window\ttrue\tbusy"
      WF.events (fsWindows fs) >>= (`shouldBe` [])
      -- Resumed, it takes a texture result (returning a request place) and retries the window request.
      void (tryPutMVar (fsGate fs) ())
      awaitLine fs "retried\ttrue"
      WF.awaitEvent (fsWindows fs) "issue create"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "ends an instance whose init failed after starting both requests, with the window and the texture retired and the failure preserved" $ do
    outcome ← runFacade ((defaultShape failedInit) {shapeBoth = False}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [LuaError]
    map rfStage (outFailures outcome) `shouldBe` [OnInit]
    outRetired outcome `shouldBe` True

  it "retires a window and a texture when the role's shutdown raises, keeping that failure" $ do
    outcome ← runFacade ((defaultShape throwingShutdown) {shapeBoth = False}) $ \fs → do
      awaitLine fs "ready"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [LuaError]
    map rfStage (outFailures outcome) `shouldBe` [OnShutdown]
    outRetired outcome `shouldBe` True

  it "settles requests the script cancelled in the segment that started them, and retires what the providers had begun" $ do
    outcome ← runFacade ((defaultShape cancelAtOnce) {shapeBoth = False}) $ \fs → do
      awaitLine fs "cancel\tcancelled\tcancelled"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "settles a window request the script cancelled while the provider held its acceptance, retires the window once, and leaves the instance healthy" $ do
    outcome ← runFacade ((defaultShape cancelHeld) {shapeBoth = False, shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldAdmit]}}) $ \fs → do
      awaitLine fs "cancel\tcancelled\tcancelled"
      WF.release (fsWindows fs) WF.HoldAdmit
      atomically (providerReading (fsProvider fs) >>= \found → unless (readingAcquisitions found == 0) retry)
      closes ← length . filter (Text.isPrefixOf "close w") <$> WF.events (fsWindows fs)
      closes `shouldBe` 1
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "raises the output failure only after the window and the texture are retired, when the authored output sink raises after both requests started, with no native work left" $ do
    -- The session's call raises the sink's failure once every role has retired and every release has run; the rig then checks,
    -- as the example returns, that no native image, registration or upload is left.
    raised ←
      runFacadeEither ((defaultShape sinkFails) {shapeBoth = False, shapeSinkFails = True}) $ \fs →
        atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    case raised of
      Left failure → fromException failure `shouldSatisfy` (\found → case found of Just OutputFailure {} → True; Nothing → False)
      Right outcome → expectationFailure ("expected the output failure, found " <> show (outVerdict outcome))

  it "keeps the script's failure primary and the failed texture cleanup beside it as evidence, the cleanup arriving after the primary, run once and raised once" $ do
    ref ← newIORef []
    sessionRef ← newIORef Nothing
    raised ←
      try @SomeException . void $
        runFacade ((defaultShape releaseFails) {shapeBoth = False, shapeRecord = Just ref, shapeSession = Just sessionRef, shapeInject = [Fake.FailRelease (FaultFatal "the table release failed")]}) $ \fs → do
          -- The primary failure (the script's own error) is observed first: the cleanup is the lease's release when the instance ends.
          atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    -- The fatal cleanup failure is raised on the way out, once, with what the backend retained...
    case raised of
      Left failure → show failure `shouldSatisfy` Text.isInfixOf "the table release failed" . Text.pack
      Right () → expectationFailure "expected the cleanup failure to be raised"
    logged ← readIORef ref
    length (filter (Text.isPrefixOf "release attempted") logged) `shouldBe` 1
    -- ...and the session's record, still readable, holds the script's failure as the primary.
    found ← readIORef sessionRef >>= maybe (assertFailure "the session handle was not left") (atomically . sessionOutcomeNow)
    map rfCode (take 1 (outFailures found)) `shouldBe` [LuaError]
    fmap eeCode (erPrimary (outEngine found)) `shouldBe` Just LuaError

  it "raises the output failure after a texture handle was published to the script, with the texture the engine's, released exactly once, and no false retirement" $ do
    -- The handle is the script's the moment it takes the result; the lease that owns the texture was registered in the host's
    -- lease scope before that (Requirement 7's order), so the sink's failure, raised on the very line that prints it, finds the
    -- texture owned and releases it once: one allocation, one release attempt, one release, and none for anything else.
    (raised, logged) ←
      runFacadeLogged ((defaultShape sinkFailsAfterTake) {shapeBoth = False, shapeSinkFails = True}) $ \fs →
        atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    case raised of
      Left failure → fromException failure `shouldSatisfy` (\found → case found of Just OutputFailure {} → True; Nothing → False)
      Right outcome → expectationFailure ("expected the output failure, found " <> show (outVerdict outcome))
    length (filter (Text.isPrefixOf "allocated ") logged) `shouldBe` 1
    length (filter (Text.isPrefixOf "release attempted") logged) `shouldBe` 1
    length (filter (Text.isPrefixOf "released ") logged) `shouldBe` 1

  it "refuses a facade installation whose services break the registration, before any role starts, leaving the pipeline and the provider with nothing" $ do
    ref ← newIORef []
    raised ←
      try @SomeException . void $
        runFacade ((defaultShape twoRequests) {shapeBoth = False, shapeRecord = Just ref, shapeAlter = \services → services {gsTypes = gsTypes services <> gsTypes services}}) $ \_ → pure ()
    case raised of
      Left failure → show failure `shouldSatisfy` Text.isInfixOf "installation" . Text.pack
      Right () → expectationFailure "expected the installation to be refused"
    -- No request was ever made, so nothing native was: no allocation, upload or registration, and no service owner released
    -- (nothing was acquired to release).
    logged ← readIORef ref
    filter (\event → any (`Text.isPrefixOf` event) ["allocated", "upload", "registered", "release"]) logged `shouldBe` []

  it "settles a window request the provider's invalidation overtakes while the host holds its adoption: the window is closed once, retired, and nothing is left" $ do
    entered ← newEmptyMVar
    proceed ← newEmptyMVar
    seen ← newIORef False
    let hooks =
          noProviderHooks
            { hookBeforeAdopt = do
                first ← atomicModifyIORef' seen (\held → (True, not held))
                if first then putMVar entered () >> readMVar proceed else pure ()
            }
    outcome ← runFacade ((defaultShape cancelClaimed) {shapeBoth = False, shapeProviderHooks = hooks}) $ \fs → do
      -- The window is created and attached, the host claimed the adoption recipe and the example holds it there. The provider
      -- is invalidated meanwhile (the session-stop action ends every window), and then the recipe is let go.
      takeMVar entered
      endWindows (fsProvider fs)
      putMVar proceed ()
      atomically (providerReading (fsProvider fs) >>= \found → unless (readingAcquisitions found == 0) retry)
      closes ← length . filter (Text.isPrefixOf "close w") <$> WF.events (fsWindows fs)
      closes `shouldBe` 1
      requestStop (fsSession fs) StopQuit
    outRetired outcome `shouldBe` True

  it "raises the device's fault as an engine failure, never a content failure, with the window retired and no native work left" $ do
    (raised, logged) ←
      runFacadeLogged ((defaultShape twoRequests) {shapeBoth = False, shapeInject = [Fake.FailAllocate (FaultFatal "the device was lost")]}) $ \fs →
        atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    case raised of
      Left failure → show failure `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack
      Right outcome → expectationFailure ("expected the engine failure to be raised, found " <> show (outVerdict outcome))
    -- Nothing was allocated for the failed request.
    length (filter (Text.isPrefixOf "allocated") logged) `shouldBe` 0

  it "refuses a second window request of an instance as an ordinary error, caught, with the first window unharmed" $ do
    outcome ← runFacade ((defaultShape secondWindow) {shapeBoth = False}) $ \fs → do
      awaitLine fs "second\tfalse\ttrue"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "answers a repeated texture release retiring and then already_released, without repeating the cleanup" $ do
    outcome ← runFacade ((defaultShape repeatedRelease) {shapeBoth = False, shapeTexture = Fake.defaultFakeConfig {Fake.fcInitialHolds = [Fake.HoldReclaim]}}) $ \fs → do
      awaitLine fs "release\tretiring"
      releasedCount fs >>= (`shouldSatisfy` (<= 1))
      Fake.release (rigFake (fsRig fs)) Fake.HoldReclaim
      awaitLine fs "release\talready_released"
      releasedCount fs `shouldReturn` 1
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "refuses new acquisition after quit in the same segment while quit stays idempotent, and the session still ends as a quit" $ do
    outcome ← runFacade ((defaultShape afterQuit) {shapeBoth = False}) $ \fs → awaitLine fs "after\tfalse\tfalse\ttrue\ttrue"
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "delivers an optional missing texture as structured data with its root and path, and leaves the instance healthy" $ do
    outcome ← runFacade ((defaultShape missingOptional) {shapeBoth = False}) $ \fs → do
      awaitLine fs "missing\tfailure\tnot_found\tgraphics-test\tnope.png\ttrue"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "latches a required missing texture as required_request even though the script never polls it" $ do
    outcome ← runFacade ((defaultShape missingRequired) {shapeBoth = False}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]

-- | How many native releases of a table handle the texture owner ran.
releasedCount ∷ FS → IO Int
releasedCount fs = length . filter (Text.isPrefixOf "released ") <$> Fake.events (rigFake (fsRig fs))

-- | Block until the roles printed exactly this line.
awaitLine ∷ FS → Text → IO ()
awaitLine fs wanted = atomically $ do
  seen ← readTVar (fsOut fs)
  unless (wanted `elem` seen) retry

-- | The quad example's published scene, exactly: the sprite's rectangle, the texture it names (the one decoded from the
-- fixture, 2 by 2) and the clear colour the sRGB bytes (24, 24, 24) convert to.
expectQuad ∷ GraphicsScene → Expectation
expectQuad scene = do
  sceneClear content `shouldSatisfy` isClear 24 24 24
  case sceneSprites content of
    [sprite] → do
      spriteRect sprite `shouldBe` SceneRect 32 32 256 256
      let view = useView (spriteTexture sprite)
      (viewWidth view, viewHeight view) `shouldBe` (2, 2)
      graphicsReferences scene `shouldBe` Set.singleton (viewIdentity view)
    other → expectationFailure ("expected one sprite, found " <> show (length other))
  where
    content = graphicsContent scene

-- | The same injection with its services altered.
alterInjection ∷ (GraphicsServices → GraphicsServices) → GraphicsInjection → GraphicsInjection
alterInjection change (GraphicsInjection make) = GraphicsInjection (fmap change . make)

-- | The host model's key of the session's first window (the provider issues even tokens).
firstWindow ∷ Int
firstWindow = 2

awaitPublished ∷ FS → Word64 → IO ()
awaitPublished fs revision = awaitRevision (fsModel fs) firstWindow (fromIntegral revision)

-- | Run the real session on this thread, and a scenario on another that is handed the session as soon as it exists. If the
-- scenario raises it stops the session, and the exception is raised here once the session has ended and the scenario's
-- thread has terminated: a failed assertion in it is never swallowed.
runFacade ∷ Shape → (FS → IO ()) → IO SessionOutcome
runFacade shape scenario = runFacadeEither shape scenario >>= either throwIO pure

-- | The same, answering what the example raised (the session's call, or a scope it ran in) instead of raising it, so that the rig's
-- check that no native work was left runs before the example sees the exception.
runFacadeEither ∷ Shape → (FS → IO ()) → IO (Either SomeException SessionOutcome)
runFacadeEither shape scenario = fst <$> runFacadeLogged shape scenario

-- | The same, with what the fake texture owner recorded.
runFacadeLogged ∷ Shape → (FS → IO ()) → IO (Either SomeException SessionOutcome, [Text])
runFacadeLogged shape scenario = (\(result, logged, _) → (result, logged)) <$> runFacadeObserved shape scenario

-- | The same, with the work the backend's pump and the fake owner did by site (see "Test.LuaEngine.Graphics.Work"), read once the
-- session has ended and nothing is left for either to do.
runFacadeObserved ∷ Shape → (FS → IO ()) → IO (Either SomeException SessionOutcome, [Text], WorkReading)
runFacadeObserved shape scenario = bounded . withRig (shapeTexture shape) $ \rig → do
  result ← try @SomeException (runCore rig shape scenario)
  logged ← Fake.events (rigFake rig)
  forM_ (shapeRecord shape) (\ref → writeIORef ref logged)
  work ← readWork (Fake.fakeWork (rigFake rig))
  pure (result, logged, work)

runCore ∷ Rig → Shape → (FS → IO ()) → IO SessionOutcome
runCore rig shape scenario = do
  let fake = rigFake rig
  forM_ (shapeInject shape) (Fake.inject fake)
  model ← newModel (fakeLedger fake)
  setBarrier fake (modelCapture model)
  forM_ [1 .. 8] (modelWindow model)
  windows ← WF.newFake (shapeWindow shape)
  unless (null (shapeCreateScript shape)) (WF.scriptCreate windows (shapeCreateScript shape))
  textures ← newTextures
  sessionRef ← newIORef (Nothing ∷ Maybe Session)
  let config =
        WindowConfig
          { windowRecords = 2
          , windowStop = readIORef sessionRef >>= mapM_ (\found → requestStop found StopQuit)
          , windowFatal = \failure →
              readIORef sessionRef >>= mapM_ (\found → void (latchTerminalFailure found (newRoleFailure HostFailure OnEngine Presentation (fatalText failure))))
          }
      files =
        [ ("hetoimasia.json", manifestFor (shapeBoth shape))
        , ("lua/main.lua", shapeEntry shape)
        , ("images/quad.png", Png.solid 2 2 (200, 100, 50, 255))
        ]
          <> shapeFiles shape
  withComposition (shapeProfile shape) files (rigPort rig) $ \composition control runtime →
    withWindowProviderWith (shapeProviderHooks shape) config (retarget (WF.fakePort windows)) $ \provider →
      ( do
          let publisher = scenePublisherOver textures provider (\window scene → fst (modelTarget model window) scene) (\window → snd (modelTarget model window))
              injection = alterInjection (shapeAlter shape) (graphicsInjection (GraphicsFacade (shapeProfile shape) (cpPipeline composition) provider publisher (shapeHooks shape) defaultIssuedMemory Nothing))
          checkpoint ← bootCheckpoint (shapeProfile shape) (cpInventory composition) (\_ _ → pure (Right (manifestFor (shapeBoth shape)))) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
          outLines ← newTVarIO []
          errLines ← newTVarIO []
          gate ← newEmptyMVar
          firstLine ← newIORef True
          let outSink =
                OutputSink
                  { sinkLine = \line → do
                      atomically (modifyTVar' outLines (<> [line]))
                      first ← readIORef firstLine
                      writeIORef firstLine False
                      if first && shapeSinkFails shape then ioError (userError "the authored output sink failed") else pure ()
                      if first && shapeParkOutput shape then readMVar gate else pure ()
                  , sinkFlush = pure ()
                  }
              errSink = OutputSink {sinkLine = \line → atomically (modifyTVar' errLines (<> [line])), sinkFlush = pure ()}
          withOutput outSink errSink $ \output → do
            handle ← newEmptyMVar
            result ← newEmptyMVar
            let scenarioAction =
                  ( do
                      found ← readMVar handle
                      writeIORef sessionRef (Just found)
                      forM_ (shapeSession shape) (\ref → writeIORef ref (Just found))
                      let fs = FS found rig windows model provider outLines gate (cpPipeline composition)
                      attempted ←
                        try @SomeException $
                          timeout 8000000 (scenario fs) >>= \case
                            Just () → pure ()
                            Nothing → do
                              status ← atomically (sessionStatus found)
                              seen ← Fake.events (rigFake rig)
                              windowEvents ← WF.events windows
                              printed ← readTVarIO outLines
                              warned ← readTVarIO errLines
                              assertFailure ("the scenario did not finish: " <> show status <> "\ntexture: " <> show seen <> "\nwindows: " <> show windowEvents <> "\nout: " <> show printed <> "\nerr: " <> show warned)
                      case attempted of
                        Left _ → requestStop found StopQuit
                        Right () → pure ()
                      -- Every adoption the host model holds is released, so that the texture an adopted scene retained can
                      -- retire and the roles with it: the host's ledger is the model's.
                      dissolve model
                      putMVar result attempted
                  )
            let sessionSpec =
                  SessionSpec
                    { sxProfile = shapeProfile shape
                    , sxCheckpoint = checkpoint
                    , sxInventory = cpInventory composition
                    , sxPool = cpPool composition
                    , sxLogger = quietLogger
                    , sxOutput = output
                    , sxClock = monotonicSource
                    , sxTimer = systemTimerBackend
                    , sxRuntime = runtime
                    , sxControl = control
                    , sxHarness = noHarness
                    , sxGraphics = Just injection
                    , sxTerrain = Nothing
                    }
            -- Both threads are owned by the call (#599). The main-step loop supplies what the session's exit needs (the windows'
            -- steps), so its scope encloses the session's run and is ended and joined after it; the scenario's thread is let
            -- go of what it may be held at (the output gate, the fake windows) first however the call ends.
            let letGo = void (tryPutMVar gate ()) >> WF.releaseAll windows
            withOwnedThread (forever (mainStep provider)) $ \_ _ →
              withOwnedThreadOpening letGo scenarioAction $ \_ terminated → do
                outcome ← runSession sessionSpec (putMVar handle) `finally` letGo
                terminated
                takeMVar result >>= either throwIO (const (pure outcome))
      )
        `finally` (WF.releaseAll windows >> dissolve model >> endWindows provider)

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | One turn of the owner loop's main-thread step, once the provider has something for the main thread.
mainStep ∷ WindowProvider Int → IO ()
mainStep provider = do
  atomically (windowMainReady provider >>= \ready → unless ready retry)
  windowMainStep provider

-- | The window fake's port, yielding the window's token number as its capability.
retarget ∷ Port () → Port Int
retarget port =
  Port
    { portIssueCreate = portIssueCreate port
    , portCreateOutcome = portCreateOutcome port
    , portAttach = portAttach port
    , portStanding = portStanding port
    , portCloseRequest = portCloseRequest port
    , portBeginClose = portBeginClose port
    , portRetirement = portRetirement port
    , portTarget = \token@(WindowToken number) → fmap (fmap (const (fromIntegral number))) (portTarget port token)
    , portOwnerFailure = portOwnerFailure port
    , portQueueRoom = portQueueRoom port
    , portWakeMain = portWakeMain port
    }

presentationOnly ∷ [Text] → ByteString
presentationOnly body =
  Text.encodeUtf8 . Text.unlines $
    ["return {", "  presentation = {", "    every_seconds=0.02,"] <> body <> ["  }", "}"]

-- | A window requested in init and never read.
unreadOpen ∷ ByteString
unreadOpen =
  presentationOnly
    [ "    init=function(self, api) self.request = api.window.open({title=\"t\", width=640, height=480}) end,"
    , "    update=function(self, dt) end"
    ]

-- | A window whose failure the role takes and then raises an error over, which it catches. The role parks in its
-- authored output first, so that the refusal settles while the invocation runs.
caughtOpen ∷ ByteString
caughtOpen =
  presentationOnly
    [ "    init=function(self, api)"
    , "      local request = api.window.open({title=\"t\", width=640, height=480})"
    , "      print(\"parked\")"
    , "      assert(api.request.ready(request), 'the refusal had settled')"
    , "      local result = api.request.take(request)"
    , "      local ok = pcall(function()"
    , "        assert(result.status == 'failure' and result.error.code == 'window_error')"
    , "        error(result.error.message)"
    , "      end)"
    , "      print('caught', ok, result.error.code, result.error.root == nil, result.error.path == nil, result.error.message)"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A window whose failure the update takes and raises uncaught, the shape of the shipped content's own @collect@. The
-- update parks in its authored output first, so that the refusal settles while the invocation runs.
raisedOpen ∷ ByteString
raisedOpen =
  presentationOnly
    [ "    init=function(self, api) self.request = api.window.open({title=\"t\", width=640, height=480}) end,"
    , "    update=function(self, dt)"
    , "      if self.raised then return end"
    , "      self.raised = true"
    , "      local api = self.api"
    , "      print(\"parked\")"
    , "      assert(api.request.ready(self.request), 'the refusal had settled')"
    , "      local result = api.request.take(self.request)"
    , "      error(result.error.message)"
    , "    end"
    ]

-- | A window requested in init, which then parks in its authored output: the startup gate stays closed.
parkedOpen ∷ ByteString
parkedOpen =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.request = api.window.open({title=\"t\", width=640, height=480})"
    , "      print(\"parked\")"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A second window request while the first is pending: an ordinary error a script catches.
secondWindow ∷ ByteString
secondWindow =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.first = api.window.open({title='a', width=64, height=64})"
    , "      local ok, err = pcall(api.window.open, {title='b', width=64, height=64})"
    , "      print('second', ok, tostring(err):find('already has a window') ~= nil)"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | Three textures of one file under three requests (colour by default, data, and data with a checked normal encoding),
-- and the one incompatible combination, which is an ordinary error.
imageKinds ∷ ByteString
imageKinds =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.c = api.content.texture('images/normals.png')"
    , "      self.d = api.content.texture('images/normals.png', {kind = 'data'})"
    , "      self.n = api.content.texture('images/normals.png', {kind = 'data', normal_encoding = 'unit-normal-rgb-v1'})"
    , "      local ok, e = pcall(api.content.texture, 'images/normals.png', {normal_encoding = 'unit-normal-rgb-v1'})"
    , "      print('combination', ok, tostring(e):find('valid only with kind') ~= nil)"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done then return end"
    , "      if api.request.ready(self.c) and api.request.ready(self.d) and api.request.ready(self.n) then"
    , "        local a, b, c = api.request.take(self.c), api.request.take(self.d), api.request.take(self.n)"
    , "        self.done = true"
    , "        print('taken', (a.status == 'success' and 1 or 0) + (b.status == 'success' and 1 or 0) + (c.status == 'success' and 1 or 0))"
    , "      end"
    , "    end"
    ]

-- | A texture taken and released on every update: the answer changes as the retirement proceeds.
repeatedRelease ∷ ByteString
repeatedRelease =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('images/quad.png') end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not self.tex then"
    , "        if not api.request.ready(self.t) then return end"
    , "        self.tex = api.request.take(self.t).value.texture"
    , "      end"
    , "      local answer = api.texture.release(self.tex)"
    , "      if answer ~= self.last then self.last = answer print('release', answer) end"
    , "    end"
    ]

-- | Quit, then statements in the same segment: acquisition is refused as ordinary errors, a second quit changes nothing.
afterQuit ∷ ByteString
afterQuit =
  presentationOnly
    [ "    init=function(self, api) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done then return end"
    , "      self.done = true"
    , "      api.session.quit()"
    , "      api.session.quit()"
    , "      local ok1, e1 = pcall(api.content.texture, 'images/quad.png')"
    , "      local ok2, e2 = pcall(api.window.open, {title='t', width=1, height=1})"
    , "      print('after', ok1, ok2, tostring(e1):find('stopping') ~= nil, tostring(e2):find('stopping') ~= nil)"
    , "    end"
    ]

-- | An optional texture the content does not hold: its failure is data.
missingOptional ∷ ByteString
missingOptional =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('nope.png', {optional = true}) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done or not api.request.ready(self.t) then return end"
    , "      self.done = true"
    , "      local r = api.request.take(self.t)"
    , "      print('missing', r.status, r.error.code, r.error.root, r.error.path, r.value == nil)"
    , "    end"
    ]

-- | A required texture the content does not hold, which the script never reads.
missingRequired ∷ ByteString
missingRequired =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('nope.png') end,"
    , "    update=function(self, dt) end"
    ]

-- | Two publications; the second is the one a stop overtakes.
publishRace ∷ ByteString
publishRace =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
    , "      if not self.img and api.request.ready(self.t) then self.img = api.request.take(self.t).value end"
    , "      if not (self.win and self.img) then return end"
    , "      if not self.a then"
    , "        self.a = true"
    , "        api.scene.publish(self.win, {clear={r=24,g=24,b=24}, sprites={{texture=self.img.texture, x=1, y=2, width=3, height=4}}})"
    , "        print('first')"
    , "        return"
    , "      end"
    , "      if not self.b then"
    , "        self.b = true"
    , "        local ok, err = pcall(api.scene.publish, self.win, {clear={r=1,g=2,b=3}, sprites={}})"
    , "        print('second', ok, tostring(err):find('scene publication is stopped') ~= nil)"
    , "      end"
    , "    end"
    ]

-- | A profile of two textures' bytes: the third request finds the bank full while a window is accepted.
textureBank ∷ ByteString
textureBank =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.t1 = api.content.texture('images/quad.png')"
    , "      self.t2 = api.content.texture('images/quad.png')"
    , "      local t3, e = api.content.texture('images/quad.png')"
    , "      local w, we = api.window.open({title='w', width=64, height=64})"
    , "      print('banks', t3 == nil, e and e.code, w ~= nil, we == nil)"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.retried then return end"
    , "      if not self.tex then"
    , "        if not api.request.ready(self.t1) then return end"
    , "        self.tex = api.request.take(self.t1).value.texture"
    , "      end"
    , "      -- Release until the retirement is proven: only then is the slot back."
    , "      if api.texture.release(self.tex) == 'already_released' then"
    , "        self.retried = true"
    , "        local t4, e4 = api.content.texture('images/quad.png')"
    , "        print('retry', t4 ~= nil, e4 == nil)"
    , "      end"
    , "    end"
    ]

-- | Two textures taken and kept, and a window request in hand: its lease is held while the third texture request, with the
-- bank full, is refused. The refusal must name the texture bytes and not the lease capacity.
heldWindowBank ∷ ByteString
heldWindowBank =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.t1 = api.content.texture('images/quad.png')"
    , "      self.t2 = api.content.texture('images/quad.png')"
    , "      self.w = api.window.open({title='w', width=64, height=64})"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done then return end"
    , "      if not self.tex1 then"
    , "        if not api.request.ready(self.t1) then return end"
    , "        self.tex1 = api.request.take(self.t1).value.texture"
    , "      end"
    , "      if not self.tex2 then"
    , "        if not api.request.ready(self.t2) then return end"
    , "        self.tex2 = api.request.take(self.t2).value.texture"
    , "      end"
    , "      self.done = true"
    , "      local r, e = api.content.texture('images/quad.png')"
    , "      print('bound', r == nil and e.code, r == nil and e.message:find('texture bytes', 1, true) ~= nil, r == nil and e.message:find('lease', 1, true) == nil)"
    , "    end"
    ]

-- | A count of textures of one pixel (the thousand of the example, or fewer), each requested as the places allow, taken when
-- ready and held; only when all are held does the role print (and park there), and then it releases every one.
pixelsOf ∷ Int → ByteString
pixelsOf count =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.reqs = {}"
    , "      self.held = {}"
    , "      self.started = 0"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done then return end"
    , "      local rest = {}"
    , "      for _, r in ipairs(self.reqs) do"
    , "        if api.request.ready(r) then"
    , "          local result = api.request.take(r)"
    , "          if result.status ~= 'success' then print('failed', result.status) self.done = true return end"
    , "          self.held[#self.held + 1] = result.value.texture"
    , "        else"
    , "          rest[#rest + 1] = r"
    , "        end"
    , "      end"
    , "      self.reqs = rest"
    , "      while self.started < " <> total <> " do"
    , "        local r, e = api.content.texture('images/pixel.png')"
    , "        if r == nil then"
    , "          if e.code ~= 'busy' then print('refused', e.code, e.message) self.done = true return end"
    , "          break"
    , "        end"
    , "        self.reqs[#self.reqs + 1] = r"
    , "        self.started = self.started + 1"
    , "      end"
    , "      if #self.held == " <> total <> " then"
    , "        self.done = true"
    , "        print('held', #self.held)"
    , "        local released = 0"
    , "        for _, t in ipairs(self.held) do"
    , "          local answer = api.texture.release(t)"
    , "          if answer == 'done' or answer == 'retiring' then released = released + 1 end"
    , "        end"
    , "        print('released', released)"
    , "      end"
    , "    end"
    ]
  where
    total = Text.pack (show count)

-- | An instance that retains this many one-pixel textures at once. The fake owner's table and image allowance have room for them
-- (and a few more): the example sizes them, as the native table's capacity is derived from the bytes.
pixelShape ∷ Int → Shape
pixelShape count =
  (defaultShape (pixelsOf count))
    { shapeBoth = False
    , shapeParkOutput = True
    , shapeTexture = Fake.defaultFakeConfig {Fake.fcSlots = fromIntegral count + 24, Fake.fcImages = count + 24}
    , shapeFiles = [("images/pixel.png", Png.solid 1 1 (10, 20, 30, 255))]
    }

-- | What 'pixelShape' of this count proves: all are held and each is charged the 4 KiB minimum, one registration for each reached the
-- owner, and every byte comes back after the release.
pixelScenario ∷ Int → FS → IO ()
pixelScenario count fs = do
  -- The role prints nothing until it holds all of them, and parks in the print: they are all held while this reads.
  awaitLine fs (Text.pack ("held\t" <> show count))
  atomically (sessionNominal (fsPipeline fs)) `shouldReturn` fromIntegral count * 4096
  registered ← length . filter (Text.isPrefixOf "registered ") <$> Fake.events (rigFake (fsRig fs))
  registered `shouldBe` count
  void (tryPutMVar (fsGate fs) ())
  awaitLine fs (Text.pack ("released\t" <> show count))
  -- The fake retires what is released; the session's bytes come back to zero.
  atomically (sessionNominal (fsPipeline fs) >>= \held → unless (held == 0) retry)
  requestStop (fsSession fs) StopQuit

-- | A profile of two request places: two texture requests fill them and the window finds no place, its own slot free.
requestBank ∷ ByteString
requestBank =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.t1 = api.content.texture('images/quad.png')"
    , "      self.t2 = api.content.texture('images/quad.png')"
    , "      local w, e = api.window.open({title='w', width=64, height=64})"
    , "      print('window', w == nil, e and e.code)"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.retried then return end"
    , "      if self.t1 then"
    , "        if not api.request.ready(self.t1) then return end"
    , "        api.request.take(self.t1)"
    , "        self.t1 = nil"
    , "      end"
    , "      local w, e = api.window.open({title='w', width=64, height=64})"
    , "      if w then self.retried = true print('retried', true) end"
    , "    end"
    ]

failedInit ∷ ByteString
failedInit =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "      error('init fails after both requests')"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

throwingShutdown ∷ ByteString
throwingShutdown =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.said or not (api.request.ready(self.w) and api.request.ready(self.t)) then return end"
    , "      self.said = true"
    , "      print('ready')"
    , "    end,"
    , "    shutdown=function(self, reason) error('shutdown fails') end"
    ]

cancelAtOnce ∷ ByteString
cancelAtOnce =
  presentationOnly
    [ "    init=function(self, api)"
    , "      local w = api.window.open({title='t', width=64, height=64})"
    , "      local t = api.content.texture('images/quad.png')"
    , "      print('cancel', api.request.cancel(w), api.request.cancel(t))"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A window request cancelled in an update while the provider holds its acceptance.
cancelHeld ∷ ByteString
cancelHeld =
  presentationOnly
    [ "    init=function(self, api) self.w = api.window.open({title='t', width=64, height=64}) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.said then return end"
    , "      self.said = true"
    , "      print('cancel', api.request.cancel(self.w), api.request.take(self.w).status)"
    , "    end"
    ]

-- | Both requests started, then the first authored line raises in the sink.
sinkFails ∷ ByteString
sinkFails =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "      print('both started')"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | Both requests started; the texture's result is taken (its handle is the script's), and the first authored line, printed
-- with it, raises in the sink.
sinkFailsAfterTake ∷ ByteString
sinkFailsAfterTake =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not self.said and api.request.ready(self.t) then"
    , "        self.said = true"
    , "        local taken = api.request.take(self.t)"
    , "        print('taken', taken.status, taken.value.texture ~= nil)"
    , "      end"
    , "    end"
    ]

-- | A texture taken, and then the script's own error: the texture's lease is released when the instance ends, and that
-- cleanup is made to fail, after the primary failure.
releaseFails ∷ ByteString
releaseFails =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('images/quad.png') end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not api.request.ready(self.t) then return end"
    , "      local tex = api.request.take(self.t).value.texture"
    , "      error('the script failed first')"
    , "    end"
    ]

twoRequests ∷ ByteString
twoRequests =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A window opened and never looked at again: the host's adoption of it is what the example holds.
cancelClaimed ∷ ByteString
cancelClaimed =
  presentationOnly
    [ "    init=function(self, api) self.w = api.window.open({title='t', width=64, height=64}) end,"
    , "    update=function(self, dt) end"
    ]
