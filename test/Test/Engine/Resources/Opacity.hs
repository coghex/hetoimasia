-- | Examples proving that 'Hetoimasia.Foundation.Resource.Scoped',
-- 'Hetoimasia.Foundation.Resource.CleanupFailure', and the collection types of
-- "Hetoimasia.Foundation.Resource.Collection" are opaque to a client outside
-- the package.
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
-- Fifteen clients are compiled: three for the scope facade, five for retained
-- cleanup evidence, and seven for the resource collection. Twelve must be
-- rejected, and each is checked against the specific diagnostic that names the
-- rejection's cause, so a missing package, an absent compiler, or an unrelated
-- error can never be mistaken for the guarantee holding. Three must be
-- accepted, linked, and run, which is both the control proving the environment
-- is sound and the evidence that closing each representation left the
-- supported readers, runners, and allocators usable.
--
-- The boundaries are closed for the same reason but protect different claims.
-- A rewritten scope would resume a continuation; a rewritten evidence entry
-- would put two payloads behind one 'CleanupFailureId', and inspection expands
-- a repeated identity's carried context only the first time it is seen, so the
-- evidence reachable only through the replacement would be lost. A forged or
-- recast collection token, or a member's release reached from outside, would
-- let a client release a member the collection still owns, or borrow a value
-- at a type it was never acquired at.
--
-- These are Hspec examples rather than a probe: the work is running a process
-- and asserting on its output, which this suite already does elsewhere.
--
-- The compilation harness is exported so the runtime component's own opacity
-- examples compile their clients the same way, against a wider package set.
module Test.Engine.Resources.Opacity
  ( spec

    -- * Compiling external clients
  , Client (..)
  , Mode (..)
  , withPackageClient
  , rejectedBecause
  ) where

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
spec = do
  scopedSpec
  cleanupEvidenceSpec
  collectionSpec

scopedSpec ∷ Spec
scopedSpec = describe "Scoped opacity across the package boundary" $ do
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

cleanupEvidenceSpec ∷ Spec
cleanupEvidenceSpec =
  describe "Cleanup evidence opacity across the package boundary" $ do
    it "rejects a client that replaces an entry's identity with record update" $
      withReplacementClient
        "cleanupFailureId"
        "CleanupFailureId"
        ["import Hetoimasia.Foundation.Resource (CleanupFailureId)"]

    it "rejects a client that replaces an entry's label with record update" $
      withReplacementClient
        "cleanupFailureLabel"
        "Text"
        ["import Data.Text (Text)"]

    it "rejects a client that replaces an entry's exception with record update" $
      withReplacementClient
        "cleanupFailureException"
        "ExceptionWithContext SomeException"
        ["import Control.Exception (ExceptionWithContext, SomeException)"]

    it "rejects a client that names the entry constructor" $
      withClient "Client.hs" evidenceConstructorClient $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "does not export any children"
        clientOutput outcome `shouldContain` "CleanupFailure"

    it "accepts and runs a client using only the readers and reattachment" $
      withClient "Main.hs" evidenceClient $ \compile → do
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
          `shouldBe` [ "retained = inner buried outer"
                     , "in context = inner buried outer"
                     , "identities distinct = True"
                     , "display = cleanup failed in inner: user error (inner released)"
                     , "carried by outer = buried"
                     , "reattached = inner buried outer"
                     , "outer alone = buried outer"
                     ]

