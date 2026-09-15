-- | Examples proving that the GLFW package keeps its native handles, its
-- session, window, and window command representations, its observation
-- publisher, and command execution and settlement out of reach of a client
-- outside the package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Engine.Resources.Opacity", exposing @base@, @text@, @stm@,
-- @hetoimasia-foundation@, and @hetoimasia-glfw@ and hiding everything else.
-- Five clients must be rejected, each for the diagnostic naming its cause: one
-- names the session's data constructor; one reaches for the native window
-- handle and the production native table, which live in the package's private
-- sublibraries; one names the window's and the observation's constructors; one
-- reaches for a window's native handle and owner-boundary driver in the private
-- window module; and one tries to close a window's observations through the
-- read endpoint it is given. Two are rejected for the monitor inventory: one
-- names the monitor identity's, description's, and inventory's constructors, and
-- one reaches for a native monitor pointer and pointer-lending resolution in the
-- private modules. Two more are rejected for the window commands: one
-- names the command host's, port's, and completion ticket's constructors, and
-- one reaches for command execution and admission hooks in the private command
-- module. One client must be accepted, linked, and run: it uses only the public
-- session, monitor, window, and window command interfaces, including the
-- read-only observation and inventory endpoints, identity resolution, a command
-- port, and a completion ticket, and every path
-- it takes is refused before GLFW is initialized, so the example opens no
-- display.
--
-- The window host from the public @runtime-glfw@ sublibrary is compiled against
-- as well, exposing @hetoimasia-runtime@ and that sublibrary beside the rest.
-- This suite does not import the sublibrary: it is built and registered because
-- @glfw-window-examples@, one of this suite's build tools, depends on it.
-- Six clients must be rejected: one names the host's constructor, one asks
-- the host for its session, windows' command host, and settings, one reaches
-- for the owner loop's executor and event processing in the private modules
-- the sublibrary uses, one asks the host for the collection that owns its
-- windows and the registry of their members and ports, one reaches for that
-- collection and the host's test hooks in the private @runtime-glfw-core@
-- implementation, and one forges a
-- window's client capabilities, or reads another window's port out of them,
-- through the capability's constructor and fields. One client must be accepted,
-- linked, and run: it uses the host's supported configuration, construction,
-- turn, window, and client capabilities, and every path it runs is refused
-- before GLFW is initialized.
--
-- The test seam is a public component so this suite can depend on it. Four more
-- clients are compiled against it and must be rejected: two name the window
-- drivers and the private command executor through the public seam, which
-- exports neither, and two reach for them in the seam's implementation, which
-- belongs to the private @seam-core@ sublibrary, and a fifth names the monitor
-- drivers through the public seam. Only the package's own
-- @glfw-window-examples@ executable can use them.
module Test.Engine.GLFW.Opacity (spec) where

import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Engine.Resources.Opacity (Client (..), Mode (..), rejectedBecause, withPackageClient)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)

