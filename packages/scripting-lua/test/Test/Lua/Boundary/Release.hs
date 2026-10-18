-- | The explicit release: the one binding run for a handle the application's own
-- check reports as retired, and the refusal an action can ask the engine to make of
-- its own call.
--
-- Every example runs a chunk in an owner built over a registration of its own:
-- @rel@ holds a ticket that can be used and released, and the examples retire
-- tickets between calls. Whether an action ran is read from what it logged.
module Test.Lua.Boundary.Release (spec) where

import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Internal.Fault (CallRefusal (CallRefusal))
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryEffect)
  , Effect (BindingRan)
  , FaultReason (BindingRefused)
  , VmConfig (vmOwnerName, vmPolicy, vmRegistration)
  )
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (libraries, ok, reasonOf, refusal, run, runFault, withOwnerOf)
import Hetoimasia.Scripting.Lua.Owner (vmConfig)

-- | What the actions observed, and the tickets the application still honours.
data World = World
  { worldLog ∷ !(IORef [Text])
  , worldLive ∷ !(IORef (Set Word64))
  }

newWorld ∷ IO World
newWorld = World <$> newIORef [] <*> newIORef Set.empty

note ∷ World → Text → IO ()
note world entry = atomicModifyIORef' (worldLog world) (\held → (entry : held, ()))

logged ∷ World → IO [Text]
logged world = reverse <$> readIORef (worldLog world)

retire ∷ World → Word64 → IO ()
retire world key = atomicModifyIORef' (worldLive world) (\held → (Set.delete key held, ()))

registered ∷ World → Registration
registered world = ok (registration [capabilityType "ticket" alive, capabilityType "badge" alive] [rel])
  where
    alive key = Set.member key <$> readIORef (worldLive world)
    rel =
      namespace
        "rel"
        [ snapshotQuery "ticket" [SInteger] [SCapability "ticket"] $ \arguments → case arguments of
            [VInteger key] → do
              atomicModifyIORef' (worldLive world) (\held → (Set.insert (fromIntegral key) held, ()))
              pure [VCapability (capability "ticket" (fromIntegral key))]
            _ → pure []
        , snapshotQuery "use" [SCapability "ticket"] [SBoolean] $ \_ → note world "use" >> pure [VBoolean True]
        , releaseOperation "release" "ticket" [SText] $ \_ → note world "release" >> pure [VText "ended"]
        , -- A release that is not first among the bindings that take a ticket, and
          -- that also takes a badge: its second argument is no handle it may accept.
          snapshotQuery "use_two" [SCapability "ticket", SCapability "badge"] [SBoolean] $ \_ → note world "use_two" >> pure [VBoolean True]
        , snapshotQuery "refuse" [SText] [] $ \_ → note world "refuse" >> throwIO (CallRefusal "no room for it")
        ]

config ∷ World → VmConfig
config world = (vmConfig libraries) {vmRegistration = registered world, vmPolicy = ["rel"], vmOwnerName = "release owner"}

spec ∷ Spec
spec = describe "releasing a handle" $ do
  it "runs the release operation for a handle whose lease has ended, and no other binding" $ do
    world ← newWorld
    withOwnerOf (config world) $ \owned → do
      run owned "held = rel.ticket(7); assert(rel.use(held)); assert(rel.release(held) == 'ended')"
      retire world 7
      -- The release is run again for the retired handle, and says what it answers.
      run owned "assert(rel.release(held) == 'ended')"
      fault ← runFault owned "rel.use(held)"
      fmap refusalRule (refusal fault) `shouldBe` Just (RuleRetiredHandle "ticket")
    -- The use never ran for the retired handle; the release ran each time.
    logged world >>= (`shouldBe` ["use", "release", "release"])

  it "still refuses what is not an authentic handle of the declared type, as the release operation's argument" $ do
    world ← newWorld
    withOwnerOf (config world) $ \owned → do
      run owned "held = rel.ticket(3)"
      retire world 3
      refusalRule <$> (runFault owned "rel.release(3)" >>= maybe (fail "not a refusal") pure . refusal)
        >>= (`shouldBe` RuleWrongType "capability ticket" "integer")
      refusalRule <$> (runFault owned "rel.release({held})" >>= maybe (fail "not a refusal") pure . refusal)
        >>= (`shouldBe` RuleWrongType "capability ticket" "table")
    logged world >>= (`shouldBe` [])

  it "does not let the release operation make another binding accept a retired handle: a ticket given to a binding with another argument is refused" $ do
    world ← newWorld
    withOwnerOf (config world) $ \owned → do
      run owned "held = rel.ticket(5)"
      retire world 5
      fault ← runFault owned "rel.use_two(held, held)"
      fmap refusalRule (refusal fault) `shouldSatisfy` (/= Nothing)
    logged world >>= (`shouldBe` [])

  it "declares a release only for a capability type the registration has" $ do
    let unknown = registration [] [namespace "rel" [releaseOperation "release" "ghost" [] (\_ → pure [])]]
    unknown `shouldSatisfy` \case
      Left (UnknownCapabilityType _ "ghost") → True
      _ → False

  describe "an engine refusal raised from an action" $ do
    it "is a fault of the call, whatever the script does with the error, and is not made a failure of the host" $ do
      world ← newWorld
      withOwnerOf (config world) $ \owned → do
        fault ← runFault owned "local ok = pcall(rel.refuse, 'x'); assert(not ok); caught = true"
        reasonOf fault `shouldBe` BindingRefused "no room for it"
        boundaryEffect fault `shouldBe` BindingRan
      logged world >>= (`shouldBe` ["refuse"])
