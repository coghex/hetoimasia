-- | The confined child of the Linux feasibility probe.
--
-- One process per mod and execution domain is the shape P-13 fixes, so the
-- question this slice has to answer is asked of a process: what does a child
-- launched inside the candidate profile still reach, and what stops it. This
-- program is that child. It is private to the probe -- no library, executable,
-- or public API of this repository depends on it -- and it admits no mod source
-- through any path a client could reach. The "mod source" it loads is a fixed
-- chunk compiled into this file.
--
-- The order of what happens here is the contract, not an implementation detail:
--
--   1. seal the in-process layers, before a Lua state exists at all;
--   2. establish the controls -- the same operations where they are meant to
--      work -- because a denial observed without one is evidence about a
--      broken fixture rather than about confinement;
--   3. attempt the forbidden operations from native helper code;
--   4. attempt them again from a thread that existed /before/ the filter did
--      and again from one the runtime started /after/ it, because a filter
--      that bound one thread would not be a confinement of this process;
--   5. only then construct a VM and load source, and attempt them once more
--      from inside Lua through trusted test bindings.
--
-- Every observation is printed as one line on standard output, in a shape the
-- parent parses and the verdict quotes. Nothing here decides whether the
-- profile is adequate: it reports what the kernel did, and the suite and the
-- verdict draw the conclusions.
module Main (main) where

import Control.Concurrent (forkOS)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless, when)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C
  ( CChar
  , CInt (CInt)
  , CSize (CSize)
  , CString
  , peekCString
  , withCString
  )
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import Hetoimasia.Scripting.Lua.Bridge
  ( ChunkName
  , FaultKind (MemoryExhausted)
  , Library (LibraryBase, LibraryString, LibraryTable)
  , LuaFault (faultKind)
  , Vm
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
  , installCallback
  )
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (BufferMode (LineBuffering), Handle, hGetLine, hSetBuffering, stdout)
import System.Posix.IO (fdToHandle)
import System.Posix.Types (Fd (Fd))

-- | What the parent asked this child to do.
--
-- Deliberately a closed set. A child that took an arbitrary instruction from
-- its command line would be a launcher, and a launcher is LUA-9's.
data Mode
  = -- | Install, probe, report, exit. What every other mode starts as.
    Report
  | -- | Report, then hold at the handshake until the parent releases it, so
    -- that two of these are alive at the same instant.
    Paired
  | -- | Report, then drive allocation past the installed ceiling.
    Memory
  | -- | Report, then enter a Lua chunk that never yields and never leaves it.
    Spin
  | -- | Report, then wait for a cancellation or a kill, which are the only two
    -- ways out of this mode and the two the lifetime cases need to observe.
    Idle
  deriving (Eq, Show)

-- | Everything the parent tells this child, and nothing it could have inferred.
data Settings = Settings
  { settingMode ∷ !Mode
  , settingOutside ∷ ![FilePath]
  -- ^ Paths that exist on the host and must not exist here.
  , settingEndpoint ∷ !String
  -- ^ The abstract name this child binds.
  , settingPeerEndpoint ∷ !String
  -- ^ The abstract name its sibling binds, which it must not reach.
  , settingModule ∷ !String
  -- ^ A native module the parent loaded successfully before launching this
  -- child, so a failure here is about this child rather than about the module.
  , settingAllocationStep ∷ !Int
  , settingOutsidePid ∷ !Int
  -- ^ A process that exists on the host, belongs to the same user, and is not
  -- in this child's PID namespace: the parent's own.
  , settingInheritedProbe ∷ !Int
  -- ^ A descriptor the parent left open, above any range a guess would have
  -- swept, and which this child must not be able to see.
  }

-- | The private working area, which is all of the filesystem this child writes.
workingArea ∷ FilePath
workingArea = "/work"

