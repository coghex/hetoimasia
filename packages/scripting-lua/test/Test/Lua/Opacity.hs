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
--
-- The VM owner (LUA-2) has clients of its own. Four must be rejected: one names
-- the owned VM's constructor; one asks the owner's module for the Lua state or a
-- native handle, for a way to close the VM, or for the callback registration that
-- is LUA-3's; one hands an owned VM to the bridge's own operations, to run Lua on
-- it or to close it behind the owner's back, which the types refuse because an
-- owned VM is not the bridge's @Vm@; and one reaches into the private owner
-- module. One must be accepted, linked and run: it uses the owner's whole public
-- contract, including a reference that outlives its lifetime and one used from
-- another thread, and its output shows each refused at run time, with 'VmClosed'
-- and 'VmNotOwned', rather than used.
--
-- The registration and value boundary (LUA-3) has clients of its own. Five must
-- be rejected: one forges a module handle from its constructor or reads its slot;
-- one forges a capability with an issuer of its choosing; one asks the
-- registration's public module for the closure a binding runs, so as to run it
-- without the boundary; one asks any public module for the Lua state, a stack
-- index, a registry reference, a coroutine or a native address by name; and one
-- reaches into the private binding module. One must be accepted, linked and run:
-- it builds a registration and an owner's policy from the public modules alone,
-- loads a module, calls an entry point with bounded arguments and results, and
-- observes a typed refusal, both of its own arguments and of a script's call to a
-- binding.
module Test.Lua.Opacity (spec) where

