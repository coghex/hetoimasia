-- | Hspec coverage for the build identity that @tools/vulkan/run.sh build@ stamps
-- and @run.sh native@ presents (#585).
--
-- @native@ runs an executable that was built earlier and builds nothing, so the
-- provenance it prints, and exports for the executable to record, must describe
-- that executable and not the source tree at run time. These examples run the
-- real @run.sh@ and @build_identity.py@ in a checkout of their own, with
-- stand-ins for what they call: @cabal@ (@build@ writes executables whose bytes
-- follow the source, @list-bin@ names them), @uname@, the isolated display, the
-- X11 evidence helper, the prefix discovery and the toolchain. The checkout is a
-- real Git repository, so revisions and the dirty marker are the real ones.
--
-- No example starts a window, a display, a session or a GPU, reads consent, or
-- needs a provisioned native prefix. The isolated display is a stand-in that
-- records its start; an executable is a stand-in that records its arguments and
-- environment; every wait is for a file a stand-in writes, and file contents,
-- not file times, order the builds.
--
-- Ownership of what an example starts: every @run.sh@ it runs is waited for
-- before the example goes on. The one that is signalled (an interrupted build)
-- runs in a process group of its own and is ended and waited for on every exit,
-- an assertion failure and a timeout included, with its output kept in the
-- checkout the failure message names.
module RunnerIdentity (runnerIdentitySpec) where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Monad (forM, forM_, void, when)
import Data.Char (isHexDigit)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort)
import Data.Maybe (listToMaybe)
import Json (asArray, asString, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , listDirectory
  , removeFile
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (IOMode (WriteMode), withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), StdStream (UseHandle), createProcess, getPid, proc, readCreateProcessWithExitCode, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotBe, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The components the fixture knows, spelled as the callers spell them

-- | The native suite most examples build and run.
suite ∷ String
suite = "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"

-- | Another suite, for a stamp copied from another component.
otherSuite ∷ String
otherSuite = "hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests"

-- | The launcher's native suite, which starts the full-product command.
launcher ∷ String
launcher = "hetoimasia:test:run-native-tests"

-- | The full-product command the launcher starts.
product' ∷ String
product' = "hetoimasia:exe:hetoimasia"

-- | The command the runner names when the launcher needs preparing: both
-- executables, in one build.
pairCommand ∷ String
pairCommand = "bash tools/vulkan/run.sh build " ++ product' ++ " " ++ launcher

-- | The one source file the fixture's executables are built from. It lies under
-- a directory the digest hashes.
sourceFile ∷ FilePath
sourceFile = "packages/runtime/Source.hs"

original, edited ∷ String
original = "module Source where\n-- original\n"
edited = "module Source where\n-- edited\n"

-- | A tracked file the digest does not hash, which a commit can change.
noteFile ∷ FilePath
noteFile = "docs/Note.md"

-- | The fingerprints the runner generates, which it removes again at exit.
generatedFingerprints ∷ [FilePath]
generatedFingerprints =
  [ "packages/gpu-vulkan/native/shaders/toolchain.fingerprint"
  , "samples/triangle/renderer/shaders/toolchain.fingerprint"
  , "samples/sprites/renderer/shaders/toolchain.fingerprint"
  , "samples/scene3d/renderer/shaders/toolchain.fingerprint"
  , "packages/render-2d-vulkan/shaders/toolchain.fingerprint"
  ]

-- ---------------------------------------------------------------------------
-- The fixture

data Native = Native
  { nativeRoot ∷ FilePath
  , nativeEnvironment ∷ [(String, String)]
  , nativeGit ∷ [(String, String)]
  }

data Outcome = Outcome
  { outcomeStatus ∷ ExitCode
  , outcomeOut ∷ String
  , outcomeErr ∷ String
  }

-- | A Git checkout holding the real runner and its helper, and stand-ins for
-- everything else, with one commit.
withNative ∷ (Native → IO a) → IO a
withNative action = do
  checkout ← getCurrentDirectory
  gitEnvironment ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-runner-identity" $ \root → do
    let put relative contents = do
          createDirectoryIfMissing True (takeDirectory (root </> relative))
          writeFile (root </> relative) contents
        putExecutable relative contents = do
          put relative contents
          permissions ← getPermissions (root </> relative)
          setPermissions (root </> relative) (setOwnerExecutable True permissions)
    createDirectoryIfMissing True (root </> "tools/vulkan")
    forM_ ["run.sh", "build_identity.py"] $ \file →
      copyFile (checkout </> "tools/vulkan" </> file) (root </> "tools/vulkan" </> file)
    put "tools/ci-image/toolchain.pin" "GHC_VERSION=9.14.1\nCABAL_VERSION=3.18.1.0\n"
    put "tools/toolchain/binding.pin" "VULKAN_FLAG_SAFE_FOREIGN_CALLS=on\nVULKAN_FLAG_DARWIN_LIB_DIRS=off\n"
    put "cabal.project.vulkan" "constraints:\n    vulkan +safe-foreign-calls,\n    vulkan -darwin-lib-dirs\n"
    put "driver.json" "{}\n"
    createDirectoryIfMissing True (root </> "layers")
    put
      "tools/native/native.py"
      ( unlines
          [ "print('export VK_DRIVER_FILES=\"" ++ root ++ "/driver.json\"')"
          , "print('export VK_LAYER_PATH=\"" ++ root ++ "/layers\"')"
          , "print('export HETOIMASIA_GLSLANG=\"" ++ root ++ "/bin/glslang\"')"
          , "print('export HETOIMASIA_VULKAN_LIBDIR=\"" ++ root ++ "/lib\"')"
          , "print('export HETOIMASIA_VULKAN_INCLUDEDIR=\"" ++ root ++ "/include\"')"
          ]
      )
    -- The helper the Linux launcher preparation loads, and the display the runner
    -- starts for a run with no consent of its own: each only records that it ran.
    put "tools/x11-window/x11_window.py" "import sys\nsys.exit(0)\n"
    putExecutable
      "tools/display/x11.sh"
      ( unlines
          [ "#!/bin/sh"
          , ": > \"$FIXTURE_ROOT/display-started\""
          , "while [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done"
          , "shift"
          , "exec \"$@\""
          ]
      )
    putExecutable "bin/glslang" "#!/bin/sh\necho stand-in glslang\n"
    putExecutable "bin/ghc" "#!/bin/sh\necho 9.14.1\n"
    putExecutable "bin/uname" "#!/bin/sh\nif [ \"$1\" = -s ]; then echo \"$FIXTURE_UNAME\"; else exec /usr/bin/uname \"$@\"; fi\n"
    put "bin/standin-body" standInBody
    putExecutable "bin/cabal" standInCabal
    put sourceFile original
    put noteFile "note\n"
    put ".gitignore" "/dist-vulkan/\n/dist-vulkan-vma-safe/\n/ran-*\n/display-started\n/build-started\n/interrupted.log\n"
    void $ git gitEnvironment root ["init", "-q"]
    void $ git gitEnvironment root ["add", "-A"]
    void $ git gitEnvironment root ["commit", "-q", "-m", "fixture"]
    inherited ← sanitizedEnvironment
    let unset =
          [ "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"
          , "DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_IMAGE_SUFFIX"
          , "PATH", "HETOIMASIA_NATIVE_SESSION", "HETOIMASIA_VMA_FOREIGN_CALLS", "HETOIMASIA_VULKAN_REVISION"
          , "HETOIMASIA_VULKAN_SOURCE_DIGEST", "HETOIMASIA_RUN_EXECUTABLE", "HETOIMASIA_VALIDATION_EVIDENCE"
          , "HETOIMASIA_NATIVE_PREFIX", "FIXTURE_ROOT", "FIXTURE_UNAME", "FIXTURE_BUILD", "FIXTURE_FAIL_ON", "FIXTURE_BUILD_TAG"
          ]
        environment =
          [ ("PATH", (root </> "bin") ++ ":" ++ maybe "/usr/bin:/bin" id (lookup "PATH" inherited))
          , ("FIXTURE_ROOT", root)
          , ("FIXTURE_UNAME", "Darwin")
          , ("FIXTURE_BUILD", "")
          , ("FIXTURE_FAIL_ON", "")
          , ("FIXTURE_BUILD_TAG", "one")
          ]
            ++ filter ((`notElem` unset) . fst) inherited
    action (Native root environment gitEnvironment)

-- | What a stand-in executable does when it is launched: record its arguments
-- and the environment the runner gave it, then exit with a status of its own.
standInBody ∷ String
standInBody =
  unlines
    [ "{"
    , "  echo \"args:$*\""
    , "  echo \"revision:${HETOIMASIA_VULKAN_REVISION-}\""
    , "  echo \"digest:${HETOIMASIA_VULKAN_SOURCE_DIGEST-}\""
    , "  echo \"launch:${HETOIMASIA_RUN_EXECUTABLE-}\""
    , "  echo \"session:${HETOIMASIA_NATIVE_SESSION-}\""
    , "  if [ -e \"$FIXTURE_ROOT/display-started\" ]; then echo display:started; else echo display:none; fi"
    , "} > \"$FIXTURE_ROOT/ran-$name\""
    , "exit 7"
    ]

-- | The toolchain's @cabal@. @build@ writes, for each target that is one
-- executable, a file whose bytes follow the source file (the full-product
-- command's follow only @FIXTURE_BUILD_TAG@), and @list-bin@ names it; a library
-- or a package names no single executable. @FIXTURE_BUILD@ chooses how a build
-- ends: @fail@, @block@ until signalled, or @edits@ the source while compiling;
-- @FIXTURE_FAIL_ON@ fails the build right after the named executable is written.
standInCabal ∷ String
standInCabal =
  unlines
    [ "#!/bin/sh"
    , "if [ \"$1\" = --numeric-version ]; then echo 3.18.1.0; exit 0; fi"
    , "command=\"$1\""
    , "shift"
    , "if [ \"$command\" = run ]; then"
    , "  while [ \"$#\" -gt 0 ]; do"
    , "    if [ \"$1\" = --output ]; then echo stand-in > \"$2\"; exit 0; fi"
    , "    shift"
    , "  done"
    , "  exit 0"
    , "fi"
    , "builddir="
    , "targets="
    , "for argument in \"$@\"; do"
    , "  case \"$argument\" in"
    , "    --builddir=*) builddir=\"${argument#--builddir=}\" ;;"
    , "    -*) ;;"
    , "    *) targets=\"$targets $argument\" ;;"
    , "  esac"
    , "done"
    , "resolve() {"
    , "  case \"$1\" in"
    , "    hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests|vulkan-native-tests) echo vulkan-native-tests ;;"
    , "    hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests) echo lua-engine-graphics-native-tests ;;"
    , "    hetoimasia:test:run-native-tests|hetoimasia:run-native-tests|run-native-tests) echo run-native-tests ;;"
    , "    hetoimasia:exe:hetoimasia|hetoimasia:hetoimasia|hetoimasia) echo hetoimasia ;;"
    , "  esac"
    , "}"
    , "emit() {"
    , "  mkdir -p \"$builddir/bin\""
    , "  source="
    , "  if [ \"$1\" != hetoimasia ]; then source=\"$(tr '\\n' ' ' < \"$FIXTURE_ROOT/packages/runtime/Source.hs\")\"; fi"
    , "  { echo '#!/bin/sh'; echo \"# $1 $FIXTURE_BUILD_TAG $source\"; echo \"name=$1\"; cat \"$FIXTURE_ROOT/bin/standin-body\"; } > \"$builddir/bin/$1\""
    , "  chmod +x \"$builddir/bin/$1\""
    , "}"
    , "target=\"${targets# }\""
    , "if [ \"$command\" = list-bin ]; then"
    , "  name=\"$(resolve \"$target\")\""
    , "  if [ -z \"$name\" ]; then echo \"cabal: $target names no single executable\" >&2; exit 1; fi"
    , "  echo \"$builddir/bin/$name\""
    , "  exit 0"
    , "fi"
    , "if [ \"$command\" = build ]; then"
    , "  for target in $targets; do"
    , "    name=\"$(resolve \"$target\")\""
    , "    [ -n \"$name\" ] || continue"
    , "    emit \"$name\""
    , "    # build-tool-depends: the launcher's build also builds the command it starts."
    , "    if [ \"$name\" = run-native-tests ]; then emit hetoimasia; fi"
    , "    if [ \"$FIXTURE_FAIL_ON\" = \"$name\" ]; then echo \"cabal: $name failed\" >&2; exit 1; fi"
    , "  done"
    , "  case \"$FIXTURE_BUILD\" in"
    , "    fail) echo 'cabal: the build failed' >&2; exit 1 ;;"
    , "    block) : > \"$FIXTURE_ROOT/build-started\"; exec sleep 300 ;;"
    , "    edits) echo '-- changed while compiling' >> \"$FIXTURE_ROOT/packages/runtime/Source.hs\" ;;"
    , "  esac"
    , "  exit 0"
    , "fi"
    , "echo \"cabal: unexpected command $command\" >&2"
    , "exit 64"
    ]

-- | The runner's environment, with these settings over the fixture's.
withSettings ∷ Native → [(String, String)] → [(String, String)]
withSettings native settings = settings ++ filter ((`notElem` map fst settings) . fst) (nativeEnvironment native)

runScript ∷ FilePath
runScript = "tools/vulkan/run.sh"

-- | Run the real runner to its end.
invoke ∷ Native → [(String, String)] → [String] → IO Outcome
invoke native settings arguments = do
  (status, out, err) ←
    readCreateProcessWithExitCode
      (proc "bash" ((nativeRoot native </> runScript) : arguments))
        { cwd = Just (nativeRoot native)
        , env = Just (withSettings native settings)
        }
      ""
  pure (Outcome status out err)

build ∷ Native → [(String, String)] → [String] → IO Outcome
build native settings targets = invoke native settings ("build" : targets)

-- | @native COMPONENT -- --complete@, the group's own shape.
runNative ∷ Native → [(String, String)] → String → IO Outcome
runNative native settings component = invoke native settings ["native", component, "--", "--complete"]

-- | A build that must succeed.
built ∷ Native → [(String, String)] → [String] → IO ()
built native settings targets = do
  outcome ← build native settings targets
  when (outcomeStatus outcome /= ExitSuccess) $
    expectationFailure ("the build was expected to succeed but ended " ++ show (outcomeStatus outcome) ++ "\n" ++ outcomeErr outcome)

-- | The toolchain's @cabal build@ itself, which the runner does not wrap: how a
-- replaced executable appears without its stamp.
cabalBuild ∷ Native → [(String, String)] → FilePath → [String] → IO ()
cabalBuild native settings buildDirectory targets = do
  (status, _, err) ←
    readCreateProcessWithExitCode
      (proc (nativeRoot native </> "bin/cabal") (["build", "--builddir=" ++ nativeRoot native </> buildDirectory] ++ targets))
        { cwd = Just (nativeRoot native)
        , env = Just (withSettings native settings)
        }
      ""
  when (status /= ExitSuccess) $ expectationFailure ("the stand-in cabal failed: " ++ err)

-- ---------------------------------------------------------------------------
-- Reading what the runner and the stand-ins left

readStrict ∷ FilePath → IO String
readStrict path = do
  contents ← readFile path
  length contents `seq` pure contents

setSource ∷ Native → String → IO ()
setSource native = writeFile (nativeRoot native </> sourceFile)

headRevision ∷ Native → IO String
headRevision native = takeWhile (/= '\n') <$> git (nativeGit native) (nativeRoot native) ["rev-parse", "HEAD"]

-- | Move @HEAD@ without touching anything the digest hashes.
commitNote ∷ Native → String → IO ()
commitNote native text = do
  writeFile (nativeRoot native </> noteFile) text
  void $ git (nativeGit native) (nativeRoot native) ["add", noteFile]
  void $ git (nativeGit native) (nativeRoot native) ["commit", "-q", "-m", "note"]

gitStatus ∷ Native → IO String
gitStatus native = git (nativeGit native) (nativeRoot native) ["status", "--short"]

-- | The revision and the digest the runner printed.
headerOf ∷ String → (Maybe String, Maybe String)
headerOf out = (after "vulkan: repository revision ", after "vulkan: source digest ")
  where
    after prefix = listToMaybe [drop (length prefix) line | line ← lines out, prefix `isPrefixOf` line]

-- | What the stand-in executable of this name recorded when it was launched.
launched ∷ Native → String → IO (Maybe [String])
launched native name = do
  let path = nativeRoot native </> ("ran-" ++ name)
  present ← doesFileExist path
  if present then Just . lines <$> readStrict path else pure Nothing

recorded ∷ String → [String] → Maybe String
recorded key entries = listToMaybe [drop (length key + 1) entry | entry ← entries, (key ++ ":") `isPrefixOf` entry]

-- | Every file of the checkout, relative, without Git's own.
filesOf ∷ FilePath → IO [FilePath]
filesOf root = go ""
  where
    go relative = do
      names ← listDirectory (root </> relative)
      fmap concat . forM (sort names) $ \name → do
        let path = if null relative then name else relative </> name
        if name == ".git"
          then pure []
          else do
            directory ← doesDirectoryExist (root </> path)
            if directory then go path else pure [path]

-- | Where the build directory keeps its stamps.
stampDirectory ∷ FilePath → FilePath
stampDirectory buildDirectory = buildDirectory </> "native-identity"

-- | The stamps of a build directory.
stampsOf ∷ Native → FilePath → IO [FilePath]
stampsOf native buildDirectory = do
  let directory = nativeRoot native </> stampDirectory buildDirectory
  present ← doesDirectoryExist directory
  if present
    then map (directory </>) . sort . filter (".stamp" `isSuffixOf`) <$> listDirectory directory
    else pure []

-- | The stamp of the executable of this name: its file name is the name, a
-- dash, sixteen hex digits, and the extension.
stampOf ∷ Native → FilePath → String → IO FilePath
stampOf native buildDirectory name = do
  stamps ← stampsOf native buildDirectory
  case filter (isStampOf . takeFileName) stamps of
    [stamp] → pure stamp
    found → fail ("expected one stamp of " ++ name ++ " in " ++ buildDirectory ++ ", found " ++ show found)
  where
    isStampOf file =
      (name ++ "-") `isPrefixOf` file
        && length file == length name + 1 + 16 + length (".stamp" ∷ String)
        && all isHexDigit (take 16 (drop (length name + 1) file))

-- | Change the text of a file through a function of its lines.
rewrite ∷ FilePath → ([String] → [String]) → IO ()
rewrite path change = do
  contents ← readStrict path
  writeFile path (unlines (change (lines contents)))

-- | Poll, boundedly, for a file a stand-in writes. Nothing is timed.
awaitFile ∷ FilePath → IO ()
awaitFile path = go (3000 ∷ Int)
  where
    go 0 = expectationFailure (path ++ " did not appear within thirty seconds")
    go remaining =
      doesFileExist path >>= \present →
        if present then pure () else threadDelay 10000 >> go (remaining - 1)

-- ---------------------------------------------------------------------------
-- What an outcome must show

-- | The runner refused with its configuration status, naming each fragment, and
-- nothing was started: no stand-in executable ran and no display was started.
refusedBeforeAnythingStarts ∷ Native → Outcome → [String] → IO ()
refusedBeforeAnythingStarts native outcome fragments = do
  outcomeStatus outcome `shouldBe` ExitFailure 2
  forM_ fragments $ \fragment → outcomeErr outcome `shouldContain` fragment
  outcomeOut outcome `shouldNotContain'` "vulkan: repository revision"
  nothingStarted native

shouldNotContain' ∷ String → String → IO ()
shouldNotContain' text fragment = (fragment `isInfixOf` text) `shouldBe` False

-- | Forget what the stand-in executables recorded, for an example that goes on to a refusal.
clearLaunches ∷ Native → IO ()
clearLaunches native = do
  files ← listDirectory (nativeRoot native)
  forM_ (filter ("ran-" `isPrefixOf`) files) $ \file → removeFile (nativeRoot native </> file)
  display ← doesFileExist (nativeRoot native </> "display-started")
  when display $ removeFile (nativeRoot native </> "display-started")

nothingStarted ∷ Native → IO ()
nothingStarted native = do
  files ← listDirectory (nativeRoot native)
  filter ("ran-" `isPrefixOf`) files `shouldBe` []
  doesFileExist (nativeRoot native </> "display-started") >>= (`shouldBe` False)

-- | The suite ran, with the stand-in's own status, and the header it printed
-- and the pair it was handed are this one.
ranWith ∷ Native → Outcome → String → String → IO [String]
ranWith native outcome name revision = do
  outcomeStatus outcome `shouldBe` ExitFailure 7
  fst (headerOf (outcomeOut outcome)) `shouldBe` Just revision
  entries ← launched native name >>= maybe (fail (name ++ " was not launched")) pure
  recorded "revision" entries `shouldBe` Just revision
  recorded "digest" entries `shouldBe` snd (headerOf (outcomeOut outcome))
  pure entries

-- | The fingerprints the runner generated are gone again.
fingerprintsRemoved ∷ Native → IO ()
fingerprintsRemoved native =
  forM_ generatedFingerprints $ \relative →
    doesFileExist (nativeRoot native </> relative) >>= (`shouldBe` False)

-- ---------------------------------------------------------------------------
-- The examples

runnerIdentitySpec ∷ Spec
runnerIdentitySpec = describe "the runner's build identity (#585)" $ do
  provenanceSpec
  refusalSpec
  failedBuildSpec
  launcherSpec
  revisionSpec
  spellingSpec
  launchOrderSpec

provenanceSpec ∷ Spec
provenanceSpec = describe "the provenance a native run presents" $ do
  it "prints the revision and digest of the tree the executable was built from, and runs it with its arguments and its status, when nothing changed since the build" $
    withNative $ \native → do
      built native [] [suite]
      revision ← headRevision native
      outcome ← runNative native [] suite
      entries ← ranWith native outcome "vulkan-native-tests" revision
      recorded "args" entries `shouldBe` Just "--complete"
      -- The same lines the runner always printed.
      case headerOf (outcomeOut outcome) of
        (Just printed, Just digest) → do
          printed `shouldBe` revision
          length digest `shouldBe` 64
          all isHexDigit digest `shouldBe` True
        other → expectationFailure ("the header lines are missing: " ++ show other)
      gitStatus native >>= (`shouldBe` "")

  it "refuses an executable built from the clean tree after an input was edited and nothing was built again (row 2)" $
    withNative $ \native → do
      built native [] [suite]
      setSource native edited
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite, "source digest"]

  it "refuses an executable built from an edited tree after the source was restored and nothing was built again (row 3)" $
    withNative $ \native → do
      setSource native edited
      built native [] [suite]
      setSource native original
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite]

  it "runs an executable built from the edited tree, and says the tree was dirty, when the edit is still in place (row 4)" $
    withNative $ \native → do
      built native [] [suite]
      setSource native edited
      built native [] [suite]
      revision ← headRevision native
      outcome ← runNative native [] suite
      void $ ranWith native outcome "vulkan-native-tests" (revision ++ " (dirty)")

  it "records the same digest whether or not a stamp is already there, so the stamp is not one of the digest's inputs" $
    withNative $ \native → do
      built native [] [suite]
      first ← runNative native [] suite
      built native [] [suite]
      second ← runNative native [] suite
      snd (headerOf (outcomeOut first)) `shouldBe` snd (headerOf (outcomeOut second))
      snd (headerOf (outcomeOut first)) `shouldNotBe` Nothing

  it "leaves its stamps under a declared generated path of the validation catalog, and nothing the checkout shows" $
    withNative $ \native → do
      before ← filesOf (nativeRoot native)
      built native [] [suite, launcher]
      after ← filesOf (nativeRoot native)
      _ ← runNative native [] suite
      let added = [path | path ← after, path `notElem` before]
          stamps = [path | path ← added, ".stamp" `isSuffixOf` path]
      length stamps `shouldBe` 3
      catalog ← readFile "tools/validation/catalog.json"
      let generated = maybe [] id (parseJson catalog >>= field "generated_paths" >>= asArray >>= traverse asString)
      forM_ added $ \path →
        (path, any (`isPrefixOf` path) generated) `shouldBe` (path, True)
      gitStatus native >>= (`shouldBe` "")

  it "refuses a component that was never built with the diagnostic it always had" $
    withNative $ \native → do
      outcome ← runNative native [] suite
      outcomeStatus outcome `shouldBe` ExitFailure 2
      outcomeErr outcome `shouldContain` ("has not been built; prepare it with: bash tools/vulkan/run.sh build " ++ suite)
      nothingStarted native