collectionSpec ∷ Spec
collectionSpec =
  describe "Collection opacity across the package boundary" $ do
    it "rejects a client that names the collection constructor" $
      withClient "Client.hs" (collectionConstructorClient "Collection (Collection)" "Collection") $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "does not export any children"
        clientOutput outcome `shouldContain` "Collection"

    it "rejects a client that names the member token constructor" $
      withClient "Client.hs" (collectionConstructorClient "Member (Member)" "Member") $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "does not export any children"
        clientOutput outcome `shouldContain` "Member"

    it "rejects a client that rewrites a collection with record update" $
      withClient "Client.hs" collectionUpdateClient $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "Not in scope: record field"
        clientOutput outcome `shouldContain` "liveMemberCount"

    it "rejects a client that rewrites a member token with record update" $
      withClient "Client.hs" memberUpdateClient $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "Not in scope: record field"
        clientOutput outcome `shouldContain` "memberStatus"

    it "rejects a client that coerces a member token to another type with the same representation" $
      withClient "Client.hs" memberCoercionClient $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "Couldn't match type"
        clientOutput outcome `shouldContain` "coerce"

    it "rejects a client that reaches for a member's release through the implementation module" $
      withClient "Client.hs" releaseExtractionClient $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure
              ("the client compiled, so a member's release is reachable:\n" <> clientOutput outcome)
        -- The one environment-looking diagnostic this case expects: the
        -- module is found in the built package and refused as hidden.
        clientOutput outcome `shouldContain` "hidden module"
        clientOutput outcome `shouldContain` "hetoimasia-foundation"
        clientOutput outcome `shouldNotContain` "cannot satisfy"

    it "accepts and runs a client using only the public collection operations" $
      withClient "Main.hs" collectionClient $ \compile → do
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
          `shouldBe` [ "acquire left"
                     , "acquire middle"
                     , "acquire right"
                     , "borrow left+right"
                     , "in use = RetirementInUse"
                     , "release middle"
                     , "retired = Retired"
                     , "again = AlreadyRetired"
                     , "live = 2"
                     , "release right"
                     , "release left"
                     , "middle after exit = retired"
                     , "left after exit = retired"
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
-- The foundation's clients see exactly @base@, @text@, and
-- @hetoimasia-foundation@.
withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "text", "hetoimasia-foundation"]

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
                  (proc ghc (arguments packages mode packageDatabase name)) { cwd = Just directory }
                  ""
              pure (Client status (out <> err) directory)
          (status, _, err) →
            expectationFailure ("ghc could not be interrogated (" <> show status <> "): " <> err)

-- | The compiler arguments an external client is built with.
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
    <> concatMap (\package → ["-package", package]) packages
    <> ["-fdiagnostics-color=never"]
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

-- | Compile one field-replacement client and require the compiler to reject it
-- because the replacement is inaccessible, naming the reader that was reached
-- for so the three cases cannot pass for each other's reasons.
withReplacementClient ∷ String → String → [String] → IO ()
withReplacementClient reader replacementType extraImports =
  withClient "Client.hs" (replacementClient reader replacementType extraImports) $ \compile → do
    outcome ← compile Typecheck
    rejectedBecause outcome "Not in scope: record field"
    clientOutput outcome `shouldContain` reader

-- | The client from the issue, one field at a time: it replaces part of a
-- retained entry through record-update syntax, which needs only the field
-- label in scope.
--
-- Each of the three reader names is tried on its own, so a rejection names the
-- field that was reached for rather than leaving the other two untested. The
-- reader is imported by name in every case, which is what makes the rejection
-- mean what the example claims: an unimported label is out of scope whether or
-- not it is a field, so a client that did not import it would be rejected on
-- the unrepaired library too.
--
-- The entry itself comes in as an argument, because a client can obtain one
-- only from inspection; what is under test is the rewrite, not the
-- acquisition.
replacementClient ∷ String → String → [String] → String
replacementClient reader replacementType extraImports =
  unlines $
    [ "module Client (rewritten) where"
    , ""
    ]
      <> extraImports
      <> [ "import Hetoimasia.Foundation.Resource (CleanupFailure, " <> reader <> ")"
         , ""
         , "rewritten ∷ CleanupFailure → " <> replacementType <> " → CleanupFailure"
         , "rewritten entry replacement = entry { " <> reader <> " = replacement }"
         ]

-- | The other half of the same reach: building an entry of the client's own by
-- naming the constructor.
--
-- This one is rejected on master as well, since the type has always been
-- exported without its children. It is kept as the guard proving that the
-- field-label route the three cases above close was the only one open.
evidenceConstructorClient ∷ String
evidenceConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Control.Exception (ExceptionWithContext, SomeException)"
    , "import Data.Text (Text)"
    , "import Hetoimasia.Foundation.Resource"
    , "  ( CleanupFailure (CleanupFailure)"
    , "  , CleanupFailureId"
    , "  )"
    , ""
    , "forged ∷ CleanupFailureId → Text → ExceptionWithContext SomeException → CleanupFailure"
    , "forged = CleanupFailure"
    ]