spec ∷ Spec
spec = describe "GLFW session opacity across the package boundary" $ do
  it "rejects a client that names the session constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Session"

  it "rejects a client that reaches for a native window handle or the production native table" $
    withClient "Client.hs" nativeHandleClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a native handle is reachable:\n" <> clientOutput outcome)
      -- The modules are found in the built package and refused as belonging to
      -- its private sublibraries, not missing from the environment.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Session"
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Native"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names the window or observation constructor" $
    withClient "Client.hs" windowConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Window"
      clientOutput outcome `shouldContain` "WindowObservation"

  it "rejects a client that reaches for a window's native handle or owner-boundary driver" $
    withClient "Client.hs" windowInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a window's native handle is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Window"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that closes a window's observations through its read endpoint" $
    withClient "Client.hs" publisherClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "SnapshotPublisher"
      clientOutput outcome `shouldContain` "SnapshotReader"

  it "rejects a client that constructs a monitor identity, description, or inventory" $
    withClient "Client.hs" monitorConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "MonitorId"
      clientOutput outcome `shouldContain` "MonitorDescription"
      clientOutput outcome `shouldContain` "MonitorInventory"

  it "rejects a client that reaches for a native monitor pointer or pointer-lending resolution" $
    withClient "Client.hs" monitorInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a native monitor pointer is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Monitor"
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Session"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names a monitor driver through the public seam" $
    withSeamClient "Client.hs" publicSeamMonitorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "seamDeliverMonitorEvents"
      clientOutput outcome `shouldContain` "seamSetMonitorTopology"

  it "rejects a client that names a command host, port, or completion ticket constructor" $
    withClient "Client.hs" commandConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "WindowCommandHost"
      clientOutput outcome `shouldContain` "WindowCommandPort"
      clientOutput outcome `shouldContain` "CompletionTicket"

  it "rejects a client that reaches for command execution or admission hooks in the private command module" $
    withClient "Client.hs" commandInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so command execution is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Command"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names the command executor through the public seam" $
    withSeamClient "Client.hs" publicSeamExecutorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "seamExecuteNext"
      clientOutput outcome `shouldContain` "submitWith"

  it "rejects a client that reaches for the command executor in the private seam implementation" $
    withSeamClient "Client.hs" privateSeamExecutorClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the command executor is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Seam"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "seam-core"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names a window driver through the public seam" $
    withSeamClient "Client.hs" publicSeamDriverClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "seamDrive"
      clientOutput outcome `shouldContain` "seamRejectCloseRequest"

  it "rejects a client that reaches for the window drivers in the private seam implementation" $
    withSeamClient "Client.hs" privateSeamDriverClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the window drivers are reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Seam"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "seam-core"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names the window host's constructor" $
    withHostClient "Client.hs" hostConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "WindowHost"

  it "rejects a client that asks the window host for its session or command host" $
    withHostClient "Client.hs" hostAuthorityClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "hostSession"
      clientOutput outcome `shouldContain` "hostCommands"

  it "rejects a client that asks the window host for the collection owning its windows or their registry" $
    withHostClient "Client.hs" hostCollectionClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "hostCollection"
      clientOutput outcome `shouldContain` "hostEntries"

  it "rejects a client that reaches for the collection or the host hooks in the window host's private implementation" $
    withHostClient "Client.hs" hostCoreClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the window host's collection is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.Runtime.GLFW.Internal"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "runtime-glfw-core"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that forges a window's client capabilities or takes another window's port out of them" $
    withHostClient "Client.hs" windowClientForgeryClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "WindowClient"

  it "rejects a client holding a window host that reaches for the owner loop's executor or event processing" $
    withHostClient "Client.hs" hostInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the owner loop's executor is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Command"
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Window"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts and runs a client using the window host's supported capabilities, without initializing GLFW" $
    withHostClient "Main.hs" hostClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported host client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "default = Right ()"
                   , "zero budget = CommandBudgetRejected 0"
                   , "without the threaded runtime = NotProcessMainThread"
                   ]

  it "accepts and runs a client using only the public session, window, and command interfaces, without initializing GLFW" $
    withClient "Main.hs" publicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "wayland = unsupported Just Wayland, raised by glfw enter session"
                   , "without the threaded runtime = NotProcessMainThread, raised by glfw enter session"
                   , "capacity = 16, description limit = 1024"
                   , "zero width = WindowExtentRejected {rejectedWidth = 0, rejectedHeight = 48}"
                   ]

-- | Compile a client that can also see the runtime and the window host's
-- sublibrary, by its unit id.
withHostClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withHostClient =
  withPackageClient
    [ "base"
    , "text"
    , "stm"
    , "hetoimasia-foundation"
    , "hetoimasia-runtime"
    , "hetoimasia-glfw-0.1.0.0-inplace"
    , "hetoimasia-glfw-0.1.0.0-inplace-runtime-glfw"
    ]

-- | A client naming the window host's data constructor.
hostConstructorClient ∷ String
hostConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Runtime.GLFW (WindowHost (WindowHost))"
    , ""
    , "forged ∷ Maybe WindowHost"
    , "forged = Nothing"
    ]

