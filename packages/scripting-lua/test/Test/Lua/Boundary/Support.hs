-- | What the boundary's examples share: a sample registration whose bindings
-- record what they were asked, an owner built over it, and the readings an
-- example takes of a fault.
--
-- The sample registration is a fixture and names no game namespace: @sample@ and
-- @other@ stand for whatever an application would register. Each binding writes
-- what it did to the fixture, so an example can tell a binding that ran from one
-- that was refused before its action, and from the order of the two.
module Test.Lua.Boundary.Support
  ( -- * The fixture
    Fixture (..)
  , newFixture
  , sampleRegistration
  , sampleConfig
  , libraries
  , withOwner
  , withOwnerOf
  , chunk
    -- * Running Lua
  , run
  , runFault
  , faultOf
  , logged
  , stateOf
    -- * Building values
  , ok
  , record
  , grantTicket
  , retire
    -- * Reading a fault
  , refusal
  , reasonOf
  ) where

import Control.Exception (SomeException, fromException, try)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Vm (closeVm)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryReason)
  , FaultReason (ValueRefused)
  , Library (LibraryBase, LibraryMath, LibraryString, LibraryTable)
  , OwnedVm
  , VmClosed (VmClosed)
  , VmConfig (vmOwnerName, vmPolicy, vmRegistration)
  , VmNotOwned (VmNotOwned)
  , VmReentered (VmReentered)
  , chunkName
  , evalOwned
  , vmConfig
  , withVmOwner
  )
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value

-- | What the sample bindings observe and share.
data Fixture = Fixture
  { fixtureLog ∷ !(IORef [Text])
    -- ^ What the bindings did, oldest last.
  , fixtureState ∷ !(IORef (Map Text Int64))
  , fixtureLive ∷ !(IORef (Set Word64))
    -- ^ The ticket keys the application still honours.
  , fixtureSelf ∷ !(IORef (Maybe OwnedVm))
    -- ^ The VM @game.reenter@'s action tries to run Lua on.
  , fixtureOther ∷ !(IORef (Maybe OwnedVm))
    -- ^ Another owner's VM, which @game.trespass@'s action tries to use.
  , fixtureAttempt ∷ !(IORef (Maybe Text))
    -- ^ How the last of those attempts was refused.
  }

newFixture ∷ IO Fixture
newFixture = Fixture <$> newIORef [] <*> newIORef Map.empty <*> newIORef Set.empty <*> newIORef Nothing <*> newIORef Nothing <*> newIORef Nothing

-- | Everything the bindings noted, oldest first.
logged ∷ Fixture → IO [Text]
logged fixture = reverse <$> readIORef (fixtureLog fixture)

stateOf ∷ Fixture → IO (Map Text Int64)
stateOf = readIORef . fixtureState

note ∷ Fixture → Text → IO ()
note fixture entry = atomicModifyIORef' (fixtureLog fixture) (\held → (entry : held, ()))

-- | A ticket the application honours, as a value.
grantTicket ∷ Fixture → Word64 → IO Value
grantTicket fixture key = do
  atomicModifyIORef' (fixtureLive fixture) (\held → (Set.insert key held, ()))
  pure (VCapability (capability "ticket" key))

-- | The application stops honouring a ticket.
retire ∷ Fixture → Word64 → IO ()
retire fixture key = atomicModifyIORef' (fixtureLive fixture) (\held → (Set.delete key held, ()))

ok ∷ Either RegistrationRefusal a → a
ok = either (error . ("registration refused: " <>) . show) id

-- | A record value.
record ∷ [(Text, Value)] → Value
record = VRecord