import Control.Exception (finally)
import System.Directory (getPermissions, setPermissions, writable)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  )
import Test.Support.ExternalClient
  ( Client (clientDirectory, clientOutput, clientStatus)
  , Mode (Link, Typecheck)
  , rejectedBecause
  , storeDatabases
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

  it "rejects a client that names the owned VM's constructor" $
    withClient "Client.hs" ownedConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "OwnedVm"

  it "rejects a client asking the owner for a state, a native handle, a close or a callback registration" $
    withClient "Client.hs" ownerSurfaceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "ownedInternalVm"
      clientOutput outcome `shouldContain` "closeOwned"
      clientOutput outcome `shouldContain` "installCallback"

  it "rejects a client using the bridge's operations on an owned VM, to run Lua on it or close it" $
    withClient "Client.hs" bridgeBypassClient $ \compile → do
      outcome ← compile Typecheck
      -- An owned VM is not the bridge's `Vm`: the type error names the two.
      rejectedBecause outcome "GHC-83865"
      clientOutput outcome `shouldContain` "OwnedVm"
      clientOutput outcome `shouldContain` "Vm"

  it "rejects a client reaching into the private owner module" $
    withClient "Client.hs" privateOwnerClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the owner's internals are reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Owner"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts, links and runs a client using the whole public owner contract, a stale and a foreign reference refused" $
    withClient "Main.hs" ownerPublicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the owner client must compile, but the compiler exited with "
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
        `shouldBe` [ "initial chunk = ran"
                   , "body = called"
                   , "fault kind = CallFailed"
                   , "failed initialization = CallFailed"
                   , "after the lifetime = VmClosed {closedOperation = \"eval-chunk\"}"
                   , "another thread = VmNotOwned {notOwnedOperation = \"eval-chunk\"}"
                   , "after another thread = still ran"
                   ]

  it "rejects a client that forges a module handle or reads the slot it names" $
    withClient "Client.hs" moduleHandleClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "ModuleHandle"

  it "rejects a client that forges an export or capture handle, or reads the slot one names" $ do
    withClient "Client.hs" exportHandleClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "ExportHandle"
    withClient "Client.hs" captureHandleClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "CaptureHandle"

  it "rejects a client asking the public module for a retained table, a registry reference or a stack index of an export" $
    withClient "Client.hs" exportSurfaceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"

  it "rejects a client reaching into the private export module" $
    withClient "Client.hs" exportInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the export internals are reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Export"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client asking the public module for the loader, its handler or its host" $
    withClient "Client.hs" loaderSurfaceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"

  it "rejects a client reaching into the private loader module" $
    withClient "Client.hs" loaderInternalsClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the loader internals are reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Loader"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client that forges a capability, or stamps one with the VM that issued it" $
    withClient "Client.hs" capabilityForgeryClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Capability"

  it "rejects a client asking the registration for the closure a binding runs" $
    withClient "Client.hs" bindingActionClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "bindingAction"

  it "rejects a client asking any public module for a Lua state, stack index, registry reference, coroutine or address" $
    withClient "Client.hs" luaSurfaceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "State"
      clientOutput outcome `shouldContain` "StackIndex"
      clientOutput outcome `shouldContain` "luaReference"
      clientOutput outcome `shouldContain` "Coroutine"
      clientOutput outcome `shouldContain` "Ptr"

  it "rejects a client that updates a registration, a namespace or a binding through its labels, skipping validation" $
    mapM_
      ( \(client, label) →
          withClient "Client.hs" (updateClient client) $ \compile → do
            outcome ← compile Typecheck
            rejectedBecause outcome "Not in scope: record field"
            clientOutput outcome `shouldContain` label
      )
      [ ("a = emptyRegistration {registrationNamespaces = [namespace \"math\" []]}", "registrationNamespaces")
      , ("a = (snapshotQuery \"x\" [] [] (\\_ → pure [])) {bindingKind = LifecycleOperation}", "bindingKind")
      , ("a = (namespace \"n\" []) {namespaceBindings = []}", "namespaceBindings")
      ]

  it "rejects a client that builds a value-limit configuration without the checked constructor" $
    withClient "Client.hs" limitsUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "ValueLimits"

  it "rejects a client that updates a value-limit configuration through its labels" $
    withClient "Client.hs" limitsLabelClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "limitBytes"

  it "rejects a client reaching into the private binding module" $
    withClient "Client.hs" privateBindingClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure
            ("the client compiled, so the binding's internals are reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "Hetoimasia.Scripting.Lua.Internal.Binding"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts, links and runs a client building a registration and policy, loading a module, calling an entry point and observing a typed refusal" $
    withClient "Main.hs" boundaryPublicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the boundary client must compile, but the compiler exited with "
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
        `shouldBe` [ "namespaces = [\"app\"]"
                   , "confined exposure = []"
                   , "call = Returned [VInteger 42,VText \"ok\"]"
                   , "state = 21"
                   , "optional entry = EntryAbsent"
                   , "argument refusal = RuleFloatForInteger"
                   , "argument effect = NoEffect"
                   , "script refusal binding = Just (\"app\",\"double\")"
                   , "script refusal rule = RuleFloatForInteger"
                   , "script refusal effect = LuaRan"
                   , "unsupported = NotYetSupported LifecycleOperation"
                   , "handle after the lifetime = VmClosed"
                   ]

  it "accepts, links and runs a client composing injected sources and the owner's loader, through the public owner alone" $
    withClient "Main.hs" loaderPublicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the loader client must compile, but the compiler exited with "
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
        `shouldBe` [ "admitted = RootQueued"
                   , "blocked = BlockedSource (ExportIdentity \"game:dep\")"
                   , "chain = 1"
                   , "another thread = VmNotOwned"
                   , "delivered = SourceDelivered"
                   , "settled = [ExportIdentity \"game:dep\",ExportIdentity \"game:root\"]"
                   , "root = ready"
                   , "interests = (2,2)"
                   , "unknown root = ModuleUnknown"
                   , "stopped = StopReport {stopIdentities = [], stopFrames = 0, stopWithdrawn = 0, stopWasStopped = False}"
                   , "stopped again = True"
                   , "late delivery = SourceAfterStop"
                   ]

  it "accepts, links and runs a client evaluating export modules, capturing a behavior and releasing it, through the public owner alone" $
    withClient "Main.hs" exportPublicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the export client must compile, but the compiler exited with "
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
        `shouldBe` [ "evaluated = kept"
                   , "again = same table"
                   , "retrieved = same table"
                   , "unknown = Nothing"
                   , "failed = ExportShapeRefused (ExportNotTable \"number\")"
                   , "failed again = same failure"
                   , "shape = BehaviorShape {shapeInit = True, shapeUpdate = True, shapeShutdown = False, shapeEveryTicks = FieldInteger 3, shapeEverySeconds = FieldAbsent}"
                   , "missing role = BehaviorMissing"
                   , "refused behavior = BehaviorUnknownKey \"extra\""
                   , "released twice = ok"
                   , "export after the lifetime = VmClosed"
                   , "capture after the lifetime = VmClosed"
                   ]

  it "accepts, links and runs a client opting a binding in to recoverable refusals through the public modules alone" $
    withClient "Main.hs" recoverablePublicClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the recoverable-refusal client must compile, but the compiler exited with "
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
        `shouldBe` [ "caught = app.double: argument 1: a float where an integer is declared"
                   , "next call = 42"
                   , "actions run = 1"
                   , "closed = app.tick: engine closed"
                   , "open again = ticked"
                   , "uncaught = ErrorMessage \"app.double: argument 1: a float where an integer is declared\" False"
                   , "generic binding = refused by the fault it always was"
                   ]

  it "finds the dependency store without reading a project it cannot write to" $
    withSystemTempDirectory "hetoimasia-readonly" $ \directory → do
      -- A checkout shaped like this one that the run may not write to: an
      -- extraction a reviewer reads, or a build sent elsewhere with
      -- `--builddir`. Asking Cabal a question that makes it resolve this
      -- project would make it try to create a build directory here and fail,
      -- and the answer would silently become "no store" -- which rejects every
      -- client above for a reason about the environment rather than about the
      -- boundary.
      writeFile (directory </> "cabal.project") "packages: .\n"
      permissions ← getPermissions directory
      found ←
        (setPermissions directory permissions {writable = False} >> storeDatabases directory)
          `finally` setPermissions directory permissions
      found `shouldNotBe` []

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
                   , "opaque value = ErrorOpaque \"boolean\""
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
    , "  opaque ← try (evalChunk vm (chunkName \"opaque\") \"error(true)\")"
    , "  case opaque ∷ Either LuaFault () of"
    , "    Right () → putStrLn \"opaque value = none\""
    , "    -- A native address would be reachable through this value if the"
    , "    -- bridge put one in it. It names the Lua type and nothing else."
    , "    Left fault → putStrLn (\"opaque value = \" <> show (faultValue fault))"
    , "  closeVm vm"
    , "  putStrLn \"closed = ()\""
    ]

ownedConstructorClient ∷ String
ownedConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (OwnedVm (OwnedVm))"
    , ""
    , "forged ∷ Maybe OwnedVm"
    , "forged = Nothing"
    ]