-- | A client asking the host for the session and command host it owns.
hostAuthorityClient ∷ String
hostAuthorityClient =
  unlines
    [ "module Client (session) where"
    , ""
    , "import Hetoimasia.GLFW.Session (Session)"
    , "import Hetoimasia.Runtime.GLFW (WindowHost, hostCommands, hostSession)"
    , ""
    , "session ∷ WindowHost → Session"
    , "session = hostSession"
    ]

-- | A client asking the host for the collection that owns its windows and the
-- registry of their members and ports.
hostCollectionClient ∷ String
hostCollectionClient =
  unlines
    [ "module Client (collection) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Collection (Collection)"
    , "import Hetoimasia.Runtime.GLFW (WindowHost, hostCollection, hostEntries)"
    , ""
    , "collection ∷ WindowHost → Collection"
    , "collection = hostCollection"
    ]

-- | A client importing the window host's collection and hooks from its private
-- implementation.
hostCoreClient ∷ String
hostCoreClient =
  unlines
    [ "module Client (collection) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Collection (Collection)"
    , "import Hetoimasia.Runtime.GLFW.Internal (WindowHost, allocWindowHostWith, hostCollection)"
    , ""
    , "collection ∷ WindowHost → Collection"
    , "collection = hostCollection"
    ]

-- | A client forging a window's capabilities through their constructor, and
-- reading the port field out of capabilities it was given.
windowClientForgeryClient ∷ String
windowClientForgeryClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Command (WindowClient (WindowClient, clientPort), WindowCommandPort)"
    , ""
    , "forged ∷ WindowClient → WindowCommandPort"
    , "forged (WindowClient _ port _) = port"
    ]

-- | A client holding a host that reaches for the owner loop's executor and
-- event processing in the private modules.
hostInternalsClient ∷ String
hostInternalsClient =
  unlines
    [ "module Client (pump) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Command (executeNextWith)"
    , "import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)"
    , "import Hetoimasia.Runtime.GLFW (WindowHost)"
    , ""
    , "pump ∷ Maybe WindowHost → EventProcessing"
    , "pump _ = ProcessPending"
    ]

-- | A client using the host's supported capabilities. Every path it runs is
-- refused before GLFW is initialized: a budget of zero before the session, and
-- a session entered without the threaded runtime.
hostClient ∷ String
hostClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Control.Exception (SomeException, fromException, try)"
    , "import qualified Data.Text as Text"
    , "import Hetoimasia.Foundation.Messaging.Snapshot (readSnapshot)"
    , "import Hetoimasia.Foundation.Resource (withScoped)"
    , "import Hetoimasia.GLFW.Command"
    , "import Hetoimasia.GLFW.Session (SessionMisuse)"
    , "import Hetoimasia.GLFW.Window"
    , "import Hetoimasia.Runtime.GLFW"
    , "import Hetoimasia.Runtime.Logging (LoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision (RuntimeControl)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let config = defaultHostConfig [hiddenTestWindowConfig (Text.pack \"tool\") 64 48]"
    , "  putStrLn (\"default = \" <> show (validateHostConfig config))"
    , "  rejected ← try (withScoped (allocWindowHost config {hostCommandBudget = 0}) (atomically . hostCommandStatistics))"
    , "  putStrLn (\"zero budget = \" <> describe rejected)"
    , "  unthreaded ← try (withScoped (allocWindowHost config) (atomically . hostCommandStatistics))"
    , "  putStrLn (\"without the threaded runtime = \" <> describe unthreaded)"
    , ""
    , "describe ∷ Either SomeException CommandStatistics → String"
    , "describe outcome = case outcome of"
    , "  Right statistics → \"built \" <> show statistics"
    , "  Left caught"
    , "    | Just rejection ← fromException caught → show (rejection ∷ HostConfigRejected)"
    , "    | Just misuse ← fromException caught → show (misuse ∷ SessionMisuse)"
    , "    | otherwise → \"unexpected \" <> show caught"
    , ""
    , "application ∷ (∀ r. (LoggingLifetime → IO r) → IO r) → IO Int"
    , "application enter ="
    , "  runWindowApplication enter (Text.pack \"tool\") (allocWindowHost (defaultHostConfig [])) id (\\host _ → pure host) serve"
    , ""
    , "serve ∷ WindowHost → RuntimeControl → IO Int"
    , "serve host control ="
    , "  runOwnerLoop host control LoopHooks"
    , "    { loopEvent = noApplicationEvents"
    , "    , loopUpdate = \\turn → do"
    , "        activity ← atomically (hostActivity host)"
    , "        _ ← atomically (readSnapshot (hostMonitors host))"
    , "        mapM_ (rejectHostCloseRequest host) (turnCloseRequests turn)"
    , "        identities ← atomically (hostWindowIdentities host)"
    , "        mapM_ (\\window → submitWindowCommand (hostCommandPort host) [] (observeWindowCommand window)) identities"
    , "        created ← submitWindowCommand (hostCommandPort host) [] (createWindowCommand (hiddenTestWindowConfig (Text.pack \"more\") 64 48))"
    , "        case created of"
    , "          SubmitAccepted ticket → atomically (pollWindowClient ticket) >>= mapM_ (\\client → do"
    , "            _ ← atomically (readSnapshot (clientObservations client))"
    , "            submitWindowCommand (clientCommandPort client) [] (closeWindowCommand (clientWindow client)))"
    , "          _ → pure ()"
    , "        mapM_ (\\window → withHostWindow host window (\\_ → closeHostWindow host window)) identities"
    , "        mapM_ (honourHostCloseRequest host) (turnCloseRequests turn)"
    , "        _ ← hostBookkeeping host"
    , "        atomically (quiesceWindowHost host)"
    , "        pure (if activityWaiting activity then Finish (turnCommands turn) else Continue)"
    , "    }"
    ]