-- | A client using only what the evidence boundary offers: the three readers,
-- both inspection entry points, the renderer, and reattachment of an unchanged
-- entry through @base@'s annotation API.
--
-- The scope it drives fails in three places at once. The body throws; the
-- inner release throws; and the outer release throws from inside a scope of
-- its own whose release also threw, so the outer entry carries evidence that
-- is reachable only by expanding that entry's own retained context. The client
-- reports observation order, the carried context, and what reattaching entries
-- that are already present does, which is the case the identity-to-payload
-- invariant exists to permit.
evidenceClient ∷ String
evidenceClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Exception"
    , "  ( ErrorCall (ErrorCall)"
    , "  , ExceptionWithContext (ExceptionWithContext)"
    , "  , SomeException"
    , "  , someExceptionContext"
    , "  , throwIO"
    , "  , try"
    , "  )"
    , "import Control.Exception.Context (addExceptionAnnotation, emptyExceptionContext)"
    , "import Data.Text (pack, unpack)"
    , "import Hetoimasia.Foundation.Resource"
    , "  ( CleanupFailure"
    , "  , cleanupFailureException"
    , "  , cleanupFailureId"
    , "  , cleanupFailureLabel"
    , "  , cleanupFailures"
    , "  , cleanupFailuresInContext"
    , "  , displayCleanupFailure"
    , "  , withResourceLabelled"
    , "  )"
    , "import System.Exit (exitFailure)"
    , "import System.IO (hPutStrLn, stderr)"
    , ""
    , "labelsOf ∷ [CleanupFailure] → String"
    , "labelsOf = unwords . map (unpack . cleanupFailureLabel)"
    , ""
    , "-- The outer release fails from inside a scope of its own, so its"
    , "-- exception carries evidence reachable only through that entry."
    , "nestedRelease ∷ IO ()"
    , "nestedRelease ="
    , "  withResourceLabelled (pack \"buried\") (pure ()) (\\_ → throwIO (userError \"buried released\")) $ \\_ →"
    , "    throwIO (userError \"outer released\")"
    , ""
    , "failingScope ∷ IO ()"
    , "failingScope ="
    , "  withResourceLabelled (pack \"outer\") (pure ()) (\\_ → nestedRelease) $ \\_ →"
    , "    withResourceLabelled (pack \"inner\") (pure ()) (\\_ → throwIO (userError \"inner released\")) $ \\_ →"
    , "      throwIO (ErrorCall \"body failed\")"
    , ""
    , "expectFailure ∷ IO () → IO SomeException"
    , "expectFailure action = do"
    , "  outcome ← try action"
    , "  case outcome of"
    , "    Left propagated → pure propagated"
    , "    Right () → do"
    , "      hPutStrLn stderr \"expected the scope to fail, but it returned\""
    , "      exitFailure"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  propagated ← expectFailure failingScope"
    , "  let retained = cleanupFailures propagated"
    , "  putStrLn (\"retained = \" <> labelsOf retained)"
    , "  putStrLn"
    , "    ( \"in context = \""
    , "        <> labelsOf (cleanupFailuresInContext (someExceptionContext propagated))"
    , "    )"
    , "  case retained of"
    , "    [inner, buried, outer] → do"
    , "      putStrLn"
    , "        ( \"identities distinct = \""
    , "            <> show"
    , "              ( cleanupFailureId inner /= cleanupFailureId buried"
    , "                  && cleanupFailureId buried /= cleanupFailureId outer"
    , "              )"
    , "        )"
    , "      putStrLn (\"display = \" <> displayCleanupFailure inner)"
    , "      case cleanupFailureException outer of"
    , "        ExceptionWithContext carried _ →"
    , "          putStrLn (\"carried by outer = \" <> labelsOf (cleanupFailuresInContext carried))"
    , "      -- Reattaching entries that are already present is supported, and"
    , "      -- inspection still reports each of them exactly once."
    , "      let reattached ="
    , "            foldr addExceptionAnnotation emptyExceptionContext (retained <> retained)"
    , "      putStrLn (\"reattached = \" <> labelsOf (cleanupFailuresInContext reattached))"
    , "      let alone = addExceptionAnnotation outer emptyExceptionContext"
    , "      putStrLn (\"outer alone = \" <> labelsOf (cleanupFailuresInContext alone))"
    , "    _ → do"
    , "      hPutStrLn stderr (\"unexpected evidence: \" <> labelsOf retained)"
    , "      exitFailure"
    ]

