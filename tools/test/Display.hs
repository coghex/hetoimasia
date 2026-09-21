-- | Hspec coverage for the native worker's isolated display helpers.
--
-- Every example runs a shipped helper — @tools/display/x11.sh@ or
-- @tools/display/wayland.sh@ — with a @PATH@ holding only the utilities it
-- needs and stub display programs, so what is asserted is the script's own
-- contract rather than whichever X server or compositor a machine happens to
-- have: the command runs inside the session the script established, with the
-- other display protocol removed and with the native suite's isolated-session
-- consent set for that session alone, and a missing or failing server, window
-- manager, or compositor stops the run before the command starts, so the
-- consent reaches nothing. A signal the helper can catch ends it the same way,
-- with what it started stopped and what it created removed. The real server is
-- exercised by the @test.glfw-native@ group itself, and the real compositor by
-- the @ci-image@ workflow's own run inside the published image.
module Display (spec) where

import Control.Monad (forM_)
import Sandbox (run, sanitizedEnvironment)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory
  ( createDirectory
  , createFileLink
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , getPermissions
  , listDirectory
  , removePathForcibly
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  )

data Display = Display
  { directory ∷ FilePath
  , toolbox ∷ FilePath
  , script ∷ FilePath
  }

spec ∷ Spec
spec = x11Spec >> waylandSpec

x11Spec ∷ Spec
x11Spec = describe "Isolated X11 display" $ do
  it "runs the command inside the display it established, with Wayland removed and that display's consent set, and stops the display after it" $
    withDisplay $ \display → do
      installStubs display workingStubs
      (result, output, errors) ←
        helper display ["--summary", directory display </> "summary.md", "--", "sh", "-c", recordEnvironment display]
      (result, errors) `shouldBe` (ExitSuccess, "")
      output `shouldContain` "display :42"
      output `shouldContain` "window manager \"Openbox\""
      -- The consent names the display the script established, and only the
      -- command sees it: the helper's own environment carried none.
      readFile (directory display </> "environment.txt") `shouldReturn` ":42 unset x11 isolated-x11::42\n"
      readFile (directory display </> "summary.md") >>= (`shouldContain` "## Isolated X11 display")
      server ← readFile (directory display </> "server.pid")
      stopped (takeWhile (/= '\n') server) `shouldReturn` True

  it "refuses to run the command without an X server" $
    withDisplay $ \display → do
      installStubs display (filter ((/= "Xvfb") . fst) workingStubs)
      refused display "Xvfb was not found on PATH"

  it "refuses to run the command when the X server exits before reporting a display" $
    withDisplay $ \display → do
      installStubs display (("Xvfb", "#!/bin/sh\necho 'cannot open the framebuffer' >&2\nexit 1\n") : filter ((/= "Xvfb") . fst) workingStubs)
      refused display "the X server exited before reporting a display"

  it "refuses to run the command when the window manager exits instead of taking the display" $
    withDisplay $ \display → do
      -- A window manager that exits never announces itself on the root window.
      installStubs
        display
        ( ("openbox", "#!/bin/sh\necho 'no display' >&2\nexit 1\n")
            : ("xprop", "#!/bin/sh\nexit 0\n")
            : filter ((`notElem` ["openbox", "xprop"]) . fst) workingStubs
        )
      refused display "the window manager exited before taking :42"

  it "refuses to run the command when the window manager never takes the display within the bound" $
    withDisplay $ \display → do
      -- A window manager that stays alive but never announces itself exhausts
      -- the helper's ten-second bound; this example waits that bound out. The
      -- server's own thirty-second bound ends in the same refusal.
      installStubs display (("xprop", "#!/bin/sh\nexit 0\n") : filter ((/= "xprop") . fst) workingStubs)
      refused display "the window manager did not take :42 within 10 seconds"

  it "exits with the command's own status once the display is established" $
    withDisplay $ \display → do
      installStubs display workingStubs
      (result, _, _) ← helper display ["--", "sh", "-c", "exit 3"]
      result `shouldBe` ExitFailure 3

  it "rejects a call that names no command" $
    withDisplay $ \display → do
      installStubs display workingStubs
      (result, _, errors) ← helper display ["--summary", directory display </> "summary.md"]
      result `shouldBe` ExitFailure 2
      errors `shouldContain` "usage"

