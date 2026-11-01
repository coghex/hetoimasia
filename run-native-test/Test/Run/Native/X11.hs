{-# LANGUAGE OverloadedStrings #-}

-- | The client of tools/x11-window/x11_window.py: external operating-system evidence for the owned native windows on the
-- isolated X11 display (LFE-25, #540).
--
-- Each operation is one owned subprocess of the helper that is waited for under a bound and reaped on every way out
-- (a timeout or any exception ends and waits for it through 'withCreateProcess'), whose one JSON object is parsed
-- here. The helper identifies a window by the process id and window id the caller names and re-verifies that identity
-- at each action; this module never picks a window the helper refused to pick, never turns a refusal into a pass and
-- never signals a process (a close is a @WM_DELETE_WINDOW@ message to that window, and its delivery is only a
-- delivery). 'Refused' carries the helper's own outcome word (@ambiguous@, @vanished@, @identity_mismatch@, ...), so
-- a vanished window is a diagnostic outcome the caller reports.
module Test.Run.Native.X11
  ( X11 (..)
  , Candidate (..)
  , Captured (..)
  , Refused (..)
  , defaultX11
  , runBounded
  , prepare
  , candidates
  , viewableCandidates
  , geometry
  , capture
  , requestClose
  ) where

import Control.Concurrent.STM (atomically, check, readTVar, readTVarIO)
import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.IO (hPutStrLn, stderr)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))
import System.Environment (getEnvironment)
import System.Process (waitForProcess)
import System.Timeout (timeout)
import Test.Run.Native.Child (Child (..), withChild)
import Test.Run.Native.Json

-- | Where the helper is and how to run it.
data X11 = X11
  { x11Python ∷ !FilePath
  , x11Script ∷ !FilePath
  }

-- | The helper in the repository, from the repository root the runner starts the suite in.
defaultX11 ∷ X11
defaultX11 = X11 "python3" "tools/x11-window/x11_window.py"

-- | The helper refused, or could not answer.
data Refused = Refused
  { refusedOutcome ∷ !Text
  , refusedDetail ∷ !Text
  }
  deriving (Show)

instance Exception Refused

-- | One top-level client window of a process.
data Candidate = Candidate
  { candWindow ∷ !Integer
  , candPid ∷ !Int
  , candX ∷ !Int
  , candY ∷ !Int
  , candWidth ∷ !Int
  , candHeight ∷ !Int
  , candMapState ∷ !Int
  , candProtocols ∷ ![Text]
  }
  deriving (Eq, Show)

-- | A capture the helper wrote.
data Captured = Captured
  { capturedPath ∷ !FilePath
  , capturedSha256 ∷ !Text
  , capturedWidth ∷ !Int
  , capturedHeight ∷ !Int
  , capturedProbes ∷ ![((Int, Int), (Int, Int, Int))]
  , capturedIdentity ∷ !Candidate
  , capturedRaw ∷ !Json
  }
  deriving (Show)

-- | Run one helper operation: bounded, reaped, and answered as the helper's own JSON.
run ∷ X11 → [String] → IO Json
run = runBounded (30 * 1000000)

-- | The same under a stated bound, in microseconds. The helper process is the suite's owned child
-- ('Test.Run.Native.Child.withChild'): on every way out, a timeout and a cancellation included, it is killed if it has not
-- exited and reaped before this returns (a process that could not be confirmed reaped fails the call), and its pipes are
-- drained. The library's own cleanup of a timed-out process reaps it in a background thread, which would let a capture race a
-- helper still writing its files.
runBounded ∷ Int → X11 → [String] → IO Json
runBounded bound helper arguments = do
  started ← getCurrentTime
  environment ← getEnvironment
  outcome ←
    withChild (x11Python helper) ("-I" : x11Script helper : arguments) environment $ \child →
      timeout bound $ do
        code ← waitForProcess (childProcess child)
        atomically (readTVar (childOutEnded child) >>= check >> readTVar (childErrEnded child) >>= check)
        out ← readTVarIO (childOut child)
        err ← readTVarIO (childErr child)
        pure (code, Text.unpack (Text.unlines out), Text.unpack (Text.unlines err))
  finished ← getCurrentTime
  -- A slow or failed operation says so where it happened, so a run that runs out of budget names the step.
  let seconds = realToFrac (diffUTCTime finished started) ∷ Double
  when (seconds > 2 || maybe True (\(code, _, _) → code /= ExitSuccess) outcome) $
    hPutStrLn stderr ("run-native-tests: x11 helper " <> unwords (take 2 arguments) <> " took " <> show seconds <> "s" <> maybe ", timed out" (\(code, _, _) → ", " <> show code) outcome)
  case outcome of
    Nothing → throwIO (Refused "timeout" "the helper did not answer within 30 seconds; it was ended and reaped")
    Just (code, out, err) → case parseJson out of
      Left why → throwIO (Refused "unreadable" (Text.pack ("the helper's answer could not be read (" <> why <> "); exit " <> show code <> ", stderr: " <> take 400 err)))
      Right json → case (code, field "ok" json >>= asBool) of
        (ExitSuccess, Just True) → pure json
        (_, Just False) → throwIO (Refused (fromMaybe "refused" (field "outcome" json >>= asText)) (fromMaybe (Text.pack out) (field "detail" json >>= asText)))
        _ → throwIO (Refused "unexpected" (Text.pack ("exit " <> show code <> ": " <> take 400 (out <> err))))