refusalSpec ∷ Spec
refusalSpec = describe "a recorded identity that cannot be trusted" $ do
  let prepareCommand = "bash tools/vulkan/run.sh build " ++ suite
      refusing ∷ String → (FilePath → IO ()) → Spec
      refusing label change =
        it ("is refused when " ++ label) $
          withNative $ \native → do
            built native [] [suite]
            stamp ← stampOf native "dist-vulkan" "vulkan-native-tests"
            change stamp
            outcome ← runNative native [] suite
            refusedBeforeAnythingStarts native outcome [suite, prepareCommand]
  refusing "the stamp is missing" removeFile
  refusing "the stamp is empty" (`writeFile` "")
  refusing "the stamp is garbage" (`writeFile` "this is not a build identity\n")
  refusing "the stamp is truncated" (`rewrite` take 4)
  refusing "the stamp ends in the middle of a line" (\stamp → readStrict stamp >>= writeFile stamp . take 60)
  refusing "the stamp lost its end marker" (`rewrite` filter (/= "end"))
  refusing "the stamp has no digest" (`rewrite` filter (not . ("digest " `isPrefixOf`)))
  refusing "the stamp has an empty revision" (`rewrite` map (\line → if "revision " `isPrefixOf` line then "revision " else line))
  refusing "the stamp's digest is not a digest" (`rewrite` map (\line → if "digest " `isPrefixOf` line then "digest not-a-digest" else line))
  refusing "the stamp's revision is not a revision" (`rewrite` map (\line → if "revision " `isPrefixOf` line then "revision HEAD" else line))
  refusing "the stamp is in another format" (`rewrite` map (\line → if "hetoimasia-native-identity" `isPrefixOf` line then "hetoimasia-native-identity 2" else line))

  it "is refused when the executable was replaced by another build that left the old stamp in place" $
    withNative $ \native → do
      built native [] [suite]
      cabalBuild native [("FIXTURE_BUILD_TAG", "two")] "dist-vulkan" [suite]
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite, "replaced"]

  it "is refused when an executable was never stamped at all" $
    withNative $ \native → do
      cabalBuild native [] "dist-vulkan" [suite]
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "no recorded build identity"]

  it "is refused when the stamp was copied from another component" $
    withNative $ \native → do
      built native [] [suite, otherSuite]
      mine ← stampOf native "dist-vulkan" "vulkan-native-tests"
      theirs ← stampOf native "dist-vulkan" "lua-engine-graphics-native-tests"
      copyFile theirs mine
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite]
      -- The component the stamp was copied from is still good.
      other ← runNative native [] otherSuite
      outcomeStatus other `shouldBe` ExitFailure 7

  it "is refused when the stamp was copied from the build of the same component in the other build directory, and the reverse" $
    withNative $ \native → do
      built native [] [suite]
      built native [("HETOIMASIA_VMA_FOREIGN_CALLS", "safe")] [suite]
      unsafeStamp ← stampOf native "dist-vulkan" "vulkan-native-tests"
      safeStamp ← stampOf native "dist-vulkan-vma-safe" "vulkan-native-tests"
      unsafeText ← readStrict unsafeStamp
      safeText ← readStrict safeStamp
      writeFile safeStamp unsafeText
      refusedSafe ← runNative native [("HETOIMASIA_VMA_FOREIGN_CALLS", "safe")] suite
      refusedBeforeAnythingStarts native refusedSafe [suite, "HETOIMASIA_VMA_FOREIGN_CALLS=safe bash tools/vulkan/run.sh build " ++ suite]
      writeFile safeStamp safeText
      writeFile unsafeStamp safeText
      refusedUnsafe ← runNative native [] suite
      refusedBeforeAnythingStarts native refusedUnsafe [suite, prepareWithout]
      outcomeErr refusedUnsafe `shouldSatisfy` (not . ("HETOIMASIA_VMA_FOREIGN_CALLS" `isInfixOf`))
  where
    prepareWithout = "bash tools/vulkan/run.sh build " ++ suite