-- | A shell command that records the display environment the helper gave it,
-- including the native suite's consent variable.
recordEnvironment ∷ Display → String
recordEnvironment display =
  "echo \"$DISPLAY ${WAYLAND_DISPLAY-unset} $XDG_SESSION_TYPE ${HETOIMASIA_NATIVE_SESSION-unset}\" > '"
    ++ (directory display </> "environment.txt")
    ++ "'"

-- | Stub display programs that behave like a server and window manager that
-- come up: the server reports display 42 and records its process, the window
-- manager announces itself on the root window.
workingStubs ∷ [(String, String)]
workingStubs =
  [ ("Xvfb", "#!/bin/sh\necho $$ > server.pid\necho 42 >&3\nexec sleep 300\n")
  , ("openbox", "#!/bin/sh\nexec sleep 300\n")
  , ("xdpyinfo", "#!/bin/sh\necho 'vendor string:    Stub X Server'\n")
  , ( "xprop"
    , unlines
        [ "#!/bin/sh"
        , "case \"$1\" in"
        , "  -root) echo '_NET_SUPPORTING_WM_CHECK(WINDOW): window id # 0x200001' ;;"
        , "  -id) echo '_NET_WM_NAME(UTF8_STRING) = \"Openbox\"' ;;"
        , "esac"
        ]
    )
  ]

-- | Run the helper with a PATH holding only the toolbox, where an example wants
-- the command it names to record its environment if it ever runs. A refusal
-- runs it never, so no consent reaches anything: the record is absent.
refused ∷ Display → String → IO ()
refused display reason = do
  (result, _, errors) ← helper display ["--", "sh", "-c", recordEnvironment display]
  result `shouldBe` ExitFailure 1
  errors `shouldContain` reason
  errors `shouldContain` "the command did not run"
  doesFileExist (directory display </> "environment.txt") `shouldReturn` False

-- | Run the helper in a Wayland-looking environment that carries no native
-- consent, whatever the developer's own shell holds, so what the command
-- records can only have come from the helper.
helper ∷ Display → [String] → IO (ExitCode, String, String)
helper display arguments = do
  inherited ← sanitizedEnvironment
  let overrides =
        [ ("PATH", toolbox display)
        , ("WAYLAND_DISPLAY", "wayland-0")
        , ("XDG_SESSION_TYPE", "wayland")
        , ("TMPDIR", directory display)
        ]
      removed = "HETOIMASIA_NATIVE_SESSION" : map fst overrides
      settings = overrides ++ filter ((`notElem` removed) . fst) inherited
  bash ← findExecutable "bash" >>= maybe (fail "bash is not on PATH") pure
  run settings (directory display) bash (script display : arguments)

-- | Whether a process has stopped existing. The helper waits for what it
-- stops, so by the time it returns this is already settled.
stopped ∷ String → IO Bool
stopped pid = do
  (result, _, _) ← run [] "/" "kill" ["-0", pid]
  pure (result /= ExitSuccess)

installStubs ∷ Display → [(String, String)] → IO ()
installStubs display stubs =
  forM_ stubs $ \(name, contents) → do
    let path = toolbox display </> name
    -- A stub may stand in for an ordinary utility the toolbox already links
    -- to; writing through that link would write the real program.
    removePathForcibly path
    writeFile path contents
    permissions ← getPermissions path
    setPermissions path (setOwnerExecutable True permissions)

withDisplay ∷ (Display → IO a) → IO a
withDisplay = withHelper "tools/display/x11.sh"