-- | The exit statuses this child uses, and what each one means to the parent.
--
-- Distinct because "it failed" is not an observation: the parent has to be able
-- to tell a containment hole from a refusal from an ordinary end.
statusSealRefused
  , statusHoleFound
  , statusSourceFailed
  , statusUsage
  , statusMemoryRefused
  , statusMemoryUnbounded ∷
    Int
statusSealRefused = 10
statusHoleFound = 11
statusSourceFailed = 12
statusUsage = 13
statusMemoryRefused = 20
statusMemoryUnbounded = 21

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments ← getArgs
  case settingsFrom arguments of
    Nothing → do
      putStrLn "USAGE the probe child takes --mode and the fixtures the suite supplies"
      exitWith (ExitFailure statusUsage)
    Just settings → run settings

-- | Parse the parent's instruction. Anything unrecognized is a usage error
-- rather than a default, because a default here would be a profile nobody
-- chose.
settingsFrom ∷ [String] → Maybe Settings
settingsFrom arguments = do
  mode ← lookup "--mode" pairs >>= modeFrom
  endpoint ← lookup "--endpoint" pairs
  peer ← lookup "--peer-endpoint" pairs
  native ← lookup "--module" pairs
  step ← lookup "--allocation-step" pairs
  bytes ← readMaybeInt step
  inheritedProbe ← lookup "--inherited-probe" pairs >>= readMaybeInt
  outsidePid ← lookup "--outside-pid" pairs >>= readMaybeInt
  pure
    Settings
      { settingMode = mode
      , settingOutside = [value | ("--outside", value) ← pairs]
      , settingEndpoint = endpoint
      , settingPeerEndpoint = peer
      , settingModule = native
      , settingAllocationStep = bytes
      , settingOutsidePid = outsidePid
      , settingInheritedProbe = inheritedProbe
      }
  where
    pairs = [splitOnce argument | argument ← arguments, "--" `isPrefixOf` argument]
    splitOnce argument = case break (== '=') argument of
      (key, '=' : value) → (key, value)
      (key, _) → (key, "")
    readMaybeInt text = case reads text of
      [(value, "")] → Just value
      _ → Nothing
    modeFrom name = case name of
      "report" → Just Report
      "paired" → Just Paired
      "memory" → Just Memory
      "spin" → Just Spin
      "idle" → Just Idle
      _ → Nothing

run ∷ Settings → IO ()
run settings = do
  channel ← openCommandChannel
  -- Started before the filter exists, and asked its questions afterwards.
  --
  -- `TSYNC` claims to reach every thread already running, and a threaded
  -- runtime always has several by the time `main` does anything. An assertion
  -- about them is not an observation of them, so one is made here: this thread
  -- is an ordinary bound OS thread that predates the filter, parked until
  -- there is something to ask.
  begin ← newEmptyMVar
  fromExistingThread ← newEmptyMVar
  _ ←
    forkOS $ do
      (own, peer) ← takeMVar begin
      probeNatively "existing-thread" settings own peer
        >>= putMVar fromExistingThread

  seal
  own ← control settings
  -- The pair holds here, before either sibling asks anything about the other.
  --
  -- Binding an endpoint and asking whether a sibling's is reachable are two
  -- events in two processes, and nothing orders them: a probe that ran first
  -- would be refused because the name did not exist yet, which is not the
  -- refusal the example is about. The parent releases both children only once
  -- both have said they are bound.
  peer ←
    if settingMode settings == Paired
      then do
        putStrLn "BOUND mode=paired"
        instruction ← command channel
        putStrLn ("PROCEEDING instruction=" <> instruction)
        -- The sibling's identity on the host, which the parent knows and this
        -- child could not have. Naming it is what makes the signalling probe
        -- adversarial rather than a guess.
        pure (peerPidIn instruction)
      else pure Nothing
  attempts ← probeNatively "native" settings own peer
  putMVar begin (own, peer)
  fromExisting ← takeMVar fromExistingThread

  -- And inheritance is the other half. A filter that covered only the threads
  -- alive when it went in would leave every worker the runtime starts
  -- afterwards unconfined, and the runtime starts them whether or not anyone
  -- asked it to.
  afterwards ← newEmptyMVar
  _ ← forkOS (probeNatively "started-thread" settings own peer >>= putMVar afterwards)
  fromNewThread ← takeMVar afterwards

  let escaped =
        [ name
        | (name, forbidden, observed) ← attempts <> fromExisting <> fromNewThread
        , forbidden
        , observed == 0
        ]
  unless (null escaped) $ do
    putStrLn ("BREACH operations=" <> show escaped)
    exitWith (ExitFailure statusHoleFound)

  loaded ← try (withSource settings own)
  case loaded of
    Left failure → do
      putStrLn ("SOURCE loaded=no reason=" <> show (failure ∷ SomeException))
      exitWith (ExitFailure statusSourceFailed)
    Right () → putStrLn "SOURCE loaded=yes probes=denied controls=allowed"

  case settingMode settings of
    Report → putStrLn "DONE mode=report"
    Paired → do
      putStrLn "READY mode=paired"
      instruction ← command channel
      putStrLn ("DONE mode=paired instruction=" <> instruction)
    Idle → do
      putStrLn "READY mode=idle"
      forever'
    Spin → spin
    Memory → exhaust settings

