{-# LANGUAGE NoOverloadedStrings #-}

-- | The issuer guard of the ownership transactions (#721; the design's "Approved amendment · Textual issuer guard").
--
-- It scans every @.cabal@ and @cabal.project*@ file in the repository for the protected texts ("Scan") and requires
-- each to lie in a stanza @tools/validation/owner-tx-issuers.fields@ lists ("Policy"). It evaluates no Cabal semantics
-- and needs no compiler or store.
--
-- @owner-tx-guard check [--root DIR]@ fails (exit 1) on any problem and refuses (exit 2) an allowlist it cannot read.
-- @owner-tx-guard scope [--root DIR]@ prints every file the check reads, one @file path@ per line.
module Main (main) where

import Control.Monad (forM, forM_, unless)
import qualified Data.ByteString as ByteString
import GHC.IO.Encoding (setFileSystemEncoding, setForeignEncoding, setLocaleEncoding)
import Policy (Allowlist, check, readAllowlist)
import Scan (scanFile, scannedFiles)
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

allowlistPath ∷ FilePath
allowlistPath = "tools/validation/owner-tx-issuers.fields"

main ∷ IO ()
main = do
  -- Every file, path and handle is UTF-8, whatever the locale: package descriptions, project files and diagnostics hold
  -- non-ASCII text, and a C locale would otherwise refuse to read or write it.
  mapM_ ($ utf8) [setLocaleEncoding, setFileSystemEncoding, setForeignEncoding]
  mapM_ (`hSetEncoding` utf8) [stdout, stderr]
  arguments ← getArgs
  case arguments of
    [command] → run command "."
    [command, "--root", root] → run command root
    _ → refuse "usage: owner-tx-guard (check | scope) [--root DIR]"

run ∷ String → FilePath → IO ()
run command given = do
  root ← makeAbsolute given
  (files, walkProblems) ← scannedFiles root
  case command of
    "scope" → mapM_ (putStrLn . ("file " <>)) (files <> [allowlistPath])
    "check" → do
      allowlist ← readAllowlistAt root
      scanned ← forM files $ \path → (,) path . scanFile <$> ByteString.readFile (root </> path)
      let problems = walkProblems <> check allowlist scanned
      forM_ problems (hPutStrLn stderr . ("owner_tx_guard: " <>))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    _ → refuse ("unknown command " <> command)

readAllowlistAt ∷ FilePath → IO Allowlist
readAllowlistAt root = do
  present ← doesFileExist (root </> allowlistPath)
  unless present (refuse (allowlistPath <> " cannot be read: it does not exist"))
  bytes ← ByteString.readFile (root </> allowlistPath)
  either (\why → refuse (allowlistPath <> " cannot be read: " <> why)) pure (readAllowlist bytes)

refuse ∷ String → IO a
refuse why = hPutStrLn stderr ("owner_tx_guard: " <> why) >> exitWith (ExitFailure 2)
