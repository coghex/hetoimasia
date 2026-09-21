-- | Examples proving that the GLFW package keeps its native handles, its
-- session, window, and window command representations, its observation
-- publisher, and command execution and settlement out of reach of a client
-- outside the package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @text@, @stm@,
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
-- module. Two are rejected for the window controls: one constructs a control
-- command or its size constraints through their constructors, or alters
-- constraints through a field, outside the smart constructors and owner-thread
-- validation, and one reaches for the control representation in the private
-- control module. Two are rejected for the window modes: one names a mode's,
-- saved placement's, or mode record's constructor, or sets a record's saved
-- placement through a field, and one reaches for the mode representation and the
-- owner's record updates in the private mode module. One is rejected for
-- reaching for the private window attachment model, which no public module
-- exports. Five are rejected for the input feeds: one names the reader's,
-- control's, event's, epoch's, and reset token's constructors; one coerces a
-- number into an input epoch, so a token could be retargeted; one rewrites a
-- token's epoch through record syntax; and one reaches for the feed, its
-- producer, and its resumption through the public input module, and another
-- in the private input module, and one reaches for native callback injection.
-- One client must be accepted, linked, and run: it uses only the public
-- session, monitor, window, and window command interfaces, including the
-- read-only observation and inventory endpoints, identity resolution, a command
-- port, every control command constructor, the mode requests, a startup mode,
-- the mode record's accessors, the capability description, and a
-- completion ticket, and every path
-- it takes is refused before GLFW is initialized, so the example opens no
-- display.
--
-- The window host from the public @runtime-glfw@ sublibrary is compiled against
-- as well, exposing @hetoimasia-runtime@ and that sublibrary beside the rest.
-- This suite declares the sublibrary as a dependency so it is built and
-- registered for these clients, rather than relying on another component
-- registering it incidentally.
-- Eight clients must be rejected: one names the host's constructor, one asks
-- the host for its session, windows' command host, and settings, one reaches
-- for the owner loop's executor and event processing in the private modules
-- the sublibrary uses, one asks the host for the collection that owns its
-- windows and the registry of their members and ports, one reaches for that
-- collection and the host's test hooks in the private @runtime-glfw-core@
-- implementation, one forges a
-- window's client capabilities, or reads another window's port out of them,
-- through the capability's constructor and fields, one asks the public
-- @runtime-glfw@ sublibrary for the private attachment seam it does not export,
-- and one reaches for the retirement boundary that owns it in the private
-- implementation. Those last two are the export-boundary evidence for the
-- protected host: what may attach to it is private, while the lifetime itself
-- is not. One client must be accepted,
-- linked, and run: it uses the host's supported configuration, construction,
-- turn, window, and client capabilities, including a window's input reader and
-- admission control, and the protected host lifetime and its runner, and every
-- path it runs is refused
-- before GLFW is initialized.
--
-- The test seam is a public component, and this suite declares it for the same
-- reason. Four more
-- clients are compiled against it and must be rejected: two name the window
-- drivers and the private command executor through the public seam, which
-- exports neither, and two reach for them in the seam's implementation, which
-- belongs to the private @seam-core@ sublibrary, and a fifth names the monitor
-- drivers through the public seam. Only components inside @hetoimasia-glfw@,
-- such as this suite's window examples, can use them.
--
-- This suite belongs to @hetoimasia-glfw@, so its own modules may import the
-- private sublibraries; that access is not evidence about the boundary. Only a
-- client compiled here, with every package it may see named explicitly and
-- every other package hidden, answers what a package outside can reach.
module Test.GLFW.Opacity (spec) where