ownerSurfaceClient ∷ String
ownerSurfaceClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (ownedInternalVm, closeOwned, installCallback)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | A body that is handed an owned VM and gives it to the bridge's operations.
bridgeBypassClient ∷ String
bridgeBypassClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Client (bypass) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Bridge (chunkName, closeVm, evalChunk)"
    , "import Hetoimasia.Scripting.Lua.Owner (vmConfig, withVmOwner)"
    , ""
    , "bypass ∷ IO ()"
    , "bypass = withVmOwner (vmConfig []) $ \\owned → do"
    , "  evalChunk owned (chunkName \"bypass\") \"x = 1\""
    , "  closeVm owned"
    ]

privateOwnerClient ∷ String
privateOwnerClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm, OwnerConfig (ownerAllowlist))"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | The owner's whole public contract, used the way a later slice would use it.
ownerPublicClient ∷ String
ownerPublicClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Concurrent (forkIO)"
    , "import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)"
    , "import Control.Exception (try)"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , "  ( FaultKind"
    , "  , Library (LibraryBase)"
    , "  , LuaFault (faultKind)"
    , "  , VmClosed"
    , "  , VmNotOwned"
    , "  , VmConfig (vmInitialChunks)"
    , "  , callOwned"
    , "  , chunkName"
    , "  , evalOwned"
    , "  , vmConfig"
    , "  , withVmOwner"
    , "  )"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  escaped ← withVmOwner"
    , "    (vmConfig [LibraryBase]) {vmInitialChunks = [(chunkName \"init\", \"function defined() end\")]}"
    , "    $ \\owned → do"
    , "      putStrLn \"initial chunk = ran\""
    , "      callOwned owned \"defined\""
    , "      putStrLn \"body = called\""
    , "      raised ← try (evalOwned owned (chunkName \"raise\") \"error('boom')\")"
    , "      case raised ∷ Either LuaFault () of"
    , "        Right () → putStrLn \"fault kind = none\""
    , "        Left fault → putStrLn (\"fault kind = \" <> show (faultKind fault ∷ FaultKind))"
    , "      -- Another thread's use is refused while the VM is open, and the owner"
    , "      -- goes on using it afterwards."
    , "      refused ← newEmptyMVar"
    , "      _ ← forkIO (try (evalOwned owned (chunkName \"foreign\") \"touched = true\") >>= putMVar refused)"
    , "      elsewhere ← takeMVar refused"
    , "      pure (owned, elsewhere)"
    , "  let (owned, elsewhere) = escaped"
    , "  failedInit ← try (withVmOwner (vmConfig [LibraryBase]) {vmInitialChunks = [(chunkName \"bad\", \"error('init')\")]} (\\_ → pure ()))"
    , "  case failedInit ∷ Either LuaFault () of"
    , "    Right () → putStrLn \"failed initialization = none\""
    , "    Left fault → putStrLn (\"failed initialization = \" <> show (faultKind fault ∷ FaultKind))"
    , "  late ← try (evalOwned owned (chunkName \"late\") \"late = true\")"
    , "  case late ∷ Either VmClosed () of"
    , "    Right () → putStrLn \"after the lifetime = ran\""
    , "    Left refusal → putStrLn (\"after the lifetime = \" <> show refusal)"
    , "  case elsewhere ∷ Either VmNotOwned () of"
    , "    Right () → putStrLn \"another thread = ran\""
    , "    Left refusal → putStrLn (\"another thread = \" <> show refusal)"
    , "  putStrLn \"after another thread = still ran\""
    ]

