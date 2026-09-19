-- | The parent side of the Linux feasibility probe.
--
-- Everything the examples need to launch a confined child, read what it
-- observed, and end it: the launcher binding, the environment record the
-- verdict quotes, the controls that make a denial mean something, and the
-- admission ledger that makes "quota release follows observed termination" a
-- checkable claim rather than a sentence.
--
-- Three things here are deliberately not conveniences.
--
-- The ledger is not a counter the launcher decrements. An owner is admitted
-- when a child starts and released only by 'releaseAfter', which observes the
-- termination first; there is no other way to release one, so an example
-- cannot assert a release that nothing observed.
--
-- 'availability' is measured, not inferred. Whether the candidate profile can
-- be installed is a conjunction the kernel evaluates -- a namespace created, a
-- tmpfs mounted, a root pivoted -- and this suite runs in two environments that
-- answer it differently. It is established once, by launching a child, and
-- every example is written against the answer rather than against a hope.
--
-- And a 'Confined' remembers the termination it was told about. Both 'stillRunning'
-- and 'observeExit' reap, and a second reap of the same child is an error
-- rather than a repeat, so the first answer is kept and re-used.
module Test.Confinement.Support
  ( -- * The machine this run is on
    Environment (..)
  , environment
  , describeEnvironment

    -- * Whether the profile installs here
  , Availability (..)
  , availability
  , describeAvailability

    -- * Controls
  , Controls (..)
  , controls

    -- * Launching
  , Launch (..)
  , launchFor
  , Refusal (..)
  , describeRefusal
  , Confined (..)
  , withLaunch
  , withRoot

    -- * The admission ledger
  , Ledger
  , newLedger
  , admittedOwners
  , releaseAfter

    -- * Reading a child
  , Observation (..)
  , observationsIn
  , observationFor
  , fieldIn
  , collect
  , awaitReady
  , awaitLine
  , instruct

    -- * Ending a child
  , requestStop
  , forceStop
  , observeExit
  , stillRunning
  , describeStatus

    -- * Reporting
  , announce
  , whenAvailable
  , reportedObservations
  , reportedLines
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (bracket, catch, throwIO)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Foreign.C
  ( CChar
  , CInt (CInt)
  , CLong (CLong)
  , CSize (CSize)
  , CString
  , withCString
  )
import Foreign.C.String (peekCString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (withArray0)
import Foreign.Marshal.Utils (withMany)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable)
import System.IO
  ( BufferMode (LineBuffering)
  , Handle
  , IOMode (ReadMode, ReadWriteMode)
  , hClose
  , hFlush
  , hGetLine
  , hPutStrLn
  , hSetBuffering
  , openFile
  )
import System.IO.Error (isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO (closeFd, createPipe, fdToHandle, handleToFd)
import System.Posix.Process
  ( ProcessStatus (Exited, Stopped, Terminated)
  , getProcessID
  , getProcessStatus
  )
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcess)
import System.Posix.Types (CPid (CPid), Fd, ProcessID)
import Test.Hspec (Expectation, shouldNotBe)
import Test.Support.Bounded (bounded)

-- --------------------------------------------------------------------------
-- The machine this run is on

-- | What requirement 8 asks a record of, read from the unconfined parent.
--
-- The parent reads it rather than the child because a confined child cannot:
-- once its private root is in place there is no @/proc@ and no @/etc@ to read
-- an answer from, and a record assembled from inside the sandbox would be a
-- record of the sandbox.
data Environment = Environment
  { environmentKernel ∷ !String
  , environmentDistribution ∷ !String
  , environmentUser ∷ !String
  , environmentSysAdmin ∷ !Bool
  , environmentUserNamespace ∷ !(Either Int ())
  -- ^ @Left errno@ when no user namespace this process could confine a child
  -- in can be created. The whole sequence is attempted, not only the
  -- @unshare@: a namespace the creator holds no capability inside is not one
  -- anything can be confined in, and on a distribution that restricts
  -- unprivileged user namespaces that is exactly what the bare call produces.
  , environmentUsernsRestriction ∷ !(Maybe String)
  -- ^ The distribution's unprivileged-user-namespace restriction, when it has
  -- one. Ubuntu 24.04 ships @kernel.apparmor_restrict_unprivileged_userns@ set,
  -- which is administrative setup requirement 8 asks a record of and which a
  -- reader of a refusal would otherwise have to guess at.
  , environmentCgroupControllers ∷ !String
  , environmentCgroupDelegated ∷ !Bool
  , environmentContainerised ∷ !Bool
  }

environment ∷ IO Environment
environment = do
  kernel ← textIn "/proc/sys/kernel/osrelease"
  release ← textIn "/etc/os-release"
  identity ← textIn "/proc/self/status"
  controllers ← textIn "/sys/fs/cgroup/cgroup.controllers"
  delegated ← writable "/sys/fs/cgroup/cgroup.subtree_control"
  container ← doesFileExist "/.dockerenv"
  restriction ← textIn "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
  admin ← (/= 0) <$> hetoimasia_confine_has_sys_admin
  (available, reported) ←
    alloca $ \observed → do
      answered ← hetoimasia_confine_user_namespace_available observed
      (,) answered <$> peek observed
  pure
    Environment
      { environmentKernel = firstLine kernel
      , environmentDistribution = fromMaybe "unknown" (valueOf "PRETTY_NAME=" release)
      , environmentUser = fromMaybe "unknown" (fieldOf "Uid:" identity)
      , environmentSysAdmin = admin
      , environmentUserNamespace =
          if available /= 0 then Right () else Left (fromIntegral reported)
      , environmentUsernsRestriction =
          case words restriction of
            [] → Nothing
            (setting : _) → Just ("apparmor_restrict_unprivileged_userns=" <> setting)
      , environmentCgroupControllers = firstLine controllers
      , environmentCgroupDelegated = delegated
      , environmentContainerised = container
      }
  where
    firstLine text = case lines text of
      (line : _) → line
      [] → "unknown"
    valueOf key text =
      case [drop (length key) line | line ← lines text, key `isPrefixOf` line] of
        (value : _) → Just (filter (/= '"') value)
        [] → Nothing
    fieldOf key text =
      case [unwords (words (drop (length key) line)) | line ← lines text, key `isPrefixOf` line] of
        (value : _) → Just value
        [] → Nothing

-- | Read a file this machine may not have. Absence is an answer, not a failure.
textIn ∷ FilePath → IO String
textIn path = catch (readFile path) (\failure → const (pure "") (failure ∷ IOError))

-- | Whether this process could write a file, asked without writing one.
--
-- Read-write rather than write: this asks a question about a kernel control
-- file, and opening one for writing alone would truncate it on any filesystem
-- that honours that, which is not a question anybody asked.
writable ∷ FilePath → IO Bool
writable path = do
  present ← doesFileExist path
  if not present
    then pure False
    else
      catch
        (bracket (openFile path ReadWriteMode) hClose (const (pure True)))
        (\failure → const (pure False) (failure ∷ IOError))

describeEnvironment ∷ Environment → String
describeEnvironment record =
  "ENVIRONMENT kernel="
    <> show (environmentKernel record)
    <> " distribution="
    <> show (environmentDistribution record)
    <> " uid="
    <> show (environmentUser record)
    <> " cap-sys-admin="
    <> yesNo (environmentSysAdmin record)
    <> " user-namespace="
    <> either
      (\code → "denied:errno=" <> show code)
      (const "available")
      (environmentUserNamespace record)
    <> " userns-restriction="
    <> maybe "none" show (environmentUsernsRestriction record)
    <> " cgroup-controllers="
    <> show (environmentCgroupControllers record)
    <> " cgroup-subtree-writable="
    <> yesNo (environmentCgroupDelegated record)
    <> " container="
    <> yesNo (environmentContainerised record)

yesNo ∷ Bool → String
yesNo condition = if condition then "yes" else "no"

-- --------------------------------------------------------------------------
-- Controls

-- | The same operations the child will be refused, performed here, where
-- nothing refuses them.
--
-- Without these the child's report is indistinguishable from a broken fixture:
-- a sentinel that never existed is unreadable everywhere, and a module name
-- this machine does not have fails to load everywhere.
data Controls = Controls
  { controlSentinels ∷ ![(FilePath, Int)]
  -- ^ Each host sentinel and the @errno@ the parent saw reading it; 0 is the
  -- only value that makes the child's failure to read it mean anything.
  , controlModule ∷ !(Maybe String)
  -- ^ A native module this machine has, that the parent could load, and that
  -- neither process already links.
  , controlInetSocket ∷ !Int
  -- ^ The @errno@ the parent saw creating an @AF_INET@ socket. The filter
  -- treats that domain differently from @AF_UNIX@, so the child's @AF_UNIX@
  -- control says nothing about it: without this, a machine with no network
  -- stack at all would produce the same refusal inside the child and it would
  -- be read as the filter's work.
  , controlInheritedDescriptor ∷ !Int
  -- ^ A descriptor the parent holds open, without close-on-exec, at a number
  -- above any range a sweep might have guessed at. A child that can still see
  -- it was handed an ambient capability.
  }

controls ∷ [FilePath] → IO Controls
controls sentinels = do
  readable ←
    mapM
      (\path → (,) path . fromIntegral <$> withCString path hetoimasia_probe_read_file)
      sentinels
  loadable ← firstLoadable moduleCandidates
  inet ← fromIntegral <$> hetoimasia_probe_open_socket afInet
  -- The fixture has to sit above the number a swept range would have stopped
  -- at, and the default soft limit puts the highest usable descriptor exactly
  -- at that boundary, so the limit is raised to its hard value first.
  ceilingNow ← hetoimasia_raise_descriptor_limit
  held ← openFile "/dev/null" ReadMode >>= handleToFd
  -- Left inheritable on purpose. Nothing closes it: it must still be there
  -- when every child is launched.
  raised ← fcntlDuplicateAbove held (placeFixtureAt ceilingNow)
  closeFd held
  pure
    Controls
      { controlSentinels = readable
      , controlModule = loadable
      , controlInetSocket = inet
      , controlInheritedDescriptor = fromIntegral raised
      }
  where
    -- Ordinary shared libraries a Linux distribution has and a Haskell program
    -- does not link. Both halves matter. The parent must be able to load it,
    -- so that the child failing to is about the child; and neither may already
    -- have it loaded, because `dlopen` on a module the program links takes a
    -- reference to what is already mapped without mapping a file, which would
    -- succeed inside the child and prove nothing.
    moduleCandidates =
      [ "libbz2.so.1.0"
      , "liblzma.so.5"
      , "libzstd.so.1"
      , "libz.so.1"
      , "libexpat.so.1"
      , "libcrypt.so.1"
      ]
    firstLoadable [] = pure Nothing
    firstLoadable (candidate : rest) = do
      alreadyHere ← withCString candidate hetoimasia_probe_module_loaded
      if alreadyHere /= 0
        then firstLoadable rest
        else do
          outcome ←
            allocaBytes 256 $ \message →
              withCString candidate $ \path →
                hetoimasia_probe_load_module path message 256
          if outcome == 0 then pure (Just candidate) else firstLoadable rest

-- | Where the deliberately inherited descriptor is put.
--
-- Above 1024, because a sweep that loops to a round number is exactly the
-- mistake this fixture exists to catch, and below the limit now in force
-- because otherwise it cannot be placed at all.
placeFixtureAt ∷ CSize → CInt
placeFixtureAt ceilingNow
  | ceilingNow > 1200 = 1100
  | ceilingNow > 16 = fromIntegral ceilingNow - 8
  | otherwise = 8

-- | Duplicate a descriptor to at least @lowest@, without close-on-exec.
fcntlDuplicateAbove ∷ Fd → CInt → IO Fd
fcntlDuplicateAbove source lowest = do
  raised ← c_fcntl_dupfd (fromIntegral source) fDupfd lowest
  if raised < 0
    then throwIO (userError "could not place the inherited-descriptor fixture")
    else pure (fromIntegral raised)

-- | @F_DUPFD@: duplicates to the lowest free number at or above the argument,
-- and -- unlike @F_DUPFD_CLOEXEC@ -- leaves the copy inheritable, which is the
-- whole point of the fixture.
fDupfd ∷ CInt
fDupfd = 0

foreign import ccall unsafe "fcntl"
  c_fcntl_dupfd ∷ CInt → CInt → CInt → IO CInt

-- | @AF_INET@, spelled here for the same reason the child spells it.
afInet ∷ CInt
afInet = 2

-- --------------------------------------------------------------------------
-- Launching

-- | One launch, fully described. Nothing is defaulted inside the launcher.
data Launch = Launch
  { launchMode ∷ !String
  , launchRoot ∷ !FilePath
  , launchOutside ∷ ![FilePath]
  , launchEndpoint ∷ !String
  , launchPeerEndpoint ∷ !String
  , launchModule ∷ !String
  , launchMemoryLimit ∷ !Integer
  , launchAllocationStep ∷ !Int
  , launchInheritedProbe ∷ !Int
  , launchOutsidePid ∷ !Int
  }

-- | A launch of @mode@ with this run's fixtures, and no memory ceiling.
launchFor ∷ String → FilePath → Controls → [FilePath] → String → Launch
launchFor mode root available sentinels endpoint =
  Launch
    { launchMode = mode
    , launchRoot = root
    , launchOutside = sentinels
    , launchEndpoint = endpoint
    , launchPeerEndpoint = endpoint <> "-absent-peer"
    , launchModule = fromMaybe "libc.so.6" (controlModule available)
    , launchMemoryLimit = 0
    , launchAllocationStep = 64 * 1024 * 1024
    , launchInheritedProbe = controlInheritedDescriptor available
    , launchOutsidePid = 0
    }

-- | Which prerequisite was missing, and what the kernel said about it.
data Refusal = Refusal
  { refusedLayer ∷ !String
  , refusedErrno ∷ !Int
  }
  deriving (Eq, Show)

describeRefusal ∷ Refusal → String
describeRefusal refusal =
  "layer=" <> refusedLayer refusal <> " errno=" <> show (refusedErrno refusal)

-- | A running confined child, the two descriptors the parent holds for it, and
-- the termination it has already been told about.
data Confined = Confined
  { confinedPid ∷ !ProcessID
  , confinedReading ∷ !Handle
  -- ^ The child's standard output and error.
  , confinedWriting ∷ !Handle
  -- ^ The parent's end of the child's inherited command endpoint.
  , confinedStatus ∷ !(IORef (Maybe ProcessStatus))
  }

-- | Run a body over a private root directory.
--
-- The directory stays empty on the host: the child mounts a tmpfs over it
-- inside its own mount namespace, so nothing written there is written here.
withRoot ∷ (FilePath → IO a) → IO a
withRoot body =
  withSystemTempDirectory "hetoimasia-confine" $ \directory → do
    let root = directory <> "/root"
    createDirectoryIfMissing True root
    body root

-- | Launch a child, run a body over it, and leave nothing running.
--
-- The cleanup is unconditional and ends with an observed termination, because
-- an example that failed is exactly the case in which a child would otherwise
-- be left behind. A body that already released the owner is not released
-- twice: the ledger is what says whether there is anything to do.
withLaunch ∷ Ledger → Launch → (Either Refusal Confined → IO a) → IO a
withLaunch ledger request = bracket (launch ledger request) release
  where
    release (Left _) = pure ()
    release (Right child) = do
      owners ← admittedOwners ledger
      when (confinedPid child `elem` owners) $ do
        alive ← stillRunning child
        when alive (forceStop child)
        _ ← releaseAfter ledger child
        pure ()
      closeQuietly (confinedReading child)
      closeQuietly (confinedWriting child)
    closeQuietly handle =
      catch (hClose handle) (\failure → const (pure ()) (failure ∷ IOError))

launch ∷ Ledger → Launch → IO (Either Refusal Confined)
launch ledger request = do
  -- This process is a real process on the host, owned by the same user, and
  -- outside whatever namespace the child ends up in. Whether the child can
  -- reach it is the adversarial question, so the child is told where to aim.
  here ← getProcessID
  found ← findExecutable "lua-confine-child"
  program ←
    maybe
      (throwIO (userError "no lua-confine-child on PATH; the probe cannot launch"))
      pure
      found
  (outputRead, outputWrite) ← createPipe
  (commandRead, commandWrite) ← createPipe
  nothing ← openFile "/dev/null" ReadMode >>= handleToFd
  let settled = request {launchOutsidePid = fromIntegral here}
  (pid, layer, failure) ←
    withCString program $ \programPath →
      withCString (launchRoot settled) $ \rootPath →
        withMany withCString (argumentsFor settled) $ \argumentList →
          withArray0 nullPtr argumentList $ \argv →
            withMany withCString childEnvironment $ \environmentList →
              withArray0 nullPtr environmentList $ \envp →
                alloca $ \refusedLayerAt → alloca $ \refusedErrnoAt → do
                  started ←
                    hetoimasia_confine_spawn
                      programPath
                      argv
                      envp
                      rootPath
                      (fromIntegral (launchMemoryLimit settled))
                      (fromIntegral commandRead)
                      (fromIntegral nothing)
                      (fromIntegral outputWrite)
                      refusedLayerAt
                      refusedErrnoAt
                  (,,) started <$> peek refusedLayerAt <*> peek refusedErrnoAt
  closeFd outputWrite
  closeFd commandRead
  closeFd nothing
  if pid < 0
    then do
      closeFd outputRead
      closeFd commandWrite
      named ← hetoimasia_confine_layer_name layer >>= peekCString
      pure (Left (Refusal named (fromIntegral failure)))
    else do
      reading ← fdToHandle outputRead
      writing ← fdToHandle commandWrite
      hSetBuffering reading LineBuffering
      hSetBuffering writing LineBuffering
      remembered ← newIORef Nothing
      admit ledger pid
      pure
        ( Right
            Confined
              { confinedPid = pid
              , confinedReading = reading
              , confinedWriting = writing
              , confinedStatus = remembered
              }
        )
  where
    argumentsFor settings =
      "/probe"
        : ("--mode=" <> launchMode settings)
        : ("--endpoint=" <> launchEndpoint settings)
        : ("--peer-endpoint=" <> launchPeerEndpoint settings)
        : ("--module=" <> launchModule settings)
        : ("--allocation-step=" <> show (launchAllocationStep settings))
        : ("--inherited-probe=" <> show (launchInheritedProbe settings))
        : ("--outside-pid=" <> show (launchOutsidePid settings))
        : ["--outside=" <> path | path ← launchOutside settings]
    -- No home directory, no credentials, no inherited configuration: what the
    -- child gets is what a mod would get, which is a locale and nothing else.
    childEnvironment = ["PATH=/", "LANG=C.UTF-8", "LC_ALL=C.UTF-8"]

-- --------------------------------------------------------------------------
-- The admission ledger

-- | The owners this parent has admitted and not yet released.
newtype Ledger = Ledger (MVar [ProcessID])

newLedger ∷ IO Ledger
newLedger = Ledger <$> newMVar []

admit ∷ Ledger → ProcessID → IO ()
admit (Ledger slot) pid = modifyMVar_ slot (pure . (pid :))

admittedOwners ∷ Ledger → IO [ProcessID]
admittedOwners (Ledger slot) = sort <$> readMVar slot

-- | Observe this child's termination, and only then release its owner.
--
-- The order is the claim. Nothing else releases an owner, so an example that
-- asserts the ledger is empty is asserting that a termination was observed for
-- every child, not that a launcher counted one down optimistically.
releaseAfter ∷ Ledger → Confined → IO ProcessStatus
releaseAfter (Ledger slot) child = do
  status ← observeExit child
  modifyMVar_ slot (pure . filter (/= confinedPid child))
  pure status

-- --------------------------------------------------------------------------
-- Reading a child

-- | One line of a child's report, parsed into the fields it names.
data Observation = Observation
  { observationKind ∷ !String
  , observationFields ∷ ![(String, String)]
  }
  deriving (Eq, Show)

observationsIn ∷ [String] → [Observation]
observationsIn = mapMaybe parse
  where
    parse line = case words line of
      [] → Nothing
      (kind : rest) → Just (Observation kind (map field rest))
    field token = case break (== '=') token of
      (key, '=' : value) → (key, value)
      (key, _) → (key, "")

-- | The observation of one named probe in one phase.
observationFor ∷ String → String → [Observation] → Maybe Observation
observationFor phase name reported =
  case
    [ entry
    | entry ← reported
    , observationKind entry == "OBSERVED"
    , lookup "phase" (observationFields entry) == Just phase
    , lookup "name" (observationFields entry) == Just name
    ]
    of
    (entry : _) → Just entry
    [] → Nothing

fieldIn ∷ String → Observation → String
fieldIn key entry = fromMaybe "" (lookup key (observationFields entry))

-- | Read everything the child prints, to its end.
collect ∷ Confined → IO [String]
collect child = bounded (drain [])
  where
    drain gathered = do
      line ←
        catch
          (Just <$> hGetLine (confinedReading child))
          (\failure → if isEOFError failure then pure Nothing else throwIO failure)
      case line of
        Nothing → pure (reverse gathered)
        Just text → drain (text : gathered)

-- | Read the child's report up to and including its @READY@ line.
awaitReady ∷ Confined → IO [String]
awaitReady = awaitLine "READY"

-- | Read the child's report up to and including the first line starting with
-- @marker@.
awaitLine ∷ String → Confined → IO [String]
awaitLine marker child = bounded (drain [])
  where
    drain gathered = do
      line ← hGetLine (confinedReading child)
      if marker `isPrefixOf` line
        then pure (reverse (line : gathered))
        else drain (line : gathered)

-- | Send one instruction over the child's inherited endpoint.
instruct ∷ Confined → String → IO ()
instruct child text = do
  hPutStrLn (confinedWriting child) text
  hFlush (confinedWriting child)

-- --------------------------------------------------------------------------
-- Ending a child

requestStop ∷ Confined → IO ()
requestStop = sendTo sigTERM

forceStop ∷ Confined → IO ()
forceStop = sendTo sigKILL

-- | A signal aimed at a child that may already have ended is not a failure:
-- the question these examples ask is what the parent observed, and a child
-- that ended first has already answered it.
sendTo ∷ Signal → Confined → IO ()
sendTo signal child =
  catch
    (signalProcess signal (confinedPid child))
    (\failure → const (pure ()) (failure ∷ IOError))

-- | Wait for this child to terminate, and answer how it did.
--
-- Bounded, because an example that waits forever for a child that will never
-- end is a hung run rather than a failing test.
observeExit ∷ Confined → IO ProcessStatus
observeExit child = do
  remembered ← readIORef (confinedStatus child)
  case remembered of
    Just status → pure status
    Nothing → do
      reported ← bounded (getProcessStatus True False (confinedPid child))
      case reported of
        Nothing → throwIO (userError "no termination was reported for a child")
        Just status → do
          writeIORef (confinedStatus child) (Just status)
          pure status

-- | Whether this child is still running, asked without waiting for it.
stillRunning ∷ Confined → IO Bool
stillRunning child = do
  remembered ← readIORef (confinedStatus child)
  case remembered of
    Just _ → pure False
    Nothing → do
      reported ← getProcessStatus False False (confinedPid child)
      case reported of
        Nothing → pure True
        Just (Stopped _) → pure True
        Just status → do
          writeIORef (confinedStatus child) (Just status)
          pure False

describeStatus ∷ ProcessStatus → String
describeStatus (Exited code) = "exited:" <> show code
describeStatus (Terminated signal dumped) =
  "signalled:" <> show signal <> (if dumped then ":core" else "")
describeStatus (Stopped signal) = "stopped:" <> show signal

-- --------------------------------------------------------------------------
-- Whether the profile installs here

-- | Whether the candidate profile can be installed on this machine at all.
data Availability
  = -- | It installed, and this is what the trial child reported.
    Installs ![String]
  | -- | It did not, and this is the prerequisite that was missing.
    Blocked !Refusal

availability ∷ Ledger → Controls → [FilePath] → IO Availability
availability ledger available sentinels =
  withRoot $ \root →
    withLaunch ledger (launchFor "report" root available sentinels "hetoimasia-trial") $
      \outcome → case outcome of
        Left refusal → pure (Blocked refusal)
        Right child → do
          reported ← collect child
          _ ← releaseAfter ledger child
          pure (Installs reported)

-- | The trial child's own report, verbatim, or none when nothing ran.
reportedLines ∷ Availability → [String]
reportedLines (Installs reported) = reported
reportedLines (Blocked _) = []

-- | The trial child's own observations, or none when nothing ran.
reportedObservations ∷ Availability → [Observation]
reportedObservations = observationsIn . reportedLines

-- | Run an example's body where the profile installs; where it does not, assert
-- the blocked contract instead and say so.
--
-- This is what keeps a green suite from reading as a supported platform. An
-- environment that cannot install the profile still has something to verify --
-- that the refusal is typed and names a prerequisite, which is requirement 2's
-- fail-closed contract -- and the line it prints is what the verdict quotes
-- when it records the experiment as unproven here.
whenAvailable ∷ Availability → String → IO () → Expectation
whenAvailable (Installs _) _ body = body
whenAvailable (Blocked refusal) subject _ = do
  refusedLayer refusal `shouldNotBe` ""
  refusedErrno refusal `shouldNotBe` 0
  announce ("BLOCKED experiment=" <> subject <> " unproven-here " <> describeRefusal refusal)

describeAvailability ∷ Availability → String
describeAvailability (Installs _) = "AVAILABILITY profile=installed"
describeAvailability (Blocked refusal) =
  "AVAILABILITY profile=refused " <> describeRefusal refusal

-- --------------------------------------------------------------------------
-- Reporting

-- | Print what an example proved, or what blocked it.
--
-- Every example calls this. The suite's own output is the retained evidence
-- requirement 8 asks for, and a green example that printed nothing would leave
-- the verdict quoting a pass rather than an observation.
announce ∷ String → IO ()
announce = putStrLn

-- --------------------------------------------------------------------------
-- The launcher and the probes, from the parent's side

foreign import ccall safe "hetoimasia_confine.h hetoimasia_confine_spawn"
  hetoimasia_confine_spawn
    ∷ CString
    → Ptr CString
    → Ptr CString
    → CString
    → CLong
    → CInt
    → CInt
    → CInt
    → Ptr CInt
    → Ptr CInt
    → IO CPid

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_confine_layer_name"
  hetoimasia_confine_layer_name ∷ CInt → IO CString

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_read_file"
  hetoimasia_probe_read_file ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_open_socket"
  hetoimasia_probe_open_socket ∷ CInt → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_load_module"
  hetoimasia_probe_load_module ∷ CString → Ptr CChar → CSize → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_module_loaded"
  hetoimasia_probe_module_loaded ∷ CString → IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_raise_descriptor_limit"
  hetoimasia_raise_descriptor_limit ∷ IO CSize

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_confine_has_sys_admin"
  hetoimasia_confine_has_sys_admin ∷ IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_confine_user_namespace_available"
  hetoimasia_confine_user_namespace_available ∷ Ptr CInt → IO CInt
