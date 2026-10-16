-- | The shutdown phase and the finalizer allowlist.
--
-- Before the state closes the owner closes admission, and a callback Lua's
-- finalizers reach runs only if the owner's allowlist names it. The allowlist is
-- empty by default, so any other callback is refused without running, and the
-- refusal is recorded as cleanup evidence whether or not the finalizer's script
-- caught the error it raised. What is recorded from finalizers is bounded.
--
-- These examples install their callbacks and name their allowlists through the
-- package-private configuration, which is the only route to a callback that is
-- not a registered binding. The allowlist a registration builds is the subject of
-- "Test.Lua.Boundary.Finalizers".
module Test.Lua.Owner.Shutdown (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Bridge
  ( FinalizerEvidenceTruncated (FinalizerEvidenceTruncated)
  , FinalizerRefused (FinalizerRefused)
  , Library (LibraryBase)
  , VmReentered (VmReentered)
  , chunkName
  )
import Hetoimasia.Scripting.Lua.Internal.Call (callGlobal, evalChunk)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterLibraries, ownerAllowlist, ownerChunks)
  , defaultOwnerConfig
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (closeVm)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Owner.Support

-- | Callbacks a finalizer may call, and what they observed.
data Fixture = Fixture
  { fixtureEvents ∷ !Events
  , _fixtureLive ∷ !(IORef Bool)
  }

newFixture ∷ IO Fixture
newFixture = Fixture <$> newEvents <*> newIORef False

-- | An owner over the base library that installs three callbacks and loads
-- these chunks, with this allowlist:
--
-- * @allowed@ notes that it ran and whether its dependency was still held, and
--   its release notes itself;
-- * @denied@ notes that it ran, which no example expects to see, and its release
--   notes itself;
-- * @probe@ asks its own VM for an operation of each kind and notes how each was
--   refused.
config ∷ Fixture → [Text] → [(Text, ByteString)] → OwnerConfig
config (Fixture log' live) allowlist chunks =
  (defaultOwnerConfig [LibraryBase])
    { ownerAllowlist = Set.fromList allowlist
    , ownerAfterLibraries = \vm → do
        writeIORef live True
        installCallback
          vm
          "allowed"
          ( do
              held ← readIORef live
              note log' (if held then "allowed: dependency live" else "allowed: dependency gone")
              pure NoResult
          )
          (writeIORef live False >> note log' "allowed: release")
        installCallback
          vm
          "denied"
          (note log' "denied: ran" >> pure NoResult)
          (note log' "denied: release")
        installCallback
          vm
          "probe"
          ( do
              evaluated ← try @SomeException (evalChunk vm (chunkName "probe") "probed = true")
              called ← try @SomeException (callGlobal vm "allowed")
              closed ← try @SomeException (closeVm vm)
              mapM_ (note log' . refusal) [evaluated, called, closed]
              pure NoResult
          )
          (pure ())
    , ownerChunks = [(chunkName name, source) | (name, source) ← chunks]
    }
  where
    refusal = \case
      Left failure | Just (VmReentered operation) ← fromException failure → "probe: refused " <> operation
      Left _ → "probe: refused otherwise"
      Right () → "probe: ran"

spec ∷ Spec
spec = describe "the shutdown phase and the finalizer allowlist" $ do
  it "runs an allowlisted callback from a finalizer with its dependency still held, releasing it after" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        (config fixture ["allowed"] [("guard", "guard = setmetatable({}, {__gc = function() allowed() end})")])
        (\_ → pure ())
    either (const False) (const True) outcome `shouldBe` True
    events (fixtureEvents fixture) >>= (`shouldBe` ["allowed: dependency live", "allowed: release", "denied: release"])

  it "refuses a callback no allowlist names without running it, and keeps the refusal as cleanup evidence" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        (config fixture [] [("guard", "guard = setmetatable({}, {__gc = function() denied() end})")])
        (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → do
        causeOf failure `shouldBe` Just (FinalizerRefused "denied")
        evidenceLabels failure `shouldBe` ["lua finalizer refused"]
        evidenceCauses failure `shouldBe` [Just (FinalizerRefused "denied")]
    logged ← events (fixtureEvents fixture)
    -- It performed no action; its dependency was still released, once.
    logged `shouldSatisfy` notElem "denied: ran"
    length (filter (== "denied: release") logged) `shouldBe` 1

  it "keeps the refusal as cleanup evidence even when the finalizer's script caught the error" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        (config fixture [] [("guard", "guard = setmetatable({}, {__gc = function() pcall(denied) end})")])
        (\_ → pure ())
    case outcome of
      Right () → expectationFailure "a refusal the script caught was dropped"
      Left failure → evidenceLabels failure `shouldBe` ["lua finalizer refused"]
    events (fixtureEvents fixture) >>= (`shouldSatisfy` notElem "denied: ran")

  it "refuses only what the allowlist does not name when finalizers call both" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        ( config
            fixture
            ["allowed"]
            [ ("first guard", "first_guard = setmetatable({}, {__gc = function() allowed() end})")
            , ("second guard", "second_guard = setmetatable({}, {__gc = function() denied() end})")
            ]
        )
        (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the refusal was dropped"
      Left failure → evidenceCauses failure `shouldBe` [Just (FinalizerRefused "denied")]
    logged ← events (fixtureEvents fixture)
    logged `shouldSatisfy` elem "allowed: dependency live"
    logged `shouldSatisfy` notElem "denied: ran"

  it "admits no operation on the VM during the shutdown, from a finalizer's own callback" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        (config fixture ["probe"] [("guard", "guard = setmetatable({}, {__gc = function() probe() end})")])
        (\_ → pure ())
    either (const False) (const True) outcome `shouldBe` True
    -- The finalizer asked for a chunk, a call and a close, and every one was
    -- refused before it ran or changed anything.
    events (fixtureEvents fixture)
      >>= (`shouldBe` ["probe: refused eval-chunk", "probe: refused call-global", "probe: refused close-vm", "allowed: release", "denied: release"])

  it "bounds what it records from finalizers, saying how many it dropped" $ do
    fixture ← newFixture
    outcome ←
      runOwner
        ( config
            fixture
            []
            [ ( "guards"
              , "kept = {}\nfor i = 1, 100 do kept[i] = setmetatable({}, {__gc = function() denied() end}) end"
              )
            ]
        )
        (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the refusals were dropped"
      Left failure → do
        -- Sixty-four refusals kept, in the order they happened, and one entry
        -- saying the other thirty-six were not.
        evidenceLabels failure `shouldBe` replicate 64 "lua finalizer refused" <> ["lua evidence truncated"]
        take 64 (evidenceCauses failure) `shouldBe` replicate 64 (Just (FinalizerRefused "denied"))
        drop 64 (evidenceCauses failure) `shouldBe` [Just (FinalizerEvidenceTruncated 36)]
    events (fixtureEvents fixture) >>= (`shouldSatisfy` notElem "denied: ran")
