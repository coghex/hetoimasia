-- | Hspec coverage for the native worker's isolated X11 display helper.
--
-- Every example runs the shipped @tools/display/x11.sh@ with a @PATH@ holding
-- only the utilities it needs and stub display programs, so what is asserted is
-- the script's own contract rather than whichever X server a machine happens to
-- have: the command runs inside the display the script established, with
-- Wayland removed and with the native suite's isolated-display consent set for
-- that display, and a missing or failing server or window manager stops the
-- run before the command starts, so the consent reaches nothing. The real
-- server is exercised by the @test.glfw-native@ group itself.
module Display (spec) where

import Control.Monad (forM_)
import Sandbox (run, sanitizedEnvironment)
import System.Directory
  ( createDirectory
  , createFileLink
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , getPermissions
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldReturn)

data Display = Display
  { directory ∷ FilePath
  , toolbox ∷ FilePath
  , script ∷ FilePath
  }

spec ∷ Spec
spec = describe "Isolated X11 display" $ do
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
    writeFile path contents
    permissions ← getPermissions path
    setPermissions path (setOwnerExecutable True permissions)

withDisplay ∷ (Display → IO a) → IO a
withDisplay action = do
  checkout ← getCurrentDirectory
  withSystemTempDirectory "hetoimasia-display" $ \scratch → do
    let box = scratch </> "bin"
    createDirectory box
    forM_ utilities $ \name →
      findExecutable name >>= \case
        Just found → createFileLink found (box </> name)
        Nothing → expectationFailure (name ++ " is not on PATH, so the helper's toolbox cannot be assembled")
    action (Display scratch box (checkout </> "tools/display/x11.sh"))

-- | The ordinary utilities the helper and these examples' commands use. The
-- display programs themselves are deliberately absent unless stubbed.
utilities ∷ [String]
utilities = ["cat", "mkfifo", "mktemp", "rm", "sed", "sh", "sleep", "tail", "touch", "tr"]
