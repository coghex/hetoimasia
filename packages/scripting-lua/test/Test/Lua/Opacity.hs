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
    , "  , loadModule"
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
    , "      config = (vmConfig [LibraryBase]) {vmRegistration = registered, vmPolicy = [\"app\"], vmOwnerName = \"client\", vmModules = []}"
    , "  escaped ← withVmOwner config $ \\owned → do"
    , "    handle ← loadModule owned source"
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