-- | Compile a client that can also see the public test seam, by its unit id.
withSeamClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withSeamClient =
  withPackageClient
    [ "base"
    , "text"
    , "stm"
    , "hetoimasia-foundation"
    , "hetoimasia-glfw-0.1.0.0-inplace"
    , "hetoimasia-glfw-0.1.0.0-inplace-seam"
    ]

-- | A client naming the window drivers through the public seam.
publicSeamDriverClient ∷ String
publicSeamDriverClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Seam (seamDrive, seamRejectCloseRequest)"
    ]

-- | A client naming the command executor and the admission hooks through the
-- public seam.
publicSeamExecutorClient ∷ String
publicSeamExecutorClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Seam (seamExecuteNext, submitWith)"
    ]

-- | A client importing the command executor from the seam's private
-- implementation.
privateSeamExecutorClient ∷ String
privateSeamExecutorClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Seam (seamExecuteNext, seamExecuteNextScripted)"
    ]

-- | A client naming the monitor identity's, description's, and inventory's data
-- constructors.
monitorConstructorClient ∷ String
monitorConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Monitor (MonitorDescription (MonitorDescription), MonitorId (MonitorId), MonitorInventory (MonitorInventory))"
    , ""
    , "forged ∷ Maybe (MonitorId, MonitorDescription, MonitorInventory)"
    , "forged = Nothing"
    ]

-- | A client reaching for the native monitor pointer type and the resolution
-- that lends one, in the private monitor and session modules.
monitorInternalsClient ∷ String
monitorInternalsClient =
  unlines
    [ "module Client (pointer) where"
    , ""
    , "import Foreign.Ptr (Ptr, nullPtr)"
    , "import Hetoimasia.GLFW.Internal.Monitor (NativeMonitor)"
    , "import Hetoimasia.GLFW.Internal.Session (withResolvedMonitor)"
    , ""
    , "pointer ∷ Ptr NativeMonitor"
    , "pointer = nullPtr"
    ]

-- | A client naming the monitor drivers through the public seam.
publicSeamMonitorClient ∷ String
publicSeamMonitorClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Seam (seamDeliverMonitorEvents, seamSetMonitorTopology)"
    ]

