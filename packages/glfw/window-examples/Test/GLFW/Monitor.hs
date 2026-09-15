-- | Examples for the monitor inventory a session owns, driven through the
-- private test seam.
--
-- They live in the package's @glfw-window-examples@ executable because they use
-- the seam's private monitor drivers: 'seamSetMonitorTopology' changes what the
-- scripted platform enumerates, 'seamDeliverMonitorEvents' invokes the monitor
-- callback the session attached, and neither is public. The inventory,
-- identities, validation, callback containment, and teardown under test are the
-- production model's, and nothing initializes GLFW.
--
-- A scripted monitor's native pointer stands for its scripted address, so a
-- reconnect at the same address is a reused native pointer, and the seam raises
-- if the model ever queries an address the current topology does not list.
-- Threads are coordinated with 'MVar's and STM, never with a sleep.
module Test.GLFW.Monitor (spec) where

import Control.Concurrent (forkIO, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), toException)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (Update (..), awaitSnapshot, observedCursor, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures)
import Hetoimasia.GLFW.Internal.Monitor (monitorEventCapacity)
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Internal.Session (reconcileMonitorEvents, withResolvedMonitor)
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session
import Test.GLFW.Window (boundedExample, caughtAs, contextsOf, entered, onThread, originOf, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldNotBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW monitor inventory" $ do
  describe "observations" $ do
    it "publishes an empty inventory as revision zero of an observation, and republishes nothing unchanged"
      (boundedExample testEmptyInventory)
    it "describes monitors at negative and nonzero desktop origins, reporting the primary only as an attribute"
      (boundedExample testSeveralMonitors)
    it "turns inconsistent native numbers into unavailable fields rather than fabricated values"
      (boundedExample testInconsistentNumbers)
    it "makes an inconsistent enumeration unavailable and ends every identity until a consistent one"
      (boundedExample testInconsistentEnumeration)
    it "reports a query GLFW calls unavailable as unavailable, and fails the boundary on any other report"
      (boundedExample testQueryReports)

  describe "identities" $ do
    it "ends an identity on disconnect while its copied description stays readable"
      (boundedExample testDisconnect)
    it "issues a fresh identity to a monitor reconnected at the same native address, and keeps identities through reordering"
      (boundedExample testReconnect)
    it "answers a stale identity as disconnected before any native operation targets its monitor"
      (boundedExample testStaleBeforeNative)
    it "never resolves an identity from a completed session in a later one, though its number and address repeat"
      (boundedExample testAcrossSessions)

  describe "the monitor callback" $ do
    it "rethrows a callback fault at the next boundary with its context and ends every identity"
      (boundedExample testCallbackFault)
    it "ends every identity after more changes than one boundary keeps, or an event code GLFW does not define"
      (boundedExample testLostChanges)
    it "raises a fault latched after the last boundary from the session's release, which still completes"
      (boundedExample testLateFault)

  describe "ownership and teardown" $ do
    it "refuses monitor operations off the owner thread before any native call, while any thread reads the inventory"
      (boundedExample testOwnerThread)
    it "closes the inventory before termination: the last descriptions stay readable, waiters wake, and the callback is detached first and freed last"
      (boundedExample testClose)

-- ---------------------------------------------------------------------------
-- Observations

testEmptyInventory ∷ Expectation
testEmptyInventory = do
  seam ← newSeam defaultScript
  (initial, synchronized, refresh) ← inSession seam $ \session → do
    initial ← published session
    before ← length <$> seamCalls seam
    synchronized ← synchronizeMonitors session
    refresh ← drop before <$> seamCalls seam
    pure (initial, synchronized, refresh)
  inventoryMonitors initial `shouldBe` Observed []
  inventoryRevision initial `shouldBe` 0
  inventoryPhase initial `shouldBe` InventoryOpen
  synchronized `shouldBe` initial
  refresh `shouldBe` [QueryMonitors, QueryPrimaryMonitor]

testSeveralMonitors ∷ Expectation
testSeveralMonitors = do
  seam ← withTopology (laid 2 [(1, left), (2, centre), (3, above)])
  (initial, undesignated) ← inSession seam $ \session → do
    initial ← published session
    seamSetMonitorTopology seam (laid 0 [(1, left), (2, centre), (3, above)])
    undesignated ← synchronizeMonitors session
    pure (initial, undesignated)
  descriptions ← described initial
  map monitorName descriptions `shouldBe` map Observed ["left", "centre", "above"]
  map monitorPosition descriptions
    `shouldBe` map Observed [MonitorPosition (-1920) 0, MonitorPosition 0 0, MonitorPosition 320 (-1200)]
  map monitorWorkArea descriptions
    `shouldBe` map Observed [WorkArea (-1920) 0 1920 1080, WorkArea 0 0 2560 1440, WorkArea 320 (-1200) 1600 1200]
  map monitorCurrentMode descriptions `shouldBe` map Observed [mode 1920 1080, mode 2560 1440, mode 1600 1200]
  map monitorVideoModes descriptions `shouldBe` map (Observed . pure) [mode 1920 1080, mode 2560 1440, mode 1600 1200]
  map monitorPhysicalSize descriptions `shouldBe` replicate 3 (Observed (PhysicalSize 600 340))
  map monitorContentScale descriptions `shouldBe` replicate 3 (Observed (ContentScale 1 1))
  map monitorPrimary descriptions `shouldBe` map Observed [False, True, False]
  map (monitorLocalIdentity . monitorIdentity) descriptions `shouldBe` [1, 2, 3]
  -- A platform that designates no primary monitor reports every one as not
  -- primary, and the change keeps every identity.
  inventoryRevision undesignated `shouldBe` 1
  later ← described undesignated
  map monitorPrimary later `shouldBe` replicate 3 (Observed False)
  map monitorIdentity later `shouldBe` map monitorIdentity descriptions

testInconsistentNumbers ∷ Expectation
testInconsistentNumbers = do
  let broken =
        (scriptedMonitor "broken" (10, 20) (800, 600))
          { scriptedName = Nothing
          , scriptedWorkArea = (10, 20, -1, 600)
          , scriptedPhysicalSize = (0, 340)
          , scriptedContentScale = (0 / 0, 1)
          , scriptedCurrentMode = Nothing
          , scriptedVideoModes = Just [NativeVideoMode 800 600 8 8 8 60, NativeVideoMode 0 600 8 8 8 60]
          }
      partial =
        (scriptedMonitor "partial" (-5, -5) (640, 480))
          { scriptedPhysicalSize = (-600, -340)
          , scriptedContentScale = (1, 1 / 0)
          , scriptedCurrentMode = Just (NativeVideoMode 640 480 (-1) 8 8 0)
          , scriptedVideoModes = Nothing
          }
  -- The primary address the platform names is not among the monitors it lists.
  seam ← withTopology (laid 9 [(1, broken), (2, partial)])
  (first, second) ← inSession seam published >>= described >>= twoOf
  monitorName first `shouldBe` Unavailable
  monitorPosition first `shouldBe` Observed (MonitorPosition 10 20)
  monitorWorkArea first `shouldBe` Unavailable
  monitorPhysicalSize first `shouldBe` Unavailable
  monitorContentScale first `shouldBe` Unavailable
  monitorCurrentMode first `shouldBe` Unavailable
  monitorVideoModes first `shouldBe` Unavailable
  monitorName second `shouldBe` Observed "partial"
  monitorPosition second `shouldBe` Observed (MonitorPosition (-5) (-5))
  monitorWorkArea second `shouldBe` Observed (WorkArea (-5) (-5) 640 480)
  monitorPhysicalSize second `shouldBe` Unavailable
  monitorContentScale second `shouldBe` Unavailable
  monitorCurrentMode second `shouldBe` Observed (VideoMode 640 480 Unavailable (Observed 8) (Observed 8) Unavailable)
  monitorVideoModes second `shouldBe` Unavailable
  map monitorPrimary [first, second] `shouldBe` [Unavailable, Unavailable]

testInconsistentEnumeration ∷ Expectation
testInconsistentEnumeration = do
  seam ← withTopology (laid 1 [(1, left)])
  (original, attempts, restored, stale) ← inSession seam $ \session → do
    original ← published session >>= identities
    let attempt topology = do
          seamSetMonitorTopology seam topology
          inventory ← synchronizeMonitors session
          resolved ← mapM (resolveMonitor session) original
          pure (inventoryMonitors inventory, resolved)
    uncounted ← attempt (MonitorTopology Nothing 1)
    nulled ← attempt (laid 1 [(0, left)])
    repeated ← attempt (laid 1 [(1, left), (1, left)])
    seamSetMonitorTopology seam (laid 1 [(1, left)])
    restored ← synchronizeMonitors session >>= identities
    stale ← mapM (resolveMonitor session) original
    pure (original, [uncounted, nulled, repeated], restored, stale)
  map fst attempts `shouldBe` replicate 3 Unavailable
  map snd attempts `shouldBe` replicate 3 (map MonitorDisconnected original)
  -- The monitor is back at the same address, as a new connection.
  map monitorLocalIdentity restored `shouldBe` [2]
  stale `shouldBe` map MonitorDisconnected original

testQueryReports ∷ Expectation
testQueryReports = do
  reporting ← newIORef False
  seam ←
    newSeam
      defaultScript
        { scriptMonitorTopology = laid 1 [(1, left)]
        , scriptMonitorQuery = \_ query reporter → case query of
            PositionQuery → reportError reporter featureUnavailableCode "Wayland: The platform does not provide the monitor position"
            NameQuery → readIORef reporting >>= \on → when on (reportError reporter 0x00010008 "name query failed")
            _ → pure ()
        }
  (positions, (failure, caught)) ← inSession seam $ \session → do
    positions ← map monitorPosition <$> (published session >>= described)
    writeIORef reporting True
    failed ← caughtAs (synchronizeMonitors session)
    writeIORef reporting False
    pure (positions, failed)
  positions `shouldBe` [Unavailable]
  nativeOutcome failure `shouldBe` NativeCallReturned
  map nativeErrorCode (reportedErrors (nativeReports failure)) `shouldBe` [0x00010008]
  originOf caught `shouldBe` Just ("glfw", "sample monitors", [("monitor", "1")])

-- ---------------------------------------------------------------------------
-- Identities

testDisconnect ∷ Expectation
testDisconnect = do
  seam ← withTopology (laid 1 [(1, left), (2, centre)])
  (before, after, stale, live) ← inSession seam $ \session → do
    before ← published session
    (ended, continuing) ← described before >>= twoOf
    seamSetMonitorTopology seam (laid 2 [(2, centre)])
    seamDeliverMonitorEvents seam [MonitorDetached 1]
    reconcileMonitorEvents session
    after ← published session
    stale ← resolveMonitor session (monitorIdentity ended)
    live ← resolveMonitor session (monitorIdentity continuing)
    pure (before, after, stale, live)
  (gone, kept) ← described before >>= twoOf
  stale `shouldBe` MonitorDisconnected (monitorIdentity gone)
  -- The copied description of the ended connection is still whole.
  monitorName gone `shouldBe` Observed "left"
  monitorPosition gone `shouldBe` Observed (MonitorPosition (-1920) 0)
  monitorCurrentMode gone `shouldBe` Observed (mode 1920 1080)
  inventoryRevision after `shouldBe` 1
  remaining ← described after
  map monitorIdentity remaining `shouldBe` [monitorIdentity kept]
  map monitorPrimary remaining `shouldBe` [Observed True]
  live `shouldSatisfy` \case
    MonitorAvailable description → monitorIdentity description == monitorIdentity kept
    MonitorDisconnected _ → False

testReconnect ∷ Expectation
testReconnect = do
  seam ← withTopology (laid 1 [(1, left), (2, centre)])
  (original, sameBoundary, stale, reordered, separate) ← inSession seam $ \session → do
    original ← published session >>= identities
    -- Disconnected and reconnected at the same address before one boundary, so
    -- the enumeration the boundary sees is unchanged.
    seamDeliverMonitorEvents seam [MonitorDetached 1, MonitorAttached 1]
    reconcileMonitorEvents session
    sameBoundary ← published session
    stale ← mapM (resolveMonitor session) (take 1 original)
    seamSetMonitorTopology seam (laid 1 [(2, centre), (1, left)])
    reordered ← synchronizeMonitors session >>= identities
    -- Disconnected at one boundary and reconnected at the same address at a
    -- later one.
    seamSetMonitorTopology seam (laid 2 [(2, centre)])
    seamDeliverMonitorEvents seam [MonitorDetached 1]
    reconcileMonitorEvents session
    seamSetMonitorTopology seam (laid 2 [(2, centre), (1, left)])
    seamDeliverMonitorEvents seam [MonitorAttached 1]
    reconcileMonitorEvents session
    separate ← published session >>= identities
    pure (original, sameBoundary, stale, reordered, separate)
  map monitorLocalIdentity original `shouldBe` [1, 2]
  inventoryRevision sameBoundary `shouldBe` 1
  renewed ← identities sameBoundary
  map monitorLocalIdentity renewed `shouldBe` [3, 2]
  drop 1 renewed `shouldBe` drop 1 original
  stale `shouldBe` map MonitorDisconnected (take 1 original)
  -- Reordering the enumeration keeps every continuing connection's identity.
  map monitorLocalIdentity reordered `shouldBe` [2, 3]
  map monitorLocalIdentity separate `shouldBe` [2, 4]

testStaleBeforeNative ∷ Expectation
testStaleBeforeNative = do
  seam ← withTopology (laid 1 [(1, left), (2, centre)])
  ran ← newIORef (0 ∷ Int)
  (ended, staleResult, refresh, liveResult) ← inSession seam $ \session → do
    (ended, continuing) ← published session >>= described >>= twoOf
    seamSetMonitorTopology seam (laid 2 [(2, centre)])
    seamDeliverMonitorEvents seam [MonitorDetached 1]
    before ← length <$> seamCalls seam
    staleResult ←
      withResolvedMonitor session exampleOperation (monitorIdentity ended) $ \_ →
        atomicModifyIORef' ran (\count → (count + 1, ()))
    refresh ← drop before <$> seamCalls seam
    liveResult ←
      withResolvedMonitor session exampleOperation (monitorIdentity continuing) $ \_ →
        atomicModifyIORef' ran (\count → (count + 1, count + 1))
    pure (ended, staleResult, refresh, liveResult)
  staleResult `shouldBe` MonitorDisconnected (monitorIdentity ended)
  -- Resolution enumerated the current monitors, and nothing targeted the ended
  -- monitor's address.
  take 2 refresh `shouldBe` [QueryMonitors, QueryPrimaryMonitor]
  [call | call@(QueryMonitor 1 _) ← refresh] `shouldBe` []
  liveResult `shouldBe` MonitorAvailable 1
  readIORef ran `shouldReturn` 1

testAcrossSessions ∷ Expectation
testAcrossSessions = do
  seam ← withTopology (laid 1 [(1, left)])
  earlier ← inSession seam (\session → published session >>= identities)
  (later, resolved) ← inSession seam $ \session → do
    later ← published session >>= identities
    resolved ← mapM (resolveMonitor session) earlier
    pure (later, resolved)
  map monitorLocalIdentity earlier `shouldBe` [1]
  map monitorLocalIdentity later `shouldBe` [1]
  later `shouldNotBe` earlier
  resolved `shouldBe` map MonitorDisconnected earlier

-- ---------------------------------------------------------------------------
-- The monitor callback

testCallbackFault ∷ Expectation
testCallbackFault = do
  seam ← withTopology (laid 1 [(1, left), (2, centre)])
  (original, (fault, caught), after, stale, quiet) ← inSession seam $ \session → do
    original ← published session >>= identities
    seamDeliverMonitorEvents seam [MonitorEventRaises 2 (toException (ErrorCall "injected monitor callback fault"))]
    failed ← caughtAs (reconcileMonitorEvents session)
    after ← published session
    stale ← mapM (resolveMonitor session) original
    revision ← inventoryRevision <$> published session
    reconcileMonitorEvents session
    quiet ← (== revision) . inventoryRevision <$> published session
    pure (original, failed, after, stale, quiet)
  fault `shouldBe` ErrorCall "injected monitor callback fault"
  [operationName | (_, operationName, _) ← contextsOf caught] `shouldSatisfy` elem "monitor callback"
  -- The refresh the fault forced committed before the fault was rethrown.
  inventoryRevision after `shouldBe` 1
  renewed ← identities after
  map monitorLocalIdentity renewed `shouldBe` [3, 4]
  stale `shouldBe` map MonitorDisconnected original
  quiet `shouldBe` True

testLostChanges ∷ Expectation
testLostChanges = do
  seam ← withTopology (laid 1 [(1, left), (2, centre)])
  (original, overflowed, undefinedCode, unrelated) ← inSession seam $ \session → do
    original ← published session >>= identities
    seamDeliverMonitorEvents seam (replicate (monitorEventCapacity + 1) (MonitorAttached 7))
    reconcileMonitorEvents session
    overflowed ← published session >>= identities
    seamDeliverMonitorEvents seam [MonitorEventCode 1 0x7fff]
    reconcileMonitorEvents session
    undefinedCode ← published session >>= identities
    seamDeliverMonitorEvents seam (replicate monitorEventCapacity (MonitorAttached 7))
    reconcileMonitorEvents session
    unrelated ← published session
    pure (original, overflowed, undefinedCode, unrelated)
  map monitorLocalIdentity original `shouldBe` [1, 2]
  map monitorLocalIdentity overflowed `shouldBe` [3, 4]
  map monitorLocalIdentity undefinedCode `shouldBe` [5, 6]
  -- Changes within capacity for an address that is not enumerated end nothing.
  identities unrelated `shouldReturn` undefinedCode
  inventoryRevision unrelated `shouldBe` 2

testLateFault ∷ Expectation
testLateFault = do
  seam ← withTopology (laid 1 [(1, left)])
  (fault, caught) ←
    asProcessMainThread seam . caughtAs . entered seam $ \_ →
      seamDeliverMonitorEvents seam [MonitorEventRaises 1 (toException (ErrorCall "fault after the last boundary"))]
  fault `shouldBe` ErrorCall "fault after the last boundary"
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw monitor callback"]
  calls ← seamCalls seam
  drop (length calls - length teardownCalls) calls `shouldBe` teardownCalls
  seamLiveMonitorCallbacks seam `shouldReturn` 0
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

-- ---------------------------------------------------------------------------
-- Ownership and teardown

testOwnerThread ∷ Expectation
testOwnerThread = do
  seam ← withTopology (laid 1 [(1, left)])
  (synchronizing, resolving, readElsewhere, calls) ← inSession seam $ \session → do
    identity ← published session >>= identities >>= oneOf
    before ← length <$> seamCalls seam
    synchronizing ← onThread forkOS (fst <$> caughtAs (synchronizeMonitors session))
    resolving ← onThread forkOS (fst <$> caughtAs (resolveMonitor session identity))
    readElsewhere ← onThread forkIO (inventoryRevision <$> published session)
    calls ← drop before <$> seamCalls seam
    pure (synchronizing, resolving, readElsewhere, calls)
  synchronizing `shouldBe` NotSessionOwner
  resolving `shouldBe` NotSessionOwner
  readElsewhere `shouldBe` 0
  calls `shouldBe` []

testClose ∷ Expectation
testClose = do
  seam ← withTopology (laid 1 [(1, left)])
  waiter ← newEmptyMVar
  (reader, lastOpen) ← inSession seam $ \session → do
    observation ← atomically (readSnapshot (monitorInventory session))
    _ ← forkIO (atomically (awaitSnapshot (monitorInventory session) (observedCursor observation)) >>= putMVar waiter)
    pure (monitorInventory session, preparedValue (observedValue observation))
  final ←
    takeMVar waiter >>= \case
      Updated observation → pure observation
      EndOfStream → unexpected "the waiter saw the end of the inventory without its closed observation"
  let closed = preparedValue (observedValue final)
  inventoryPhase closed `shouldBe` InventoryClosed
  inventoryRevision closed `shouldBe` inventoryRevision lastOpen + 1
  inventoryMonitors closed `shouldBe` inventoryMonitors lastOpen
  atomically (awaitSnapshot reader (observedCursor final)) >>= \case
    EndOfStream → pure ()
    Updated _ → unexpected "the closed inventory published again"
  calls ← seamCalls seam
  [call | call ← calls, call `elem` teardownCalls] `shouldBe` teardownCalls
  seamLiveMonitorCallbacks seam `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Support

inSession ∷ Seam → (Session → IO a) → IO a
inSession seam = asProcessMainThread seam . entered seam

withTopology ∷ MonitorTopology → IO Seam
withTopology topology = newSeam defaultScript {scriptMonitorTopology = topology}

-- | A topology listing monitors by scripted address, with a primary address.
laid ∷ Int → [(Int, ScriptedMonitor)] → MonitorTopology
laid primary monitors = MonitorTopology (Just monitors) primary

left, centre, above ∷ ScriptedMonitor
left = scriptedMonitor "left" (-1920, 0) (1920, 1080)
centre = scriptedMonitor "centre" (0, 0) (2560, 1440)
above = scriptedMonitor "above" (320, -1200) (1600, 1200)

-- | The mode 'scriptedMonitor' scripts, as the model describes it.
mode ∷ Int → Int → VideoMode
mode width height = VideoMode width height (Observed 8) (Observed 8) (Observed 8) (Observed 60)

-- | The session's latest published inventory.
published ∷ Session → IO MonitorInventory
published session = preparedValue . observedValue <$> atomically (readSnapshot (monitorInventory session))

described ∷ MonitorInventory → IO [MonitorDescription]
described inventory = case inventoryMonitors inventory of
  Observed descriptions → pure descriptions
  Unavailable → unexpected "the inventory's monitors were unavailable"

identities ∷ MonitorInventory → IO [MonitorId]
identities inventory = map monitorIdentity <$> described inventory

oneOf ∷ [a] → IO a
oneOf = \case
  [only] → pure only
  found → unexpected ("expected one, found " <> show (length found))

twoOf ∷ [a] → IO (a, a)
twoOf = \case
  [first, second] → pure (first, second)
  found → unexpected ("expected two, found " <> show (length found))

exampleOperation ∷ Operation
exampleOperation = operation "monitor example"

-- | The native calls of a complete, safe session teardown, in order.
teardownCalls ∷ [NativeCall]
teardownCalls = [DetachMonitorCallback, Terminate, DetachErrorCallback, FreeErrorCallback, FreeMonitorCallback]
