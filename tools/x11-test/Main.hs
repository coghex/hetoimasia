-- | Headless checks of the isolated X11 helper, including its real startup
-- deadlines. Kept out of workflow-tests so unrelated workflow checks never
-- wait for X11 startup failures. All display programs are stubs; no desktop
-- session is initialized.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.List (isPrefixOf)
import System.Directory
  ( createDirectory, createFileLink, doesFileExist, findExecutable
  , getCurrentDirectory, getPermissions, listDirectory, removePathForcibly
  , setOwnerExecutable, setPermissions
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (cwd, env), proc, readCreateProcessWithExitCode)
import Test.Hspec
  ( Spec, describe, expectationFailure, it, shouldBe, shouldContain
  , shouldNotContain, shouldReturn
  )
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig { configFailOnEmpty = True } x11Spec

data Display = Display
  { directory ∷ FilePath
  , toolbox ∷ FilePath
  , script ∷ FilePath
  }

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

  it "refuses to run the command when the X server exits before its startup report closes" $
    withDisplay $ \display → do
      -- The exit is complete before the report channel closes: the stub hands
      -- the channel to a process that closes it only once the stub has gone.
      -- The helper reads the closed channel and still names the exit, which is
      -- what the server's own status says, rather than the timeout the job
      -- table's later notice of that exit once allowed.
      installStubs display (("Xvfb", outlivedServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup
        display
        "the X server exited before reporting a display: the framebuffer could not be opened"
        ["holder.pid"]

  it "refuses to run the command when the X server exits while its startup report stays open" $
    withDisplay $ \display → do
      -- The exit is the only observation there is to make: the stub hands its
      -- report channel to a process that never closes it, so the channel is
      -- still open when the bound expires and answers nothing at all. An
      -- observer that had to read that channel to its end before it could wait
      -- for the server would never reach the wait, and this exit would be
      -- refused as the report simply not arriving in time. Which of the two
      -- the helper said is what this example reads.
      installStubs display (("Xvfb", handedOffServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup
        display
        "the X server exited before reporting a display: the framebuffer could not be opened"
        ["server.pid"]
      -- The writer really did outlive the bound: blocked on a channel with no
      -- writer of its own, it is still there once the helper has refused. The
      -- helper never started it and never learned of it, so ending it belongs
      -- to the example that arranged it.
      holder ← pidIn display "holder.pid"
      stopped holder `shouldReturn` False
      ended holder

  it "refuses to run the command when the X server closes its startup report without naming a display" $
    withDisplay $ \display → do
      -- A server that stays alive with the channel shut is not an exit, and a
      -- shut channel is not a report either. Which of the two this was is
      -- settled at the bound, because a server on its way out would be reaped
      -- and named as the exit it is before then; this example waits that bound
      -- out. The stub handles the helper's termination signal and exits
      -- cleanly, so a refusal that still says "closed or invalid" cannot have
      -- come from reading how the cleanup ended it.
      installStubs display (("Xvfb", closingServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup
        display
        "the X server's startup report was closed or invalid before it named a display: the startup report was closed"
        ["server.pid"]

  it "refuses to run the command when the X server's startup report names no display number" $
    withDisplay $ \display → do
      -- A line arrived, so the channel is not closed; it names no display, so
      -- the report is invalid. Both are the same refusal, and the bound settles
      -- it against an exit the same way; this example waits that bound out.
      installStubs display (("Xvfb", babblingServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup
        display
        "the X server's startup report was closed or invalid before it named a display: the display number is unavailable"
        ["server.pid"]

  it "refuses to run the command when the X server reports no display within the bound" $
    withDisplay $ \display → do
      -- A server that holds the report channel open and says nothing exhausts
      -- the helper's thirty-second bound; this example waits that bound out.
      -- This stub too handles the termination signal and exits cleanly, so the
      -- timeout is the outstanding report rather than the cleanup's doing.
      --
      -- This is also where the request to stop that cleanup sends at the bound
      -- arrives: the observer is waiting for a server that has not exited, and
      -- the reader beside it is waiting on a channel that says nothing. A
      -- handler that only recorded the request would return into that same
      -- wait and go on waiting for a server nobody had stopped, which would
      -- then run until it ran out on its own — long after the refusal, and
      -- with the helper still waiting on it.
      --
      -- Which of the two happened is settled by the server's own note rather
      -- than by how long any of it took: it writes @stopped@ from the handler
      -- that ends it, and @expired@ only if it was still running when its own
      -- time ran out. A recording handler leaves exactly the second note.
      installStubs display (("Xvfb", silentServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup display "the X server reported no display within 30 seconds" ["server.pid"]
      doesFileExist (directory display </> "stopped") `shouldReturn` True
      doesFileExist (directory display </> "expired") `shouldReturn` False

  it "refuses to run the command when the startup report is still incomplete at the bound" $
    withDisplay $ \display → do
      -- Buffered digits are not a display number until the report is complete,
      -- so this is the bound expiring rather than a readiness the helper may
      -- act on; this example waits that bound out too.
      installStubs display (("Xvfb", stammeringServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup display "the X server reported no display within 30 seconds" ["server.pid"]

  it "stops the X server when the request to stop it reaches the observer as it starts the server" $
    withDisplay $ \display → do
      -- The earliest a request to stop can arrive: the server asks for it at
      -- its own first instruction, while the observer that started it may not
      -- yet have reached the wait that reaps it. The observer stops what it
      -- started — the server and the reader beside it — waits for both, and
      -- ends without writing an outcome, because an outcome it was told to
      -- produce would be the helper's own signalling coming back to it, and a
      -- report channel its own cleanup closed is not the server closing it.
      -- The helper is left with the report that never came; this example waits
      -- the bound out.
      installStubs display (("Xvfb", earlyStopServer) : filter ((/= "Xvfb") . fst) workingStubs)
      refusedStartup display "the X server reported no display within 30 seconds" ["server.pid"]

  it "follows the report when the X server names a display and exits at once" $
    withDisplay $ \display → do
      -- The report and the exit are made by separate observers, so they arrive
      -- in whichever order they were noticed and neither can overtake the
      -- other. The helper waits for both and answers from the pair: the
      -- display it was given outranks the exit that came with it, so this is
      -- never the server exiting before reporting a display it had already
      -- named. What a departed server is refused for is the answer it does not
      -- give.
      installStubs
        display
        ( ("Xvfb", departingServer)
            : ("xdpyinfo", closedDisplay)
            : filter ((`notElem` ["Xvfb", "xdpyinfo"]) . fst) workingStubs
        )
      (result, _, errors) ← helper display ["--", "sh", "-c", recordEnvironment display]
      result `shouldBe` ExitFailure 1
      errors `shouldContain` "the X server on :42 does not answer: unable to open display"
      errors `shouldNotContain` "exited before reporting a display"
      doesFileExist (directory display </> "environment.txt") `shouldReturn` False
      server ← pidIn display "server.pid"
      stopped server `shouldReturn` True
      leftBehind "hetoimasia-x11." display `shouldReturn` []

  it "stops the X server and removes its scratch directory when a signal ends the startup" $
    withDisplay $ \display → do
      -- Cleanup's first window: the server is running and nothing has reported
      -- yet, which is where the helper spends the bound. The server itself is
      -- what signals the helper, so the signal lands there rather than after an
      -- elapsed time, and it then stays alive so that the helper stopping it is
      -- what ends it.
      installStubs display (("Xvfb", signallingServer) : filter ((/= "Xvfb") . fst) workingStubs)
      (result, _, errors) ← helper display ["--", "sh", "-c", recordEnvironment display]
      result `shouldBe` ExitFailure 143
      errors `shouldContain` "terminated by SIGTERM"
      -- The display was never established, so the command never ran and the
      -- consent reached nothing.
      doesFileExist (directory display </> "environment.txt") `shouldReturn` False
      server ← pidIn display "server.pid"
      stopped server `shouldReturn` True
      leftBehind "hetoimasia-x11." display `shouldReturn` []

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

-- | A server that exits before reporting a display, and whose report channel
-- closes only afterwards. The holder inherits the channel and blocks on a
-- second one whose only writer is the server itself, so it wakes — and closes
-- the report channel by exiting — exactly when the server has exited. The
-- handshake is what orders the two: the server does not exit until the holder
-- is already blocked, so no elapsed time stands in for the ordering.
outlivedServer ∷ String
outlivedServer =
  unlines
    [ "#!/bin/sh"
    , "echo 'the framebuffer could not be opened' >&2"
    , "rm -f gate ack"
    , "mkfifo gate ack"
    , "sh -c 'exec 5<gate; echo ready > ack; cat <&5 >/dev/null' &"
    , "echo $! > holder.pid"
    , "exec 4>gate"
    , "read ready < ack"
    , "exit 1"
    ]

-- | A server that exits before reporting a display and leaves its report
-- channel open behind it: the writer it forked inherits the channel and then
-- blocks for good on a channel of its own that no one ever writes to, so the
-- report channel never closes and answers nothing at all. The exit is the only
-- observation there is, and it is made while the report is still outstanding.
handedOffServer ∷ String
handedOffServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "echo 'the framebuffer could not be opened' >&2"
    , "rm -f gate"
    , "mkfifo gate"
    , "sh -c 'read held < gate' &"
    , "echo $! > holder.pid"
    , "exit 1"
    ]

-- | A server that closes its report channel and then stays alive, so the
-- channel closes with no exit to observe at all. Like the real Xvfb it handles
-- the termination signal the helper's cleanup sends and exits cleanly, of its
-- own accord and with a status of its own choosing, so an outcome that can be
-- told apart from an exit here is being read from the server's own channels
-- rather than from how the helper's cleanup happened to end it.
closingServer ∷ String
closingServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "echo 'the startup report was closed' >&2"
    , "exec 3>&-"
    , "trap 'kill $waiter 2>/dev/null; exit 0' TERM"
    , "sleep 300 & waiter=$!"
    , "wait"
    ]

-- | A server that reports something other than a display number and stays
-- alive, so the report is invalid without the channel having closed. This one
-- is ended by the helper's cleanup signal rather than handling it, the other
-- disposition a live server can have when it is stopped.
babblingServer ∷ String
babblingServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "echo 'the display number is unavailable' >&2"
    , "echo not-a-display >&3"
    , "exec sleep 300"
    ]

-- | A server that asks for its own observer to be stopped at its first
-- instruction, so the request races that observer's startup rather than
-- arriving long after it. Its parent is that observer and not the helper,
-- which is what makes @$PPID@ the right target here and the wrong one in
-- 'signallingServer'.
earlyStopServer ∷ String
earlyStopServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "kill -TERM \"$PPID\""
    , "exec sleep 300"
    ]

-- | A server that names a display and exits in the same breath. It says it is
-- leaving before it reports, so by the time the helper has the report the
-- display is already unservable and nothing about the outcome turns on which
-- of the two the helper noticed first.
departingServer ∷ String
departingServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , ": > departed"
    , "echo 42 >&3"
    , "exit 0"
    ]

-- | An @xdpyinfo@ that answers for a server that is still there and refuses
-- for one that has said it is leaving, the way the real one fails against a
-- display with nothing behind it.
closedDisplay ∷ String
closedDisplay =
  unlines
    [ "#!/bin/sh"
    , "if [ -e departed ]; then"
    , "  echo 'unable to open display' >&2"
    , "  exit 1"
    , "fi"
    , "echo 'vendor string:    Stub X Server'"
    ]

-- | A server that signals the helper as soon as it is running and then stays
-- alive. The helper is the server's grandparent — the observer process that
-- starts the server, reads nothing itself, and waits for it sits between them
-- — so the signal is aimed through the server's own parent rather than at it.
signallingServer ∷ String
signallingServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "helper=$(ps -o ppid= -p \"$PPID\" | tr -d ' ')"
    , "kill -TERM \"$helper\""
    , "exec sleep 300"
    ]

-- | A server that holds its report channel open and reports nothing, and that
-- records how it was ended. Stopped by the helper, it handles the termination
-- signal, notes that it was stopped, and exits cleanly, as a real Xvfb does.
-- Left to itself it outlives the helper's bound by a wide margin and then
-- notes that it ran out instead. The two notes are what tell an immediate,
-- handler-driven shutdown from a server that merely went away on its own
-- eventually, without either one being read off a clock.
silentServer ∷ String
silentServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "trap 'kill $waiter 2>/dev/null; : > stopped; exit 0' TERM"
    , "sleep 120 & waiter=$!"
    , "wait"
    , ": > expired"
    ]

-- | A server whose report never becomes a complete line: the digits it wrote
-- sit in the channel unterminated while it stays alive.
stammeringServer ∷ String
stammeringServer =
  unlines
    [ "#!/bin/sh"
    , "echo $$ > server.pid"
    , "printf 4 >&3"
    , "exec sleep 300"
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

-- | What a refusal during server startup must leave behind, beyond the refusal
-- itself: the reason names the outcome it was, quoting the server's own log
-- where the helper quotes one, the helper's scratch directory is gone, and
-- every process the stub recorded has been stopped.
refusedStartup ∷ Display → String → [FilePath] → IO ()
refusedStartup display reason recorded = do
  refused display reason
  leftBehind "hetoimasia-x11." display `shouldReturn` []
  forM_ recorded $ \name → do
    process ← pidIn display name
    stopped process `shouldReturn` True

-- | Run the helper in a Wayland-looking environment that carries no native
-- consent, whatever the developer's own shell holds, so what the command
-- records can only have come from the helper.
helper ∷ Display → [String] → IO (ExitCode, String, String)
helper display arguments = do
  inherited ← getEnvironment
  let overrides =
        [ ("LC_ALL", "C")
        , ("PATH", toolbox display)
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

-- | End a process an example's stub started outside the helper's reach, and
-- wait until it is gone. Whether the helper stopped what it owns is asserted
-- before this runs; this is the example clearing up its own apparatus, and the
-- wait is for the process to be reaped by whoever inherited it rather than for
-- anything the helper does.
ended ∷ String → IO ()
ended pid = do
  _ ← run [] "/" "kill" [pid]
  let await attempt =
        stopped pid >>= \gone →
          if gone
            then pure ()
            else
              if attempt >= (600 ∷ Int)
                then expectationFailure (pid ++ " is still running six seconds after it was ended")
                else threadDelay 10000 >> await (attempt + 1)
  await 0

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
  ["cat", "head", "mkdir", "mkfifo", "mktemp", "ps", "rm", "sed", "sh", "sleep", "tail", "touch", "tr"]

-- | The X11 helper's own scratch directories still sitting in its TMPDIR.
-- An empty answer proves that none of those directories survived the run.
leftBehind ∷ String → Display → IO [FilePath]
leftBehind prefix session =
  filter (prefix `isPrefixOf`) <$> listDirectory (directory session)

pidIn ∷ Display → FilePath → IO String
pidIn display name = takeWhile (/= '\n') <$> readFile (directory display </> name)

-- These fixtures execute shell utilities only; each helper supplies its own
-- display environment and cannot inherit native-session consent.
run ∷ [(String, String)] → FilePath → String → [String] → IO (ExitCode, String, String)
run environment path executable arguments =
  readCreateProcessWithExitCode
    (proc executable arguments) {cwd = Just path, env = Just environment} ""
