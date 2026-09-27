-- | The native Wayland evidence: every required case of the Wayland
-- qualification design's D-12 matrix, on the isolated headless compositor.
--
-- This tree is the whole Wayland selection. The catalog's @test.glfw-wayland@
-- group names exactly it, and @tools/display/wayland.sh@ runs it with the
-- consent @isolated-wayland:<socket>@, under which the shared session requests
-- Wayland by name and must select it. Every example is listed on every
-- platform, so a dry run names them and a macOS run lists them without
-- acquiring anything, but each runs only under that consent: an X11 or Cocoa
-- run reaches the hook and reports it pending, never asserting Wayland against
-- the session it actually has. Under the Wayland consent nothing here is
-- skipped or reported as unperformed; a case that cannot run fails.
--
-- The cases that need a session the shared fixture cannot host run in bounded
-- private children ("Test.GLFW.Native.Private",
-- "Test.GLFW.Native.WaylandScenarios"): the default request with no X11
-- display, the Wayland request in an X11-only environment (under
-- @tools/display/x11.sh@ itself), the traced unsupported operations, shutdown,
-- failure cleanup, every connection-loss situation, each of which ends a
-- compositor of the child's own and never the one this run's consent names,
-- and the settle against a compositor of the child's own that it pauses.
-- The compiled-support rejection has no native form here: a prefix built with
-- Wayland cannot be asked to lack it, so the seam proves it in @glfw-tests@.
--
-- The two X11 test-check drivers are unavailable on Wayland (D-9), and the
-- helpers example asserts exactly that. Nothing else here depends on them, and
-- neither counts as Wayland pass evidence.
module Test.GLFW.Native.Wayland (spec) where

import Control.Monad (void)
import GHC.Clock (getMonotonicTime)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Native
  ( requestCloseForCheck
  , sizeLimitsForCheck
  , takeLastWaitForCheck
  , takeWaitNotedForCheck
  , wakeCountsForCheck
  , windowSizeForCheck
  , windowTitleForCheck
  )
import Hetoimasia.GLFW.Internal.Window (EventProcessing (AwaitEventsFor), processWindowEvents, windowNativeHandle)
import Hetoimasia.GLFW.Session
  ( Backend (Wayland)
  , Session
  , reportedErrors
  , sessionBackend
  , takeAsynchronousReports
  )
import Hetoimasia.GLFW.Window
import Numeric.Natural (Natural)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, stdout)
import Test.GLFW.Native.Consent (Consent (IsolatedWayland), waylandValue)
import Test.GLFW.Native.Control (converge, returnedWithRevision, showAndRelease, withTwo)
import Test.GLFW.Native.Host (testCloseOrder)
import Test.GLFW.Native.Private
  ( Launched (..)
  , childDeadline
  , launchCommand
  , launchWith
  , privateScenarioReporting
  , privateSessionFlag
  )