import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Info (os)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "GLFW session opacity across the package boundary" $ do
  it "rejects a client that names the session constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
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

  it "rejects a client that constructs a wake capability, or reaches through one for the native table" $ do
    withClient "Client.hs" wakeConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "SessionWake"
    withClient "Client.hs" wakeInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a wake capability's native table is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Session"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that forges a demand request or publisher, or reaches for a demand slot" $ do
    withClient "Client.hs" demandConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "DemandRequest"
    withClient "Client.hs" demandInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a demand slot is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Demand"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names the window or observation constructor" $
    withClient "Client.hs" windowConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
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
      rejectedBecause outcome "GHC-10237"
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
      rejectedBecause outcome "GHC-10237"
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

  it "rejects a client that constructs or alters a control command or its size constraints outside the smart constructors" $
    withClient "Client.hs" controlConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "WindowCommand"
      clientOutput outcome `shouldContain` "SizeConstraints"

  it "rejects a client that reaches for the control representation in the private control module" $
    withClient "Client.hs" controlInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a control's representation is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Control"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that constructs a mode, a saved placement, or a mode record, or sets a saved placement through a field" $
    withClient "Client.hs" modeConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      mapM_ (clientOutput outcome `shouldContain`) ["WindowMode", "SavedPlacement", "ModeRecord"]

  it "rejects a client that reaches for the mode representation or the owner's record updates in the private mode module" $
    withClient "Client.hs" modeInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a mode's representation is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Mode"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that reaches for the private window attachment model" $
    withClient "Client.hs" attachmentModelClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the attachment model is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Attachment"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that constructs an input reader, control, event, epoch, or reset token" $
    withClient "Client.hs" inputConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      mapM_ (clientOutput outcome `shouldContain`) ["InputReader", "InputControl", "InputEvent", "InputEpoch", "ResetToken"]

  it "rejects a client that coerces a number into an input epoch to retarget a reset" $
    withClient "Client.hs" inputEpochCoercionClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match representation"
      clientOutput outcome `shouldContain` "InputEpoch"

  it "rejects a client that rewrites a reset token's epoch through record syntax" $
    withClient "Client.hs" inputTokenUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "resetEpoch"
      clientOutput outcome `shouldContain` "record"

  it "rejects a client that reaches for an input feed, its producer, or its resumption through the public input module" $
    withClient "Client.hs" publicInputEndpointClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      mapM_ (clientOutput outcome `shouldContain`) ["InputFeed", "produceInput", "resumeInput"]

  it "rejects a client that reaches for an input feed's producer or channel in the private input module" $
    withClient "Client.hs" privateInputClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so an input producer is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Input"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-glfw"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that registers an input callback or injects an event through the private native table" $
    withClient "Client.hs" inputCallbackClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so an input callback is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.GLFW.Internal.Native"
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
      rejectedBecause outcome "GHC-10237"
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
      rejectedBecause outcome "GHC-10237"
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

  it "rejects a client asking the public host sublibrary for the private attachment seam" $
    withHostClient "Client.hs" publicAttachmentClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a public module exports an attachment:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Runtime.GLFW"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that names the opaque graphics service's constructor" $
    withHostClient "Client.hs" graphicsServiceConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "GraphicsService"

  it "rejects a client that reaches for the graphics service's representation and its observation cell" $
    withHostClient "Client.hs" graphicsInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so a service's observation cell is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.Runtime.GLFW.Internal.Graphics"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts and runs a client using the public attachment contract, without initializing GLFW" $
    withHostClient "Main.hs" attachmentClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the attachment client must compile, but the compiler exited with "
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
        `shouldBe` [ "zero retirement budget = Left (RetirementBudgetRejected 0)"
                   , "no demand = RetirementDemand {retirementPending = 0, retirementStalled = 0, retirementRefused = 0, retirementImmediate = False, retirementNextPossible = Nothing}"
                   , "refusals = [GraphicsAdmissionEnded,GraphicsForeignSession,GraphicsSlotUnavailable]"
                   , "facts = [CpuUseRetired,SubmittedWorkEnded,PresentationEnded,DependentsDisposed]"
                   , "absent = (GraphicsAbsent,DisposalPending,SlotFree)"
                   ]

  it "rejects a client that reaches for the retirement boundary in the host's private implementation" $
    withHostClient "Client.hs" retirementInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the retirement boundary is reachable:\n" <> clientOutput outcome)
      -- Found in the built package and refused as private, not missing.
      clientOutput outcome `shouldContain` "Hetoimasia.Runtime.GLFW.Internal.Retirement"
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
                   , "protected zero budget = CommandBudgetRejected 0"
                   , "protected without the threaded runtime = NotProcessMainThread"
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
        `shouldBe` [ "unadmitted backend = unsupported Just " <> unadmittedBackend <> ", raised by glfw enter session"
                   , "without the threaded runtime = NotProcessMainThread, raised by glfw enter session"
                   , "capacity = 16, description limit = 1024"
                   , "zero width = WindowExtentRejected {rejectedWidth = 0, rejectedHeight = 48}"
                   , "constraints = (Extent {extentWidth = 1, extentHeight = 1},Extent {extentWidth = 64, extentHeight = 48},Just (AspectRatio {aspectNumerator = 4, aspectDenominator = 3}))"
                   , "wayland cannot perform = [SetPositionOperation,FocusOperation,BorderlessOperation], report = [PlacementReport,IconifiedReport]"
                   , "mode = (2,Just (Extent {extentWidth = 1920, extentHeight = 1080},Just 60),WindowedPresentation)"
                   , "wake outcomes = [WakePosted,WakeTerminal,WakeFailed (Reports {reportedErrors = [], reportsLost = 0, callbackFaults = 1})]"
                   ]