withHelper ∷ FilePath → (Display → IO a) → IO a
withHelper relative action = do
  checkout ← getCurrentDirectory
  withSystemTempDirectory "hetoimasia-display" $ \scratch → do
    let box = scratch </> "bin"
    createDirectory box
    forM_ utilities $ \name →
      findExecutable name >>= \case
        Just found → createFileLink found (box </> name)
        Nothing → expectationFailure (name ++ " is not on PATH, so the helper's toolbox cannot be assembled")
    action (Display scratch box (checkout </> relative))

-- | The ordinary utilities the helpers and these examples' commands use. The
-- display programs themselves are deliberately absent unless stubbed.
utilities ∷ [String]
utilities =
  ["cat", "head", "mkdir", "mkfifo", "mktemp", "rm", "sed", "sh", "sleep", "tail", "touch", "tr"]

-- ---------------------------------------------------------------------------
-- The isolated headless Wayland session

waylandSpec ∷ Spec
waylandSpec = describe "Isolated headless Wayland session" $ do
  it "runs the command on the socket it established, in a private runtime directory, with that socket's consent set, and stops the compositor after it" $
    withSession $ \session → do
      installStubs session waylandStubs
      (result, output, errors) ←
        sessionHelper session ["--summary", directory session </> "summary.md", "--", "sh", "-c", recordSession session]
      (result, errors) `shouldBe` (ExitSuccess, "")
      -- The command's own environment: the session it can reach is the one the
      -- helper named, and neither display protocol it did not.
      recorded ← words <$> readFile (directory session </> "environment.txt")
      socket ← case recorded of
        ["unset", "unset", "wayland", waylandDisplay, consent, runtime] → do
          consent `shouldBe` ("isolated-wayland:" ++ waylandDisplay)
          runtime `shouldContain` directory session
          pure waylandDisplay
        _ → expectationFailure ("the command recorded " ++ show recorded) >> pure ""
      output `shouldContain` ("on socket " ++ socket)
      output `shouldContain` "weston 13.0.0"
      readFile (directory session </> "summary.md")
        >>= (`shouldContain` "## Isolated headless Wayland session")

      -- The compositor's own environment: it was started with no session of
      -- anyone else's to join, in the helper's private runtime directory.
      readFile (directory session </> "compositor-environment.txt")
        `shouldReturn` "unset unset unset wayland\n"
      options ← readFile (directory session </> "compositor-options.txt")
      options `shouldContain` "--backend=headless"
      options `shouldContain` "--no-config"
      options `shouldContain` ("--socket=" ++ socket)
      options `shouldNotContain` "xwayland"

      -- Readiness was a connection to that socket, in that runtime directory,
      -- rather than a file appearing or a wait elapsing.
      probed ← words <$> readFile (directory session </> "probe.txt")
      runtime ← privateRuntime session
      probed `shouldBe` [socket, runtime]

      cleanedUp session

  it "refuses to run the command without a compositor" $
    withSession $ \session → do
      installStubs session (filter ((/= "weston") . fst) waylandStubs)
      refusedSession session "weston was not found on PATH"

  it "refuses to run the command without the client it proves readiness with" $
    withSession $ \session → do
      installStubs session (filter ((/= "wayland-info") . fst) waylandStubs)
      refusedSession session "wayland-info was not found on PATH"

  it "refuses to run the command when the compositor exits before serving the socket, and cleans up after it" $
    withSession $ \session → do
      installStubs session (("weston", exitingCompositor) : filter ((/= "weston") . fst) waylandStubs)
      refusedSession session "the compositor exited before serving"
      cleanedUp session

  it "refuses to run the command when the compositor never serves the socket within the bound" $
    withSession $ \session → do
      -- A compositor that stays alive but never answers a connection exhausts
      -- the helper's ten-second bound; this example waits that bound out. A
      -- socket file alone would not have satisfied the helper either.
      installStubs session (("wayland-info", refusingClient) : filter ((/= "wayland-info") . fst) waylandStubs)
      refusedSession session "did not serve"
      cleanedUp session

  it "exits with the command's own status once the compositor serves, and cleans up after it" $
    withSession $ \session → do
      installStubs session waylandStubs
      (result, _, _) ← sessionHelper session ["--", "sh", "-c", "exit 3"]
      result `shouldBe` ExitFailure 3
      cleanedUp session

  it "rejects a call that names no command" $
    withSession $ \session → do
      installStubs session waylandStubs
      (result, _, errors) ← sessionHelper session ["--summary", directory session </> "summary.md"]
      result `shouldBe` ExitFailure 2
      errors `shouldContain` "usage"

  it "removes the private runtime directory when a signal ends the setup before the compositor starts" $
    withSession $ \session → do
      -- The window the helper's cleanup has to cover first: the runtime
      -- directory exists and the compositor does not. `mkdir` is what creates
      -- it, so a `mkdir` that signals the helper as it returns puts the signal
      -- exactly there, with nothing timed.
      real ← findExecutable "mkdir" >>= maybe (fail "mkdir is not on PATH") pure
      installStubs session (("mkdir", signallingMkdir real) : waylandStubs)
      (result, _, errors) ← sessionHelper session ["--", "sh", "-c", recordSession session]
      result `shouldBe` ExitFailure 143
      errors `shouldContain` "terminated by SIGTERM"
      -- The compositor was never reached, so nothing recorded itself, and the
      -- command never ran.
      doesFileExist (directory session </> "compositor.pid") `shouldReturn` False
      doesFileExist (directory session </> "environment.txt") `shouldReturn` False
      created ← lines <$> readFile (directory session </> "early-mkdir.txt")
      case reverse created of
        runtime : _ → doesDirectoryExist runtime `shouldReturn` False
        [] → expectationFailure "the stub recorded no directory"
      leftBehind session `shouldReturn` []

  it "leaves nothing behind when the private runtime directory cannot be prepared" $
    withSession $ \session → do
      installStubs session (("mkdir", "#!/bin/sh\nexit 1\n") : waylandStubs)
      refusedSession session "no private runtime directory could be created"
      leftBehind session `shouldReturn` []

  it "stops and reaps the compositor and removes the runtime directory when a signal ends the startup" $
    withSession $ \session → do
      -- The signal comes from the readiness probe, which is the one thing the
      -- helper runs while it is waiting: the helper itself decides when that
      -- happens, and it tries again every tick, so the moment is the helper's
      -- own rather than an elapsed time. The compositor never serves, so the
      -- wait is where the helper stays.
      installStubs
        session
        ( ("weston", idleCompositor)
            : ("wayland-info", signallingClient)
            : filter ((`notElem` ["weston", "wayland-info"]) . fst) waylandStubs
        )
      (result, _, errors) ← sessionHelper session ["--", "sh", "-c", recordSession session]
      errors `shouldContain` "terminated by SIGTERM"
      result `shouldBe` ExitFailure 143
      -- The command never ran, so the consent reached nothing.
      doesFileExist (directory session </> "environment.txt") `shouldReturn` False
      cleanedUp session

  it "stops the command and the compositor and removes the runtime directory when a signal ends the run" $
    withSession $ \session → do
      installStubs session waylandStubs
      -- The command signals the helper once it is running, which is the only
      -- moment this example is about, and then stays alive so that the helper
      -- stopping it is what ends it.
      (result, _, errors) ←
        sessionHelper session ["--", "sh", "-c", recordSession session ++ "; echo $$ > command.pid; kill -TERM \"$PPID\"; exec sleep 300"]
      result `shouldBe` ExitFailure 143
      errors `shouldContain` "terminated by SIGTERM"
      commanded ← pidIn session "command.pid"
      stopped commanded `shouldReturn` True
      cleanedUp session