-- | An application that opts a binding in to recoverable refusals and gives another
-- a precondition reading the engine's own state, from the public modules alone: the
-- private bridge's handlers, escapes and markers are not needed.
recoverablePublicClient ∷ String
recoverablePublicClient =
  unlines
    [ "{-# LANGUAGE LambdaCase #-}"
    , "{-# LANGUAGE ScopedTypeVariables #-}"
    , "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Exception (try)"
    , "import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)"
    , "import Data.Text (Text)"
    , "import qualified Data.Text as Text"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , "  ( BoundaryFault"
    , "  , Library (LibraryBase)"
    , "  , LuaFault (faultValue)"
    , "  , VmConfig (vmOwnerName, vmPolicy, vmRegistration)"
    , "  , chunkName"
    , "  , evalOwned"
    , "  , vmConfig"
    , "  , withVmOwner"
    , "  )"
    , "import Hetoimasia.Scripting.Lua.Registration"
    , "  ( namespace"
    , "  , recoverableRefusals"
    , "  , registration"
    , "  , snapshotQuery"
    , "  , stateOperation"
    , "  , withPrecondition"
    , "  )"
    , "import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SText), Value (VInteger, VText))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  ran <- newIORef (0 ∷ Int)"
    , "  -- What stands for the engine's own state: only the application writes it."
    , "  engineOpen <- newIORef True"
    , "  let say = stateOperation \"say\" [SText] [] (\\case [VText text] → putStrLn (Text.unpack text) >> pure []; _ → pure [])"
    , "      double = snapshotQuery \"double\" [SInteger] [SInteger] $ \\case"
    , "        [VInteger n] → modifyIORef' ran (+ 1) >> pure [VInteger (2 * n)]"
    , "        _ → pure []"
    , "      tick = stateOperation \"tick\" [] [] (\\_ → putStrLn \"open again = ticked\" >> pure [])"
    , "      closedUnlessOpen _ = (\\open → if open then Nothing else Just (\"engine closed\" ∷ Text)) <$> readIORef engineOpen"
    , "      generic = snapshotQuery \"generic\" [SInteger] [SInteger] (\\_ → pure [])"
    , "  registered ← either (fail . show) pure . registration [] $"
    , "    [namespace \"app\" [say, recoverableRefusals double, withPrecondition closedUnlessOpen tick, generic]]"
    , "  let config = (vmConfig [LibraryBase]) {vmRegistration = registered, vmPolicy = [\"app\"], vmOwnerName = \"client\"}"
    , "  withVmOwner config $ \\owned → do"
    , "    let run name = evalOwned owned (chunkName name)"
    , "    run \"caught\""
    , "      \"local ok, err = pcall(app.double, 1.5); assert(ok == false); app.say('caught = ' .. err)\""
    , "    run \"next\" \"app.say('next call = ' .. app.double(21))\""
    , "    readIORef ran >>= \\held → putStrLn (\"actions run = \" <> show held)"
    , "    writeIORef engineOpen False"
    , "    run \"closed\" \"local ok, err = pcall(app.tick); assert(ok == false); app.say('closed = ' .. err)\""
    , "    writeIORef engineOpen True"
    , "    run \"open\" \"app.tick()\""
    , "    uncaught ← try (run \"uncaught\" \"app.double(1.5)\")"
    , "    case uncaught of"
    , "      Left fault → putStrLn (\"uncaught = \" <> show (faultValue fault))"
    , "      Right () → putStrLn \"uncaught = none\""
    , "    -- A binding that is not opted in keeps the fault a script cannot hide."
    , "    generic' ← try (run \"generic\" \"pcall(app.generic, 1.5)\")"
    , "    case generic' of"
    , "      Left (_ ∷ BoundaryFault) → putStrLn \"generic binding = refused by the fault it always was\""
    , "      Right () → putStrLn \"generic binding = hidden\""
    ]