-- | The backend this platform does not admit, which the public client asks for
-- so that its request is refused at resolution wherever the suite runs.
unadmittedBackend ∷ String
unadmittedBackend = if os == "darwin" then "Wayland" else "Cocoa"

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
    , "import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)"
    , "import Hetoimasia.Foundation.Messaging.Snapshot (readSnapshot)"
    , "import Hetoimasia.Foundation.Resource (withScoped)"
    , "import Hetoimasia.GLFW.Command"
    , "import qualified Hetoimasia.GLFW.Input as Input"
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
    , "  let logger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\\_ → pure ()))"
    , "  refused ← try (withProtectedWindowHost logger config {hostCommandBudget = 0} (atomically . hostCommandStatistics))"
    , "  putStrLn (\"protected zero budget = \" <> describe refused)"
    , "  protected ← try (withProtectedWindowHost logger config (atomically . hostCommandStatistics))"
    , "  putStrLn (\"protected without the threaded runtime = \" <> describe protected)"
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
    , "protectedApplication ∷ (∀ r. (LoggingLifetime → IO r) → IO r) → Logger → IO Int"
    , "protectedApplication enter logger ="
    , "  runProtectedWindowApplication"
    , "    enter"
    , "    (Text.pack \"tool\")"
    , "    (\\_ use → withProtectedWindowHost logger (defaultHostConfig []) use)"
    , "    id"
    , "    (\\host _ → pure host)"
    , "    serve"
    , ""
    , "serve ∷ WindowHost → RuntimeControl → IO Int"
    , "serve host control ="
    , "  runOwnerLoop host control LoopHooks"
    , "    { loopLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\\_ → pure ()))"
    , "    , loopEvent = noApplicationEvents"
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
    , "            consume client"
    , "            submitWindowCommand (clientCommandPort client) [] (closeWindowCommand (clientWindow client)))"
    , "          _ → pure ()"
    , "        mapM_ (\\window → withHostWindow host window (\\_ → closeHostWindow host window)) identities"
    , "        mapM_ (honourHostCloseRequest host) (turnCloseRequests turn)"
    , "        _ ← hostBookkeeping host"
    , "        _ ← pure (unperformableOperations (hostWindowCapabilities host))"
    , "        atomically (quiesceWindowHost host)"
    , "        pure (if activityWaiting activity then Finish (turnCommands turn) else Continue)"
    , "    }"
    , ""
    , "consume ∷ WindowClient → IO ()"
    , "consume client = do"
    , "  let reader = clientInputReader client"
    , "  _ ← atomically (Input.enableInput (clientInputControl client))"
    , "  found ← atomically (Input.awaitInput reader)"
    , "  case found of"
    , "    Input.InputDelivered event → print (Input.inputWindow event, Input.epochNumber (Input.inputEpoch event), Input.inputPayload event)"
    , "    Input.InputResetRequired token → atomically (Input.acknowledgeReset reader token) >>= either (\\misuse → print (misuse ∷ Input.InputMisuse)) print"
    , "    _ → atomically (Input.inputStatistics reader) >>= print . Input.statisticsLastReset"
    , "  _ ← atomically (Input.suspendInput (clientInputControl client))"
    , "  pure ()"
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

