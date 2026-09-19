-- | The confined helper the macOS probe launches.
--
-- It is a test fixture, not a shipped tool: no production library, executable,
-- or public API depends on it, and it admits no untrusted source through any
-- public path -- the only Lua it ever loads is the fixture its own parent wrote
-- into the private directory it was given.
--
-- The order of its startup is the thing being proved. Confinement is installed
-- and then verified against accesses the parent has separately shown are
-- reachable without it; only after that does anything read module source. Every
-- failure before that point is a typed refusal with its own exit status, and
-- none of them continues as a plain unconfined child.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import qualified Data.ByteString as ByteString
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import Text.Read (readMaybe)

import Hetoimasia.Scripting.Lua.Bridge
  ( Library (..)
  , Vm
  , callGlobal
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Confine
  ( Attempt (..)
  , Confinement (..)
  , attemptConnectUnix
  , attemptExecute
  , attemptLoadModule
  , attemptReadFile
  , installConfinement
  , probeExecuteProgram
  , probeHomeSentinel
  , probeNativeModule
  , probeOwnEndpoint
  , probePeerEndpoint
  , probePeerSentinel
  , probePrelude
  , readFootprint
  , addressSpaceFloor
  , verifyConfinement
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report
  ( Origin (..)
  , Outcome (..)
  , Refusal (..)
  , Report (..)
  , refusalExitCode
  , renderReport
  )

-- | The helper's command line, all of it supplied by the parent.
data Options = Options
  { optionMode ∷ Text
  , optionProfile ∷ FilePath
  , optionPrivate ∷ FilePath
  , optionEndpoint ∷ FilePath
  , optionPeerEndpoint ∷ FilePath
  , optionHomeSentinel ∷ FilePath
  , optionPeerSentinel ∷ FilePath
  , optionExecTarget ∷ FilePath
  , optionNativeModule ∷ FilePath
  , optionCeilingMiB ∷ Int
  }

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  options ← parseOptions <$> getArgs
  selfBinary ← getExecutablePath
  let confinement =
        Confinement
          { confinementSelfBinary = selfBinary
          , confinementPrivateDirectory = optionPrivate options
          , confinementEndpoint = optionEndpoint options
          }
  profile ← try @SomeException (Text.readFile (optionProfile options))
  case profile of
    Left _ →
      refuse
        ConfinementUnavailable
        ("no profile at " <> Text.pack (optionProfile options))
    Right text → do
      installed ← installConfinement text confinement
      case installed of
        Left (refusal, detail) → refuse refusal detail
        Right () → confined options confinement

-- | Everything after the profile is in force.
confined ∷ Options → Confinement → IO ()
confined options confinement = do
  attempts ← nativeSweep options
  forM_ attempts $ \(name, attempt) → emit (access OriginNative name attempt)
  -- The helper's own endpoint is the control inside the sandbox: if the profile
  -- refused that too, its parameters did not resolve and every denial beside it
  -- proves nothing.
  ownReachable ← attemptConnectUnix (confinementEndpoint confinement)
  emit (access OriginNative probeOwnEndpoint ownReachable)
  case attemptOutcome ownReachable of
    Denied →
      refuse
        ConfinementFailed
        ("the profile refused this instance's own endpoint: " <> attemptMechanism ownReachable)
    Allowed → case verifyConfinement attempts of
      Left (refusal, detail) → refuse refusal detail
      Right () → do
        emit Ready
        admitted options confinement

-- | The forbidden accesses, attempted natively before any source is loaded.
nativeSweep ∷ Options → IO [(Text, Attempt)]
nativeSweep options =
  forM
    [ (probeHomeSentinel, attemptReadFile (optionHomeSentinel options))
    , (probePeerSentinel, attemptReadFile (optionPeerSentinel options))
    , (probePeerEndpoint, attemptConnectUnix (optionPeerEndpoint options))
    , (probeExecuteProgram, attemptExecute (optionExecTarget options))
    , (probeNativeModule, attemptLoadModule (optionNativeModule options))
    ]
    (\(name, attempt) → (name,) <$> attempt)

-- | The helper is confined, verified, and admitted; now it does its mode.
admitted ∷ Options → Confinement → IO ()
admitted options confinement
  | optionMode options == "init-fail" =
      refuse InitializationFailed "the mode asked for a failure after admission"
  | otherwise = do
      let sourcePath = confinementPrivateDirectory confinement <> "/module.lua"
      source ← try @SomeException (ByteString.readFile sourcePath)
      case source of
        Left _ → refuse ModuleSourceUnavailable ("no module source at " <> Text.pack sourcePath)
        Right bytes → do
          vm ← newVm [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryIo, LibraryOs, LibraryPackage]
          evalChunk vm (chunkName "prelude") (Text.encodeUtf8 (prelude options))
          evalChunk vm (chunkName "module") bytes
          postLoadSweep options
          runMode options vm
          closeVm vm

-- | The same forbidden accesses again, natively, once untrusted source is
-- resident.
--
-- Lua's standard library has no socket API, so the network row cannot be
-- attempted from Lua at all; attempting it natively after the load is how that
-- row is covered without pretending a Lua call made it.
postLoadSweep ∷ Options → IO ()
postLoadSweep options = do
  attempts ← nativeSweep options
  forM_ attempts $ \(name, attempt) → emit (access OriginNativePostLoad name attempt)

-- | What each mode does once it is admitted and loaded.
runMode ∷ Options → Vm → IO ()
runMode options vm = case optionMode options of
  "hold" → do
    reportFootprint
    callGlobal vm "hmp_spin"
  "grow" → do
    reportFootprint
    grow 0 []
  _ → do
    reportFootprint
    floorResult ← addressSpaceFloor
    forM_ floorResult (\(bytes, code) → emit (RlimitFloor bytes code))
    emit Done
 where
  -- The workload's own finite ceiling. It is independent of the limit under
  -- test, and reaching it is the observation that the limit did nothing.
  grow held natively
    | held >= optionCeilingMiB options = do
        reportFootprint
        emit (Ceiling held)
        emit Done
    | otherwise = do
        callGlobal vm "hmp_grow_step"
        let block = ByteString.replicate (8 * 1024 * 1024) 0x6e
        ByteString.length block `seq` pure ()
        emit (Held (held + 16))
        -- Reported every step, not once: the last footprint before the kill is
        -- what says which ledger the limit was measured against.
        reportFootprint
        grow (held + 16) (block : natively)

  reportFootprint = do
    measured ← readFootprint
    forM_ measured (\(footprint, virtualSize) → emit (Footprint footprint virtualSize))

prelude ∷ Options → Text
prelude options =
  probePrelude
    [ ("HMP_HOME_SENTINEL", optionHomeSentinel options)
    , ("HMP_PEER_SENTINEL", optionPeerSentinel options)
    , ("HMP_EXEC_TARGET", optionExecTarget options)
    , ("HMP_NATIVE_MODULE", optionNativeModule options)
    ]

access ∷ Origin → Text → Attempt → Report
access origin name attempt =
  Access origin name (attemptOutcome attempt) (attemptMechanism attempt)

emit ∷ Report → IO ()
emit = Text.putStrLn . renderReport

-- | Report a refusal and leave its own exit status behind.
refuse ∷ Refusal → Text → IO a
refuse refusal detail = do
  emit (Refused refusal detail)
  exitWith (ExitFailure (refusalExitCode refusal))

parseOptions ∷ [String] → Options
parseOptions arguments =
  Options
    { optionMode = text "--mode" "report"
    , optionProfile = value "--profile" ""
    , optionPrivate = value "--private" ""
    , optionEndpoint = value "--endpoint" ""
    , optionPeerEndpoint = value "--peer-endpoint" ""
    , optionHomeSentinel = value "--home-sentinel" ""
    , optionPeerSentinel = value "--peer-sentinel" ""
    , optionExecTarget = value "--exec-target" ""
    , optionNativeModule = value "--native-module" ""
    , optionCeilingMiB = fromMaybe 0 (readMaybe (value "--ceiling-mib" "0"))
    }
 where
  pairs = go arguments
  go (key : rest@(next : more))
    | take 2 key == "--" && take 2 next /= "--" = (key, next) : go more
    | take 2 key == "--" = (key, "") : go rest
  go (key : rest) | take 2 key == "--" = (key, "") : go rest
  go (_ : rest) = go rest
  go [] = []
  value key fallback = fromMaybe fallback (lookup key pairs)
  text key fallback = Text.pack (value key (Text.unpack fallback))
