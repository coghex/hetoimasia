-- | Examples proving that 'Hetoimasia.Foundation.Resource.Scoped' is opaque to
-- a client outside the package.
--
-- The other resource examples import the foundation directly, so they share
-- this test suite's own module environment and cannot observe what the package
-- boundary exposes. These examples therefore compile separate single-module
-- clients with the same compiler against the package database this build
-- already produced, exposing @base@, @text@, and @hetoimasia-foundation@ and
-- hiding everything else. What such a client can say is exactly what the
-- library's @exposed-modules@ and each module's export list allow, which is the
-- boundary the opacity claim is about.
--
-- Three clients are compiled. Two must be rejected, and each is checked against
-- the specific diagnostic that names the rejection's cause, so a missing
-- package, an absent compiler, or an unrelated error can never be mistaken for
-- the guarantee holding. One must be accepted, linked, and run, which is both
-- the control proving the environment is sound and the evidence that closing
-- the representation left the runner and the allocators usable.
--
-- These are Hspec examples rather than a probe: the work is running a process
-- and asserting on its output, which this suite already does elsewhere.
module Test.Engine.Resources.Opacity (spec) where

import Control.Monad (filterM)
import Data.Version (showVersion)
import System.Directory (doesDirectoryExist, findExecutable)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hPutStr, withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Info (fullCompilerVersion)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldNotContain
  , shouldContain
  )

spec ∷ Spec
spec = describe "Scoped opacity across the package boundary" $ do
  it "rejects a client that replaces the continuation with record update" $
    withClient "Client.hs" recordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "withScoped"

  it "rejects a client that names the constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Scoped"

  it "accepts and runs a client using only the runner and the allocators" $
    withClient "Main.hs" runnerClient $ \compile → do
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
          (proc (clientDirectory outcome </> "client") []) { cwd = Just (clientDirectory outcome) }
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "held = outer staged left right"
                   , "acquire outer"
                   , "acquire staged"
                   , "release staged"
                   , "acquire left"
                   , "acquire right"
                   , "body"
                   , "release right"
                   , "release left"
                   , "release outer"
                   ]

-- | A compiled client: how the compiler exited, everything it said, and the
-- directory the client was compiled in.
data Client = Client
  { clientStatus ∷ ExitCode
  , clientOutput ∷ String
  , clientDirectory ∷ FilePath
  }

-- | Whether the client is only typechecked or also linked into an executable.
data Mode = Typecheck | Link

-- | Assert that the compiler rejected the client, and that it rejected it for
-- the stated reason rather than for a reason about the environment.
--
-- The second half is what keeps this example honest: without it, a client that
-- failed because the foundation package could not be found would be reported as
-- the representation holding.
rejectedBecause ∷ Client → String → IO ()
rejectedBecause outcome reason = do
  case clientStatus outcome of
    ExitFailure _ → pure ()
    ExitSuccess →
      expectationFailure
        ("the client compiled, so the representation is reachable from outside the package:\n" <> said)
  mapM_ (shouldNotContain said) environmentFailures
  said `shouldContain` reason
  where
    said = clientOutput outcome
    environmentFailures =
      [ "Could not find module"
      , "cannot satisfy"
      , "Could not load module"
      , "is a member of the hidden package"
      ]

-- | Write one client into a temporary directory, compile it against this
-- build's own package database, and hand the outcome to the example.
--
-- The compiler is the one on @PATH@, required to be the version this suite was
-- itself built with, because a client compiled by a different compiler would
-- not answer the question the example asks. @-package-env -@ suppresses any
-- ambient package environment file, and @-hide-all-packages@ leaves the client
-- with exactly the three packages named here.
withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient name source use = do
  compiler ← findExecutable "ghc"
  database ← findPackageDatabase
  case (compiler, database) of
    (Nothing, _) →
      expectationFailure "no ghc on PATH, so the package boundary cannot be exercised"
    (_, Nothing) →
      expectationFailure
        ( "no package database for ghc-"
            <> showVersion fullCompilerVersion
            <> " above this test executable, so the built foundation package cannot be exposed"
        )
    (Just ghc, Just packageDatabase) →
      withSystemTempDirectory "hetoimasia-opacity" $ \directory → do
        withFile (directory </> name) WriteMode (`hPutStr` source)
        expected ← readCreateProcessWithExitCode (proc ghc ["--numeric-version"]) ""
        case expected of
          (ExitSuccess, reported, _)
            | filter (/= '\n') reported /= showVersion fullCompilerVersion →
                expectationFailure
                  ( "ghc on PATH reports "
                      <> filter (/= '\n') reported
                      <> " but this suite was built with "
                      <> showVersion fullCompilerVersion
                  )
          (ExitSuccess, _, _) →
            use $ \mode → do
              (status, out, err) ←
                readCreateProcessWithExitCode
                  (proc ghc (arguments mode packageDatabase name)) { cwd = Just directory }
                  ""
              pure (Client status (out <> err) directory)
          (status, _, err) →
            expectationFailure ("ghc could not be interrogated (" <> show status <> "): " <> err)

