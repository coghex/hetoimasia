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
  , prepare
  , candidates
  , viewableCandidates
  , geometry
  , capture
  , requestClose
  ) where

import Control.Exception (Exception, throwIO)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
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
run helper arguments = do
  outcome ← timeout (30 * 1000000) (readCreateProcessWithExitCode (proc (x11Python helper) ("-I" : x11Script helper : arguments)) "")
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
