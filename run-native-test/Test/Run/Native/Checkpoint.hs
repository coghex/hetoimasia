{-# LANGUAGE OverloadedStrings #-}

-- | Owner-confirmation checkpoints (LFE-25, #540 requirements 2 to 4 and the owner decision of 2026-11-01).
--
-- On macOS there is no OS capture: what the quad, the resize clipping and the surviving peer look like is confirmed by
-- the owner, relayed by the manager, and no test infers it from a passing run. The /unattended/ receipt (the catalog's
-- @--complete@ profile, and every isolated-display run) never holds: at a checkpoint it records the confirmation as
-- PENDING and goes on. The /supervised/ run (the desktop consent with a narrower selection) holds the state on an
-- explicit, bounded wait that ends only when the operator enters a line on standard input after the manager has
-- relayed the owner's actual confirmation; an end of input, a bound that expires or any failure fails the case, and
-- the confirmation stays pending. No flag, environment variable, consent value or product mode is added.
--
-- What is recorded for an acknowledged checkpoint is what the issue asks of a confirmation: its time (read from the
-- clock when the acknowledgment arrived), the operator's line as provenance, the owning process and the windows' identity,
-- and the metrics and lifecycle facts the caller names. The record is evidence; nothing reads its values back.
module Test.Run.Native.Checkpoint (checkpoint) where

import Control.Concurrent.STM (atomically, readTQueue)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (getCurrentTime)
import System.IO (hFlush, hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)
import Test.Run.Native.Capture (ownPid)
import Test.Run.Native.Env (Env (..), Hold (..), evidence)

-- | A named point at which the owner's visual confirmation of @what@ is owed. @facts@ names the windows' identity and
-- metrics at this moment.
checkpoint ∷ Env → Text → Text → Text → IO ()
checkpoint env name what facts = case envHold env of
  Nothing ->
    evidence env ("owner-confirmation checkpoint " <> name <> ": PENDING (" <> what <> "); this receipt does not hold, and no confirmation is inferred from it. " <> facts)
  Just hold -> do
    pid ← ownPid
    hPutStrLn stderr . Text.unpack $
      "\n=== OWNER CONFIRMATION CHECKPOINT: "
        <> name
        <> " ===\n"
        <> what
        <> "\nowning pid "
        <> Text.pack (show pid)
        <> "; "
        <> facts
        <> "\nThe state is held. After the manager has relayed the owner's actual confirmation, enter a line (the owner's words) on standard input to continue; the wait is bounded at "
        <> Text.pack (show (holdSeconds hold))
        <> " seconds."
    hFlush stderr
    answer ← timeout (holdSeconds hold * 1000000) (atomically (readTQueue (holdInput hold)))
    case answer of
      Nothing → expectationFailure ("checkpoint " <> Text.unpack name <> " expired without an acknowledgment; the confirmation stays PENDING")
      Just Nothing → expectationFailure ("checkpoint " <> Text.unpack name <> ": standard input ended without an acknowledgment; the confirmation stays PENDING")
      Just (Just line) → do
        now ← getCurrentTime
        evidence env ("owner-confirmation checkpoint " <> name <> ": acknowledged at " <> Text.pack (show now) <> " by the operator's line " <> Text.pack (show line) <> " (entered on standard input of owning pid " <> Text.pack (show pid) <> "; the operator's line is the only provenance this record holds, and is never taken to be confirmed by this program); " <> what <> "; " <> facts)