moduleHandleClient ∷ String
moduleHandleClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (ModuleHandle (ModuleHandle, handleSlot))"
    , ""
    , "forged ∷ Maybe ModuleHandle"
    , "forged = Nothing"
    ]

exportHandleClient ∷ String
exportHandleClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (ExportHandle (ExportHandle, exportHandleSlot))"
    , ""
    , "forged ∷ Maybe ExportHandle"
    , "forged = Nothing"
    ]

captureHandleClient ∷ String
captureHandleClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (CaptureHandle (CaptureHandle, captureHandleSlot))"
    , ""
    , "forged ∷ Maybe CaptureHandle"
    , "forged = Nothing"
    ]

exportSurfaceClient ∷ String
exportSurfaceClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (exportTable, exportReference, captureSelf, liveExportReferences, liveCaptureReferences, callBehavior)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

exportInternalsClient ∷ String
exportInternalsClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Internal.Export (liveExportReferences, liveCaptureReferences)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | The export interface, used the way an application would.
exportPublicClient ∷ String
exportPublicClient =
  unlines
    [ "{-# LANGUAGE LambdaCase #-}"
    , "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Exception (try)"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , "  ( BehaviorProblem (BehaviorMissing, BehaviorUnknownKey)"
    , "  , Captured (capturedHandle, capturedShape)"
    , "  , ExportIdentity (ExportIdentity)"
    , "  , ExportOutcome (ExportFailed, ExportReady)"
    , "  , FacadeSource (FacadeValue)"
    , "  , ExportSource (ExportSource)"
    , "  , Library (LibraryBase)"
    , "  , VmClosed"
    , "  , VmConfig (vmExports)"
    , "  , boundaryReason"
    , "  , captureBehavior"
    , "  , evaluateExport"
    , "  , releaseBehavior"
    , "  , retrieveExport"
    , "  , vmConfig"
    , "  , withVmOwner"
    , "  )"
    , "import Hetoimasia.Scripting.Lua.Value (Value (VRecord, VText))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let initial = ExportSource (ExportIdentity \"main\") \"main\" \"return { gameplay = { init = function() end, update = function() end, every_ticks = 3 }, presentation = { extra = 1 } }\""
    , "  escaped ← withVmOwner ((vmConfig [LibraryBase]) {vmExports = [initial]}) $ \\owned → do"
    , "    first ← evaluateExport owned initial"
    , "    export ← case first of"
    , "      ExportReady handle → putStrLn \"evaluated = kept\" >> pure handle"
    , "      ExportFailed fault → fail (show fault)"
    , "    again ← evaluateExport owned (ExportSource (ExportIdentity \"main\") \"main\" \"error('never run')\")"
    , "    putStrLn (\"again = \" <> (if again == first then \"same table\" else \"different\"))"
    , "    retrieved ← retrieveExport owned (ExportIdentity \"main\")"
    , "    putStrLn (\"retrieved = \" <> (if retrieved == Just first then \"same table\" else \"different\"))"
    , "    retrieveExport owned (ExportIdentity \"other\") >>= \\unknown → putStrLn (\"unknown = \" <> show (fmap (const ()) unknown))"
    , "    broken ← evaluateExport owned (ExportSource (ExportIdentity \"broken\") \"broken\" \"return 5\")"
    , "    failure ← case broken of"
    , "      ExportFailed fault → putStrLn (\"failed = \" <> show (boundaryReason fault)) >> pure broken"
    , "      ExportReady _ → fail \"a number is no export table\""
    , "    evaluateExport owned (ExportSource (ExportIdentity \"broken\") \"broken\" \"return {}\")"
    , "      >>= \\retry → putStrLn (\"failed again = \" <> (if retry == failure then \"same failure\" else \"different\"))"
    , "    capture ← captureBehavior owned export \"gameplay\" (FacadeValue (VRecord [(\"name\", VText \"facade\")])) >>= \\case"
    , "      Right found → putStrLn (\"shape = \" <> show (capturedShape found)) >> pure found"
    , "      Left problem → fail (show problem)"
    , "    captureBehavior owned export \"absent\" (FacadeValue (VRecord [])) >>= \\case"
    , "      Left BehaviorMissing → putStrLn \"missing role = BehaviorMissing\""
    , "      other → fail (show (fmap capturedShape other))"
    , "    captureBehavior owned export \"presentation\" (FacadeValue (VRecord [])) >>= \\case"
    , "      Left problem@(BehaviorUnknownKey _) → putStrLn (\"refused behavior = \" <> show problem)"
    , "      other → fail (show (fmap capturedShape other))"
    , "    releaseBehavior owned (capturedHandle capture)"
    , "    releaseBehavior owned (capturedHandle capture)"
    , "    putStrLn \"released twice = ok\""
    , "    pure (owned, export, capture)"
    , "  let (owned, export, capture) = escaped"
    , "  try (evaluateExport owned initial) >>= \\case"
    , "    Left closed → putStrLn (\"export after the lifetime = \" <> (const \"VmClosed\" (closed ∷ VmClosed)))"
    , "    Right _ → putStrLn \"export after the lifetime = used\""
    , "  try (captureBehavior owned export \"gameplay\" (FacadeValue (VRecord []))) >>= \\case"
    , "    Left closed → putStrLn (\"capture after the lifetime = \" <> (const \"VmClosed\" (closed ∷ VmClosed)))"
    , "    Right _ → putStrLn \"capture after the lifetime = used\""
    , "  _ ← pure capture"
    , "  pure ()"
    ]