-- | A client building a control command and its size constraints through their
-- data constructors, and altering constraints through a record field, rather
-- than through the smart constructors.
controlConstructorClient ∷ String
controlConstructorClient =
  unlines
    [ "module Client (forged, altered) where"
    , ""
    , "import Hetoimasia.GLFW.Command (SizeConstraints (SizeConstraints, constraintsMinimum), WindowCommand (ControlWindow))"
    , "import Hetoimasia.GLFW.Window (Extent (..))"
    , ""
    , "forged ∷ Maybe WindowCommand"
    , "forged = Nothing"
    , ""
    , "altered ∷ SizeConstraints → SizeConstraints"
    , "altered constraints = constraints {constraintsMinimum = Extent 0 0}"
    ]

-- | A client reaching for the control representation, which commands carry,
-- in the private control module.
controlInternalsClient ∷ String
controlInternalsClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Control (WindowControl (..), validateControl)"
    , ""
    , "forged ∷ WindowControl"
    , "forged = SizeControl 0 0"
    ]

-- | A client naming a mode's, a saved placement's, and a mode record's data
-- constructors, and setting a record's saved placement through a field, rather
-- than requesting a transition.
modeConstructorClient ∷ String
modeConstructorClient =
  unlines
    [ "module Client (forged, moved) where"
    , ""
    , "import Hetoimasia.GLFW.Mode (ModeRecord (ModeRecord, recSaved), SavedPlacement (SavedPlacement), WindowMode (FullscreenMode))"
    , ""
    , "forged ∷ Maybe WindowMode"
    , "forged = Nothing"
    , ""
    , "moved ∷ SavedPlacement → ModeRecord → ModeRecord"
    , "moved saved record = record {recSaved = Just saved}"
    ]

-- | A client reaching for the mode representation and the owner's record
-- updates in the private mode module.
modeInternalsClient ∷ String
modeInternalsClient =
  unlines
    [ "module Client (moved) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Mode (ModeRecord, recordSaved, savedPlacement)"
    , "import Hetoimasia.GLFW.Window (Extent (..), Placement (..))"
    , ""
    , "moved ∷ ModeRecord → ModeRecord"
    , "moved = recordSaved (savedPlacement (Placement 0 0) (Extent 1 1))"
    ]

-- | A client reaching for the attachment model, its owner's authority, and a
-- retirement fact in the private model sublibrary.
attachmentModelClient ∷ String
attachmentModelClient =
  unlines
    [ "module Client (retire) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Attachment (AttachmentModel, OwnerAuthority, Registered (..), RetirementFact (..), recordRetirementFact)"
    , ""
    , "retire ∷ OwnerAuthority → Registered → AttachmentModel () → Bool"
    , "retire owner registered model ="
    , "  either (const False) (const True) (recordRetirementFact owner (registeredAttachment registered) (registeredAcknowledgement registered) DependentsDisposed model)"
    ]

-- | A client asking the public host sublibrary for the private attachment seam:
-- the protected lifetime is exported, what may attach to it is not.
publicAttachmentClient ∷ String
publicAttachmentClient =
  unlines
    [ "module Client (attached) where"
    , ""
    , "import Hetoimasia.Runtime.GLFW"
    , "  ( WindowHost"
    , "  , attachHostWindow"
    , "  , hostAttachmentIdentity"
    , "  , hostCompletionPublisher"
    , "  , reportHostRetirementFact"
    , "  )"
    , ""
    , "attached ∷ Maybe WindowHost"
    , "attached = Nothing"
    ]

-- | A client naming the opaque graphics service's data constructor. The public
-- contract exports the type and its accessors and no way to build one.
graphicsServiceConstructorClient ∷ String
graphicsServiceConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Runtime.GLFW (GraphicsService (GraphicsService))"
    , ""
    , "forged ∷ Maybe GraphicsService"
    , "forged = Nothing"
    ]

-- | A client reaching for the graphics service's own representation, and the
-- observation cell it retains, in the private @runtime-glfw-core@
-- implementation.
graphicsInternalsClient ∷ String
graphicsInternalsClient =
  unlines
    [ "module Client (cell) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import Hetoimasia.Runtime.GLFW.Internal.Graphics (GraphicsCell, GraphicsObservation, readGraphicsCell)"
    , ""
    , "cell ∷ GraphicsCell → STM GraphicsObservation"
    , "cell = readGraphicsCell"
    ]