-- | The registration the examples share: two namespaces and a capability type.
--
-- @sample@ holds one binding of each kind, and bindings whose actions are
-- fixtures for what the boundary does around them. @other@ is a namespace an
-- owner may or may not be granted.
sampleRegistration ∷ Fixture → Registration
sampleRegistration fixture = ok (registration [capabilityType "ticket" alive, capabilityType "badge" alive] [sample, other])
  where
    alive key = Set.member key <$> readIORef (fixtureLive fixture)
    sample =
      namespace
        "sample"
        [ snapshotQuery "add" [SInteger, SInteger] [SInteger] $ \arguments → do
            note fixture "add"
            case arguments of
              [VInteger a, VInteger b] → pure [VInteger (a + b)]
              _ → pure []
        , snapshotQuery "echo_number" [SNumber] [SNumber] (\values → note fixture "echo_number" >> pure values)
        , snapshotQuery "echo_integer" [SInteger] [SInteger] (\values → note fixture "echo_integer" >> pure values)
        , snapshotQuery "echo_float" [SFloat] [SFloat] (\values → note fixture "echo_float" >> pure values)
        , snapshotQuery "echo_text" [SText] [SText] (\values → note fixture "echo_text" >> pure values)
        , snapshotQuery "echo_bytes" [SBytes] [SBytes] (\values → note fixture "echo_bytes" >> pure values)
        , snapshotQuery "echo_list" [SList SNumber] [SList SNumber] (\values → note fixture "echo_list" >> pure values)
        , snapshotQuery "echo_nested" [SList (SList SInteger)] [SList (SList SInteger)] (\values → note fixture "echo_nested" >> pure values)
        , snapshotQuery "echo_record" [recordSchema] [recordSchema] (\values → note fixture "echo_record" >> pure values)
        , snapshotQuery "echo_any3" [SNumber, SText, SOptional SBoolean] [SNumber, SText, SOptional SBoolean] (\values → note fixture "echo_any3" >> pure values)
        , snapshotQuery "nothing" [] [] (\_ → note fixture "nothing" >> pure [])
        , snapshotQuery "count" [SList SInteger] [SInteger] $ \arguments → do
            note fixture "count"
            case arguments of
              [VList items] → pure [VInteger (fromIntegral (length items))]
              _ → pure []
        , snapshotQuery "make_list" [SInteger] [SList SInteger] $ \arguments → do
            note fixture "make_list"
            case arguments of
              [VInteger n] → pure [VList (map VInteger [1 .. n])]
              _ → pure []
        , snapshotQuery "make_text" [SInteger] [SText] $ \arguments → do
            note fixture "make_text"
            case arguments of
              [VInteger n] → pure [VText (Text.replicate (fromIntegral n) "x")]
              _ → pure []
        , snapshotQuery "make_nested" [] [SList (SList SInteger)] (\_ → note fixture "make_nested" >> pure [VList [VList [VInteger 1]]])
        , snapshotQuery "nil_list" [] [SList (SOptional SInteger)] (\_ → note fixture "nil_list" >> pure [VList [VInteger 1, VNil, VInteger 3]])
        , snapshotQuery "nil_field" [] [SRecord [("a", SInteger), ("b", SOptional SInteger)]] (\_ → note fixture "nil_field" >> pure [VRecord [("a", VNil), ("b", VNil)]])
        , snapshotQuery "nil_optional" [] [SRecord [("a", SInteger), ("b", SOptional SInteger)]] (\_ → note fixture "nil_optional" >> pure [VRecord [("a", VInteger 1), ("b", VNil)]])
        , snapshotQuery "endless_nil" [] [SRecord [("a", SOptional SInteger)]] (\_ → note fixture "endless_nil" >> pure [VRecord (repeat ("a", VNil))])
        , snapshotQuery "wrong_result" [] [SInteger] (\_ → note fixture "wrong_result" >> pure [VText "not an integer"])
        , snapshotQuery "short_result" [] [SInteger, SInteger] (\_ → note fixture "short_result" >> pure [VInteger 1])
        , stateOperation "set_value" [SText, SInteger] [] $ \arguments → do
            note fixture "set_value"
            case arguments of
              [VText key, VInteger value] → atomicModifyIORef' (fixtureState fixture) (\held → (Map.insert key value held, ()))
              _ → pure ()
            pure []
        , stateOperation "set_float" [SText, SFloat] [] (\_ → note fixture "set_float" >> pure [])
        , commandIntention "submit" [SText] $ \arguments → do
            note fixture "submit"
            pure $ case arguments of
              [VText "bad"] → Rejected "not allowed"
              [VText "huge"] → Rejected (Text.replicate (commandReasonLimit + 1) "r")
              _ → Accepted
        , snapshotQuery "ticket" [SInteger] [SCapability "ticket"] $ \arguments → do
            note fixture "ticket"
            case arguments of
              [VInteger key] → (: []) <$> grantTicket fixture (fromIntegral key)
              _ → pure []
        , snapshotQuery "redeem" [SCapability "ticket"] [SBoolean] $ \_ → note fixture "redeem" >> pure [VBoolean True]
        , snapshotQuery "redeem_badge" [SCapability "badge"] [SBoolean] $ \_ → note fixture "redeem_badge" >> pure [VBoolean True]
        , snapshotQuery "redeem_two" [SList (SCapability "ticket")] [SInteger] $ \arguments → do
            note fixture "redeem_two"
            case arguments of
              [VList items] → pure [VInteger (fromIntegral (length items))]
              _ → pure []
        , stateOperation "fail" [SText] [] $ \_ → do
            note fixture "fail"
            ioError (userError "the action failed")
        , attempt "reenter" (fixtureSelf fixture) "run Lua"
        , attempt "close_self" (fixtureSelf fixture) "close"
        , attempt "trespass" (fixtureOther fixture) "run Lua"
        , asynchronousNativeRequest "spawn_async" [SText] [SInteger] (\_ → note fixture "spawn_async: ran" >> pure [VInteger 1])
        , lifecycleOperation "stop" [] [] (\_ → note fixture "stop: ran" >> pure [])
        , finalizerEligible (stateOperation "note_gc" [SText] [] (\arguments → note fixture ("note_gc " <> render arguments) >> pure []))
        , finalizerEligible (lifecycleOperation "lifecycle_gc" [] [] (\_ → note fixture "lifecycle_gc: ran" >> pure []))
        , stateOperation "plain" [SText] [] (\_ → note fixture "plain" >> pure [])
        , withoutDirectPath (snapshotQuery "hidden" [] [] (\_ → note fixture "hidden" >> pure []))
        , confinedEligible (snapshotQuery "pure_sum" [SList SInteger] [SInteger] (\_ → pure [VInteger 0]))
        ]
    other =
      namespace
        "other"
        [ snapshotQuery "ping" [] [SText] (\_ → note fixture "ping" >> pure [VText "pong"])
        ]
    attempt name target what = stateOperation name [] [] $ \_ → do
      note fixture name
      found ← readIORef target
      for_ found $ \vm → do
        outcome ←
          try @SomeException $
            if what == ("close" ∷ Text)
              then closeVm (ownedInternalVm vm)
              else evalOwned vm (chunkName "attempt") "attempted = true"
        writeIORef (fixtureAttempt fixture) . Just $ case outcome of
          Right () → "ran"
          Left failure
            | Just (VmReentered _) ← fromException failure → "reentered"
            | Just (VmNotOwned _) ← fromException failure → "not owned"
            | Just (VmClosed _) ← fromException failure → "closed"
            | otherwise → "other: " <> Text.pack (show failure)
      pure []
    recordSchema = SRecord [("name", SText), ("count", SInteger), ("note", SOptional SText)]
    render [VText text] = text
    render _ = "?"