loaderSurfaceClient ∷ String
loaderSurfaceClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (Loader, loaderHost, importHandler, installLoader, newLoader)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

loaderInternalsClient ∷ String
loaderInternalsClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Internal.Loader (newLoader, loaderHost)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | The module loader, used the way an application would: a supplier that holds a source
-- until another thread finds it, a resolver, and the owner's thread delivering and advancing.
loaderPublicClient ∷ String
loaderPublicClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Concurrent (forkIO)"
    , "import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)"
    , "import Control.Exception (try)"
    , "import Data.Text.Encoding (encodeUtf8)"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let known = [(ExportIdentity \"game:root\", SourceVerified \"local dep = import('dep') return { dep = dep }\")]"
    , "      supplier = SourceSupplier"
    , "        { supplierAcquire = \\identity → pure (maybe SourcePending id (lookup identity known))"
    , "        , supplierRelease = \\_ → pure ()"
    , "        }"
    , "      resolver _ path _ = pure (Right (ResolvedAddress (ExportIdentity (\"game:\" <> encodeUtf8 path)) (\"game:\" <> path)))"
    , "  withVmOwner ((vmConfig [LibraryBase]) {vmLoader = Just (loaderConfig supplier resolver)}) $ \\owned → do"
    , "    admitted ← admitRoot owned (RootRequest (ExportIdentity \"game:root\") \"game:root\")"
    , "    putStrLn (\"admitted = \" <> show admitted)"
    , "    held ← advanceLoader owned"
    , "    putStrLn (\"blocked = \" <> show (advanceBlocked held))"
    , "    putStrLn (\"chain = \" <> show (advanceChainDepth held))"
    , "    -- The provider's thread finds the source and tells the owner. It may not touch the"
    , "    -- loader itself."
    , "    found ← newEmptyMVar"
    , "    refused ← newEmptyMVar"
    , "    _ ← forkIO $ do"
    , "      outcome ← try (advanceLoader owned)"
    , "      putMVar refused (either (\\(VmNotOwned _) → \"VmNotOwned\") (const \"ran\") outcome)"
    , "      putMVar found (SourceVerified \"return { name = 'dep' }\")"
    , "    answer ← takeMVar found"
    , "    takeMVar refused >>= \\how → putStrLn (\"another thread = \" <> how)"
    , "    delivered ← deliverSource owned (ExportIdentity \"game:dep\") answer"
    , "    putStrLn (\"delivered = \" <> show delivered)"
    , "    done ← advanceLoader owned"
    , "    putStrLn (\"settled = \" <> show (map fst (advanceSettled done)))"
    , "    status ← lookupModule owned (ExportIdentity \"game:root\")"
    , "    putStrLn (\"root = \" <> (case status of ModuleReady _ → \"ready\"; other → show other))"
    , "    counts ← moduleLoaderCounts owned"
    , "    putStrLn (\"interests = \" <> show (countInterestsAcquired counts, countInterestsReleased counts))"
    , "    lookupModule owned (ExportIdentity \"game:nobody\") >>= \\unknown → putStrLn (\"unknown root = \" <> show unknown)"
    , "    stopModuleLoader owned >>= \\report → putStrLn (\"stopped = \" <> show report)"
    , "    stopModuleLoader owned >>= \\report → putStrLn (\"stopped again = \" <> show (stopWasStopped report))"
    , "    deliverSource owned (ExportIdentity \"game:dep\") answer >>= \\late → putStrLn (\"late delivery = \" <> show late)"
    ]

capabilityForgeryClient ∷ String
capabilityForgeryClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Value (Capability (Capability, capabilityIssuer), VmIdentity)"
    , ""
    , "forged ∷ Maybe Capability"
    , "forged = Nothing"
    ]