-- | A client using the public attachment contract. It builds no host, so it
-- initializes no GLFW: what it proves is that the contract is reachable, that
-- its values are opaque, and that a configuration the attachment budget refuses
-- is refused before anything is acquired.
attachmentClient ∷ String
attachmentClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import qualified Data.Text as Text"
    , "import Hetoimasia.GLFW.Window (WindowId, hiddenTestWindowConfig)"
    , "import Hetoimasia.Runtime.GLFW"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let config = defaultHostConfig [hiddenTestWindowConfig (Text.pack \"tool\") 64 48]"
    , "  putStrLn (\"zero retirement budget = \" <> show (validateHostConfig config {hostRetirementBudget = 0}))"
    , "  putStrLn (\"no demand = \" <> show noRetirementDemand)"
    , "  putStrLn (\"refusals = \" <> show [GraphicsAdmissionEnded, GraphicsForeignSession, GraphicsSlotUnavailable])"
    , "  putStrLn (\"facts = \" <> show allRetirementFacts)"
    , "  putStrLn (\"absent = \" <> show (GraphicsAbsent, DisposalPending, SlotFree))"
    , ""
    , "-- | The contract as a client names it: an owner in, an opaque service out."
    , "attach ∷ WindowHost → WindowId → AttachmentProtocol → IO GraphicsAttachment"
    , "attach = attachWindowGraphics"
    , ""
    , "detach ∷ WindowHost → GraphicsService → IO DetachAnswer"
    , "detach = detachWindowGraphics"
    , ""
    , "-- | The service the host holds for a window, which is the one it published."
    , "recover ∷ WindowHost → WindowId → STM (Maybe GraphicsService)"
    , "recover = windowGraphicsService"
    , ""
    , "-- | Everything a service exposes: an identity, an incarnation, and its own"
    , "-- observation. No native pointer, no window, no session, no release."
    , "observe ∷ GraphicsService → (WindowId, AttachmentId, Integer)"
    , "observe service ="
    , "  ( graphicsWindow service"
    , "  , graphicsAttachment service"
    , "  , toInteger (graphicsIncarnation service)"
    , "  )"
    ]

-- | A client reaching for the retirement boundary that owns the attachment
-- model, in the private @runtime-glfw-core@ implementation.
retirementInternalsClient ∷ String
retirementInternalsClient =
  unlines
    [ "module Client (retire) where"
    , ""
    , "import Hetoimasia.Runtime.GLFW.Internal.Retirement (HostRetirement, closeAttachmentAdmission)"
    , "import Control.Concurrent.STM (STM)"
    , ""
    , "retire ∷ HostRetirement → STM ()"
    , "retire = closeAttachmentAdmission"
    ]

-- | A client naming the input capabilities' and values' data constructors.
inputConstructorClient ∷ String
inputConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Input (InputControl (InputControl), InputEpoch (InputEpoch), InputEvent (InputEvent), InputReader (InputReader), ResetToken (ResetToken))"
    , ""
    , "forged ∷ Maybe (InputReader, InputControl, InputEvent, InputEpoch, ResetToken)"
    , "forged = Nothing"
    ]

-- | A client coercing a number into an input epoch.
inputEpochCoercionClient ∷ String
inputEpochCoercionClient =
  unlines
    [ "module Client (retargeted) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.GLFW.Input (InputEpoch)"
    , "import Numeric.Natural (Natural)"
    , ""
    , "retargeted ∷ Natural → InputEpoch"
    , "retargeted = coerce"
    ]

-- | A client rewriting a reset token's epoch as if its reader were a field.
inputTokenUpdateClient ∷ String
inputTokenUpdateClient =
  unlines
    [ "module Client (retargeted) where"
    , ""
    , "import Hetoimasia.GLFW.Input (InputEpoch, ResetToken, resetEpoch)"
    , ""
    , "retargeted ∷ InputEpoch → ResetToken → ResetToken"
    , "retargeted epoch token = token {resetEpoch = epoch}"
    ]