-- | Install the in-process layers, before a Lua state exists at all.
--
-- A refusal ends the child here. Continuing would be exactly the unconfined
-- child the contract forbids, and this process has nothing else to be.
seal ∷ IO ()
seal = do
  (outcome, layers, failure) ←
    alloca $ \installed → alloca $ \failed → do
      answered ← hetoimasia_confine_seal 0 installed failed
      (,,) answered <$> peek installed <*> peek failed
  if outcome /= 0
    then do
      putStrLn ("PROFILE sealed=no errno=" <> show (fromIntegral failure ∷ Int))
      exitWith (ExitFailure statusSealRefused)
    else do
      held ← hetoimasia_confine_hold_term
      ceilingBytes ← hetoimasia_confine_address_space_limit
      ownPid ← hetoimasia_probe_own_pid
      putStrLn
        ( "PROFILE sealed=yes layers="
            <> show (fromIntegral layers ∷ Int)
            <> " address-space="
            <> show (fromIntegral ceilingBytes ∷ Integer)
            <> " holds-term="
            <> (if held == 0 then "yes" else "no")
            <> " pid="
            <> show (fromIntegral ownPid ∷ Int)
        )

-- | The controls: the same operations, where they are meant to work.
--
-- Answers the child's own sentinel path, written and read back here, so that a
-- later failure to read a path outside the view cannot be confused with this
-- child being unable to read anything at all. The executable-mapping pair is
-- reported here too, because its control and its probe are the same file and
-- differ only in @PROT_EXEC@ -- which is precisely what makes the denial
-- attributable to the filter rather than to the file.
control ∷ Settings → IO FilePath
control settings = do
  let sentinel = workingArea <> "/sentinel"
  ByteString.writeFile sentinel "the child's own file, inside its private working area\n"
  readable ← withCString sentinel hetoimasia_probe_read_file
  unix ← hetoimasia_probe_open_socket afUnix
  bound ← withCString (settingEndpoint settings) hetoimasia_probe_bind_abstract
  reached ← withCString (settingEndpoint settings) hetoimasia_probe_connect_abstract
  (made, withExec, withoutExec) ←
    alloca $ \executable → alloca $ \ordinary → do
      answered ←
        withCString
          (workingArea <> "/mapping")
          (\path → hetoimasia_probe_executable_mapping path executable ordinary)
      (,,) answered <$> peek executable <*> peek ordinary
  report "control" "read-own-sentinel" False readable
  report "control" "open-unix-socket" False unix
  report "control" "bind-own-endpoint" False bound
  report "control" "connect-own-endpoint" False reached
  if made == 0
    then do
      report "control" "map-own-file" False withoutExec
      report "native" "map-own-file-executable" True withExec
    else putStrLn "OBSERVED phase=control name=map-own-file outcome=unavailable"
  pure sentinel