bindingActionClient ∷ String
bindingActionClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Registration (Binding, bindingAction, Action (ValuesAction))"
    , ""
    , "reached ∷ Maybe Binding"
    , "reached = Nothing"
    ]

luaSurfaceClient ∷ String
luaSurfaceClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Owner (State, StackIndex, luaReference, Coroutine)"
    , "import Hetoimasia.Scripting.Lua.Value (Ptr)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | A client whose only binding is this update of a registration, a namespace or
-- a binding.
updateClient ∷ String → String
updateClient definition =
  unlines
    [ "module Client (a) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Registration"
    , "  ( BindingKind (LifecycleOperation), bindingKind, emptyRegistration, namespace"
    , "  , namespaceBindings, registrationNamespaces, snapshotQuery )"
    , ""
    , definition
    ]

limitsUpdateClient ∷ String
limitsUpdateClient =
  unlines
    [ "module Client (bad) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Value (ValueLimits (ValueLimits))"
    , ""
    , "bad ∷ ValueLimits"
    , "bad = ValueLimits (-1) 8 (-1)"
    ]

limitsLabelClient ∷ String
limitsLabelClient =
  unlines
    [ "module Client (bad) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Value (ValueLimits, defaultValueLimits, limitBytes)"
    , ""
    , "bad ∷ ValueLimits"
    , "bad = defaultValueLimits {limitBytes = -1}"
    ]

privateBindingClient ∷ String
privateBindingClient =
  unlines
    [ "module Client (reached) where"
    , ""
    , "import Hetoimasia.Scripting.Lua.Internal.Binding (valueHandler)"
    , "import Hetoimasia.Scripting.Lua.Internal.Marshal (readValues)"
    , ""
    , "reached ∷ ()"
    , "reached = ()"
    ]

