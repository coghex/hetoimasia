-- | Examples proving that the GLFW package keeps its native handles, its
-- session and window representations, and its observation publisher out of
-- reach of a client outside the package.
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
-- read endpoint it is given. One client must be accepted, linked, and run: it
-- uses only the public session and window interfaces, including the read-only
-- observation endpoint, and every path it takes is refused before GLFW is
-- initialized, so the example opens no display.
--
-- The test seam is a public component so this suite can depend on it. Two more
-- clients are compiled against it and must be rejected: one names the window
-- drivers through the public seam, which does not export them, and one reaches
-- for them in the seam's implementation, which belongs to the private
-- @seam-core@ sublibrary. Only the package's own @glfw-window-examples@
-- executable can use them.
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

  it "accepts and runs a client using only the public session and window interfaces, without initializing GLFW" $
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
-- process main thread: neither reaches GLFW.
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
    , "import Hetoimasia.GLFW.Session"
    , "import Hetoimasia.GLFW.Window"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  wayland ← try (withSession defaultSessionConfig {requestedBackend = Just Wayland} (\\_ → pure ()))"
    , "  report \"wayland\" wayland"
    , "  unthreaded ← try (withSession defaultSessionConfig (\\session → withWindow session (hiddenTestWindowConfig (Text.pack \"tool\") 64 48) latest >> pure ()))"
    , "  report \"without the threaded runtime\" unthreaded"
    , "  putStrLn (\"capacity = \" <> show errorEvidenceCapacity <> \", description limit = \" <> show errorDescriptionLimit)"
    , "  putStrLn (\"zero width = \" <> either show (const \"accepted\") (validateWindowConfig (hiddenTestWindowConfig (Text.pack \"tool\") 0 48)))"
    , ""
    , "latest ∷ Window → IO (Attribute Extent)"
    , "latest window = observedFramebufferExtent . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))"
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