-- | Attempt every forbidden operation from native helper code, and report each.
--
-- Answers @(name, forbidden, errno)@ for each, so the caller can ask the one
-- question that matters without re-deriving it: did anything that should have
-- been refused succeed.
probeNatively ∷ String → Settings → FilePath → Maybe Int → IO [(String, Bool, CInt)]
probeNatively phase settings own peerPid = do
  outside ←
    mapM
      (\path → (,) path <$> withCString path hetoimasia_probe_read_file)
      (settingOutside settings)
  inet ← hetoimasia_probe_open_socket afInet
  peer ← withCString (settingPeerEndpoint settings) hetoimasia_probe_connect_abstract
  executed ← withCString "/probe" hetoimasia_probe_execute
  (loaded, diagnostic) ←
    allocaBytes messageLength $ \message →
      withCString (settingModule settings) $ \path → do
        answered ← hetoimasia_probe_load_module path message (fromIntegral messageLength)
        (,) answered <$> peekCString message
  inherited ←
    hetoimasia_probe_descriptor_open (fromIntegral (settingInheritedProbe settings))
  outsideProcess ← hetoimasia_probe_signal (fromIntegral (settingOutsidePid settings))
  peerProcess ← traverse (hetoimasia_probe_signal . fromIntegral) peerPid
  -- The control travels with them: a phase whose own sentinel became
  -- unreadable is reporting about something other than confinement.
  ownAgain ← withCString own hetoimasia_probe_read_file

  let observations =
        [(readOutside path, True, observed) | (path, observed) ← outside]
          <> [ ("signal-outside-process", True, outsideProcess)]
          <> [("signal-peer-process", True, observed) | Just observed ← [peerProcess]]
          <> [ ("see-inherited-descriptor", True, inherited)
             , ("open-inet-socket", True, inet)
             , ("connect-peer-endpoint", True, peer)
             , ("execute-program", True, executed)
             , ("load-native-module", True, loaded)
             , ("read-own-sentinel", False, ownAgain)
             ]
  mapM_ (\(name, forbidden, observed) → report phase name forbidden observed) observations
  when (loaded /= 0) $
    putStrLn
      ("DETAIL phase=" <> phase <> " name=load-native-module message=" <> show diagnostic)
  pure observations
  where
    messageLength = 256
    readOutside path = "read-outside-sentinel:" <> path

-- | Print one observation.
--
-- The expectation is printed beside the outcome so that a reader of the log,
-- and the verdict quoting it, never has to remember which operations were
-- supposed to be refused.
report ∷ String → String → Bool → CInt → IO ()
report phase name forbidden observed =
  putStrLn
    ( "OBSERVED phase="
        <> phase
        <> " name="
        <> name
        <> " expected="
        <> (if forbidden then "denied" else "allowed")
        <> " outcome="
        <> (if observed == 0 then "allowed" else "denied")
        <> " errno="
        <> show (fromIntegral observed ∷ Int)
    )