-- | A client that imports one collection type together with its constructor.
collectionConstructorClient ∷ String → String → String
collectionConstructorClient imported typeName =
  unlines
    [ "module Client (named) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Collection (" <> imported <> ")"
    , ""
    , "named ∷ Maybe " <> typeName <> (if typeName == "Member" then " ()" else "")
    , "named = Nothing"
    ]

-- | A client that imports the collection's reader by name and tries to replace
-- it through record-update syntax.
collectionUpdateClient ∷ String
collectionUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Collection (Collection, liveMemberCount)"
    , ""
    , "rewritten ∷ Collection → Collection"
    , "rewritten collection = collection { liveMemberCount = pure 0 }"
    ]

-- | A client that imports a token's reader by name and tries to replace it
-- through record-update syntax.
memberUpdateClient ∷ String
memberUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Collection (Member, MemberStatus (MemberLive), memberStatus)"
    , ""
    , "rewritten ∷ Member () → Member ()"
    , "rewritten member = member { memberStatus = pure MemberLive }"
    ]

-- | A client that recasts a token through 'Data.Coerce.coerce' between two
-- types sharing a representation. Without a nominal role this would compile,
-- because coercing under a type constructor needs no constructor in scope.
memberCoercionClient ∷ String
memberCoercionClient =
  unlines
    [ "module Client (recast) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.Foundation.Resource.Collection (Member)"
    , ""
    , "newtype Celsius = Celsius Double"
    , ""
    , "recast ∷ Member Celsius → Member Double"
    , "recast = coerce"
    ]

-- | A client that reaches for the ledger release primitive a member's release
-- is stored with. The public module exports no release, so the only route to
-- one is the implementation module, which the package hides.
releaseExtractionClient ∷ String
releaseExtractionClient =
  unlines
    [ "module Client (release) where"
    , ""
    , "import Hetoimasia.Foundation.Resource.Internal (Ledger, releaseAcquired)"
    , ""
    , "release ∷ Ledger → IO ()"
    , "release ledger = () <$ releaseAcquired ledger"
    ]

-- | A client using only the public collection operations. It reports its
-- acquisitions, a nested borrow, the retirement outcomes, and each release in
-- order, then the terminal state of tokens it retained past the scope.
collectionClient ∷ String
collectionClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Data.Text (Text, pack, unpack)"
    , "import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, withScoped)"
    , "import Hetoimasia.Foundation.Resource.Collection"
    , "  ( Member"
    , "  , MemberStatus (..)"
    , "  , acquireMember"
    , "  , allocCollection"
    , "  , liveMemberCount"
    , "  , memberStatus"
    , "  , retireMember"
    , "  , withMember"
    , "  )"
    , ""
    , "member ∷ String → Assembly Text"
    , "member name ="
    , "  acquirePart"
    , "    (pack name)"
    , "    (releaseRank 0)"
    , "    (putStrLn (\"acquire \" <> name) >> pure (pack name))"
    , "    (\\held → putStrLn (\"release \" <> unpack held))"
    , ""
    , "describeStatus ∷ MemberStatus → String"
    , "describeStatus status = case status of"
    , "  MemberLive → \"live\""
    , "  MemberRetired → \"retired\""
    , "  MemberRetirementFailed _ → \"failed\""
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  (middle, left) ← withScoped (allocCollection 3) $ \\collection → do"
    , "    left ← acquireMember collection (member \"left\")"
    , "    middle ← acquireMember collection (member \"middle\")"
    , "    right ← acquireMember collection (member \"right\")"
    , "    joined ← withMember collection left $ \\l →"
    , "      withMember collection right $ \\r → pure (unpack l <> \"+\" <> unpack r)"
    , "    putStrLn (\"borrow \" <> joined)"
    , "    inUse ← withMember collection middle (\\_ → retireMember collection middle)"
    , "    putStrLn (\"in use = \" <> show inUse)"
    , "    retired ← retireMember collection middle"
    , "    putStrLn (\"retired = \" <> show retired)"
    , "    again ← retireMember collection middle"
    , "    putStrLn (\"again = \" <> show again)"
    , "    live ← liveMemberCount collection"
    , "    putStrLn (\"live = \" <> show live)"
    , "    pure (middle, left ∷ Member Text)"
    , "  middleStatus ← memberStatus middle"
    , "  putStrLn (\"middle after exit = \" <> describeStatus middleStatus)"
    , "  leftStatus ← memberStatus left"
    , "  putStrLn (\"left after exit = \" <> describeStatus leftStatus)"
    ]
