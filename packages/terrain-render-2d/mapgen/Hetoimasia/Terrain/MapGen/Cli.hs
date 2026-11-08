-- | The @terrain-mapgen@ command line as a function of its arguments (TRA-14).
--
-- > terrain-mapgen --output DIR [--sample DIR]
-- > terrain-mapgen --check [--catalog DIR] [--sample DIR]
-- > terrain-mapgen --evidence DIR [--sample DIR]
--
-- @--output@ generates the catalog and its manifest into an explicit directory.
-- @--check@ regenerates in temporary storage and compares with the committed
-- catalog, which it only reads; it fails, naming each affected identity or
-- path, on a missing, changed or unexpected file. @--evidence@ writes the CPU
-- comparison sheets and their index. The sample directory defaults to the
-- @samples/ecce-homo@ found at or above the working directory, and the
-- committed catalog to @content/textures/facemap@ under it, so neither depends
-- on which directory the command is started in. Exactly one mode is accepted.
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
  ) where

import Hetoimasia.Terrain.MapGen.Evidence (writeEvidence)
import Hetoimasia.Terrain.MapGen.Generate (checkCatalog, describeDiscrepancy, generate, inventory, writeCatalog)
import Hetoimasia.Terrain.MapGen.Inputs (loadInputs, textureDirectory)
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))

-- | What a run prints and how it ends.
data Outcome = Outcome
  { outcomeExit ∷ !Int
  , outcomeOut ∷ ![String]
  , outcomeErr ∷ ![String]
  }
  deriving stock (Eq, Show)

-- | The committed catalog directory under the sample directory.
defaultCatalogRelative ∷ FilePath
defaultCatalogRelative = textureDirectory </> "facemap"

data Mode = Output FilePath | Check | Evidence FilePath

data Options = Options
  { optMode ∷ !(Maybe Mode)
  , optSample ∷ !(Maybe FilePath)
  , optCatalog ∷ !(Maybe FilePath)
  }

usage ∷ [String]
usage =
  [ "usage: terrain-mapgen --output DIR [--sample DIR]"
  , "       terrain-mapgen --check [--catalog DIR] [--sample DIR]"
  , "       terrain-mapgen --evidence DIR [--sample DIR]"
  ]

parse ∷ [String] → Either String Options
parse = go (Options Nothing Nothing Nothing)
  where
    go options [] = Right options
    go options ("--output" : directory : rest) = setMode options (Output directory) rest
    go options ("--evidence" : directory : rest) = setMode options (Evidence directory) rest
    go options ("--check" : rest) = setMode options Check rest
    go options ("--sample" : directory : rest) = go options {optSample = Just directory} rest
    go options ("--catalog" : directory : rest) = go options {optCatalog = Just directory} rest
    go _ (flag : _)
      | flag `elem` ["--output", "--evidence", "--sample", "--catalog"] = Left (flag <> " needs a directory")
      | otherwise = Left ("unknown argument: " <> flag)
    setMode options mode rest = case optMode options of
      Nothing → go options {optMode = Just mode} rest
      Just _ → Left "give exactly one of --output, --check and --evidence"

-- | The nearest @samples/ecce-homo@ at or above a directory.
findSample ∷ FilePath → IO (Maybe FilePath)
findSample directory = do
  let candidate = directory </> "samples" </> "ecce-homo"
  found ← doesDirectoryExist candidate
  if found
    then pure (Just candidate)
    else
      let parent = takeDirectory directory
       in if parent == directory then pure Nothing else findSample parent

-- | Run the command.
runCli ∷ [String] → IO Outcome
runCli arguments = case parse arguments of
  Left why → pure (Outcome 2 [] (("terrain-mapgen: " <> why) : usage))
  Right options → case optMode options of
    Nothing → pure (Outcome 2 [] ("terrain-mapgen: give exactly one of --output, --check and --evidence" : usage))
    Just mode → do
      sample ← case optSample options of
        Just directory → pure (Just directory)
        Nothing → getCurrentDirectory >>= findSample
      case sample of
        Nothing → pure (Outcome 1 [] ["terrain-mapgen: no samples/ecce-homo at or above the working directory; pass --sample DIR"])
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