-- | A client naming the command host's, port's, and ticket's data constructors.
commandConstructorClient ∷ String
commandConstructorClient =
  unlines
    [ "module Client (host, port, ticket) where"
    , ""
    , "import Hetoimasia.GLFW.Command (CompletionTicket (CompletionTicket), WindowCommandHost (WindowCommandHost), WindowCommandPort (WindowCommandPort))"
    , ""
    , "host ∷ Maybe WindowCommandHost"
    , "host = Nothing"
    , ""
    , "port ∷ Maybe WindowCommandPort"
    , "port = Nothing"
    , ""
    , "ticket ∷ Maybe CompletionTicket"
    , "ticket = Nothing"
    ]

-- | A client reaching for command execution, which settles tickets, and for the
-- admission hooks, in the private command module.
commandInternalsClient ∷ String
commandInternalsClient =
  unlines
    [ "module Client (settle) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Command (ExecutionStep, WindowCommandHost, executeNextWith, noAdmissionHooks)"
    , ""
    , "settle ∷ WindowCommandHost → IO ExecutionStep"
    , "settle host = noAdmissionHooks `seq` executeNextWith (pure ()) host (\\_ _ → pure (Left undefined))"
    ]

-- | A client importing the window drivers from the seam's private
-- implementation.
privateSeamDriverClient ∷ String
privateSeamDriverClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Seam (seamDrive, seamRejectCloseRequest)"
    ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
-- The main library is named by its local unit id: its sublibraries share its
-- package name.
withClient = withPackageClient ["base", "text", "stm", "hetoimasia-foundation", "hetoimasia-glfw-0.1.0.0-inplace"]

-- | A client naming the session's data constructor.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Session (Session (Session))"
    , ""
    , "forged ∷ Maybe Session"
    , "forged = Nothing"
    ]

-- | A client reaching for the native window handle type and the production
-- native table, whose modules belong to private sublibraries.
nativeHandleClient ∷ String
nativeHandleClient =
  unlines
    [ "module Client (handle, table) where"
    , ""
    , "import Foreign.Ptr (Ptr, nullPtr)"
    , "import Hetoimasia.GLFW.Internal.Native (productionNative)"
    , "import Hetoimasia.GLFW.Internal.Session (Native, NativeWindow)"
    , ""
    , "handle ∷ Ptr NativeWindow"
    , "handle = nullPtr"
    , ""
    , "table ∷ Native"
    , "table = productionNative"
    ]

-- | A client naming the window's and the observation's data constructors.
windowConstructorClient ∷ String
windowConstructorClient =
  unlines
    [ "module Client (forged, observed) where"
    , ""
    , "import Hetoimasia.GLFW.Window (Window (Window), WindowObservation (WindowObservation))"
    , ""
    , "forged ∷ Maybe Window"
    , "forged = Nothing"
    , ""
    , "observed ∷ Maybe WindowObservation"
    , "observed = Nothing"
    ]

-- | A client reaching for a window's native handle and the owner-boundary
-- driver, which live in the private window module.
windowInternalsClient ∷ String
windowInternalsClient =
  unlines
    [ "module Client (handleOf) where"
    , ""
    , "import Foreign.Ptr (Ptr)"
    , "import Hetoimasia.GLFW.Internal.Window (Window, windowNativeHandle, windowStep)"
    , "import Hetoimasia.GLFW.Internal.Session (NativeWindow)"
    , ""
    , "handleOf ∷ Window → Ptr NativeWindow"
    , "handleOf = windowNativeHandle"
    ]

-- | A client trying to end a window's observations, which needs the publisher
-- endpoint the package never hands out.
publisherClient ∷ String
publisherClient =
  unlines
    [ "module Client (endObservations) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Hetoimasia.Foundation.Messaging.Snapshot (closeSnapshot)"
    , "import Hetoimasia.GLFW.Window (Window, windowObservations)"
    , ""
    , "endObservations ∷ Window → IO ()"
    , "endObservations window = atomically (closeSnapshot (windowObservations window))"
    ]

