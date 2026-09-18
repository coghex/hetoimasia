-- | What this package's boundary exposes, asked from outside it.
--
-- An example inside the suite shares the suite's module environment and can
-- reach the package's private bridge sublibrary, so it cannot answer this
-- question about itself. These examples compile separate single-module clients
-- against the package database this build produced, exposing @base@,
-- @bytestring@, @text@, @hetoimasia-foundation@, and this package's main
-- library and nothing else. What such a client can say is exactly what the
-- public module's export list allows.
--
-- Six clients must be rejected: one names the VM's constructor; one names the
-- chunk name's; one asks the public module for the Lua state, a stack index, or
-- a registry reference; one asks it to install a Haskell callback, which is
-- LUA-3's surface and not this slice's; one asks it to open every standard
-- library at once, which no call offers; and one reaches into the private
-- bridge sublibrary for the state and the trampoline directly.
--
-- One client must be accepted, linked, and run. It uses the whole public
-- contract -- construct over a chosen library set, run a chunk, call a global,
-- read a fault's bounded diagnostic, and close -- and its output is the
-- evidence that the public surface is sufficient as well as narrow.
module Test.Lua.Opacity (spec) where

import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient
  ( Client (clientDirectory, clientOutput, clientStatus)
  , Mode (Link, Typecheck)
  , rejectedBecause
  , withStorePackageClient
  )

-- The main library is named by its local unit id: its sublibraries share its
-- package name. The dependency store is exposed as well, because the private
-- bridge sublibrary this library is built on depends on the binding, and a
-- client that cannot resolve that unit would be rejected for a reason about the
-- environment rather than about the boundary.
withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withStorePackageClient
    [ "base"
    , "bytestring"
    , "text"
    , "hetoimasia-foundation"
    , "hetoimasia-scripting-lua-0.1.0.0-inplace"
    ]

spec ∷ Spec
spec = describe "opacity across the package boundary" $ do
  it "rejects a client that names the VM's constructor" $
    withClient "Client.hs" vmConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Vm"

  it "rejects a client that names the chunk name's constructor" $
    withClient "Client.hs" chunkConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "ChunkName"

  it "rejects a client asking the public module for a state, an index, or a reference" $
    withClient "Client.hs" nativeSurfaceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"

  it "rejects a client asking the public module to install a Haskell callback" $
    withClient "Client.hs" registrationClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"

  it "rejects a client asking for every standard library at once" $
    withClient "Client.hs" openAllClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"

  it "rejects a client reaching into the private bridge for the state and the trampoline" $
    withClient "Client.hs" internalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the Lua state is reachable:\n" <> clientOutput outcome)
      -- The modules are found in the built package and refused as belonging to
      -- its private sublibrary, not missing from the environment.
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Vm"
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Callback"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-scripting-lua"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts, links, and runs a client using the whole public contract" $
    withClient "Main.hs" publicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the public client must compile, but the compiler exited with "
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
        `shouldBe` [ "no libraries = ran"
                   , "defined global = called"
                   , "fault kind = CallFailed"
                   , "fault value = ErrorMessage \"raise:1: boom\" False"
                   , "closed = ()"
                   ]

vmConstructorClient ∷ String
vmConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (Vm (Vm))"
    , ""
    , "forged ∷ Maybe Vm"
    , "forged = Nothing"
    ]

chunkConstructorClient ∷ String
chunkConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (ChunkName (ChunkName))"
    , ""
    , "forged ∷ Maybe ChunkName"
    , "forged = Nothing"
    ]

nativeSurfaceClient ∷ String
nativeSurfaceClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (vmState, stackDepth, withTemporaryReference)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

registrationClient ∷ String
registrationClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (installCallback)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

openAllClient ∷ String
openAllClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (openLibraries, newVmWithAllLibraries)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

internalsClient ∷ String
internalsClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Internal.Vm (vmState)"
    , "import Hetoimasia.Scripting.Lua.Internal.Callback (installCallback)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | The whole public contract, used the way a later slice would use it.
publicClient ∷ String
publicClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Exception (try)"
    , "import Hetoimasia.Scripting.Lua.Bridge"
    , "  ( FaultKind"
    , "  , Library (LibraryBase)"
    , "  , LuaFault (faultKind, faultValue)"
    , "  , callGlobal"
    , "  , chunkName"
    , "  , closeVm"
    , "  , evalChunk"
    , "  , newVm"
    , "  )"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  bare ← newVm []"
    , "  evalChunk bare (chunkName \"bare\") \"local ignored = 1\""
    , "  putStrLn \"no libraries = ran\""
    , "  closeVm bare"
    , "  vm ← newVm [LibraryBase]"
    , "  evalChunk vm (chunkName \"define\") \"function defined() end\""
    , "  callGlobal vm \"defined\""
    , "  putStrLn \"defined global = called\""
    , "  raised ← try (evalChunk vm (chunkName \"raise\") \"error('boom')\")"
    , "  case raised ∷ Either LuaFault () of"
    , "    Right () → putStrLn \"fault kind = none\""
    , "    Left fault → do"
    , "      putStrLn (\"fault kind = \" <> show (faultKind fault ∷ FaultKind))"
    , "      putStrLn (\"fault value = \" <> show (faultValue fault))"
    , "  closeVm vm"
    , "  putStrLn \"closed = ()\""
    ]