-- | The standard libraries every example's owner opens.
libraries ∷ [Library]
libraries = [LibraryBase, LibraryString, LibraryTable, LibraryMath]

-- | An owner configuration over the sample registration exposing these
-- namespaces.
sampleConfig ∷ Fixture → [Text] → VmConfig
sampleConfig fixture granted =
  (vmConfig libraries)
    { vmRegistration = sampleRegistration fixture
    , vmPolicy = granted
    , vmOwnerName = "sample owner"
    }

-- | Run a body over an owner granted these namespaces of the sample registration.
withOwner ∷ Fixture → [Text] → (OwnedVm → IO a) → IO a
withOwner fixture granted = withVmOwner (sampleConfig fixture granted)

-- | Run a body over an owner of this configuration.
withOwnerOf ∷ VmConfig → (OwnedVm → IO a) → IO a
withOwnerOf = withVmOwner

-- | A chunk's source from text.
chunk ∷ Text → ByteString
chunk = encodeUtf8

-- | Run a chunk in the owner's VM.
run ∷ OwnedVm → Text → IO ()
run owned source = evalOwned owned (chunkName "example") (chunk source)

-- | The fault a chunk raises, if it raises a boundary fault.
faultOf ∷ IO a → IO (Maybe BoundaryFault)
faultOf action = either Just (const Nothing) <$> try action

-- | The fault a chunk raises; the example fails if it does not raise one.
runFault ∷ OwnedVm → Text → IO BoundaryFault
runFault owned source = do
  outcome ← faultOf (run owned source)
  case outcome of
    Just found → pure found
    Nothing → error "the chunk raised no boundary fault"

-- | The refusal a fault carries, if it is the refusal of a value.
refusal ∷ BoundaryFault → Maybe ValueRefusal
refusal fault = case boundaryReason fault of
  ValueRefused found → Just found
  _ → Nothing

-- | The reason of a fault.
reasonOf ∷ BoundaryFault → FaultReason
reasonOf = boundaryReason
