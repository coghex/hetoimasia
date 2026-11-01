{-# LANGUAGE OverloadedStrings #-}

-- | Linux visible-output evidence for the milestone cases: bind a native window to the instance that made it, capture
-- what it presented through the external X11 helper, judge the capture against the fixture's landmarks, and retain the
-- capture with a machine-readable record (LFE-25, #540 requirements 2 to 5).
--
-- Everything here is a no-op returning 'Nothing' where the run has no helper (macOS and any non-isolated session): there
-- is no OS capture on macOS, and its evidence is the owner's confirmation, which no test reads. Where the helper is
-- present every step is required: a window that cannot be bound unambiguously, a capture that is refused, or a landmark
-- that fails is the case's failure, never a skip, and a capture or window-identity outcome is never retried until it
-- passes. The one polled wait is for the external presentation to show the quad (the X server is not observable from
-- here), bounded and recorded with its attempt count; the final image is retained whether or not it passed.
--
-- A capture is evidence of what the native window presented. It is never evidence of GPU retirement.
module Test.Run.Native.Capture
  ( Bound (..)
  , viewableNow
  , bindNew
  , snap
  , snapWith
  , bindChild
  , ownPid
  , closeBound
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (forM_, unless, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Data.Text (Text)
import Hetoimasia.GLFW.Window (WindowId)
import System.Directory (doesFileExist, removeFile, renameFile)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)
import Test.Run.Native.Env (Env (..), evidence)
import Test.Run.Native.Json
import Test.Run.Native.Landmarks
import Test.Run.Native.Observe (Metrics (..), note, requestPosition, windowMetrics, windowsNow)
import Test.Run.Native.Peers (Peers)
import Test.Run.Native.X11 (Candidate (..), Captured (..), Refused (..), X11, candidates, capture, geometry, requestClose, viewableCandidates)

-- | A native window bound to the instance that made it, with the process that owns it.
data Bound = Bound
  { boundHelper ∷ !X11
  , boundPid ∷ !Int
  , boundWindow ∷ !(Maybe WindowId)
  -- ^ The host's window identity for a harness window; none for the actual command's, which is another process.
  , boundX ∷ !Integer
  }

-- | This process's id, as the windows it owns carry it.
ownPid ∷ IO Int
ownPid = fromIntegral <$> getProcessID

-- | The ids of this process's viewable native windows now.
viewableNow ∷ Env → IO [Integer]
viewableNow env = case envX11 env of
  Nothing → pure []
  Just helper → do
    pid ← ownPid
    map candWindow <$> viewableCandidates helper pid

-- | Bind the native window the host just created to its X window: while the creation gates leave it the only window
-- that appeared since @known@, the one new viewable candidate is that instance's. More than one new candidate, or none
-- within the bound, is a failure (the helper never picks); the candidate's size is cross-checked against the geometry
-- the host observed for the window.
bindNew ∷ Env → Peers → WindowId → [Integer] → IO (Maybe Bound)
bindNew env peers window known = case envX11 env of
  Nothing → pure Nothing
  Just helper → do
    pid ← ownPid
    seen ← newIORef ("nothing was seen yet" ∷ String)
    note ("binding host window " <> show window <> " (pid " <> show pid <> "), known X windows " <> show known)
    found ← pollFor "the new window to be viewable on the X display" (readIORef seen) $ do
      everything ← candidates helper pid
      writeIORef seen ("the process owns these InputOutput windows: " <> show [(candWindow c, candMapState c, candWidth c, candHeight c) | c ← everything])
      let now = filter ((== 2) . candMapState) everything
      case filter ((`notElem` known) . candWindow) now of
        [] → pure Nothing
        [one] → pure (Just (Right one))
        several → pure (Just (Left several))
    case found of
      Left several → expectationFailure ("the X windows of pid " <> show pid <> " are ambiguous for host window " <> show window <> ": " <> show (map candWindow several)) >> pure Nothing
      Right one → do
        metrics ← windowMetrics peers window
        when (metricsLogical metrics /= Just (candWidth one, candHeight one)) $
          expectationFailure ("the host observed " <> show (metricsLogical metrics) <> " for window " <> show window <> " but the bound X window " <> show (candWindow one) <> " is " <> show (candWidth one, candHeight one))
        pure (Just (Bound helper pid (Just window) (candWindow one)))

-- | Bind the actual command's native window: the one viewable window its process owns, within the bound. Zero or several
-- viewable windows is a failure; the helper never picks.
bindChild ∷ Env → Int → IO (Maybe Bound)
bindChild env pid = case envX11 env of
  Nothing → pure Nothing
  Just helper → do
    found ← pollFor "the command's window to be viewable on the X display" (pure ("pid " <> show pid)) $ do
      now ← viewableCandidates helper pid
      case now of
        [] → pure Nothing
        [one] → pure (Just (Right one))
        several → pure (Just (Left several))
    case found of
      Left several → expectationFailure ("the command (pid " <> show pid <> ") owns several viewable windows: " <> show (map candWindow several)) >> pure Nothing
      Right one → pure (Just (Bound helper pid Nothing (candWindow one)))

-- | Capture a harness window and require the quad scene's landmarks: 'snapWith' with the host's own metrics beside it.
snap ∷ Env → Peers → Text → Maybe Bound → IO ()
snap _ _ _ Nothing = pure ()
snap env peers name (Just bound) = do
  forM_ (boundWindow bound) (isolate peers)
  metrics ← traverse (windowMetrics peers) (boundWindow bound)
  snapWith env name bound quadLandmarks metrics

-- | Make the subject the only window on its part of the display: an X server without a compositor answers a capture with
-- whatever is on top of the subject's pixels (another window, or a window manager's frame), and two 640 x 480 windows with
-- their frames do not both fit on the isolated 1280 x 1024 display. So the subject is moved to a fixed place and every
-- other window of the process is parked below and to the right, where the subject (even enlarged to 800 x 600) is not.
-- Both are the public, window-system mediated position commands; the capture then waits for the display to show the
-- subject's own pixels, and a landmark that is still wrong after that is a failure.
isolate ∷ Peers → WindowId → IO ()
isolate peers subject = do
  others ← filter (/= subject) <$> windowsNow peers
  forM_ others $ \other → () <$ requestPosition peers other (700, 720)
  () <$ requestPosition peers subject (10, 40)

-- | Capture the bound window's client area, require every landmark, retain the capture and its record under the given
-- name, and say what was presented. The client area is whatever the X server reports now and the landmarks follow its
-- size; the host's own metrics, when there are any (a harness window), are recorded beside it and cross-checked.
snapWith ∷ Env → Text → Bound → ((Int, Int) → [Landmark]) → Maybe Metrics → IO ()
snapWith env name bound landmarksFor metrics = do
  let final = envCaptureDir env </> Text.unpack name <> ".png"
      stage n = envCaptureDir env </> Text.unpack name <> ".attempt" <> show (n ∷ Int) <> ".png"
      loop n previous = do
        now ← required "geometry" (try (geometry (boundHelper bound) (boundPid bound) (boundX bound)))
        let size = (candWidth now, candHeight now)
        shot ← required "capture" (try (capture (boundHelper bound) (boundPid bound) (boundX bound) (stage n) [lmPoint l | l ← landmarksFor size] Nothing))
        mapM_ removeIfPresent previous
        let judged = judge (capturedProbes shot) (landmarksFor (capturedWidth shot, capturedHeight shot))
        if all judgedPassed judged
          then pure (n, shot, judged, True)
          else do
            when (n `mod` 8 == 1) $ note ("capture " <> Text.unpack name <> " attempt " <> show n <> ": " <> describeFailures judged)
            if n >= attemptsAllowed
              then pure (n, shot, judged, False)
              else threadDelay 250000 >> loop (n + 1) [stage n]
  outcome ← timeout (25 * 1000000) (loop 1 [])
  (attempts, shot, judged, passed) ← case outcome of
    Just done → pure done
    Nothing → expectationFailure ("the capture " <> Text.unpack name <> " never showed the scene's landmarks within 40 seconds") >> error "unreachable"
  renameFile (capturedPath shot) final
  let scale = metrics >>= metricsScale
      scaleOk = scale `elem` [Just (1, 1), Nothing]
      record =
        JObject
          [ ("name", JString name)
          , ("png", JString (Text.pack (Text.unpack name <> ".png")))
          , ("sha256", JString (capturedSha256 shot))
          , ("pid", JNumber (fromIntegral (boundPid bound)))
          , ("x_window", JNumber (boundX bound))
          , ("client_area", JArray [JNumber (fromIntegral (capturedWidth shot)), JNumber (fromIntegral (capturedHeight shot))])
          , ("host_logical_extent", extentJson (metrics >>= metricsLogical))
          , ("host_framebuffer_extent", extentJson (metrics >>= metricsFramebuffer))
          , ("host_content_scale", case scale of Just (x, y) → JString (Text.pack (show (x, y))); Nothing → JNull)
          , ("host_metrics_available", JBool (maybe False (const True) metrics))
          , ("attempts", JNumber (fromIntegral attempts))
          , ("tolerance_per_channel", JNumber (fromIntegral tolerance))
          , ("colour_handling", JString "Xvfb TrueColor display, no colour management; presented through an sRGB target by the software rasteriser; landmark expectations are the fixture's byte values (samples/lua-quad), never a first-run capture")
          , ("landmarks", JArray (map judgementJson judged))
          , ("passed", JBool (passed && scaleOk))
          ]
  writeFile (envCaptureDir env </> Text.unpack name <> ".json") (render record <> "\n")
  unless scaleOk $ expectationFailure ("the host reports content scale " <> show scale <> " on the X display; this receipt's landmarks assume scale 1")
  unless passed $ expectationFailure ("a landmark failed in capture " <> Text.unpack name <> " after " <> show attempts <> " attempts (the last image is retained as " <> Text.unpack name <> ".png): " <> describeFailures judged)
  evidence env ("capture " <> name <> ": X window " <> Text.pack (show (boundX bound)) <> " of pid " <> Text.pack (show (boundPid bound)) <> ", client area " <> Text.pack (show (capturedWidth shot, capturedHeight shot)) <> ", sha256 " <> capturedSha256 shot <> ", " <> Text.pack (show (length judged)) <> " landmarks passed within " <> Text.pack (show tolerance) <> " per channel after " <> Text.pack (show attempts) <> " capture(s); a capture is what the window presented, not GPU retirement evidence")
  where
    extentJson = \case
      Just (w, h) → JArray [JNumber (fromIntegral w), JNumber (fromIntegral h)]
      Nothing → JNull
    judgementJson j =
      JObject
        [ ("landmark", JString (lmName (judgedLandmark j)))
        , ("point", pairJson (lmPoint (judgedLandmark j)))
        , ("expected", tripleJson (Just (lmExpected (judgedLandmark j))))
        , ("actual", tripleJson (judgedActual j))
        , ("passed", JBool (judgedPassed j))
        ]
    pairJson (a, b) = JArray [JNumber (fromIntegral a), JNumber (fromIntegral b)]
    tripleJson = \case
      Just (a, b, c) → JArray (map (JNumber . fromIntegral) [a, b, c])
      Nothing → JNull
    removeIfPresent path = doesFileExist path >>= \there → when there (removeFile path)

-- | How many captures one step makes while the external presentation catches up (about twelve seconds).
attemptsAllowed ∷ Int
attemptsAllowed = 45

-- | Each failing landmark with what was expected and what was captured.
describeFailures ∷ [Judgement] → String
describeFailures judged =
  unlines ["  " <> Text.unpack (lmName (judgedLandmark j)) <> " at " <> show (lmPoint (judgedLandmark j)) <> ": expected " <> show (lmExpected (judgedLandmark j)) <> ", captured " <> show (judgedActual j) | j ← judged, not (judgedPassed j)]

-- | Deliver a genuine @WM_DELETE_WINDOW@ request to the bound window through the helper (delivery only).
closeBound ∷ Maybe Bound → IO ()
closeBound Nothing = pure ()
closeBound (Just bound) = () <$ required "close request" (try (requestClose (boundHelper bound) (boundPid bound) (boundX bound)))

-- | A helper outcome that is a refusal fails the case with the helper's own word for it.
required ∷ String → IO (Either Refused a) → IO a
required what action =
  action >>= \case
    Right value → pure value
    Left (Refused outcome detail) → expectationFailure ("the X11 helper refused the " <> what <> " (" <> Text.unpack outcome <> "): " <> Text.unpack detail) >> error "unreachable"

-- | Poll an external fact under a bound; the first answer is returned. A refusal in the poll is the case's failure.
pollFor ∷ String → IO String → IO (Maybe a) → IO a
pollFor label lastSeen probe = do
  outcome ← timeout (40 * 1000000) loop
  case outcome of
    Just answer → pure answer
    Nothing → do
      seen ← lastSeen
      expectationFailure ("no " <> label <> " within 40 seconds; " <> seen) >> error "unreachable"
  where
    loop =
      probe >>= \case
        Just answer → pure answer
        Nothing → threadDelay 100000 >> loop
