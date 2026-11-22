{-# LANGUAGE NoOverloadedStrings #-}

-- | The dependency guard of the ownership transactions' issuer bridge (#721; the design's "Cabal issuer dependency
-- guard").
--
-- Cabal supplies the components, their configurations, dependencies, re-exports, mixins and declared modules
-- ("Inventory"); the guard compares those facts with the exact component allowlist
-- @tools/validation/owner_tx_issuers.json@ ("Policy"). It reads no Haskell source and needs no compiler or store.
--
-- @owner-tx-guard check [--root DIR]@ fails (exit 1) on any problem and refuses (exit 2) what it cannot read.
-- @owner-tx-guard scope [--root DIR]@ prints every project file and package description the check reads, one
-- @kind path@ per line.
module Main (main) where

import Control.Monad (filterM, forM_, unless)
import Data.List (nub, sort)
import GHC.IO.Encoding (setFileSystemEncoding, setForeignEncoding, setLocaleEncoding)
import Inventory (Inventory (..), Package (..), readInventory)
import Policy (Allowlist, check, readAllowlist)
import System.Directory (doesFileExist, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

allowlistPath ∷ FilePath
allowlistPath = "tools/validation/owner_tx_issuers.json"

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
  projects ← filterM (\project → doesFileExist (root </> project)) ["cabal.project", "cabal.project.vulkan"]
  unless ("cabal.project" `elem` projects) (refuse (root </> "cabal.project does not exist"))
  inventory ← readInventory root projects >>= either refuse pure
  case command of
    "scope" → mapM_ putStrLn (scope inventory)
    "check" → do
      allowlist ← readAllowlistAt root
      let problems = check allowlist inventory
      forM_ problems (hPutStrLn stderr . ("owner_tx_guard: " <>))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    _ → refuse ("unknown command " <> command)

scope ∷ Inventory → [String]
scope inventory =
  sort . nub $
    ["project " <> file | file ← inventoryFiles inventory]
      <> ["description " <> packageCabal package | package ← inventoryPackages inventory]

readAllowlistAt ∷ FilePath → IO Allowlist
readAllowlistAt root = do
  present ← doesFileExist (root </> allowlistPath)
  unless present (refuse (allowlistPath <> " cannot be read: it does not exist"))
  text ← readFile (root </> allowlistPath)
  either (\why → refuse (allowlistPath <> " cannot be read: " <> why)) pure (readAllowlist text)

refuse ∷ String → IO a
refuse why = hPutStrLn stderr ("owner_tx_guard: " <> why) >> exitWith (ExitFailure 2)