-- | Load the fixture source and let it attempt the same operations.
--
-- The chunk is the third vantage point, and the only one a mod would have. It
-- reaches the native operations through trusted bindings this package's own
-- fixture installs, which is what P-13 asks for: the question is whether the
-- operating system refuses, not whether Lua was built without @io@.
--
-- The chunk raises rather than returns on a forbidden success, so a completed
-- load is Lua's own observation of those denials rather than the parent's
-- reading of a number afterwards.
withSource ∷ Settings → FilePath → IO ()
withSource settings own = do
  vm ← newVm [LibraryBase, LibraryString, LibraryTable]
  observations ← newIORef []
  bind vm observations "probe_read_outside_sentinel" $
    case settingOutside settings of
      [] → pure 0
      (path : _) → withCString path hetoimasia_probe_read_file
  bind vm observations "probe_open_inet_socket" (hetoimasia_probe_open_socket afInet)
  bind vm observations "probe_connect_peer_endpoint" $
    withCString (settingPeerEndpoint settings) hetoimasia_probe_connect_abstract
  bind vm observations "probe_execute_program" (withCString "/probe" hetoimasia_probe_execute)
  bind vm observations "probe_load_native_module" $
    allocaBytes 256 $ \message →
      withCString (settingModule settings) $ \path →
        hetoimasia_probe_load_module path message 256
  bind vm observations "probe_read_own_sentinel" (withCString own hetoimasia_probe_read_file)
  evalChunk vm fixtureName fixtureSource
  recorded ← readIORef observations
  mapM_
    (\(name, observed) → report "lua" (Text.unpack name) (name /= ownProbe) observed)
    (reverse recorded)
  closeVm vm
  where
    ownProbe = "probe_read_own_sentinel"

-- | Publish one probe as a global, recording what it observed on the way out.
--
-- @True@ means the operation /succeeded/, so the chunk's own test reads as the
-- question it is asking: did this work.
bind ∷ Vm → IORef [(Text, CInt)] → Text → IO CInt → IO ()
bind vm observations name action =
  installCallback
    vm
    name
    ( do
        observed ← action
        atomicModifyIORef' observations (\entries → ((name, observed) : entries, ()))
        pure (BooleanResult (observed == 0))
    )
    (pure ())

-- | The sibling's host identity, from the parent's release instruction.
--
-- The instruction is @probe \<pid\>@; anything else carries no peer, which is
-- how a mode with no sibling says so.
peerPidIn ∷ String → Maybe Int
peerPidIn instruction = case words instruction of
  [_, value] → case reads value of
    [(pid, "")] → Just pid
    _ → Nothing
  _ → Nothing

fixtureName ∷ ChunkName
fixtureName = chunkName "fixture-mod"

-- | The fixture mod source.
--
-- A literal, because a probe that read source from anywhere a caller could
-- influence would be an admission path, and this slice has none. It raises on
-- any forbidden success, so reaching its last line is Lua's own evidence.
fixtureSource ∷ ByteString.ByteString
fixtureSource =
  "if probe_read_outside_sentinel() then error('a host file outside the view was readable') end\n\
  \if probe_open_inet_socket() then error('an internet socket was created') end\n\
  \if probe_connect_peer_endpoint() then error(\"the sibling's endpoint was reachable\") end\n\
  \if probe_execute_program() then error('another program was executed') end\n\
  \if probe_load_native_module() then error('a native module was loaded') end\n\
  \if not probe_read_own_sentinel() then error('the control read failed, so nothing above is evidence') end\n"

-- | Read one instruction from the inherited endpoint.
--
-- The whole protocol: one line at a time, from the one descriptor the parent
-- gave this child. It is not the wire format -- that is LUA-10's -- but it is
-- inherited, private, and framed, which is what these examples need of it.
--
-- The handle is made once, at the start of the run, because a paired child
-- reads twice: once when its sibling is known to be bound, and once when the
-- parent is finished with it. Re-deriving it from the descriptor for the second
-- read would close the first one's buffer and lose whatever had arrived into
-- it.
openCommandChannel ∷ IO Handle
openCommandChannel = do
  handle ← fdToHandle (Fd 3)
  hSetBuffering handle LineBuffering
  pure handle

command ∷ Handle → IO String
command = hGetLine

-- | Wait for something that never comes.
forever' ∷ IO ()
forever' = do
  never ← newEmptyMVar ∷ IO (MVar ())
  takeMVar never