-- | The value boundary's whole public contract, used the way an application would.
boundaryPublicClient ∷ String
boundaryPublicClient =
  unlines
    [ "{-# LANGUAGE LambdaCase #-}"
    , "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Exception (try)"
    , "import Data.IORef (modifyIORef', newIORef, readIORef)"
    , "import Data.Int (Int64)"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , "  ( BoundaryFault (boundaryBinding, boundaryEffect, boundaryReason)"
    , "  , CallResult"
    , "  , EntryPoint (EntryPoint)"
    , "  , FaultReason (NotYetSupported, ValueRefused)"
    , "  , Library (LibraryBase)"
    , "  , ModuleRef (ModuleRef)"
    , "  , ModuleSource (ModuleSource)"
    , "  , Requirement (Optional, Required)"
    , "  , VmClosed"
    , "  , VmConfig (vmModules, vmOwnerName, vmPolicy, vmRegistration)"
    , "  , callEntry"
    , "  , chunkName"
    , "  , evalOwned"
    , "  , loadedModule"
    , "  , vmConfig"
    , "  , withVmOwner"
    , "  )"
    , "import Hetoimasia.Scripting.Lua.Registration"
    , "  ( confinedEligibleBindings"
    , "  , lifecycleOperation"
    , "  , namespace"
    , "  , namespaceName"
    , "  , registration"
    , "  , registrationNamespaces"
    , "  , snapshotQuery"
    , "  , stateOperation"
    , "  )"
    , "import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SText), Value (VInteger, VFloat, VText), ValueRefusal (refusalRule))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  total ← newIORef (0 ∷ Int64)"
    , "  let built = registration []"
    , "        [ namespace \"app\""
    , "            [ snapshotQuery \"double\" [SInteger] [SInteger] (\\case [VInteger n] → pure [VInteger (2 * n)]; _ → pure [])"
    , "            , stateOperation \"add\" [SInteger] [] (\\case [VInteger n] → modifyIORef' total (+ n) >> pure []; _ → pure [])"
    , "            , lifecycleOperation \"stop\" [] [] (\\_ → pure [])"
    , "            ]"
    , "        ]"
    , "  registered ← either (fail . show) pure built"
    , "  putStrLn (\"namespaces = \" <> show (map namespaceName (registrationNamespaces registered)))"
    , "  putStrLn (\"confined exposure = \" <> show (confinedEligibleBindings registered))"
    , "  let source ="
    , "        ModuleSource"
    , "          (ModuleRef \"client\" \"1\")"
    , "          \"function run(n) app.add(n); return app.double(n), 'ok' end\\nfunction bad() return app.double(1.5) end\\nfunction halt() app.stop() end\""
    , "          [ EntryPoint \"run\" Required [SInteger] [SInteger, SText]"
    , "          , EntryPoint \"bad\" Required [] [SInteger]"
    , "          , EntryPoint \"halt\" Required [] []"
    , "          , EntryPoint \"tick\" Optional [SInteger] []"
    , "          ]"
    , "      config = (vmConfig [LibraryBase]) {vmRegistration = registered, vmPolicy = [\"app\"], vmOwnerName = \"client\", vmModules = [source]}"
    , "  escaped ← withVmOwner config $ \\owned → do"
    , "    handle ← loadedModule owned (ModuleRef \"client\" \"1\") >>= maybe (fail \"the initial module has no handle\") pure"
    , "    called ← callEntry owned handle \"run\" [VInteger 21]"
    , "    putStrLn (\"call = \" <> show (called ∷ CallResult))"
    , "    readIORef total >>= \\held → putStrLn (\"state = \" <> show held)"
    , "    callEntry owned handle \"tick\" [VInteger 1] >>= \\absent → putStrLn (\"optional entry = \" <> show absent)"
    , "    refused ← try (callEntry owned handle \"run\" [VFloat 1.5])"
    , "    case refused of"
    , "      Left fault → do"
    , "        putStrLn (\"argument refusal = \" <> show (ruleOf (boundaryReason fault)))"
    , "        putStrLn (\"argument effect = \" <> show (boundaryEffect fault))"
    , "      Right other → putStrLn (\"argument refusal = none \" <> show (other ∷ CallResult))"
    , "    scripted ← try (callEntry owned handle \"bad\" [])"
    , "    case scripted of"
    , "      Left fault → do"
    , "        putStrLn (\"script refusal binding = \" <> show (boundaryBinding fault))"
    , "        putStrLn (\"script refusal rule = \" <> show (ruleOf (boundaryReason fault)))"
    , "        putStrLn (\"script refusal effect = \" <> show (boundaryEffect fault))"
    , "      Right other → putStrLn (\"script refusal = none \" <> show (other ∷ CallResult))"
    , "    unsupported ← try (callEntry owned handle \"halt\" [])"
    , "    case unsupported of"
    , "      Left fault → putStrLn (\"unsupported = \" <> show (boundaryReason fault))"
    , "      Right other → putStrLn (\"unsupported = none \" <> show (other ∷ CallResult))"
    , "    pure (owned, handle)"
    , "  let (owned, handle) = escaped"
    , "  late ← try (callEntry owned handle \"run\" [VInteger 1])"
    , "  case late ∷ Either VmClosed CallResult of"
    , "    Left _ → putStrLn \"handle after the lifetime = VmClosed\""
    , "    Right other → putStrLn (\"handle after the lifetime = \" <> show other)"
    , "  where"
    , "    ruleOf = \\case"
    , "      ValueRefused refusal → refusalRule refusal"
    , "      other → error (show other)"
    ]
