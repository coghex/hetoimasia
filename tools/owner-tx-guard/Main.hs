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
import qualified Data.Set as Set
import Frontend (Export (..), HeaderFacts (..), Instance (..), Interface (..), withScratch)
import Inventory (Configuration (..), Inventory (..), Package (..), Source (..), configurationId, readInventory)
import Policy (Allowlist, check, checkedModules, headerFacts, readAllowlist, typedInterfaces)
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
  inventory ← readInventory root projects >>= either refuse pure
  case command of
    "scope" → mapM_ putStrLn (scope inventory)
    "check" → do
      allowlist ← readAllowlistAt root
      libdir ← compilerLibdir
      problems ←
        storeDatabases >>= \case
          Left why → pure [why]
          Right databases → withScratch $ \scratch → check root libdir scratch databases allowlist inventory
      forM_ problems (hPutStrLn stderr . ("owner_tx_guard: " <>))
      exitWith (if null problems then ExitSuccess else ExitFailure 1)
    "contract" → do
      allowlist ← readAllowlistAt root
      libdir ← compilerLibdir
      databases ← storeDatabases >>= either refuse pure
      withScratch $ \scratch → do
        let packages = inventoryPackages inventory
        cppSources ←
          headerFacts root libdir scratch databases (concatMap packageConfigurations packages) >>= \case
            Left why → refuse why
            Right factsOf → pure (Set.fromList [(configurationId c, sourcePath s') | p ← packages, c ← packageConfigurations p, s' ← configSources c, Just (Right h) ← [factsOf c s'], headerUsedCpp h])
        typed ← typedInterfaces root libdir scratch databases packages cppSources (checkedModules allowlist)
        forM_ typed $ \((component, moduleName), outcomes) →
          case outcomes of
            [] → hPutStrLn stderr ("owner_tx_guard: " <> moduleName <> " is not a source of " <> component)
            (_, Left why) : _ → hPutStrLn stderr ("owner_tx_guard: " <> why)
            (_, Right interface) : _ → do
              forM_ (interfaceExports interface) $ \export → entry component moduleName (exportSymbol export) (exportKind export) (exportType export)
              forM_ [i | i ← interfaceInstances interface, instanceProtected i] $ \i → entry component moduleName (instanceClass i) "instance" (instanceHead i)
    _ → refuse ("unknown command " <> command)
  where
    entry component moduleName symbol kind ty =
      putStrLn ("{\"component\": " <> show component <> ", \"module\": " <> show moduleName <> ", \"symbol\": " <> show symbol <> ", \"kind\": " <> show kind <> ", \"type\": " <> show ty <> "}")

scope ∷ Inventory → [String]
scope inventory =
  sort . nub $
    ["project " <> file | file ← inventoryFiles inventory]
      <> ["description " <> packageCabal package | package ← packages]
      <> ["directory " <> directory | configuration ← configurations, directory ← configSourceDirectories configuration]
      <> ["include " <> drop 2 flag | configuration ← configurations, flag ← configFlags configuration, "-I" `isPrefixOf` flag]
  where
    packages = inventoryPackages inventory
    configurations = concatMap packageConfigurations packages

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

-- The package databases of cabal's store for this compiler, where a checked module's external dependencies are. The
-- lookup ignores the project, so it writes nothing into the checkout; a lookup that fails is reported with Cabal's
-- own status and diagnostic.
storeDatabases ∷ IO (Either String [FilePath])
storeDatabases = do
  found ← findExecutable "cabal"
  case found of
    Nothing → pure (Left "uncovered: no cabal on PATH, so the store's package databases cannot be found")
    Just cabal → do
      (status, output, errors) ← readProcessWithExitCode cabal ["path", "--ignore-project", "--store-dir"] ""
      case status of
        ExitFailure code → pure (Left ("uncovered: cabal path --ignore-project --store-dir failed (" <> show code <> "): " <> unwords (lines errors)))
        ExitSuccess → do
          let store = takeWhile (/= '\n') output
          present ← doesDirectoryExist store
          if not present
            then pure (Left ("uncovered: the store " <> store <> " cabal named does not exist"))
            else do
              entries ← listDirectory store
              let prefix = "ghc-" <> cProjectVersion <> "-"
              Right <$> filterM doesDirectoryExist [store </> entry' </> "package.db" | entry' ← sort entries, prefix `isPrefixOf` entry']

refuse ∷ String → IO a
refuse why = hPutStrLn stderr ("owner_tx_guard: " <> why) >> exitWith (ExitFailure 2)