-- | The compiler arguments an external client is built with.
arguments ∷ Mode → FilePath → FilePath → [String]
arguments mode packageDatabase name =
  [ "-XGHC2024"
  , "-XUnicodeSyntax"
  , "-package-env"
  , "-"
  , "-package-db"
  , packageDatabase
  , "-hide-all-packages"
  , "-package"
  , "base"
  , "-package"
  , "text"
  , "-package"
  , "hetoimasia-foundation"
  , "-fdiagnostics-color=never"
  ]
    <> case mode of
      Typecheck → ["-fno-code", name]
      Link → [name, "-o", "client"]

-- | The package database this build wrote its local libraries into.
--
-- It is found by walking up from this test executable, which Cabal placed
-- inside the same build directory, so a build directory chosen with
-- @--builddir@ is found as readily as the default one.
findPackageDatabase ∷ IO (Maybe FilePath)
findPackageDatabase = do
  binary ← getExecutablePath
  let ancestors =
        takeWhile (\directory → directory /= takeDirectory directory)
          (iterate takeDirectory (takeDirectory binary))
      candidates =
        [ directory </> "packagedb" </> ("ghc-" <> showVersion fullCompilerVersion)
        | directory ← ancestors
        ]
  found ← filterM doesDirectoryExist candidates
  pure (case found of [] → Nothing; first : _ → Just first)

-- | The client from the issue: it replaces a scope's continuation through
-- record-update syntax, which needs only the field label in scope.
recordUpdateClient ∷ String
recordUpdateClient =
  unlines
    [ "module Client (rewritten, doubled) where"
    , ""
    , "import Data.IORef (modifyIORef', newIORef, readIORef)"
    , "import Hetoimasia.Foundation.Resource (Scoped, withScoped)"
    , ""
    , "rewritten ∷ Scoped ()"
    , "rewritten = (pure () ∷ Scoped ()) { withScoped = \\k → k () >> k () }"
    , ""
    , "doubled ∷ IO Int"
    , "doubled = do"
    , "  n ← newIORef (0 ∷ Int)"
    , "  withScoped rewritten (\\_ → modifyIORef' n (+ 1))"
    , "  readIORef n"
    ]

-- | The other half of the same reach: building a scope from a continuation of
-- the client's own by naming the constructor.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Foundation.Resource (Scoped (Scoped))"
    , ""
    , "forged ∷ Scoped ()"
    , "forged = Scoped (\\k → k () >> k ())"
    ]

-- | A client using only what the facade offers: the runner, both allocators,
-- 'Hetoimasia.Foundation.Resource.locally', @pure@, @liftIO@, and the
-- instances. It reports what it acquired and the order everything was released
-- in, so the example checks lifetimes and not merely that it built.
runnerClient ∷ String
runnerClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Monad.IO.Class (liftIO)"
    , "import Data.IORef (IORef, modifyIORef', newIORef, readIORef)"
    , "import Data.Text (pack)"
    , "import Hetoimasia.Foundation.Resource"
    , "  ( Assembly"
    , "  , Scoped"
    , "  , acquirePart"
    , "  , allocComposite"
    , "  , allocResource"
    , "  , locally"
    , "  , releaseRank"
    , "  , withScoped"
    , "  )"
    , ""
    , "note ∷ IORef [String] → String → IO ()"
    , "note trail message = modifyIORef' trail (message :)"
    , ""
    , "tracked ∷ IORef [String] → String → Scoped String"
    , "tracked trail name ="
    , "  allocResource"
    , "    (note trail (\"acquire \" <> name) >> pure name)"
    , "    (\\held → note trail (\"release \" <> held))"
    , ""
    , "part ∷ IORef [String] → String → Int → Assembly String"
    , "part trail name rank ="
    , "  acquirePart"
    , "    (pack name)"
    , "    (releaseRank rank)"
    , "    (note trail (\"acquire \" <> name) >> pure name)"
    , "    (\\held → note trail (\"release \" <> held))"
    , ""
    , "pair ∷ IORef [String] → Assembly (String, String)"
    , "pair trail = (,) <$> part trail \"left\" 1 <*> part trail \"right\" 0"
    , ""
    , "scope ∷ IORef [String] → Scoped String"
    , "scope trail = do"
    , "  first ← tracked trail \"outer\""
    , "  inner ← locally (tracked trail \"staged\")"
    , "  (left, right) ← allocComposite (pair trail)"
    , "  liftIO (note trail \"body\")"
    , "  pure (unwords [first, inner, left, right])"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  trail ← newIORef []"
    , "  held ← withScoped (scope trail) pure"
    , "  entries ← reverse <$> readIORef trail"
    , "  putStrLn (\"held = \" <> held)"
    , "  mapM_ putStrLn entries"
    ]