-- | Enter a chunk that never yields, and never leave it.
--
-- LUA-1 established that a thread inside Lua cannot be cancelled from Haskell,
-- so this child genuinely cannot end itself once the chunk starts. That is the
-- point: the parent's escalation is the only thing that ends it, and a
-- @SIGTERM@ handler is held so that the escalation is the path actually
-- exercised rather than a default action that happens to be terminal.
spin ∷ IO ()
spin = do
  vm ← newVm [LibraryBase]
  installCallback vm "entered" (putStrLn "READY mode=spin" >> pure NoResult) (pure ())
  evalChunk vm (chunkName "never-yields") "entered() while true do end"
  putStrLn "DONE mode=spin"

-- | Drive allocation past the installed ceiling, and report what refused.
--
-- Lua first, because that is the allocation a mod actually makes, and natively
-- afterwards, because the requirement is a limit covering both. The VM is
-- deliberately not closed on the refusing path: a close runs finalizers, which
-- allocate, and this process has just proved it cannot.
exhaust ∷ Settings → IO ()
exhaust settings = do
  vm ← newVm [LibraryBase, LibraryString, LibraryTable]
  outcome ← try (evalChunk vm (chunkName "allocating-mod") allocatingSource)
  let lua = case outcome of
        Left fault
          | faultKind fault == MemoryExhausted → "refused"
          | otherwise → "failed:" <> show (faultKind fault)
        Right () → "completed"
  native ← hetoimasia_probe_allocate (fromIntegral (settingAllocationStep settings))
  ceilingBytes ← hetoimasia_confine_address_space_limit
  putStrLn
    ( "MEMORY lua="
        <> lua
        <> " native-errno="
        <> show (fromIntegral native ∷ Int)
        <> " address-space="
        <> show (fromIntegral ceilingBytes ∷ Integer)
    )
  if lua == "refused" || native /= 0
    then exitWith (ExitFailure statusMemoryRefused)
    else exitWith (ExitFailure statusMemoryUnbounded)
  where
    -- Small, and bounded only by the ceiling: a workload that stopped on its
    -- own would be measuring the workload rather than the limit.
    allocatingSource =
      "local held = {}\n\
      \local block = string.rep('x', 65536)\n\
      \for index = 1, 100000 do held[index] = block .. tostring(index) end\n"

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_confine_seal"
  hetoimasia_confine_seal ∷ CInt → Ptr CInt → Ptr CInt → IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_confine_hold_term"
  hetoimasia_confine_hold_term ∷ IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_confine_address_space_limit"
  hetoimasia_confine_address_space_limit ∷ IO CSize

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_read_file"
  hetoimasia_probe_read_file ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_open_socket"
  hetoimasia_probe_open_socket ∷ CInt → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_bind_abstract"
  hetoimasia_probe_bind_abstract ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_connect_abstract"
  hetoimasia_probe_connect_abstract ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_execute"
  hetoimasia_probe_execute ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_load_module"
  hetoimasia_probe_load_module ∷ CString → Ptr CChar → CSize → IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_executable_mapping"
  hetoimasia_probe_executable_mapping ∷ CString → Ptr CInt → Ptr CInt → IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_probe_descriptor_open"
  hetoimasia_probe_descriptor_open ∷ CInt → IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_probe_signal"
  hetoimasia_probe_signal ∷ CInt → IO CInt

foreign import ccall unsafe "hetoimasia_confine.h hetoimasia_probe_own_pid"
  hetoimasia_probe_own_pid ∷ IO CInt

foreign import ccall safe "hetoimasia_confine.h hetoimasia_probe_allocate"
  hetoimasia_probe_allocate ∷ CSize → IO CInt

-- | The two socket domains this probe names, spelled here rather than bound
-- from a header: @AF_UNIX@ and @AF_INET@ are fixed by the kernel's ABI, and a
-- binding that read them from the build machine would be reading them from the
-- wrong machine when the answer mattered.
afUnix, afInet ∷ CInt
afUnix = 1
afInet = 2
