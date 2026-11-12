-- | The one way the real-platform probe obtains a volume to consume.
--
-- A 'Fixture' is a directory on a capped, disposable volume that was VERIFIED: it exists, it is owned by the
-- running user, its device differs from the working directory's and the home directory's, and the volume's total
-- capacity, asked of an opened descriptor on it (never of a path), is within the cap. The constructor is hidden:
-- every function that fills the volume or reserves in it ('Test.TerrainRuntime.Storage.ProbeSpec') takes a
-- 'Fixture', so no example can reach a filler or a reservation any other way, whichever example is selected and
-- whatever an earlier example did. The check allocates nothing (a file of no bytes, unlinked at once).
module Test.TerrainRuntime.Storage.Fixture
  ( Fixture
  , fixtureDir
  , FixtureError (..)
  , Policy (..)
  , defaultPolicy
  , acquireFixture
  , pointerFixture
  ) where

import Control.Exception (IOException, onException, try)
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Storage.Internal.File (Created (..), closeFile, createPrivate, unlinkFile)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (productionSeam)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume (VolumeProfile (..), profileOf)
import System.Directory (doesDirectoryExist, getCurrentDirectory, getHomeDirectory)
import System.Environment (lookupEnv)
import System.Posix.Files (deviceID, fileOwner, getFileStatus)
import System.Posix.User (getRealUserID)

newtype Fixture = Fixture FilePath

instance Show Fixture where
  show (Fixture d) = "Fixture " <> show d

fixtureDir ∷ Fixture → FilePath
fixtureDir (Fixture d) = d

data FixtureError
  = NoPointer FilePath
  | MissingDirectory FilePath
  | SameVolume
  | NotOwned
  | OverCap Word64 Word64
  | CannotProbe String
  deriving stock (Eq, Show)

-- | What a fixture must satisfy. The production policy is 'defaultPolicy'; the routine suite checks the rules
-- with others.
data Policy = Policy
  { polCapBytes ∷ !Word64
  , polDistinct ∷ !Bool
  }

-- | A volume of at most 4 GiB on a device of its own.
defaultPolicy ∷ Policy
defaultPolicy = Policy (4 * 1024 * 1024 * 1024) True

-- | Verify a directory against a policy. Nothing is allocated before it passes.
acquireFixture ∷ Policy → FilePath → IO (Either FixtureError Fixture)
acquireFixture pol dir = do
  exists ← doesDirectoryExist dir
  if not exists
    then pure (Left (MissingDirectory dir))
    else do
      home ← getHomeDirectory
      cwd ← getCurrentDirectory
      [fx, cw, hm] ← mapM (fmap deviceID . getFileStatus) [dir, cwd, home]
      owner ← fileOwner <$> getFileStatus dir
      me ← getRealUserID
      if polDistinct pol && (fx == cw || fx == hm)
        then pure (Left SameVolume)
        else
          if owner /= me
            then pure (Left NotOwned)
            else do
              total ← volumeTotal dir
              pure $ case total of
                Left e → Left (CannotProbe e)
                Right t | t > polCapBytes pol → Left (OverCap t (polCapBytes pol))
                Right _ → Right (Fixture dir)

-- | The fixture the setup scripts name in @$XDG_CACHE_HOME/hetoimasia/terrain-storage-probe/fixture@, verified
-- against 'defaultPolicy'.
pointerFixture ∷ IO (Either FixtureError Fixture)
pointerFixture = do
  home ← getHomeDirectory
  cache ← maybe (home <> "/.cache") id <$> lookupEnv "XDG_CACHE_HOME"
  let pointer = cache <> "/hetoimasia/terrain-storage-probe/fixture"
  raw ← try (readFile pointer) ∷ IO (Either IOException String)
  case fmap (takeWhile (/= '\n')) raw of
    Right d | not (null d) → acquireFixture defaultPolicy d
    _ → pure (Left (NoPointer pointer))

-- | The volume's total bytes, asked of an opened descriptor on it.
volumeTotal ∷ FilePath → IO (Either String Word64)
volumeTotal dir = do
  made ← createPrivate productionSeam (BC.pack dir) 77 (const (pure ()))
  case made of
    Left f → pure (Left (show f))
    Right c → do
      -- every native result is looked at: a name that could not be removed would leave a file on the fixture, and a
      -- close that failed leaves a descriptor
      -- an exception between the create and the close closes the descriptor (it is never left held)
      (unlinked, p) ← (do u ← unlinkFile productionSeam (BC.pack dir) (crName c)
                          q ← profileOf productionSeam (crFd c)
                          pure (u, q)) `onException` closeFile productionSeam (crFd c)
      closed ← closeFile productionSeam (crFd c)
      pure $ case (unlinked, closed, p) of
        (Left e, _, _) → Left ("the probe's own temp file could not be unlinked: " <> show e)
        (_, Left e, _) → Left ("the probe's own descriptor could not be closed: " <> show e)
        (_, _, Left e) → Left (show e)
        (_, _, Right prof) → Right (vpTotalBytes prof)
