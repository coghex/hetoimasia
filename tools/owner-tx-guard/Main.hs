{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The import guard of the ownership transactions' issuer bridge (#721; the design's "Guard mechanism").
--
-- Cabal supplies the components, their configurations, sources and dependencies ("Inventory"); GHC supplies each
-- source's direct imports and each protected module's typed exports ("Frontend"); the guard compares those facts with
-- the exact allowlist @tools/validation/owner_tx_issuers.json@ ("Policy").
--
-- @owner-tx-guard check [--root DIR]@ fails (exit 1) on any problem and refuses (exit 2) what it cannot read.
-- @owner-tx-guard scope [--root DIR]@ prints every project file, package description, source directory and include
-- directory the check reads, one @kind path@ per line. @owner-tx-guard contract [--root DIR]@ prints the typed exports of
-- every checked module as export-contract entries, for review.
module Main (main) where

import Control.Monad (filterM, forM_, unless)
import Data.List (isPrefixOf, nub, sort)
import GHC.Settings.Config (cProjectVersion)
import Inventory (Configuration (..), Package (..), readInventory)
import Frontend (Export (..))
import Policy (Allowlist, check, checkedModules, readAllowlist, typedExports)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, listDirectory, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import GHC.IO.Encoding (setFileSystemEncoding, setForeignEncoding, setLocaleEncoding)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import System.Process (readProcessWithExitCode)

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
    _ → refuse "usage: owner-tx-guard (check | scope | contract) [--root DIR]"

run ∷ String → FilePath → IO ()
run command given = do
  root ← makeAbsolute given
  projects ← filterM (\project → doesFileExist (root </> project)) ["cabal.project", "cabal.project.vulkan"]
  unless ("cabal.project" `elem` projects) (refuse (root </> "cabal.project does not exist"))
  inventory ← readInventory root projects
  (files, packages) ← either refuse pure inventory
  case command of
    "scope" → mapM_ putStrLn (scope files packages)
    "check" → do
      allowlist ← readAllowlistAt root
      libdir ← compilerLibdir
      databases ← storeDatabases root
      problems ← check root libdir databases allowlist packages
      forM_ problems (hPutStrLn stderr . ("owner_tx_guard: " <>))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    "contract" → do
      allowlist ← readAllowlistAt root
      libdir ← compilerLibdir
      databases ← storeDatabases root
      forM_ (checkedModules allowlist) $ \key@(component, moduleName) → do
        outcomes ← typedExports root libdir databases packages key
        case outcomes of
          [] → hPutStrLn stderr ("owner_tx_guard: " <> moduleName <> " is not a source of " <> component)
          (_, outcome) : _ → case outcome of
            Left why → hPutStrLn stderr ("owner_tx_guard: " <> why)
            Right exports →
              forM_ exports $ \export →
                putStrLn
                  ( "{\"component\": " <> show component <> ", \"module\": " <> show moduleName <> ", \"symbol\": " <> show (exportSymbol export)
                      <> ", \"kind\": " <> show (exportKind export) <> ", \"type\": " <> show (exportType export) <> "}"
                  )
    _ → refuse ("unknown command " <> command)

scope ∷ [FilePath] → [Package] → [String]
scope files packages =
  sort . nub $
    ["project " <> file | file ← files]
      <> ["description " <> packageCabal package | package ← packages]
      <> [ "directory " <> directory
         | package ← packages
         , configuration ← packageConfigurations package
         , directory ← configSourceDirectories configuration
         ]
      <> [ "include " <> drop 2 flag
         | package ← packages
         , configuration ← packageConfigurations package
         , flag ← configFlags configuration
         , "-I" `isPrefixOf` flag
         ]

readAllowlistAt ∷ FilePath → IO Allowlist
readAllowlistAt root = do
  present ← doesFileExist (root </> allowlistPath)
  unless present (refuse (allowlistPath <> " cannot be read: it does not exist"))
  text ← readFile (root </> allowlistPath)
  either (\why → refuse (allowlistPath <> " cannot be read: " <> why)) pure (readAllowlist text)

-- The libdir of the ghc on PATH, which must be the compiler this tool was built with.
compilerLibdir ∷ IO FilePath
compilerLibdir = do
  found ← findExecutable "ghc"
  case found of
    Nothing → refuse "no ghc on PATH"
    Just ghc → do
      (versionStatus, version, _) ← readProcessWithExitCode ghc ["--numeric-version"] ""
      unless (versionStatus == ExitSuccess && takeWhile (/= '\n') version == cProjectVersion) $
        refuse ("the ghc on PATH reports " <> takeWhile (/= '\n') version <> "; this guard was built with " <> cProjectVersion)
      (status, libdir, _) ← readProcessWithExitCode ghc ["--print-libdir"] ""
      unless (status == ExitSuccess) (refuse "ghc --print-libdir failed")
      pure (takeWhile (/= '\n') libdir)

-- The package databases of cabal's store for this compiler, where a checked module's external dependencies are.
storeDatabases ∷ FilePath → IO [FilePath]
storeDatabases root = do
  found ← findExecutable "cabal"
  case found of
    Nothing → pure []
    Just cabal → do
      (status, output, _) ← readProcessWithExitCode cabal ["path", "--store-dir", "--project-dir", root] ""
      let store = takeWhile (/= '\n') output
      present ← doesDirectoryExist store
      if status /= ExitSuccess || not present
        then pure []
        else do
          entries ← listDirectory store
          let prefix = "ghc-" <> cProjectVersion <> "-"
          filterM doesDirectoryExist [store </> entry </> "package.db" | entry ← sort entries, prefix `isPrefixOf` entry]

refuse ∷ String → IO a
refuse why = hPutStrLn stderr ("owner_tx_guard: " <> why) >> exitWith (ExitFailure 2)