withSession ∷ (Display → IO a) → IO a
withSession = withHelper "tools/display/wayland.sh"

-- | Run the Wayland helper in an environment that already carries both an X11
-- display and someone else's Wayland session, and a runtime directory and
-- compositor configuration of its own, whatever the developer's own shell
-- holds. Everything the command and the compositor then see can only have come
-- from the helper.
sessionHelper ∷ Display → [String] → IO (ExitCode, String, String)
sessionHelper session arguments = do
  inherited ← sanitizedEnvironment
  let overrides =
        [ ("PATH", toolbox session)
        , ("DISPLAY", ":99")
        , ("WAYLAND_DISPLAY", "wayland-0")
        , ("WAYLAND_SOCKET", "7")
        , ("XDG_SESSION_TYPE", "x11")
        , ("XDG_RUNTIME_DIR", directory session </> "ambient-runtime")
        , ("XDG_CONFIG_HOME", directory session </> "ambient-config")
        , ("WESTON_CONFIG_FILE", directory session </> "ambient-config/weston.ini")
        , ("TMPDIR", directory session)
        ]
      removed = "HETOIMASIA_NATIVE_SESSION" : map fst overrides
      settings = overrides ++ filter ((`notElem` removed) . fst) inherited
  bash ← findExecutable "bash" >>= maybe (fail "bash is not on PATH") pure
  run settings (directory session) bash (script session : arguments)