-- | A client using only the public interface. A Wayland request is refused as
-- unsupported before anything else, and a default request is refused because
-- this client is built without the threaded runtime, so no thread is the bound
-- process main thread: neither reaches GLFW, so the window command path inside
-- the second compiles and links but never runs.
publicClient ∷ String
publicClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Control.Exception (SomeException, fromException, try)"
    , "import qualified Data.Text as Text"
    , "import Hetoimasia.Foundation.Failure (FailureCause (..), FailureEvidence (..), FailureOrigin (..), failureEvidence, operationText)"
    , "import Hetoimasia.Foundation.Log (componentText)"
    , "import Hetoimasia.Foundation.Messaging.Payload (preparedValue)"
    , "import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)"
    , "import Hetoimasia.GLFW.Command"
    , "import Hetoimasia.GLFW.Monitor"
    , "import Hetoimasia.GLFW.Session"
    , "import Hetoimasia.GLFW.Window"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  wayland ← try (withSession defaultSessionConfig {requestedBackend = Just Wayland} (\\_ → pure ()))"
    , "  report \"wayland\" wayland"
    , "  unthreaded ← try (withSession defaultSessionConfig (\\session → monitors session >> withWindow session (hiddenTestWindowConfig (Text.pack \"tool\") 64 48) (request session) >> pure ()))"
    , "  report \"without the threaded runtime\" unthreaded"
    , "  putStrLn (\"capacity = \" <> show errorEvidenceCapacity <> \", description limit = \" <> show errorDescriptionLimit)"
    , "  putStrLn (\"zero width = \" <> either show (const \"accepted\") (validateWindowConfig (hiddenTestWindowConfig (Text.pack \"tool\") 0 48)))"
    , ""
    , "latest ∷ Window → IO (Attribute Extent)"
    , "latest window = observedFramebufferExtent . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))"
    , ""
    , "monitors ∷ Session → IO [Attribute MonitorPosition]"
    , "monitors session = do"
    , "  inventory ← synchronizeMonitors session"
    , "  latest ← preparedValue . observedValue <$> atomically (readSnapshot (monitorInventory session))"
    , "  case (inventoryMonitors inventory, inventoryPhase latest) of"
    , "    (Observed described, InventoryOpen) → mapM (\\description → positionOf <$> resolveMonitor session (monitorIdentity description)) described"
    , "    _ → pure []"
    , ""
    , "positionOf ∷ MonitorResult MonitorDescription → Attribute MonitorPosition"
    , "positionOf resolved = case resolved of"
    , "  MonitorAvailable fresh → monitorPosition fresh"
    , "  MonitorDisconnected _ → Unavailable"
    , ""
    , "request ∷ Session → Window → IO (Maybe Disposition)"
    , "request session window = do"
    , "  _ ← latest window"
    , "  host ← newWindowCommandHost session 4"
    , "  submitted ← submitWindowCommand (windowCommandPort host) [(Text.pack \"client\", Text.pack \"tool\")] (observeWindowCommand (windowIdentity window))"
    , "  case submitted of"
    , "    SubmitAccepted ticket → do"
    , "      _ ← atomically (closeWindowCommands host)"
    , "      Just <$> awaitCompletion ticket"
    , "    _ → pure Nothing"
    , ""
    , "report ∷ String → Either SomeException () → IO ()"
    , "report label outcome = case outcome of"
    , "  Right () → putStrLn (label <> \" = entered\")"
    , "  Left caught → putStrLn (label <> \" = \" <> describe caught <> \", raised by \" <> origin caught)"
    , ""
    , "describe ∷ SomeException → String"
    , "describe caught"
    , "  | Just unsupported ← fromException caught = \"unsupported \" <> show (unsupportedRequest unsupported)"
    , "  | Just misuse ← fromException caught = show (misuse ∷ SessionMisuse)"
    , "  | otherwise = \"unexpected \" <> show caught"
    , ""
    , "origin ∷ SomeException → String"
    , "origin caught = case failureCause (failureEvidence caught) of"
    , "  EngineOrigin found → Text.unpack (componentText (originComponent found)) <> \" \" <> Text.unpack (operationText (originOperation found))"
    , "  NativeCause → \"no engine origin\""
    ]
