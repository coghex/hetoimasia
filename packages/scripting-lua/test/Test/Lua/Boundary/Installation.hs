-- | Installing a registration into an owner's VM.
--
-- It happens during construction, inside the protected lifetime, after the
-- libraries and before any initial chunk or module, and the set it installs is
-- fixed for the VM's lifetime. A failure ends construction like any other
-- initialization failure: the VM is closed and the body never runs.
module Test.Lua.Boundary.Installation (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Bridge (evalChunk)
import Hetoimasia.Scripting.Lua.Internal.Owner (OwnerConfig (..), defaultOwnerConfig)
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration (bindingDirect, namespaceBindings, registrationNamespaces)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Boundary.Support
import Test.Lua.Owner.Support (capture, captured, causeOf, newCaptured, runOwner)

spec ∷ Spec
spec = describe "installing a registration" $ do
  it "ends construction, closing the VM and never entering the body, when a policy names an unknown namespace" $ do
    fixture ← newFixture
    vmRef ← newCaptured
    entered ← newIORef False
    let config =
          (defaultOwnerConfig libraries)
            { ownerRegistration = sampleRegistration fixture
            , ownerGranted = ["sample", "missing"]
            , ownerName = "policy"
            , ownerAfterAllocation = capture vmRef
            }
    outcome ← runOwner config (\_ → writeIORef entered True)
    case outcome of
      Right () → expectationFailure "construction succeeded"
      Left failure → case causeOf failure of
        Just fault → do
          boundaryReason fault `shouldBe` PolicyUnknownNamespace "missing"
          boundaryOperation fault `shouldBe` InstallBindings
          boundaryOwner fault `shouldBe` "policy"
          boundaryEffect fault `shouldBe` NoEffect
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)
    readIORef entered >>= (`shouldBe` False)
    captured vmRef >>= \case
      Just vm → vmPhase vm >>= (`shouldBe` Closed)
      Nothing → expectationFailure "the VM was never made"

  it "installs before the initial chunks and the initial modules run" $ do
    fixture ← newFixture
    let config =
          (sampleConfig fixture ["sample"])
            { vmInitialChunks = [(chunkName "init", chunk "sample.set_value('chunk', sample.add(1, 2))")]
            , vmModules = [ModuleSource (ModuleRef "m" "1") (chunk "sample.set_value('module', sample.add(2, 3))") []]
            }
    withOwnerOf config (\_ → pure ())
    stateOf fixture >>= (`shouldBe` Map.fromList [("chunk", 3), ("module", 5)])
    logged fixture >>= (`shouldBe` ["add", "set_value", "add", "set_value"])

  it "installs exactly the direct-eligible bindings of the granted namespaces, fixed for the lifetime" $ do
    fixture ← newFixture
    let registered = sampleRegistration fixture
        expected = [length (filter bindingDirect (namespaceBindings space)) | space ← registrationNamespaces registered]
    withOwner fixture ["sample", "other"] $ \owned → do
      run owned "count = 0; for _ in pairs(sample) do count = count + 1 end; other_count = 0; for _ in pairs(other) do other_count = other_count + 1 end"
      case expected of
        [sampleCount, otherCount] →
          run owned (Text.pack ("assert(count == " <> show sampleCount <> "); assert(other_count == " <> show otherCount <> ")"))
        _ → expectationFailure "the sample registration does not have two namespaces"

  it "creates the namespaces and the bindings by raw access, running no metamethod of the globals" $ do
    fixture ← newFixture
    let config =
          (defaultOwnerConfig libraries)
            { ownerRegistration = sampleRegistration fixture
            , ownerGranted = ["sample"]
            , ownerAfterLibraries = \vm →
                evalChunk
                  vm
                  (chunkName "trap")
                  "touched = false; setmetatable(_G, {__newindex = function(t, k, v) rawset(_G, 'touched', true); rawset(t, k, v) end})"
            }
    outcome ← runOwner config $ \owned → do
      evalOwned owned (chunkName "check") "assert(rawget(_G, 'touched') == false); assert(type(rawget(_G, 'sample')) == 'table'); assert(sample.add(1, 2) == 3)"
    either (expectationFailure . show) pure outcome

  it "refuses a namespace name that is already something other than a table" $ do
    fixture ← newFixture
    let config =
          (defaultOwnerConfig libraries)
            { ownerRegistration = sampleRegistration fixture
            , ownerGranted = ["sample"]
            , ownerAfterLibraries = \vm → evalChunk vm (chunkName "taken") "sample = 5"
            }
    outcome ← runOwner config (\_ → pure ())
    case outcome of
      Right () → expectationFailure "construction succeeded"
      Left failure → fmap boundaryReason (causeOf failure) `shouldBe` Just (NamespaceTaken "sample")

  it "installs nothing for an owner that is granted nothing" $ do
    fixture ← newFixture
    withOwner fixture [] $ \owned → run owned "assert(sample == nil and other == nil)"