-- | A client asking the public input module for the feed, its producer, and its
-- resumption.
publicInputEndpointClient ∷ String
publicInputEndpointClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.GLFW.Input (InputFeed, produceInput, resumeInput)"
    ]

-- | A client importing the feed, its producer, and its reader construction from
-- the private input module.
privateInputClient ∷ String
privateInputClient =
  unlines
    [ "module Client (produce) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Input (InputFeed, InputPayload (TextInput), Production, feedReader, produceInput)"
    , ""
    , "produce ∷ InputFeed → IO Production"
    , "produce feed = feedReader feed `seq` produceInput feed (TextInput 'x')"
    ]

-- | A client asking the private native table to inject an input event or to
-- reach callback storage.
inputCallbackClient ∷ String
inputCallbackClient =
  unlines
    [ "module Client (inject) where"
    , ""
    , "import Foreign.Ptr (Ptr, nullPtr)"
    , "import Hetoimasia.GLFW.Internal.Native (injectKeyForCheck)"
    , "import Hetoimasia.GLFW.Internal.Session (NativeWindow)"
    , ""
    , "inject ∷ IO ()"
    , "inject = injectKeyForCheck (nullPtr ∷ Ptr NativeWindow) 65 0 1 0"
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

-- | A client naming the wake capability's data constructor.
wakeConstructorClient ∷ String
wakeConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.GLFW.Session (SessionWake (SessionWake))"
    , ""
    , "forged ∷ Maybe SessionWake"
    , "forged = Nothing"
    ]

-- | A client reaching through a wake capability for the native table it posts
-- through, whose module belongs to a private sublibrary.
wakeInternalsClient ∷ String
wakeInternalsClient =
  unlines
    [ "module Client (table) where"
    , ""
    , "import Hetoimasia.GLFW.Internal.Session (Native, SessionWake (..))"
    , ""
    , "table ∷ SessionWake → Native"
    , "table = wakeNative"
    ]

-- | A client naming a demand request's and a publisher's data constructors.
demandConstructorClient ∷ String
demandConstructorClient =
  unlines
    [ "module Client (forged, publisher) where"
    , ""
    , "import Hetoimasia.GLFW.Demand (DemandPublisher (DemandPublisher), DemandRequest (DemandRequest))"
    , ""
    , "forged ∷ Maybe DemandRequest"
    , "forged = Nothing"
    , ""
    , "publisher ∷ Maybe DemandPublisher"
    , "publisher = Nothing"
    ]