failedBuildSpec ∷ Spec
failedBuildSpec = describe "a build that does not complete" $ do
  it "certifies nothing when it fails after changing the executable, keeps the compile status, and still removes its fingerprints" $
    withNative $ \native → do
      built native [] [suite]
      setSource native edited
      failed ← build native [("FIXTURE_BUILD", "fail")] [suite]
      outcomeStatus failed `shouldBe` ExitFailure 1
      fingerprintsRemoved native
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite]

  it "leaves no stamp at all when the first build fails" $
    withNative $ \native → do
      failed ← build native [("FIXTURE_BUILD", "fail")] [suite]
      outcomeStatus failed `shouldBe` ExitFailure 1
      stampsOf native "dist-vulkan" >>= (`shouldBe` [])
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite]

  it "certifies nothing when it is signalled while compiling, and still removes its fingerprints" $
    withNative $ \native → do
      built native [] [suite]
      setSource native edited
      interruptedBuild native [suite]
      fingerprintsRemoved native
      outcome ← runNative native [] suite
      refusedBeforeAnythingStarts native outcome [suite, "bash tools/vulkan/run.sh build " ++ suite]

  it "certifies none of the components when a later one fails" $
    withNative $ \native → do
      built native [] [suite, launcher]
      setSource native edited
      failed ← build native [("FIXTURE_FAIL_ON", "run-native-tests")] [suite, launcher]
      outcomeStatus failed `shouldBe` ExitFailure 1
      forM_ [suite, launcher] $ \component → do
        outcome ← runNative native [] component
        refusedBeforeAnythingStarts native outcome [component]

  it "records nothing, and fails naming the component, when the source changes while it compiles" $
    withNative $ \native → do
      outcome ← build native [("FIXTURE_BUILD", "edits")] [suite]
      outcomeStatus outcome `shouldBe` ExitFailure 1
      outcomeErr outcome `shouldContain` suite
      outcomeErr outcome `shouldContain` "changed while it was being built"
      stampsOf native "dist-vulkan" >>= (`shouldBe` [])
      fingerprintsRemoved native

  it "fails naming the component when it compiled but its stamp cannot be recorded" $
    withNative $ \native → do
      -- The place the stamps go is occupied by a file.
      createDirectoryIfMissing True (nativeRoot native </> "dist-vulkan")
      writeFile (nativeRoot native </> stampDirectory "dist-vulkan") "in the way\n"
      outcome ← build native [] [suite]
      outcomeStatus outcome `shouldBe` ExitFailure 1
      outcomeErr outcome `shouldContain` ("cannot record the build identity of " ++ suite)
      fingerprintsRemoved native

  it "builds a target that is no single executable as it always did, without a stamp or a new failure" $
    withNative $ \native → do
      outcome ← build native [] ["hetoimasia-gpu-vulkan-native"]
      outcomeStatus outcome `shouldBe` ExitSuccess
      stampsOf native "dist-vulkan" >>= (`shouldBe` [])