-- | A shell command that records the Wayland environment the helper gave it.
-- The socket the helper named is not predictable, so what is asserted is the
-- relationship between these values rather than a literal.
recordSession ∷ Display → String
recordSession session =
  "echo \"${DISPLAY-unset} ${WAYLAND_SOCKET-unset} $XDG_SESSION_TYPE $WAYLAND_DISPLAY ${HETOIMASIA_NATIVE_SESSION-unset} $XDG_RUNTIME_DIR\" > '"
    ++ (directory session </> "environment.txt")
    ++ "'"

-- | Stub display programs that behave like a compositor that comes up: it
-- reports its version, records how it was launched and what it was launched
-- into, and serves until it is stopped; the client answers once it has.
waylandStubs ∷ [(String, String)]
waylandStubs =
  [ ("weston", workingCompositor)
  , ("wayland-info", workingClient)
  ]

-- | The lines every compositor stub records before doing anything else, so an
-- example can assert the launch even when the stub then exits or signals.
compositorRecord ∷ String
compositorRecord =
  unlines
    [ "#!/bin/sh"
    , "case \"$1\" in"
    , "  --version) echo 'weston 13.0.0'; exit 0 ;;"
    , "esac"
    , "echo $$ > compositor.pid"
    , "printf '%s\\n' \"$XDG_RUNTIME_DIR\" > runtime.txt"
    , "printf '%s\\n' \"$*\" > compositor-options.txt"
    , "echo \"${WAYLAND_DISPLAY-unset} ${WAYLAND_SOCKET-unset} ${DISPLAY-unset} $XDG_SESSION_TYPE\" > compositor-environment.txt"
    ]

-- | A compositor that records its launch and then serves, which is a state of
-- its own: recording the launch is not serving, and the client below answers
-- only once this marker exists.
workingCompositor ∷ String
workingCompositor = compositorRecord ++ ": > serving\nexec sleep 300\n"

-- | A compositor that records its launch and then fails, as one refused by its
-- backend does.
exitingCompositor ∷ String
exitingCompositor = compositorRecord ++ "echo 'no headless backend' >&2\nexit 1\n"

-- | A compositor that comes up and never serves, and stays alive so that the
-- helper stopping it is observable.
idleCompositor ∷ String
idleCompositor = compositorRecord ++ "exec sleep 300\n"