import Test.GLFW.Native.Support (Gate, Shared (..), acquisitions, currentObservation, failed, gateConsent, owned)
import qualified Test.GLFW.Native.Wake as Wake
import Test.Hspec (Spec, SpecWith, before_, describe, it, pendingWith, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "on an isolated Wayland session" . onlyWayland gate $ do
  describe "backend selection" $ do
    it "enters native Wayland when a session requests it, on the isolated compositor's own socket" $ do
      socket ← authorizedSocket gate
      owned shared (pure . sessionBackend) `shouldReturn` Wayland
      lookupEnv "WAYLAND_DISPLAY" `shouldReturn` Just socket
      lookupEnv "DISPLAY" `shouldReturn` Nothing

    it "still selects X11 for a session that requests nothing, whose initialization then fails for want of an X11 display" $
      privateScenarioReporting gate "wayland-default-x11"

    it "fails a Wayland request under the isolated X11 helper for want of a Wayland connection" $
      underX11Helper gate "wayland-without-compositor"

  describe "independent window lifetimes" $ do
    it "closes the first of two windows and then the second, each closure retiring only its own window while the session and the other stay usable" $
      testCloseOrder shared [0, 1]

    it "closes the second of two windows and then the first, each closure retiring only its own window while the session and the other stay usable" $
      testCloseOrder shared [1, 0]

  describe "supported controls and observations" $ do
    it "settles a title and a size, each observed as the native boundary reports it" $ do
      (dispositions, facts) ←
        owned shared $ \session →
          withTwo session $ \perform window _ → do
            let target = windowIdentity window
                handle = windowNativeHandle window
            dispositions ←
              mapM perform [setWindowTitleCommand target "renamed on wayland", setWindowSizeCommand target (Extent 300 200)]
            facts ←
              converge window $ \observation → do
                title ← windowTitleForCheck handle
                size ← windowSizeForCheck handle
                let seen = (title, size, observedLogicalExtent observation)
                pure (seen == (Just "renamed on wayland", (300, 200), Observed (Extent 300 200)), seen)
            pure (dispositions, facts)
      dispositions `shouldSatisfy` all returnedWithRevision
      facts `shouldBe` (Just "renamed on wayland", (300, 200), Observed (Extent 300 200))

    it "reflects showing and then hiding a window in its visibility observations" $ do
      (shown, hidden) ←
        owned shared $ \session →
          withTwo session $ \perform window _ → do
            let target = windowIdentity window
            void (perform (showWindowCommand target))
            shown ← converge window (\observation → pure (observedVisible observation == Observed True, observedVisible observation))
            void (perform (hideWindowCommand target))
            hidden ← converge window (\observation → pure (observedVisible observation == Observed False, observedVisible observation))
            pure (shown, hidden)
      shown `shouldBe` Observed True
      hidden `shouldBe` Observed False

    -- Command delivery and the engine's own constraint handling only: xdg-shell
    -- lets the compositor disregard requested limits, and a client cannot read
    -- them back (D-9), so neither is asserted.
    it "delivers size limits and refuses an out-of-constraint size engine-side, reading nothing back from the compositor" $ do
      (installed, refused, inside) ←
        owned shared $ \session →
          withTwo session $ \perform window _ → do
            let target = windowIdentity window
            installed ← perform (setSizeConstraintsCommand target (sizeConstraints (Extent 200 150) (Extent 400 300) Nothing))
            refused ← perform (setWindowSizeCommand target (Extent 1000 1000))
            inside ← perform (setWindowSizeCommand target (Extent 350 250))
            pure (installed, refused, inside)
      installed `shouldSatisfy` returnedWithRevision
      refused `shouldSatisfy` \case
        Rejected (ControlRejected _ (SizeOutsideConstraints (Extent 1000 1000) _)) → True
        _ → False
      inside `shouldSatisfy` returnedWithRevision

    -- Content scale is sampled, never requested. The one change claimed is the
    -- one the example induces: its own resize, which the framebuffer extent
    -- must follow at the sampled scale.
    it "samples framebuffer extent and content scale as observations, and the framebuffer follows a resize the example induced" $ do
      (before, after) ←
        owned shared $ \session →
          withTwo session $ \perform window _ → do
            before ← currentObservation window
            _ ← perform (setWindowSizeCommand (windowIdentity window) (Extent 280 210))
            after ←
              converge window $ \observation →
                pure (observedLogicalExtent observation == Observed (Extent 280 210) && framebufferFollows observation, observation)
            pure (before, after)
      putStrLn
        ( "glfw-native-tests wayland observations: before "
            <> describeSample before
            <> "; after the induced resize "
            <> describeSample after
        )
      hFlush stdout
      mapM_
        ( \observation → do
            observedContentScale observation `shouldSatisfy` \case
              Observed (ContentScale x y) → x > 0 && y > 0
              Unavailable → False
            observedFramebufferExtent observation `shouldSatisfy` \case
              Observed (Extent width height) → width > 0 && height > 0
              Unavailable → False
        )
        [before, after]
      observedLogicalExtent after `shouldBe` Observed (Extent 280 210)
      framebufferFollows after `shouldBe` True

  describe "explicit unsupported outcomes" $
    it "answers placement, focus, and borderless requests unsupported and placement and iconified observations unavailable, invoking none of their native operations or getters" $
      privateScenarioReporting gate "wayland-unsupported"

  -- The wake examples below begin from a settled connection. These two show
  -- what settling must absorb on Wayland: the compositor's answer to an earlier
  -- example's shown and released window, which GLFW queues and sends only at
  -- the next event processing, and which can arrive after a pending-events poll
  -- has returned. Showing matters: releasing a window that was shown detaches
  -- the buffer its fallback decorations held, and the compositor posts that
  -- buffer's release, carrying the delete_id it queued for every destroyed
  -- object. Releasing a window that was never shown posts nothing.
  describe "settling before a wait" $ do
    it "settles a shown and released window's cleanup, so the next production wait nothing wakes reaches its bound" $ do
      evidence ← owned shared $ \session → do
        showAndRelease session
        beforeSettle ← wakeCountsForCheck
        Wake.settle session
        afterSettle ← wakeCountsForCheck
        unwokenWait session beforeSettle afterSettle
      unwokenLine "settled cleanup" evidence
      unwokenWakeCounts evidence `shouldSatisfy` allEqual
      unwokenReturned evidence `shouldSatisfy` (> unwokenFloor evidence)
      unwokenWoken evidence `shouldBe` False
      unwokenNoted evidence `shouldBe` False
      unwokenSeconds evidence `shouldSatisfy` (>= unwokenBound)

    -- Whether the compositor answers before or after the pending-events poll
    -- is a race in the example above. Here it is not: a child pauses a
    -- compositor of its own before settling, and resumes it only once it has
    -- observed the owner blocked, so the answer cannot arrive before the
    -- settle blocks. A settle that only processed pending events would block
    -- first in the unwoken wait, and the answer would end that wait.
    it "settles that cleanup against a compositor that answers only once the owner has blocked, in a private child" $
      privateScenarioReporting gate "wayland-settle"

  Wake.spec shared

  describe "shutdown" $
    it "fully leaves one Wayland session and enters another in a private child, while the parent's shared session serves on" $ do
      privateScenarioReporting gate "session-lifecycle"
      owned shared (pure . sessionBackend) `shouldReturn` Wayland
      acquisitions shared `shouldReturn` 1

  describe "failure cleanup" $
    it "keeps forced and injected failures primary with their cleanup evidence, leaves nothing registered, and acquires again" $
      privateScenarioReporting gate "wayland-failure-cleanup"

  describe "connection loss, each in a child that ends a compositor of its own" $ do
    it "confirms the loss at an event boundary while injected close requests are rejected and pending, and the session is terminal" $
      privateScenarioReporting gate "connection-loss-pending-close"

    it "confirms the loss of a session with no window at an event boundary, and the session is terminal" $
      privateScenarioReporting gate "connection-loss-no-windows"

    it "confirms a loss that happens while the owner is inside a native wait, after that wait returns, and the session is terminal" $
      privateScenarioReporting gate "connection-loss-in-wait"

    it "does not mistake an injected close request on a healthy connection for loss, keeping the compositor and the session" $
      privateScenarioReporting gate "connection-healthy-close"

  -- D-9's check on the backend it is about. Both drivers reach a window
  -- through a Cocoa or X11 handle, so on Wayland each must answer unavailable,
  -- and must do so without asking GLFW for a handle it would refuse: a
  -- GLFW_PLATFORM_UNAVAILABLE from glfwGetX11Display is captured on the owner
  -- thread, and takeAsynchronousReports settles exactly those strays. Reports
  -- are taken once before the two calls, so what the second take returns is
  -- the drivers' own contribution and nothing else.
  describe "test-check helpers" $
    it "answers both X11 test-check helpers unavailable, leaving no GLFW report" $ do
      (closed, limits, reports) ←
        owned shared $ \session →
          withWindow session (hiddenTestWindowConfig "wayland helper check" 200 150) $ \window → do
            let handle = windowNativeHandle window
            _ ← takeAsynchronousReports session
            closed ← requestCloseForCheck handle
            limits ← sizeLimitsForCheck handle
            reports ← takeAsynchronousReports session
            pure (closed, limits, reports)
      closed `shouldBe` False
      limits `shouldBe` Nothing
      reportedErrors reports `shouldBe` []
  where
    gate = sharedGate shared

-- | Run these examples only under the isolated Wayland consent; under any other
-- consent each is pending, and says which command supplies that consent.
onlyWayland ∷ Gate → SpecWith a → SpecWith a
onlyWayland gate = before_ $ case gateConsent gate of
  Right (IsolatedWayland _) → pure ()
  _ →
    pendingWith
      ( "this run carries no isolated Wayland consent; `bash tools/display/wayland.sh -- <command>` supplies "
          <> waylandValue "<socket>"
          <> " for one command"
      )

-- | The socket the run's consent authorized.
authorizedSocket ∷ Gate → IO String
authorizedSocket gate = case gateConsent gate of
  Right (IsolatedWayland socket) → pure socket
  _ → failed "this example runs only under the isolated Wayland consent"

-- | Run a scenario in a bounded child under @tools/display/x11.sh@, which starts
-- an isolated X11 display for it and supplies that display's own consent.
underX11Helper ∷ Gate → String → IO ()
underX11Helper gate = launchWith gate $ \scenario → do
  helper ← repositoryFile ("tools" </> "display" </> "x11.sh")
  executable ← getExecutablePath
  launched ← launchCommand childDeadline "bash" [helper, "--", executable, privateSessionFlag, scenario]
  putStr (launchedOut launched)
  hFlush stdout
  pure launched

-- | A file of this repository, found from the working directory upwards: the
-- suite runs from its package directory, or from the repository's root.
repositoryFile ∷ FilePath → IO FilePath
repositoryFile relative = getCurrentDirectory >>= search
  where
    search directory = do
      let candidate = directory </> relative
      present ← doesFileExist candidate
      if present
        then pure candidate
        else
          if takeDirectory directory == directory
            then failed ("no " <> relative <> " was found above the working directory")
            else search (takeDirectory directory)

-- | Whether the framebuffer extent is the logical extent at the sampled content
-- scale, to the pixel.
framebufferFollows ∷ WindowObservation → Bool
framebufferFollows observation =
  case (observedLogicalExtent observation, observedFramebufferExtent observation, observedContentScale observation) of
    (Observed (Extent width height), Observed (Extent framebufferWidth framebufferHeight), Observed (ContentScale x y)) →
      close framebufferWidth width x && close framebufferHeight height y
    _ → False
  where
    close framebuffer logical scale = abs (fromIntegral framebuffer - fromIntegral logical * scale) <= (1 ∷ Float)

describeSample ∷ WindowObservation → String
describeSample observation =
  "logical "
    <> show (observedLogicalExtent observation)
    <> ", framebuffer "
    <> show (observedFramebufferExtent observation)
    <> ", content scale "
    <> show (observedContentScale observation)

-- | One production wait that nothing in the example wakes.
data UnwokenWait = UnwokenWait
  { unwokenFloor ∷ Natural
    -- ^ The sequence number of the last wait recorded before this one.
  , unwokenReturned ∷ Natural
    -- ^ The sequence number of the wait that returned.
  , unwokenWoken ∷ Bool
  , unwokenNoted ∷ Bool
  , unwokenSeconds ∷ Double
    -- ^ How long the waiting owner operation took, against 'unwokenBound'.
  , unwokenWakeCounts ∷ [(Natural, Natural)]
    -- ^ The production wake counts before the example's settling or release,
    -- once that was done, and after the wait.
  }

-- | Make one production wait bounded by 'unwokenBound' on the owner thread,
-- with nothing posted to wake it, and read back its record.
unwokenWait ∷ Session → (Natural, Natural) → (Natural, Natural) → IO UnwokenWait
unwokenWait session before settled = do
  (floor', _) ← takeLastWaitForCheck
  started ← getMonotonicTime
  processWindowEvents session (AwaitEventsFor unwokenBound)
  seconds ← subtract started <$> getMonotonicTime
  (returned, woken) ← takeLastWaitForCheck
  noted ← takeWaitNotedForCheck
  after ← wakeCountsForCheck
  pure
    UnwokenWait
      { unwokenFloor = floor'
      , unwokenReturned = returned
      , unwokenWoken = woken
      , unwokenNoted = noted
      , unwokenSeconds = seconds
      , unwokenWakeCounts = [before, settled, after]
      }

-- | The bound on an unwoken wait: long beside a compositor's answer on the same
-- machine, which arrives within milliseconds, and short enough that reaching it
-- costs the run little.
unwokenBound ∷ Double
unwokenBound = 0.5

allEqual ∷ Eq a ⇒ [a] → Bool
allEqual values = and (zipWith (==) values (drop 1 values))

unwokenLine ∷ String → UnwokenWait → IO ()
unwokenLine label evidence = do
  putStrLn
    ( "glfw-native-tests settle evidence: "
        <> label
        <> ": wait "
        <> show (unwokenReturned evidence)
        <> " after wait "
        <> show (unwokenFloor evidence)
        <> " returned "
        <> (if unwokenWoken evidence then "woken" else "unwoken")
        <> (if unwokenNoted evidence then " and noted" else "")
        <> " in "
        <> show (unwokenSeconds evidence)
        <> "s of a "
        <> show unwokenBound
        <> "s bound; production wake counts "
        <> show (unwokenWakeCounts evidence)
    )
  hFlush stdout
