-- | The external-client compiler harness.
--
-- An example inside a test suite shares that suite's module environment, and a
-- suite built inside a package may reach that package's private libraries, so
-- neither can observe what a package boundary exposes to its clients. These
-- helpers compile a separate single-module client with the same compiler
-- against the package database this build already produced, exposing only the
-- packages an example names and hiding everything else. What such a client can
-- say is exactly what each package's @exposed-modules@ and export lists allow.
--
-- A rejection is checked against the diagnostic that names its cause through
-- 'rejectedBecause', so a missing package, an absent compiler, or an unrelated
-- error is never mistaken for a boundary holding.
module Test.Support.ExternalClient
  ( Client (..)
  , Mode (..)
  , withPackageClient
  , rejectedBecause
  ) where

import Control.Monad (filterM)
import Data.List (isInfixOf)
import Data.Version (showVersion)
import System.Directory (doesDirectoryExist, findExecutable)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hPutStr, withFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Info (fullCompilerVersion)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (expectationFailure, shouldContain, shouldNotContain)

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
-- failed because a package could not be found would be reported as the
-- representation holding.
--
-- Prefer GHC's own diagnostic code, such as @GHC-10237@ for an import naming a
-- child the module does not export, over a phrase from the rendered message.
-- The code identifies the same error across compiler releases; the prose does
-- not. GHC 9.14 rewrote that message from "does not export any children" to
-- "does not export any constructors called ...", which would have been read as
-- a boundary failure rather than as the rewording it was.
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
-- build's own package database exposing only the named packages, and hand the
-- outcome to the example.
--
-- The compiler is the one on @PATH@, required to be the version this suite was
-- itself built with, because a client compiled by a different compiler would
-- not answer the question the example asks. @-package-env -@ suppresses any
-- ambient package environment file, and @-hide-all-packages@ leaves the client
-- with exactly the packages named.
withPackageClient ∷ [String] → FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withPackageClient packages name source use = do
  compiler ← findExecutable "ghc"
  database ← findPackageDatabase
  case (compiler, database) of
    (Nothing, _) →
      expectationFailure "no ghc on PATH, so the package boundary cannot be exercised"
    (_, Nothing) →
      expectationFailure
        ( "no package database for ghc-"
            <> showVersion fullCompilerVersion
            <> " above this test executable, so the built local packages cannot be exposed"
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
                  (proc ghc (arguments packages mode packageDatabase name)) { cwd = Just directory }
                  ""
              pure (Client status (out <> err) directory)
          (status, _, err) →
            expectationFailure ("ghc could not be interrogated (" <> show status <> "): " <> err)

-- | The compiler arguments an external client is built with.
--
-- A name containing @-inplace@ is a local unit id, the main library's or a
-- sublibrary's, and is exposed with
-- @-package-id@. A package with public or private sublibraries registers every
-- one of them under the same package name, so @-package@ alone matches several
-- units and GHC's choice among them is not stable; naming the main library's
-- unit id exposes exactly that library.
arguments ∷ [String] → Mode → FilePath → FilePath → [String]
arguments packages mode packageDatabase name =
  [ "-XGHC2024"
  , "-XUnicodeSyntax"
  , "-package-env"
  , "-"
  , "-package-db"
  , packageDatabase
  , "-hide-all-packages"
  ]
    <> concatMap exposing packages
    <> ["-fdiagnostics-color=never"]
    <> case mode of
      Typecheck → ["-fno-code", name]
      Link → [name, "-o", "client"]
  where
    exposing package
      | "-inplace" `isInfixOf` package = ["-package-id", package]
      | otherwise = ["-package", package]

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