-- | The runner's @build@ in a process group of its own, signalled as the
-- validation runner signals a stage at its expiry once the compile has begun,
-- and always ended and waited for.
interruptedBuild ∷ Native → [String] → IO ()
interruptedBuild native targets = do
  let root = nativeRoot native
  withFile (root </> "interrupted.log") WriteMode $ \logHandle → do
    (_, _, _, handle) ←
      createProcess
        (proc "bash" ((root </> runScript) : "build" : targets))
          { cwd = Just root
          , env = Just (withSettings native [("FIXTURE_BUILD", "block")])
          , create_group = True
          , std_out = UseHandle logHandle
          , std_err = UseHandle logHandle
          }
    pid ← getPid handle >>= maybe (fail "the runner has no process id") pure
    let signalGroup = do
          (delivered, _, errors) ← run [] root "bash" ["-c", "kill -TERM -- -\"$0\"", show pid]
          (delivered, errors) `shouldBe` (ExitSuccess, "")
        endGroup = run [] root "bash" ["-c", "kill -KILL -- -\"$0\" 2>/dev/null || true", show pid]
    ( do
        awaitFile (root </> "build-started")
        signalGroup
        finished ← timeout (60 * 1000 * 1000) (waitForProcess handle)
        when (finished == Nothing) $ expectationFailure "the signalled build did not end within a minute"
      )
      `finally` (void endGroup >> void (waitForProcess handle))

