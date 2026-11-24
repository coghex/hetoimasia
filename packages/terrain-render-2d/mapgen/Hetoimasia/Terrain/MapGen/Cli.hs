-- | The @terrain-mapgen@ command line as a function of its arguments (TRA-14).
--
-- > terrain-mapgen --output DIR --fixtures DIR
-- > terrain-mapgen --check [--catalog DIR] --fixtures DIR
-- > terrain-mapgen --evidence DIR --fixtures DIR
-- > terrain-mapgen --atlas-output DIR --fixtures DIR
-- > terrain-mapgen --check-atlases [--atlas-dir DIR] --fixtures DIR
--
-- @--output@ generates the catalog and its manifest into an explicit directory.
-- @--check@ regenerates in temporary storage and compares with the committed
-- catalog, which it only reads; it fails, naming each affected identity or
-- path, on a missing, changed or unexpected file. @--evidence@ writes the CPU
-- comparison sheets and their index. @--atlas-output@ writes only the derivative terrain
-- atlases and their region manifest (TRA-17) into an explicit directory, and
-- @--check-atlases@ regenerates them in temporary storage and compares with the committed
-- atlas directory, which it only reads, failing on a missing, changed or unexpected file.
-- Neither atlas mode reads or writes the facemap catalog, and @--output@ and @--check@
-- read and write only the facemap catalog. Every mode takes its input explicitly:
-- @--fixtures@ names the fixture directory holding the pinned colour art and reference
-- masks, and a run without it is a usage error. The committed catalog defaults to
-- @content/textures/facemap@ (the atlases to @content/textures/terrain-atlas@) under that
-- directory. Exactly one mode is accepted.
--
-- The function returns what it would print and its exit status (0 success, 1 a
-- failed check or unreadable input, 2 a usage error) rather than performing
-- the printing, so a test can drive it.
--
-- State, ownership and lifetime: none beyond the files it is told to write.
module Hetoimasia.Terrain.MapGen.Cli
  ( Outcome (..)
  , runCli
  , defaultCatalogRelative
  , defaultAtlasRelative
  ) where

import Hetoimasia.Terrain.MapGen.Atlas (atlasDirectoryRelative, checkAtlases, generateAtlases)

import Hetoimasia.Terrain.MapGen.Evidence (writeEvidence)
import Hetoimasia.Terrain.MapGen.Generate (checkCatalog, describeDiscrepancy, generate, inventory, writeCatalog)
import Hetoimasia.Terrain.MapGen.Inputs (loadInputs, textureDirectory)
import System.FilePath ((</>))

-- | What a run prints and how it ends.
data Outcome = Outcome
  { outcomeExit ∷ !Int
  , outcomeOut ∷ ![String]
  , outcomeErr ∷ ![String]
  }
  deriving stock (Eq, Show)

-- | The committed catalog directory under the fixture directory.
defaultCatalogRelative ∷ FilePath
defaultCatalogRelative = textureDirectory </> "facemap"

-- | The committed atlas directory under the fixture directory.
defaultAtlasRelative ∷ FilePath
defaultAtlasRelative = atlasDirectoryRelative

data Mode = Output FilePath | Check | Evidence FilePath | AtlasOutput FilePath | CheckAtlases

data Options = Options
  { optMode ∷ !(Maybe Mode)
  , optFixtures ∷ !(Maybe FilePath)
  , optCatalog ∷ !(Maybe FilePath)
  , optAtlasDir ∷ !(Maybe FilePath)
  }

usage ∷ [String]
usage =
  [ "usage: terrain-mapgen --output DIR --fixtures DIR"
  , "       terrain-mapgen --check [--catalog DIR] --fixtures DIR"
  , "       terrain-mapgen --evidence DIR --fixtures DIR"
  , "       terrain-mapgen --atlas-output DIR --fixtures DIR"
  , "       terrain-mapgen --check-atlases [--atlas-dir DIR] --fixtures DIR"
  ]

