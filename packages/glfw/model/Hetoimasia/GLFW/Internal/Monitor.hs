{-# LANGUAGE DeriveGeneric #-}

-- | The monitor inventory a session owns, written over the session's table of
-- native monitor operations.
--
-- The session constructs these pieces as stages of its own assembly and wraps
-- every operation in its owner-thread and liveness checks; see
-- "Hetoimasia.GLFW.Internal.Session". Nothing here checks the thread, and
-- nothing here is reachable outside the package.
--
-- = Inventory
--
-- A 'MonitorInventory' is one immutable observation of every connected monitor,
-- prepared to normal form and published through a latest-value snapshot. It
-- carries a revision equal to the snapshot's, an 'InventoryPhase', and the
-- monitors as copied 'MonitorDescription's. An empty list is an ordinary
-- observation of a desktop with no monitor. No description holds a native
-- pointer, and each stays readable, with its identity, after that monitor
-- disconnects.
--
-- A refresh, at an owner boundary, folds what the monitor callback captured,
-- enumerates the monitors GLFW currently reports, and queries each one. It
-- publishes a new revision only when a description or an identity changed.
--
-- = Identities
--
-- A 'MonitorId' is the session's identity and a local number the session never
-- reissues, issued once per connection. Between boundaries the session keeps,
-- for each connection, the monitor's native address as a private correlation
-- token beside its identity. A token is only ever compared; it is never turned
-- back into a pointer, and it grants no authority to call GLFW. At a refresh:
--
-- * a captured connection or disconnection for an address ends the identity
--   that address held, so a disconnect followed by a reconnect at the same
--   address before one boundary still yields a fresh identity;
-- * a lost change — more than 'monitorEventCapacity' changes before one
--   boundary, an event code GLFW does not define, or a fault in the callback —
--   ends every identity, because which connection it concerned is unknown;
-- * every monitor in the new enumeration whose address still holds an identity
--   keeps it, whatever its position in the enumeration, and every other one is
--   issued a fresh identity;
-- * an identity whose address is absent from the enumeration ends.
--
-- An ended identity never resolves again: resolution answers
-- 'MonitorDisconnected'. An identity from another session, including a
-- completed earlier one whose local numbers and addresses repeat, never
-- resolves either, because the session identity differs.
--
-- = Resolution
--
-- A live monitor pointer exists only within one owner boundary. Resolution
-- refreshes the inventory — which enumerates the current native monitors —
-- and answers the pointer that same enumeration returned for the identity, or
-- 'MonitorDisconnected' before any native operation targets the monitor. The
-- session lends that pointer to one operation and keeps nothing.
--
-- = Validation
--
-- Every native number is checked before it becomes an observed value, and an
-- inconsistent report becomes 'Unavailable' rather than a fabricated value:
--
-- * an enumeration whose count or array was inconsistent, or that lists a null
--   or repeated monitor, makes the inventory's monitors 'Unavailable' and ends
--   every identity;
-- * a primary monitor that is not in the enumeration makes every monitor's
--   primary attribute 'Unavailable'; no designated primary makes it 'False';
-- * a null name, a negative work area extent, a non-positive physical size, a
--   non-finite or non-positive content scale, a null current mode, or a video
--   mode list whose count was inconsistent or which holds a mode with a
--   non-positive width or height is 'Unavailable'; a negative bit depth or a
--   non-positive refresh rate is 'Unavailable' within its mode.
--
-- A desktop position may be negative or nonzero and is kept as reported. A
-- query that reports only @GLFW_FEATURE_UNAVAILABLE@ is 'Unavailable'; any other
-- report fails the boundary with 'NativeFailure'. No attribute assumes a
-- primary monitor, and nothing assumes the primary monitor starts at the
-- desktop origin.
--
-- = The callback
--
-- 'monitorCallback' is contained at the trampoline. It runs uninterruptibly,
-- copies the monitor's address and the event code, records them into the
-- capture latch with one non-blocking 'IORef' update, and returns. It calls no
-- application code and no native function, waits for nothing, and lets nothing
-- unwind into C. A fault is latched with its context, marks the captured
-- changes lost, and is rethrown at the next owner boundary, annotated with the
-- @monitor callback@ operation, once that boundary's refresh has committed.
--
-- A refresh reads the latch without clearing it. It clears what it folded only
-- in the masked commit that publishes, and only if no callback recorded
-- anything since the read, and it starts again otherwise. A cancellation or
-- failure before the commit leaves every capture latched and the inventory as
-- it was.
--
-- = State
--
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
-- | State               | Owner       | Readers and writers          | Thread           | Lifetime            | Reset or disposal            |
-- +=====================+=============+==============================+==================+=====================+==============================+
-- | Capture latch       | The session | The callback writes; owner   | Callback: inside | The session         | Cleared by each committed    |
-- |                     |             | boundaries fold and clear it | owner calls;     |                     | refresh; a fault is taken    |
-- |                     |             |                              | folds: owner     |                     | when rethrown                |
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
-- | Identity counter    | The session | Refreshes issue from it      | Owner            | The session         | Never reissued               |
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
-- | Connections and     | The session | Committed refreshes write;   | Owner            | The session         | Emptied when the inventory   |
-- | current inventory   |             | resolution reads             |                  |                     | closes                       |
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
-- | Inventory snapshot  | The session | The owner publishes and      | Publish: owner;  | While referenced    | Closed holding the last      |
-- |                     |             | closes; readers read         | read: any        |                     | descriptions; never reopened |
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
-- | Inventory liveness  | The session | Closing clears it; every     | Owner            | The session         | Never set again              |
-- |                     |             | operation reads it           |                  |                     |                              |
-- +---------------------+-------------+------------------------------+------------------+---------------------+------------------------------+
--
-- None of this is application state.
module Hetoimasia.GLFW.Internal.Monitor
  ( -- * Native monitor operations
    MonitorNative (..)
  , NativeMonitor
  , NativeVideoMode (..)
  , MonitorCallback
  , MonitorCallbackStorage (..)

    -- * Identities
  , MonitorId
  , monitorLocalIdentity

    -- * Observations
  , MonitorInventory
  , inventoryRevision
  , inventoryPhase
  , inventoryMonitors
  , InventoryPhase (..)
  , MonitorDescription
  , monitorIdentity
  , monitorName
  , monitorPrimary
  , monitorPosition
  , monitorWorkArea
  , monitorPhysicalSize
  , monitorContentScale
  , monitorCurrentMode
  , monitorVideoModes
  , MonitorPosition (..)
  , WorkArea (..)
  , PhysicalSize (..)
  , VideoMode (..)
  , MonitorResult (..)

    -- * Construction, for the session's assembly
  , MonitorSource
  , newMonitorSource
  , monitorCallback
  , monitorEventCapacity
  , InitialInventory
  , sampleInitialInventory
  , MonitorCell
  , newMonitorCell
  , publishInitialInventory
  , Monitors
  , assembleMonitors
  , MonitorCallbackFault
  , takeMonitorFault
  , rethrowMonitorFault

    -- * Operations, for the session's owner checks
  , monitorsReader
  , synchronizeInventory
  , reconcileInventory
  , resolveInventory
  , closeInventory
  , liveIdentities
  , currentMonitors
  , identifyPointer

    -- * Operation names
  , sampleMonitorsOperation
  , monitorCallbackOperation
  ) where

import Control.Concurrent.STM (atomically)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( ExceptionWithContext
  , SomeException
  , evaluate
  , mask_
  , rethrowIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, void, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique)
import Foreign.C.Types (CFloat, CInt)
import Foreign.Ptr (FunPtr, IntPtr, Ptr, nullPtr, ptrToIntPtr)
import GHC.Generics (Generic)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( SnapshotPublisher
  , SnapshotReader
  , closeSnapshot
  , newSnapshot
  , publish
  , snapshotReader
  )
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..))
import Hetoimasia.GLFW.Internal.Capture
  ( Capture
  , NativeError (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , Reports (..)
  , glfwComponent
  , hasReports
  , settleStrayOwnerReports
  , takeOwnerReports
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Native monitor operations

-- | GLFW's opaque monitor object. A pointer to it never leaves this package.
data NativeMonitor

-- | The shape of GLFW's monitor callback: the monitor and the event code.
type MonitorCallback = Ptr NativeMonitor → CInt → IO ()

-- | The storage behind an installed monitor callback.
newtype MonitorCallbackStorage = MonitorCallbackStorage (FunPtr MonitorCallback)
  deriving (Eq)

-- | One @GLFWvidmode@, copied field by field as GLFW reported it.
data NativeVideoMode = NativeVideoMode
  { nativeModeWidth ∷ !CInt
  , nativeModeHeight ∷ !CInt
  , nativeModeRedBits ∷ !CInt
  , nativeModeGreenBits ∷ !CInt
  , nativeModeBlueBits ∷ !CInt
  , nativeModeRefreshRate ∷ !CInt
  }
  deriving (Eq, Show)

-- | Every native monitor operation the inventory performs. Each copies what
-- GLFW returned before it returns, so no GLFW-owned array or string outlives
-- the call.
data MonitorNative = MonitorNative
  { nativeMonitors ∷ IO (Maybe [Ptr NativeMonitor])
    -- ^ Every connected monitor, in GLFW's order. 'Nothing' when the reported
    -- count was negative, or positive beside a null array.
  , nativePrimaryMonitor ∷ IO (Ptr NativeMonitor)
    -- ^ Null when the platform designates none.
  , nativeMonitorName ∷ Ptr NativeMonitor → IO (Maybe Text)
    -- ^ 'Nothing' for a null name.
  , nativeMonitorPosition ∷ Ptr NativeMonitor → IO (CInt, CInt)
  , nativeMonitorWorkArea ∷ Ptr NativeMonitor → IO (CInt, CInt, CInt, CInt)
    -- ^ Position, then width and height.
  , nativeMonitorPhysicalSize ∷ Ptr NativeMonitor → IO (CInt, CInt)
    -- ^ In millimetres.
  , nativeMonitorContentScale ∷ Ptr NativeMonitor → IO (CFloat, CFloat)
  , nativeMonitorCurrentMode ∷ Ptr NativeMonitor → IO (Maybe NativeVideoMode)
    -- ^ 'Nothing' for a null mode.
  , nativeMonitorVideoModes ∷ Ptr NativeMonitor → IO (Maybe [NativeVideoMode])
    -- ^ 'Nothing' when the reported count was negative, or positive beside a
    -- null array.
  , nativeNewMonitorCallback ∷ MonitorCallback → IO MonitorCallbackStorage
    -- ^ Allocate callback storage; changes no native state.
  , nativeAttachMonitorCallback ∷ MonitorCallbackStorage → IO ()
  , nativeDetachMonitorCallback ∷ IO ()
  , nativeFreeMonitorCallback ∷ MonitorCallbackStorage → IO ()
  , nativeMonitorConnected ∷ !CInt
    -- ^ @GLFW_CONNECTED@.
  , nativeMonitorDisconnected ∷ !CInt
    -- ^ @GLFW_DISCONNECTED@.
  }

-- ---------------------------------------------------------------------------
-- Identities and observations

-- | A monitor connection's identity: its session's identity and a local number
-- that session never reissues. Only the local number is displayed.
data MonitorId = MonitorId !Unique !Natural
  deriving (Eq, Ord)

instance Show MonitorId where
  showsPrec precedence (MonitorId _ local) =
    showParen (precedence > 10) (showString "MonitorId " . showsPrec 11 local)

instance NFData MonitorId where
  rnf (MonitorId identity local) = identity `seq` rnf local

-- | The identity's number within its session, starting at one.
monitorLocalIdentity ∷ MonitorId → Natural
monitorLocalIdentity (MonitorId _ local) = local

-- | A monitor's upper-left corner in desktop screen coordinates. Either
-- coordinate may be negative.
data MonitorPosition = MonitorPosition
  { monitorX ∷ !Int
  , monitorY ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData MonitorPosition

-- | The area of a monitor not occupied by the platform's own bars and docks, in
-- desktop screen coordinates.
data WorkArea = WorkArea
  { workAreaX ∷ !Int
  , workAreaY ∷ !Int
  , workAreaWidth ∷ !Int
  , workAreaHeight ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData WorkArea

-- | A monitor's display area in millimetres.
data PhysicalSize = PhysicalSize
  { physicalWidth ∷ !Int
  , physicalHeight ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData PhysicalSize

-- | One video mode: its size in screen coordinates, bit depths, and refresh
-- rate in hertz.
data VideoMode = VideoMode
  { modeWidth ∷ !Int
  , modeHeight ∷ !Int
  , modeRedBits ∷ !(Attribute Int)
  , modeGreenBits ∷ !(Attribute Int)
  , modeBlueBits ∷ !(Attribute Int)
  , modeRefreshRate ∷ !(Attribute Int)
  }
  deriving (Eq, Show, Generic)

instance NFData VideoMode

-- | Whether the inventory is still being published.
data InventoryPhase
  = InventoryOpen
    -- ^ The session is live and refreshes publish here.
  | InventoryClosed
    -- ^ The session has ended: every identity has ended, and the descriptions
    -- are the last ones observed.
  deriving (Eq, Show, Generic)

instance NFData InventoryPhase

-- | One copied description of a connected monitor. Its representation is
-- private, so no description is ever built outside this package.
data MonitorDescription = MonitorDescription
  { descIdentity ∷ !MonitorId
  , descName ∷ !(Attribute Text)
  , descPrimary ∷ !(Attribute Bool)
  , descPosition ∷ !(Attribute MonitorPosition)
  , descWorkArea ∷ !(Attribute WorkArea)
  , descPhysicalSize ∷ !(Attribute PhysicalSize)
  , descContentScale ∷ !(Attribute ContentScale)
  , descCurrentMode ∷ !(Attribute VideoMode)
  , descVideoModes ∷ !(Attribute [VideoMode])
  }
  deriving (Eq, Show)

instance NFData MonitorDescription where
  rnf description =
    rnf (descIdentity description)
      `seq` rnf (descName description)
      `seq` rnf (descPrimary description)
      `seq` rnf (descPosition description)
      `seq` rnf (descWorkArea description)
      `seq` rnf (descPhysicalSize description)
      `seq` rnf (descContentScale description)
      `seq` rnf (descCurrentMode description)
      `seq` rnf (descVideoModes description)

-- | The connection this description was observed for.
monitorIdentity ∷ MonitorDescription → MonitorId
monitorIdentity = descIdentity

-- | The monitor's human-readable name, which need not be unique.
monitorName ∷ MonitorDescription → Attribute Text
monitorName = descName

-- | Whether the platform designates this monitor as its primary one.
monitorPrimary ∷ MonitorDescription → Attribute Bool
monitorPrimary = descPrimary

monitorPosition ∷ MonitorDescription → Attribute MonitorPosition
monitorPosition = descPosition

monitorWorkArea ∷ MonitorDescription → Attribute WorkArea
monitorWorkArea = descWorkArea

monitorPhysicalSize ∷ MonitorDescription → Attribute PhysicalSize
monitorPhysicalSize = descPhysicalSize

monitorContentScale ∷ MonitorDescription → Attribute ContentScale
monitorContentScale = descContentScale

monitorCurrentMode ∷ MonitorDescription → Attribute VideoMode
monitorCurrentMode = descCurrentMode

-- | Every video mode the monitor supports, in GLFW's order.
monitorVideoModes ∷ MonitorDescription → Attribute [VideoMode]
monitorVideoModes = descVideoModes

-- | One immutable observation of the connected monitors. Its representation is
-- private, so no inventory is ever built outside this package.
data MonitorInventory = MonitorInventory
  { invRevision ∷ !Natural
  , invPhase ∷ !InventoryPhase
  , invMonitors ∷ !(Attribute [MonitorDescription])
  }
  deriving (Eq, Show)

instance NFData MonitorInventory where
  rnf inventory =
    rnf (invRevision inventory) `seq` rnf (invPhase inventory) `seq` rnf (invMonitors inventory)

-- | The inventory's revision: zero for the initial observation, and the
-- snapshot's revision for every later one.
inventoryRevision ∷ MonitorInventory → Natural
inventoryRevision = invRevision

inventoryPhase ∷ MonitorInventory → InventoryPhase
inventoryPhase = invPhase

-- | Every connected monitor, in the order GLFW enumerated them. An empty list
-- is an observation of no connected monitor; 'Unavailable' is an enumeration
-- that was not consistent.
inventoryMonitors ∷ MonitorInventory → Attribute [MonitorDescription]
inventoryMonitors = invMonitors

-- | What resolving a monitor identity produced.
data MonitorResult a
  = MonitorAvailable a
  | MonitorDisconnected !MonitorId
    -- ^ The identity's connection has ended, or belongs to another session. No
    -- native operation targeted the monitor.
  deriving (Eq, Show)

sampleMonitorsOperation, monitorCallbackOperation ∷ Operation
sampleMonitorsOperation = operation "sample monitors"
-- | The operation a rethrown monitor callback fault is annotated with.
monitorCallbackOperation = operation "monitor callback"

-- ---------------------------------------------------------------------------
-- Capture

-- | What the callback recorded since the last committed refresh.
data MonitorCaptures = MonitorCaptures
  { capturedChanges ∷ ![IntPtr]
    -- ^ The addresses of monitors whose connection changed, newest first.
  , capturedKept ∷ !Int
  , capturedLost ∷ !Bool
    -- ^ A change was not kept: capacity was exceeded, the event code was not
    -- one GLFW defines, or the callback faulted.
  , capturedFault ∷ !(Maybe MonitorCallbackFault)
  , capturedGeneration ∷ !Natural
    -- ^ Advanced by every record, so a commit can tell whether the callback
    -- recorded anything since the captures it folded were read.
  }

-- | The first fault the callback raised since it was last rethrown, and how
-- many later faults were not kept.
data MonitorCallbackFault = MonitorCallbackFault !(ExceptionWithContext SomeException) !Natural

noCaptures ∷ MonitorCaptures
noCaptures = MonitorCaptures [] 0 False Nothing 0

-- | How many connection changes one boundary keeps before the rest are lost,
-- which ends every identity at the next refresh.
monitorEventCapacity ∷ Int
monitorEventCapacity = 64

-- | What the inventory reads and issues from, available before the callback is
-- attached.
data MonitorSource = MonitorSource
  { sourceNative ∷ !MonitorNative
  , sourceCapture ∷ !Capture
  , sourceFeatureUnavailable ∷ !Int
  , sourceSession ∷ !Unique
  , sourceCounter ∷ !(IORef Natural)
  , sourceCaptures ∷ !(IORef MonitorCaptures)
  }

-- | A source with an empty latch and identities starting at one.
newMonitorSource ∷ MonitorNative → Capture → Int → Unique → IO MonitorSource
newMonitorSource native capture unavailable session =
  MonitorSource native capture unavailable session <$> newIORef 1 <*> newIORef noCaptures

-- | The contained monitor callback recording into the source's latch.
--
-- The payload is copied, and every field forced, inside the handler; the record
-- is one non-blocking update. Anything raised is latched with its context
-- rather than unwinding into C, and a failure to latch it is dropped for the
-- same reason.
monitorCallback ∷ MonitorSource → MonitorCallback
monitorCallback source monitor event = uninterruptibleMask_ $ do
  outcome ← tryWithContext $ do
    token ← evaluate (ptrToIntPtr monitor)
    code ← evaluate event
    pure $ \latched →
      if code == nativeMonitorConnected native || code == nativeMonitorDisconnected native
        then changed token latched
        else latched {capturedLost = True}
  case outcome of
    Right change → record change
    Left caught → do
      latched ← try (record (latchFault caught))
      either (\(_ ∷ SomeException) → pure ()) pure latched
  where
    native = sourceNative source
    record change =
      atomicModifyIORef' (sourceCaptures source) $ \latched →
        let recorded = change latched
         in (recorded {capturedGeneration = capturedGeneration latched + 1}, ())
    changed token latched
      | capturedKept latched < monitorEventCapacity =
          latched {capturedChanges = token : capturedChanges latched, capturedKept = capturedKept latched + 1}
      | otherwise = latched {capturedLost = True}

latchFault ∷ ExceptionWithContext SomeException → MonitorCaptures → MonitorCaptures
latchFault caught latched =
  latched
    { capturedLost = True
    , capturedFault = Just $ case capturedFault latched of
        Nothing → MonitorCallbackFault caught 0
        Just (MonitorCallbackFault first later) → MonitorCallbackFault first (later + 1)
    }

-- | Take a latched callback fault, if any.
takeMonitorFault ∷ MonitorSource → IO (Maybe MonitorCallbackFault)
takeMonitorFault source =
  atomicModifyIORef' (sourceCaptures source) (\latched → (latched {capturedFault = Nothing}, capturedFault latched))

-- | Rethrow a latched callback fault with its own type and context. A
-- synchronous fault gains the callback operation's context; cancellation is
-- rethrown as it was.
rethrowMonitorFault ∷ MonitorCallbackFault → IO a
rethrowMonitorFault (MonitorCallbackFault caught later) =
  withOperationContext
    glfwComponent
    monitorCallbackOperation
    [("callback", "monitor"), ("later-faults", Text.pack (show later))]
    (rethrowIO caught)

-- | Take a latched fault and rethrow it in one masked step, so a cancellation
-- cannot discard it between the take and the rethrow.
raiseMonitorFault ∷ MonitorSource → IO ()
raiseMonitorFault source = mask_ (takeMonitorFault source >>= mapM_ rethrowMonitorFault)

-- ---------------------------------------------------------------------------
-- Refreshing

-- | One refresh, sampled and not yet committed.
data Refresh = Refresh
  { refreshGeneration ∷ !Natural
    -- ^ The latch generation the refresh folded.
  , refreshConnections ∷ !(Map IntPtr MonitorId)
  , refreshMonitors ∷ !(Attribute [MonitorDescription])
  , refreshPointers ∷ ![(MonitorId, Ptr NativeMonitor)]
    -- ^ The live pointers this boundary's enumeration returned. Never kept
    -- beyond the boundary.
  }

-- | Sample one query, bracketed by the error capture.
sampled ∷ MonitorSource → [(Text, Text)] → IO a → IO (Attribute a)
sampled source identifiers query = do
  settleStrayOwnerReports capture
  value ← query
  reports ← takeOwnerReports capture
  if not (hasReports reports)
    then Observed <$> evaluate value
    else
      if onlyUnavailable reports
        then pure Unavailable
        else throwFailure glfwComponent sampleMonitorsOperation identifiers (NativeFailure NativeCallReturned reports)
  where
    capture = sourceCapture source
    onlyUnavailable reports =
      reportsLost reports == 0
        && callbackFaults reports == 0
        && all ((== sourceFeatureUnavailable source) . nativeErrorCode) (reportedErrors reports)

-- | Fold the latched changes into the connections, enumerate, and describe
-- every monitor, without committing anything.
planRefresh ∷ MonitorSource → Map IntPtr MonitorId → IO Refresh
planRefresh source connections = do
  pending ← readIORef (sourceCaptures source)
  let continuing
        | capturedLost pending = Map.empty
        | otherwise = foldr Map.delete connections (capturedChanges pending)
      unavailable = Refresh (capturedGeneration pending) Map.empty Unavailable []
  listed ← sampled source [] (nativeMonitors native)
  case listed of
    Observed (Just pointers) | consistent pointers → do
      primary ← sampled source [] (nativePrimaryMonitor native)
      identified ← forM pointers $ \pointer → do
        let token = ptrToIntPtr pointer
        identity ← maybe (issueIdentity source) pure (Map.lookup token continuing)
        pure (token, identity, pointer)
      descriptions ←
        forM identified $ \(_, identity, pointer) →
          describe source (primaryOf primary pointers pointer) identity pointer
      pure
        Refresh
          { refreshGeneration = capturedGeneration pending
          , refreshConnections = Map.fromList [(token, identity) | (token, identity, _) ← identified]
          , refreshMonitors = Observed descriptions
          , refreshPointers = [(identity, pointer) | (_, identity, pointer) ← identified]
          }
    _ → pure unavailable
  where
    native = sourceNative source
    consistent pointers =
      nullPtr `notElem` pointers && Map.size (Map.fromList [(ptrToIntPtr pointer, ()) | pointer ← pointers]) == length pointers

issueIdentity ∷ MonitorSource → IO MonitorId
issueIdentity source =
  MonitorId (sourceSession source) <$> atomicModifyIORef' (sourceCounter source) (\next → (next + 1, next))

primaryOf ∷ Attribute (Ptr NativeMonitor) → [Ptr NativeMonitor] → Ptr NativeMonitor → Attribute Bool
primaryOf Unavailable _ _ = Unavailable
primaryOf (Observed primary) pointers pointer
  | primary == nullPtr = Observed False
  | primary `elem` pointers = Observed (primary == pointer)
  | otherwise = Unavailable

-- | Query and validate one monitor's description.
describe ∷ MonitorSource → Attribute Bool → MonitorId → Ptr NativeMonitor → IO MonitorDescription
describe source primary identity pointer = do
  name ← validated id <$> query (nativeMonitorName native pointer)
  position ← validated validPosition <$> query (nativeMonitorPosition native pointer)
  workArea ← validated validWorkArea <$> query (nativeMonitorWorkArea native pointer)
  physical ← validated validPhysicalSize <$> query (nativeMonitorPhysicalSize native pointer)
  scale ← validated validContentScale <$> query (nativeMonitorContentScale native pointer)
  current ← validated (>>= validVideoMode) <$> query (nativeMonitorCurrentMode native pointer)
  modes ← validated (>>= traverse validVideoMode) <$> query (nativeMonitorVideoModes native pointer)
  pure
    MonitorDescription
      { descIdentity = identity
      , descName = name
      , descPrimary = primary
      , descPosition = position
      , descWorkArea = workArea
      , descPhysicalSize = physical
      , descContentScale = scale
      , descCurrentMode = current
      , descVideoModes = modes
      }
  where
    native = sourceNative source
    query ∷ IO a → IO (Attribute a)
    query = sampled source [("monitor", Text.pack (show (monitorLocalIdentity identity)))]

validated ∷ (a → Maybe b) → Attribute a → Attribute b
validated check = \case
  Observed value → maybe Unavailable Observed (check value)
  Unavailable → Unavailable

validPosition ∷ (CInt, CInt) → Maybe MonitorPosition
validPosition (x, y) = Just (MonitorPosition (fromIntegral x) (fromIntegral y))

validWorkArea ∷ (CInt, CInt, CInt, CInt) → Maybe WorkArea
validWorkArea (x, y, width, height)
  | width >= 0 && height >= 0 =
      Just (WorkArea (fromIntegral x) (fromIntegral y) (fromIntegral width) (fromIntegral height))
  | otherwise = Nothing

validPhysicalSize ∷ (CInt, CInt) → Maybe PhysicalSize
validPhysicalSize (width, height)
  | width > 0 && height > 0 = Just (PhysicalSize (fromIntegral width) (fromIntegral height))
  | otherwise = Nothing

-- | Checked on the C value, before any conversion that could disguise a NaN.
validContentScale ∷ (CFloat, CFloat) → Maybe ContentScale
validContentScale (x, y) = ContentScale <$> axis x <*> axis y
  where
    axis value
      | isNaN value || isInfinite value || value <= 0 = Nothing
      | otherwise = Just (realToFrac value)

validVideoMode ∷ NativeVideoMode → Maybe VideoMode
validVideoMode mode
  | nativeModeWidth mode > 0 && nativeModeHeight mode > 0 =
      Just
        VideoMode
          { modeWidth = fromIntegral (nativeModeWidth mode)
          , modeHeight = fromIntegral (nativeModeHeight mode)
          , modeRedBits = depth (nativeModeRedBits mode)
          , modeGreenBits = depth (nativeModeGreenBits mode)
          , modeBlueBits = depth (nativeModeBlueBits mode)
          , modeRefreshRate =
              if nativeModeRefreshRate mode > 0 then Observed (fromIntegral (nativeModeRefreshRate mode)) else Unavailable
          }
  | otherwise = Nothing
  where
    depth bits = if bits >= 0 then Observed (fromIntegral bits) else Unavailable

-- | Plan a refresh, prepare what it commits, and commit it masked if the latch
-- is unchanged since the plan read it, clearing what was folded; start again
-- otherwise. Once committed, a latched callback fault is rethrown.
settleRefresh ∷ MonitorSource → Map IntPtr MonitorId → (Refresh → IO (r, IO ())) → IO r
settleRefresh source connections prepareCommit = do
  plan ← planRefresh source connections
  (result, commit) ← prepareCommit plan
  committed ← mask_ $ do
    cleared ← atomicModifyIORef' (sourceCaptures source) $ \latched →
      if capturedGeneration latched == refreshGeneration plan
        then (noCaptures {capturedGeneration = capturedGeneration latched, capturedFault = capturedFault latched}, True)
        else (latched, False)
    when cleared commit
    pure cleared
  if committed
    then result <$ raiseMonitorFault source
    else settleRefresh source connections prepareCommit

-- ---------------------------------------------------------------------------
-- The inventory

-- | The first refresh, sampled before the inventory's snapshot exists.
data InitialInventory = InitialInventory !(Map IntPtr MonitorId) !MonitorInventory !(Prepared MonitorInventory)

-- | Sample and prepare revision zero, folding anything captured since the
-- callback was attached.
sampleInitialInventory ∷ MonitorSource → IO InitialInventory
sampleInitialInventory source =
  settleRefresh source Map.empty $ \plan → do
    let inventory = MonitorInventory 0 InventoryOpen (refreshMonitors plan)
    prepared ← prepare inventory
    pure (InitialInventory (refreshConnections plan) inventory prepared, pure ())

data MonitorState = MonitorState !(Map IntPtr MonitorId) !MonitorInventory

-- | The owner's connections and current inventory, and the inventory's liveness.
data MonitorCell = MonitorCell !(IORef MonitorState) !(IORef Bool)

newMonitorCell ∷ InitialInventory → IO MonitorCell
newMonitorCell (InitialInventory connections inventory _) =
  MonitorCell <$> newIORef (MonitorState connections inventory) <*> newIORef True

-- | Create the inventory's snapshot, holding revision zero.
publishInitialInventory ∷ InitialInventory → IO (SnapshotPublisher MonitorInventory)
publishInitialInventory (InitialInventory _ _ prepared) = newSnapshot prepared

-- | The inventory a session owns.
data Monitors = Monitors
  { monitorsSource ∷ !MonitorSource
  , monitorsCell ∷ !MonitorCell
  , monitorsPublisher ∷ !(SnapshotPublisher MonitorInventory)
  }

assembleMonitors ∷ MonitorSource → MonitorCell → SnapshotPublisher MonitorInventory → Monitors
assembleMonitors = Monitors

-- | The read endpoint of the inventory. It stays readable after the session
-- ends, holding the closed inventory.
monitorsReader ∷ Monitors → SnapshotReader MonitorInventory
monitorsReader = snapshotReader . monitorsPublisher

inventoryLive ∷ Monitors → IO Bool
inventoryLive monitors = let MonitorCell _ live = monitorsCell monitors in readIORef live

currentInventory ∷ Monitors → IO MonitorInventory
currentInventory monitors = do
  let MonitorCell state _ = monitorsCell monitors
  MonitorState _ inventory ← readIORef state
  pure inventory

-- | Refresh, publish a new revision if a description or an identity changed,
-- and answer the refresh and the inventory it left current.
refreshInventory ∷ Monitors → IO (Refresh, MonitorInventory)
refreshInventory monitors = do
  MonitorState connections current ← readIORef state
  settleRefresh (monitorsSource monitors) connections $ \plan → do
    let changed = connections /= refreshConnections plan || invMonitors current /= refreshMonitors plan
        next = current {invRevision = invRevision current + 1, invMonitors = refreshMonitors plan}
    if changed
      then do
        prepared ← prepare next
        pure
          ( (plan, next)
          , do
              void (atomically (publish (monitorsPublisher monitors) prepared))
              writeIORef state (MonitorState (refreshConnections plan) next)
          )
      else pure ((plan, current), pure ())
  where
    MonitorCell state _ = monitorsCell monitors

-- | Refresh and answer the current inventory. A closed inventory answers its
-- last observation without a native call.
synchronizeInventory ∷ Monitors → IO MonitorInventory
synchronizeInventory monitors = do
  live ← inventoryLive monitors
  if live then snd <$> refreshInventory monitors else currentInventory monitors

-- | Refresh only if the callback captured anything since the last committed
-- refresh.
reconcileInventory ∷ Monitors → IO ()
reconcileInventory monitors = do
  live ← inventoryLive monitors
  pending ← readIORef (sourceCaptures (monitorsSource monitors))
  when (live && (capturedKept pending > 0 || capturedLost pending || isJust (capturedFault pending))) $
    void (refreshInventory monitors)

-- | Refresh, then answer the identity's description and the live pointer this
-- boundary's enumeration returned for it, or 'MonitorDisconnected'. The pointer
-- must not outlive the calling boundary.
resolveInventory ∷ Monitors → MonitorId → IO (MonitorResult (MonitorDescription, Ptr NativeMonitor))
resolveInventory monitors identity = do
  live ← inventoryLive monitors
  if not live
    then pure (MonitorDisconnected identity)
    else do
      (plan, inventory) ← refreshInventory monitors
      let described = case invMonitors inventory of
            Observed descriptions → find ((== identity) . descIdentity) descriptions
            Unavailable → Nothing
      pure $ case (described, lookup identity (refreshPointers plan)) of
        (Just description, Just pointer) → MonitorAvailable (description, pointer)
        _ → MonitorDisconnected identity

-- | The identities of the connections the last committed refresh observed:
-- none once the inventory has closed. It makes no native call.
liveIdentities ∷ Monitors → IO [MonitorId]
liveIdentities monitors = do
  live ← inventoryLive monitors
  let MonitorCell state _ = monitorsCell monitors
  MonitorState connections _ ← readIORef state
  pure (if live then Map.elems connections else [])

-- | The monitors of the current inventory, without a refresh.
currentMonitors ∷ Monitors → IO (Attribute [MonitorDescription])
currentMonitors = fmap invMonitors . currentInventory

-- | The identity a monitor pointer a window query just returned stands for:
-- 'Observed' 'Nothing' for a null pointer, the identity whose connection holds
-- that address, or 'Unavailable' when no current connection holds it, when the
-- callback has captured a change no refresh has folded yet, or once the
-- inventory has closed. The pointer is only compared; it makes no native call.
identifyPointer ∷ Monitors → Ptr NativeMonitor → IO (Attribute (Maybe MonitorId))
identifyPointer monitors pointer
  | pointer == nullPtr = pure (Observed Nothing)
  | otherwise = do
      live ← inventoryLive monitors
      pending ← readIORef (sourceCaptures (monitorsSource monitors))
      let MonitorCell state _ = monitorsCell monitors
      MonitorState connections _ ← readIORef state
      let settled = capturedKept pending == 0 && not (capturedLost pending) && isNothing (capturedFault pending)
      pure $
        if live && settled
          then maybe Unavailable (Observed . Just) (Map.lookup (ptrToIntPtr pointer) connections)
          else Unavailable

-- | End the inventory: every identity ends, and the last descriptions are
-- published as the closed inventory before the snapshot is closed, in one
-- transaction. It makes no native call.
closeInventory ∷ MonitorCell → SnapshotPublisher MonitorInventory → IO ()
closeInventory (MonitorCell state live) publisher = do
  atomicWriteIORef live False
  MonitorState _ current ← readIORef state
  let final = current {invRevision = invRevision current + 1, invPhase = InventoryClosed}
  prepared ← prepare final
  atomically (publish publisher prepared >> closeSnapshot publisher)
  writeIORef state (MonitorState Map.empty final)