-- | A client that records the socket and runtime directory it was pointed at,
-- and connects once the compositor is up.
workingClient ∷ String
workingClient =
  unlines
    [ "#!/bin/sh"
    , "echo \"${WAYLAND_DISPLAY-unset} ${XDG_RUNTIME_DIR-unset}\" > probe.txt"
    , "[ -f serving ] || exit 1"
    , "echo 'interface: wl_compositor'"
    ]

-- | A client that never connects, however long the compositor runs.
refusingClient ∷ String
refusingClient =
  unlines
    [ "#!/bin/sh"
    , "echo \"${WAYLAND_DISPLAY-unset} ${XDG_RUNTIME_DIR-unset}\" > probe.txt"
    , "exit 1"
    ]

-- | A client that never connects and terminates the helper instead.
--
-- The helper is named by the socket it asked for rather than by this process's
-- parent, so what is signalled is the process that chose that socket, and the
-- helper's own retry is what repeats the attempt until it takes.
signallingClient ∷ String
signallingClient =
  unlines
    [ "#!/bin/sh"
    , "echo \"${WAYLAND_DISPLAY-unset} ${XDG_RUNTIME_DIR-unset}\" > probe.txt"
    , "kill -TERM \"${WAYLAND_DISPLAY#hetoimasia-}\" 2>/dev/null"
    , "exit 1"
    ]

-- | What the helper leaves behind once it has returned, for any outcome that
-- got as far as launching the compositor: nothing running, and nothing on
-- disk. The compositor is asked for by the process it recorded, so a stub that
-- outlives the helper would be caught rather than assumed reaped.
cleanedUp ∷ Display → IO ()
cleanedUp session = do
  compositor ← recordedPid session
  stopped compositor `shouldReturn` True
  runtime ← privateRuntime session
  runtime `shouldSatisfy` (directory session `isInfixOf`)
  doesDirectoryExist runtime `shouldReturn` False
  leftBehind session `shouldReturn` []

-- | The helper's own scratch directories still sitting in its TMPDIR. The
-- runtime directory lives inside one, so an empty answer is the whole
-- statement: nothing the helper created survived it.
leftBehind ∷ Display → IO [FilePath]
leftBehind session =
  filter ("hetoimasia-wayland." `isPrefixOf`) <$> listDirectory (directory session)

-- | A @mkdir@ that does what it was asked and then terminates the helper. The
-- signal is pending before this returns, so the helper handles it before its
-- next command rather than at some elapsed time.
signallingMkdir ∷ FilePath → String
signallingMkdir real =
  unlines
    [ "#!/bin/sh"
    , "'" ++ real ++ "' \"$@\""
    , "status=$?"
    , "for argument in \"$@\"; do"
    , "  case \"$argument\" in"
    , "    -*) ;;"
    , "    *) printf '%s\\n' \"$argument\" >> early-mkdir.txt ;;"
    , "  esac"
    , "done"
    , "kill -TERM \"$PPID\""
    , "exit $status"
    ]

-- | The private runtime directory the compositor was launched into.
privateRuntime ∷ Display → IO FilePath
privateRuntime session = takeWhile (/= '\n') <$> readFile (directory session </> "runtime.txt")

recordedPid ∷ Display → IO String
recordedPid session = pidIn session "compositor.pid"

pidIn ∷ Display → FilePath → IO String
pidIn session name = takeWhile (/= '\n') <$> readFile (directory session </> name)

-- | Run the Wayland helper where an example wants the command it names to
-- record its environment if it ever runs. A refusal runs it never, so no
-- consent reaches anything: the record is absent.
refusedSession ∷ Display → String → IO ()
refusedSession session reason = do
  (result, _, errors) ← sessionHelper session ["--", "sh", "-c", recordSession session]
  result `shouldBe` ExitFailure 1
  errors `shouldContain` reason
  errors `shouldContain` "the command did not run"
  doesFileExist (directory session </> "environment.txt") `shouldReturn` False