parse ∷ [String] → Either String Options
parse = go (Options Nothing Nothing Nothing Nothing)
  where
    go options [] = Right options
    go options ("--output" : directory : rest) = setMode options (Output directory) rest
    go options ("--evidence" : directory : rest) = setMode options (Evidence directory) rest
    go options ("--atlas-output" : directory : rest) = setMode options (AtlasOutput directory) rest
    go options ("--check" : rest) = setMode options Check rest
    go options ("--check-atlases" : rest) = setMode options CheckAtlases rest
    go options ("--fixtures" : directory : rest) = go options {optFixtures = Just directory} rest
    go options ("--catalog" : directory : rest) = go options {optCatalog = Just directory} rest
    go options ("--atlas-dir" : directory : rest) = go options {optAtlasDir = Just directory} rest
    go _ (flag : _)
      | flag `elem` ["--output", "--evidence", "--atlas-output", "--fixtures", "--catalog", "--atlas-dir"] = Left (flag <> " needs a directory")
      | otherwise = Left ("unknown argument: " <> flag)
    setMode options mode rest = case optMode options of
      Nothing → go options {optMode = Just mode} rest
      Just _ → Left modeRule

modeRule ∷ String
modeRule = "give exactly one of --output, --check, --evidence, --atlas-output and --check-atlases"

-- | A run with no usable input directory: absent, or an empty argument (which would otherwise
-- name the working directory, as an unset shell variable does).
missingFixtures ∷ Outcome
missingFixtures = Outcome 2 [] ("terrain-mapgen: the input directory is required; pass --fixtures DIR" : usage)

-- | Run the command.
runCli ∷ [String] → IO Outcome
runCli arguments = case parse arguments of
  Left why → pure (Outcome 2 [] (("terrain-mapgen: " <> why) : usage))
  Right options → case optMode options of
    Nothing → pure (Outcome 2 [] (("terrain-mapgen: " <> modeRule) : usage))
    Just mode → do
      case optFixtures options of
        Nothing → pure missingFixtures
        Just "" → pure missingFixtures
        Just directory → do
          loaded ← loadInputs directory
          case loaded of
            Left problems → pure (Outcome 1 [] (map ("terrain-mapgen: " <>) problems))
            Right inputs → case mode of
              Output destination → do
                let files = generate inputs
                writeCatalog destination files
                pure (Outcome 0 (("wrote " <> show (length files) <> " files to " <> destination) : inventory files) [])
              Check → do
                let committed = maybe (directory </> defaultCatalogRelative) id (optCatalog options)
                problems ← checkCatalog inputs committed
                pure $ case problems of
                  [] → Outcome 0 ["terrain-mapgen --check: " <> committed <> " matches the regenerated catalog"] []
                  _ → Outcome 1 [] (("terrain-mapgen --check: " <> committed <> " differs from the regenerated catalog") : map (("  " <>) . describeDiscrepancy) problems)
              Evidence destination → do
                report ← writeEvidence inputs destination
                pure (Outcome 0 report [])
              AtlasOutput destination → case generateAtlases inputs of
                Left why → pure (Outcome 1 [] ["terrain-mapgen --atlas-output: " <> why])
                Right files → do
                  writeCatalog destination files
                  pure (Outcome 0 (("wrote " <> show (length files) <> " files to " <> destination) : inventory files) [])
              CheckAtlases → do
                let committed = maybe (directory </> defaultAtlasRelative) id (optAtlasDir options)
                result ← checkAtlases inputs committed
                pure $ case result of
                  Left why → Outcome 1 [] ["terrain-mapgen --check-atlases: " <> why]
                  Right [] → Outcome 0 ["terrain-mapgen --check-atlases: " <> committed <> " matches the regenerated atlases"] []
                  Right problems → Outcome 1 [] (("terrain-mapgen --check-atlases: " <> committed <> " differs from the regenerated atlases") : map (("  " <>) . describeDiscrepancy) problems)