-- | Preparation: the helper loads libX11 and the display is the isolated one. A missing prerequisite fails; it never
-- skips.
prepare ∷ X11 → IO ()
prepare helper = () <$ run helper ["check"]

windowOf ∷ Json → Maybe Candidate
windowOf json = do
  window ← field "window" json >>= asInteger
  pure
    Candidate
      { candWindow = window
      , candPid = int "pid"
      , candX = int "x"
      , candY = int "y"
      , candWidth = int "width"
      , candHeight = int "height"
      , candMapState = int "map_state"
      , candProtocols = maybe [] (mapMaybe asText) (field "protocols" json >>= asArray)
      }
  where
    int name = fromMaybe 0 (field name json >>= asInt)
    asInteger = \case
      JNumber n → Just n
      _ → Nothing

-- | Every InputOutput window the process owns, viewable or not.
candidates ∷ X11 → Int → IO [Candidate]
candidates helper pid = do
  json ← run helper ["candidates", "--pid", show pid]
  pure (maybe [] (mapMaybe windowOf) (field "candidates" json >>= asArray))

viewableCandidates ∷ X11 → Int → IO [Candidate]
viewableCandidates helper pid = filter ((== 2) . candMapState) <$> candidates helper pid

-- | The window as the X server reports it now, re-verified against the process id.
geometry ∷ X11 → Int → Integer → IO Candidate
geometry helper pid window = do
  json ← run helper ["geometry", "--pid", show pid, "--window", show window]
  maybe (throwIO (Refused "unreadable" "geometry answered no identity")) pure (field "identity" json >>= windowOf)

-- | Capture exactly this window's client area to a new file, with colours at the probe points from the same image. The
-- size the caller observed is re-checked by the helper when given.
capture ∷ X11 → Int → Integer → FilePath → [(Int, Int)] → Maybe (Int, Int) → IO Captured
capture helper pid window out probes expect = do
  json ←
    run helper $
      ["capture", "--pid", show pid, "--window", show window, "--out", out]
        <> concat [["--probe", show x <> "," <> show y] | (x, y) ← probes]
        <> maybe [] (\(w, h) → ["--expect-size", show w <> "x" <> show h]) expect
  identity ← maybe (throwIO (Refused "unreadable" "capture answered no identity")) pure (field "identity" json >>= windowOf)
  let sampled =
        [ ((x, y), (r, g, b))
        | (name, value) ← fromMaybe [] (field "probes" json >>= asObject)
        , [x, y] ← [map read (splitComma (Text.unpack name))]
        , Just [r, g, b] ← [fmap (mapMaybe asInt) (asArray value)]
        ]
  pure
    Captured
      { capturedPath = out
      , capturedSha256 = fromMaybe "" (field "sha256" json >>= asText)
      , capturedWidth = fromMaybe 0 (field "width" json >>= asInt)
      , capturedHeight = fromMaybe 0 (field "height" json >>= asInt)
      , capturedProbes = sampled
      , capturedIdentity = identity
      , capturedRaw = json
      }
  where
    splitComma text = case break (== ',') text of
      (before, ',' : after) → [before, after]
      other → [fst other]

-- | Deliver a genuine @WM_DELETE_WINDOW@ request to exactly this window. That is delivery only.
requestClose ∷ X11 → Int → Integer → IO Candidate
requestClose helper pid window = do
  json ← run helper ["close", "--pid", show pid, "--window", show window]
  maybe (throwIO (Refused "unreadable" "close answered no identity")) pure (field "identity" json >>= windowOf)
