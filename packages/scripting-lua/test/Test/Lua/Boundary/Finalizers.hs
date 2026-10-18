-- | The finalizer allowlist a registration builds.
--
-- A Lua finalizer runs during the VM's close, when the application's state may be
-- going away. An owner's allowlist is exactly the bindings of the namespaces it
-- grants that the registration declares finalizer-eligible, and it is consulted
-- before a call is dispatched: before its arguments are read, before its handles
-- are checked and before its action. Anything else reached from a finalizer is
-- refused with 'FinalizerRefused' and kept as cleanup evidence, whether or not the
-- finalizer's script caught the error.
module Test.Lua.Boundary.Finalizers (spec) where

import Control.Exception (ExceptionWithContext, SomeException, tryWithContext)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration (BindingKind (LifecycleOperation), lifecycleContext)
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support
import Test.Lua.Owner.Support (causeOf, evidenceCauses, evidenceLabels)

-- | An owner granted these namespaces whose initial chunk is this source, and how
-- its lifetime ended.
closing ∷ Fixture → [Text] → Text → IO (Either (ExceptionWithContext SomeException) ())
closing fixture granted source =
  tryWithContext @SomeException $
    withOwnerOf
      (sampleConfig fixture granted) {vmInitialChunks = [(chunkName "guard", chunk source)]}
      (\_ → pure ())

guard' ∷ Text → Text
guard' call = "guard = setmetatable({}, {__gc = function() " <> call <> " end})"

spec ∷ Spec
spec = describe "the finalizer allowlist" $ do
  it "runs a binding declared finalizer-eligible from a finalizer during the close" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] (guard' "sample.note_gc('bye')")
    either (const False) (const True) outcome `shouldBe` True
    logged fixture >>= (`shouldBe` ["note_gc bye"])

  it "refuses a binding that is not eligible without running it, keeping the refusal as cleanup evidence" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] (guard' "sample.plain('x')")
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → do
        causeOf failure `shouldBe` Just (FinalizerRefused "sample.plain")
        evidenceLabels failure `shouldBe` ["lua finalizer refused"]
    logged fixture >>= (`shouldBe` [])

  it "keeps the refusal even when the finalizer's script caught the error" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] (guard' "pcall(sample.plain, 'x')")
    case outcome of
      Right () → expectationFailure "a refusal the script caught was dropped"
      Left failure → evidenceCauses failure `shouldBe` [Just (FinalizerRefused "sample.plain")]
    logged fixture >>= (`shouldBe` [])

  it "applies the allowlist before dispatch, so an ineligible binding's arguments are never read" $ do
    fixture ← newFixture
    -- The arguments are invalid for the binding. The refusal is still the
    -- allowlist's, not a refusal of a value.
    outcome ← closing fixture ["sample"] (guard' "sample.plain(1.5, {}, print)")
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → causeOf failure `shouldBe` Just (FinalizerRefused "sample.plain")

  it "validates an eligible binding's arguments like any other call" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] (guard' "sample.note_gc(1.5)")
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → case causeOf failure of
        Just fault → fmap refusalRule (refusal fault) `shouldBe` Just (RuleWrongType "text" "float")
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)
    logged fixture >>= (`shouldBe` [])

  it "builds the allowlist from the granted namespaces only" $ do
    fixture ← newFixture
    -- Nothing in @other@ is finalizer-eligible, so nothing the owner grants runs.
    outcome ← closing fixture ["other"] (guard' "other.ping()")
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → causeOf failure `shouldBe` Just (FinalizerRefused "other.ping")
    logged fixture >>= (`shouldBe` [])
    -- An owner granted nothing has an empty allowlist: the namespace is not even
    -- visible, and a finalizer that names it fails as an ordinary script would.
    empty ← closing fixture [] (guard' "sample.note_gc('no')")
    either (const False) (const True) empty `shouldBe` True
    logged fixture >>= (`shouldBe` [])

  it "keeps an allowlisted lifecycle binding from executing anything, under the settled decision" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] (guard' "sample.lifecycle_gc()")
    case outcome of
      Right () → expectationFailure "the unsupported call was dropped"
      Left failure → case causeOf failure of
        Just fault → boundaryReason fault `shouldBe` NotYetSupported LifecycleOperation
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)
    logged fixture >>= (`shouldBe` [])

  it "keeps an allowlisted lifecycle binding from executing even for an owner configured to deliver lifecycle operations" $ do
    fixture ← newFixture
    outcome ←
      tryWithContext @SomeException $
        withOwnerOf
          (sampleConfig fixture ["sample"]) {vmInitialChunks = [(chunkName "guard", chunk (guard' "sample.lifecycle_gc()"))], vmLifecycle = Just (lifecycleContext ())}
          (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the unsupported call was dropped"
      Left failure → case causeOf failure of
        Just fault → boundaryReason fault `shouldBe` NotYetSupported LifecycleOperation
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)
    logged fixture >>= (`shouldBe` [])

  it "attributes a close-time fault to the close, not to the last operation the body ran" $ do
    fixture ← newFixture
    let config =
          (sampleConfig fixture ["sample"])
            { vmInitialChunks = [(chunkName "guard", chunk (guard' "sample.note_gc(1.5)"))]
            }
    outcome ← tryWithContext @SomeException . withOwnerOf config $ \owned → do
      handle ← loadModule owned (ModuleSource (ModuleRef "busy" "1") (chunk "function go() sample.set_value('k', 1) end") [EntryPoint "go" Required [] []])
      _ ← callEntry owned handle "go" []
      pure ()
    case outcome of
      Right () → expectationFailure "the finalizer's fault was dropped"
      Left failure → case causeOf failure of
        Just fault → do
          -- The module the body ran last, and the action it ran, are not the
          -- finalizer's.
          boundaryModule fault `shouldBe` Nothing
          boundaryEntry fault `shouldBe` Nothing
          boundaryEffect fault `shouldBe` LuaRan
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)

  it "runs an eligible binding from a finalizer of a module the owner loaded" $ do
    fixture ← newFixture
    withOwner fixture ["sample"] $ \owned → do
      _ ← loadModule owned (ModuleSource (ModuleRef "m" "1") (chunk (guard' "sample.note_gc('module')")) [])
      pure ()
    logged fixture >>= (`shouldBe` ["note_gc module"])

  it "reports the refusals of several finalizers in the order they ran, bounded like any other" $ do
    fixture ← newFixture
    outcome ← closing fixture ["sample"] "kept = {}\nfor i = 1, 100 do kept[i] = setmetatable({}, {__gc = function() sample.plain('x') end}) end"
    case outcome of
      Right () → expectationFailure "the refusals were dropped"
      Left failure → do
        take 64 (evidenceLabels failure) `shouldBe` replicate 64 "lua finalizer refused"
        drop 64 (evidenceLabels failure) `shouldSatisfy` (== ["lua evidence truncated"])
    logged fixture >>= (`shouldBe` [])