-- | A client reaching for the demand slot a publisher writes into, and for the
-- capture only the owner performs, whose module belongs to a private
-- sublibrary.
demandInternalsClient ∷ String
demandInternalsClient =
  unlines
    [ "module Client (capture) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import Hetoimasia.GLFW.Internal.Demand (CapturedDemand, DemandSlot, captureDemand)"
    , ""
    , "capture ∷ DemandSlot → STM (Maybe CapturedDemand)"
    , "capture = captureDemand"
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

-- | A client using only the public interface. A request naming the backend
-- this platform does not admit is refused as unsupported before anything else,
-- and a default request is refused because this client is built without the
-- threaded runtime, so no thread is the bound process main thread: neither
-- reaches GLFW, so the window command path inside the second compiles and
-- links but never runs.
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
    , "import Hetoimasia.GLFW.Mode"
    , "import Hetoimasia.GLFW.Monitor"
    , "import Hetoimasia.GLFW.Session"
    , "import Hetoimasia.GLFW.Window"
    , "import System.Info (os)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let unadmitted = if os == \"darwin\" then Wayland else Cocoa"
    , "  refused ← try (withSession defaultSessionConfig {requestedBackend = Just unadmitted} (\\_ → pure ()))"
    , "  report \"unadmitted backend\" refused"
    , "  unthreaded ← try (withSession defaultSessionConfig (\\session → monitors session >> withWindow session starting (request session) >> pure ()))"
    , "  report \"without the threaded runtime\" unthreaded"
    , "  putStrLn (\"capacity = \" <> show errorEvidenceCapacity <> \", description limit = \" <> show errorDescriptionLimit)"
    , "  putStrLn (\"zero width = \" <> either show (const \"accepted\") (validateWindowConfig (hiddenTestWindowConfig (Text.pack \"tool\") 0 48)))"
    , "  let constraints = sizeConstraints (Extent 1 1) (Extent 64 48) (Just (AspectRatio 4 3))"
    , "  putStrLn (\"constraints = \" <> show (constraintMinimum constraints, constraintMaximum constraints, constraintAspectRatio constraints))"
    , "  let wayland = backendWindowCapabilities Wayland"
    , "  putStrLn (\"wayland cannot perform = \" <> show (map fst (unperformableOperations wayland)) <> \", report = \" <> show (map fst (unreportableAttributes wayland)))"
    , "  putStrLn (\"mode = \" <> show (fallbackAttempts (windowedFallback 2), preferredVideoMode (exactVideoMode (Extent 1920 1080) (Just 60)), modePresentation windowedMode))"
    , "  putStrLn (\"wake outcomes = \" <> show [WakePosted, WakeTerminal, WakeFailed (Reports [] 0 1)])"
    , ""
    , "starting ∷ WindowConfig"
    , "starting = (hiddenTestWindowConfig (Text.pack \"tool\") 64 48) {windowStartupMode = Just (startupMode (modeRequest windowedMode noModeFallback) ModeOptional)}"
    , ""
    , "recorded ∷ WindowObservation → (AppliedMode, Maybe Placement, Maybe ModeOutcome, Attribute (Maybe MonitorId), Attribute Bool)"
    , "recorded observation = (modeApplied record, savedPosition <$> modeSavedPlacement record, modeLastOutcome record, observedFullscreenMonitor observation, observedDecorated observation)"
    , "  where record = observedMode observation"
    , ""
    , "latest ∷ Window → IO (Attribute Extent)"
    , "latest window = observedFramebufferExtent . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))"
    , ""
    , "monitors ∷ Session → IO [Attribute MonitorPosition]"
    , "monitors session = do"
    , "  _ ← wakeSession (sessionWake session)"
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
    , "  host ← newWindowCommandHost session 16"
    , "  let target = windowIdentity window"
    , "      constraints = sizeConstraints (Extent 1 1) (Extent 64 48) Nothing"
    , "      controls ="
    , "        [ setWindowTitleCommand target (Text.pack \"renamed\"), setWindowSizeCommand target (Extent 64 48)"
    , "        , setWindowPositionCommand target (Placement 0 0), setSizeConstraintsCommand target constraints"
    , "        , showWindowCommand target, hideWindowCommand target, requestFocusCommand target, requestAttentionCommand target"
    , "        , minimizeWindowCommand target, maximizeWindowCommand target, restoreWindowCommand target ]"
    , "  _ ← mapM (performWindowCommand host [window]) controls"
    , "  observed ← atomically (readSnapshot (windowObservations window))"
    , "  _ ← pure (recorded (preparedValue (observedValue observed)))"
    , "  described ← synchronizeMonitors session"
    , "  let modes = case inventoryMonitors described of"
    , "        Observed (monitor : _) → [modeRequest (fullscreenMode (monitorIdentity monitor) currentVideoMode) (windowedFallback 1), modeRequest (borderlessMode (monitorIdentity monitor)) noModeFallback]"
    , "        _ → [modeRequest windowedMode noModeFallback]"
    , "  _ ← mapM (performWindowCommand host [window] . setWindowModeCommand target) modes"
    , "  _ ← pure (sessionWindowCapabilities session)"
    , "  submitted ← submitWindowCommand (windowCommandPort host) [(Text.pack \"client\", Text.pack \"tool\")] (observeWindowCommand target)"
    , "  case submitted of"
    , "    SubmitAccepted ticket → do"
    , "      _ ← atomically (closeWindowCommands host)"
    , "      settled ← awaitCompletion ticket"
    , "      pure (Just (describeSettled settled))"
    , "    _ → pure Nothing"
    , ""
    , "describeSettled ∷ Disposition → Disposition"
    , "describeSettled settled = case settled of"
    , "  Attempted (ControlAttempt _ ControlReturned (PostCallRevision _)) → settled"
    , "  Unsupported (UnsupportedControl _ _ _) → settled"
    , "  Transitioned (ModeTransition _ ModeInert (PostCallRevision _)) → settled"
    , "  _ → settled"
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