launcherSpec ∷ Spec
launcherSpec = describe "the launcher and the full-product command it starts" $ do
  it "stamps the full-product command when only the launcher is named, and runs the launcher with that command" $
    withNative $ \native → do
      built native [] [launcher]
      stamps ← stampsOf native "dist-vulkan"
      length stamps `shouldBe` 2
      revision ← headRevision native
      outcome ← runNative native [] launcher
      entries ← ranWith native outcome "run-native-tests" revision
      recorded "launch" entries `shouldBe` Just (nativeRoot native </> "dist-vulkan/bin/hetoimasia")
      outcomeOut outcome `shouldContain` ("vulkan: launched executable " ++ nativeRoot native </> "dist-vulkan/bin/hetoimasia")

  let refusing ∷ String → (Native → IO ()) → Spec
      refusing label change =
        it ("refuses the launcher when " ++ label) $
          withNative $ \native → do
            built native [] [launcher]
            change native
            outcome ← runNative native [] launcher
            refusedBeforeAnythingStarts native outcome [launcher, pairCommand]
      productStamp native = stampOf native "dist-vulkan" "hetoimasia"
  refusing "the command has no stamp" (\native → productStamp native >>= removeFile)
  refusing "the command's stamp is malformed" (\native → productStamp native >>= \stamp → rewrite stamp (take 3))
  refusing "the command's stamp was copied from the launcher" $ \native → do
    mine ← productStamp native
    theirs ← stampOf native "dist-vulkan" "run-native-tests"
    copyFile theirs mine
  refusing "the command was replaced after its stamp" $ \native →
    cabalBuild native [("FIXTURE_BUILD_TAG", "two")] "dist-vulkan" [product']
  refusing "the tree changed since both were built" (\native → setSource native edited)
  refusing "the launcher's own stamp is missing" (\native → stampOf native "dist-vulkan" "run-native-tests" >>= removeFile)

  it "refuses the launcher, with the existing diagnostic, when the command itself was never built" $
    withNative $ \native → do
      built native [] [launcher]
      removeFile (nativeRoot native </> "dist-vulkan/bin/hetoimasia")
      outcome ← runNative native [] launcher
      refusedBeforeAnythingStarts native outcome ["the full-product hetoimasia executable has not been built", pairCommand]

  it "refuses the launcher when the command carries the stamp of an older tree, though the launcher was built from this one" $
    withNative $ \native → do
      built native [] [launcher]
      older ← stampOf native "dist-vulkan" "hetoimasia" >>= readStrict
      setSource native edited
      built native [] [launcher]
      stampOf native "dist-vulkan" "hetoimasia" >>= \stamp → writeFile stamp older
      outcome ← runNative native [] launcher
      refusedBeforeAnythingStarts native outcome ["hetoimasia:exe:hetoimasia was built from source digest", pairCommand]

  it "refuses a suite and a command built at different revisions of the same tree, naming the build of both, and runs them once they agree" $
    withNative $ \native → do
      built native [] [launcher]
      first ← headRevision native
      -- A documentation-only commit moves HEAD and leaves the digest as it was; only the command is built again.
      commitNote native "changed\n"
      second ← headRevision native
      second `shouldNotBe` first
      built native [] [product']
      mixed ← runNative native [] launcher
      refusedBeforeAnythingStarts native mixed [launcher, first, second, pairCommand]
      built native [] [product', launcher]
      agreed ← runNative native [] launcher
      entries ← ranWith native agreed "run-native-tests" second
      -- The pair the suite is handed, which it copies into its record, is the one pair the header printed.
      recorded "digest" entries `shouldBe` snd (headerOf (outcomeOut agreed))

revisionSpec ∷ Spec
revisionSpec = describe "the revision a run presents" $ do
  it "refuses a caller-set revision that disagrees with the recorded one, and accepts one that agrees" $
    withNative $ \native → do
      built native [] [suite]
      revision ← headRevision native
      disagreeing ← runNative native [("HETOIMASIA_VULKAN_REVISION", "0000000000000000000000000000000000000000")] suite
      refusedBeforeAnythingStarts native disagreeing ["HETOIMASIA_VULKAN_REVISION", suite, "bash tools/vulkan/run.sh build " ++ suite]
      agreeing ← runNative native [("HETOIMASIA_VULKAN_REVISION", revision)] suite
      void $ ranWith native agreeing "vulkan-native-tests" revision

  it "runs, and prints the revision recorded by the build, when HEAD moved and the digest did not" $
    withNative $ \native → do
      built native [] [suite]
      before ← headRevision native
      commitNote native "changed\n"
      after ← headRevision native
      after `shouldNotBe` before
      outcome ← runNative native [] suite
      void $ ranWith native outcome "vulkan-native-tests" before

spellingSpec ∷ Spec
spellingSpec = describe "component spellings and variants" $ do
  it "runs a component through any spelling that resolves to the executable that was built" $
    withNative $ \native → do
      built native [] [launcher]
      revision ← headRevision native
      forM_ [launcher, "hetoimasia:run-native-tests", "run-native-tests"] $ \spelling → do
        outcome ← runNative native [] spelling
        void $ ranWith native outcome "run-native-tests" revision
      built native [] ["vulkan-native-tests"]
      outcome ← runNative native [] suite
      void $ ranWith native outcome "vulkan-native-tests" revision

  it "keeps the two variants independent: building one leaves the other's identity as it was, and each is run from its own build" $
    withNative $ \native → do
      let safe = [("HETOIMASIA_VMA_FOREIGN_CALLS", "safe")]
      built native [] [suite]
      stamp ← stampOf native "dist-vulkan" "vulkan-native-tests"
      stampBefore ← readStrict stamp
      -- The safe build is made from a tree that has since been edited, then restored.
      setSource native edited
      built native safe [suite]
      setSource native original
      readStrict stamp >>= (`shouldBe` stampBefore)
      defaultRun ← runNative native [] suite
      outcomeStatus defaultRun `shouldBe` ExitFailure 7
      clearLaunches native
      -- The safe variant's own identity is of the edited tree, so it is refused, and says how to prepare it.
      refusedSafe ← runNative native safe suite
      refusedBeforeAnythingStarts native refusedSafe [suite, "HETOIMASIA_VMA_FOREIGN_CALLS=safe bash tools/vulkan/run.sh build " ++ suite]
      built native safe [suite]
      safeRun ← runNative native safe suite
      outcomeStatus safeRun `shouldBe` ExitFailure 7
      readStrict stamp >>= (`shouldBe` stampBefore)

  it "names the default variant's preparing command without a variant, and the safe variant's with it" $
    withNative $ \native → do
      defaultRefusal ← runNative native [] launcher
      outcomeErr defaultRefusal `shouldContain` "has not been built"
      built native [] [launcher]
      setSource native edited
      refusedDefault ← runNative native [] launcher
      refusedBeforeAnythingStarts native refusedDefault [pairCommand]
      outcomeErr refusedDefault `shouldSatisfy` (not . ("HETOIMASIA_VMA_FOREIGN_CALLS" `isInfixOf`))
      built native [("HETOIMASIA_VMA_FOREIGN_CALLS", "safe")] [launcher]
      setSource native original
      refusedSafe ← runNative native [("HETOIMASIA_VMA_FOREIGN_CALLS", "safe")] launcher
      refusedBeforeAnythingStarts native refusedSafe ["HETOIMASIA_VMA_FOREIGN_CALLS=safe " ++ pairCommand]

launchOrderSpec ∷ Spec
launchOrderSpec = describe "what starts only after the identity is accepted" $ do
  let linux = [("FIXTURE_UNAME", "Linux")]
      macOS = [("FIXTURE_UNAME", "Darwin"), ("HETOIMASIA_NATIVE_SESSION", "desktop")]
  it "starts the isolated display for an accepted Linux run with no consent, and the executable inside it" $
    withNative $ \native → do
      built native linux [launcher]
      revision ← headRevision native
      outcome ← runNative native linux launcher
      entries ← ranWith native outcome "run-native-tests" revision
      recorded "display" entries `shouldBe` Just "started"
      recorded "session" entries `shouldBe` Just ""
      outcomeOut outcome `shouldContain` "vulkan: X11 evidence helper ready"

  it "starts no display on macOS, where the desktop opt-in is on the run's own command, and supplies no consent" $
    withNative $ \native → do
      built native macOS [launcher]
      revision ← headRevision native
      outcome ← runNative native macOS launcher
      entries ← ranWith native outcome "run-native-tests" revision
      recorded "display" entries `shouldBe` Just "none"
      recorded "session" entries `shouldBe` Just "desktop"
      withoutConsent ← runNative native [("FIXTURE_UNAME", "Darwin")] launcher
      withoutEntries ← ranWith native withoutConsent "run-native-tests" revision
      recorded "session" withoutEntries `shouldBe` Just ""
      recorded "display" withoutEntries `shouldBe` Just "none"

  forM_ [("Linux", linux), ("macOS", macOS)] $ \(label, settings) →
    it ("refuses a stale executable on " ++ label ++ " before any display or executable starts") $
      withNative $ \native → do
        built native settings [launcher, suite]
        setSource native edited
        forM_ [launcher, suite] $ \component → do
          outcome ← runNative native settings component
          refusedBeforeAnythingStarts native outcome [component, "bash tools/vulkan/run.sh build "]
