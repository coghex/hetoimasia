-- | The shared session's monitor inventory, against the display server the run
-- is on.
--
-- The inventory examples assert only what the display actually exposes. On the
-- isolated X11 display that is the one monitor Xvfb's single screen provides,
-- whose geometry @tools/display/x11.sh@ fixes; on Cocoa it is whatever displays
-- the machine has, which the first example prints as the run's topology record.
-- Physical attach and detach cannot be simulated on Xvfb, and no automated run
-- can perform one on a Mac: that example is recorded as unexercised unless
-- @HETOIMASIA_MONITOR_HOTPLUG_SECONDS@ asks for an interactive run, in which a
-- person attaches or detaches a display within that many seconds.
module Test.GLFW.Native.Monitor (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, unless, when)
import Data.List (intercalate)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Internal.Native (waitEventsForCheck)
import Hetoimasia.GLFW.Internal.Session (reconcileMonitorEvents, withResolvedMonitor)
import Hetoimasia.GLFW.Monitor
import System.Environment (lookupEnv)
import System.IO (hFlush, stdout)
import System.Info (os)
import Test.GLFW.Native.Support (Shared (..), failed, onOwnerThread, owned, threadFacts)
import Test.Hspec (Spec, describe, it, pendingWith, shouldBe, shouldSatisfy)
import Text.Read (readMaybe)

spec ∷ Shared → Spec
spec shared = describe "the monitor inventory" $ do
  it "publishes the monitors the display server exposes, one 1280 by 1024 monitor at the origin on the isolated X11 display" $ do
    (synchronized, reader) ← owned shared $ \session → (,) <$> synchronizeMonitors session <*> pure (monitorInventory session)
    latest ← preparedValue . observedValue <$> atomically (readSnapshot reader)
    inventoryRevision latest `shouldBe` inventoryRevision synchronized
    inventoryPhase latest `shouldBe` InventoryOpen
    descriptions ← monitorsOf synchronized
    putStrLn ("glfw-native-tests monitor topology on " <> os <> ": " <> topology descriptions)
    hFlush stdout
    descriptions `shouldSatisfy` (not . null)
    length [() | Observed True ← map monitorPrimary descriptions] `shouldBe` 1
    when (os == "linux") $ do
      map monitorPosition descriptions `shouldBe` [Observed (MonitorPosition 0 0)]
      map (modeSize . monitorCurrentMode) descriptions `shouldBe` [Just (1280, 1024)]

  it "re-resolves every identity to a live monitor on the owner thread, keeping identities across refreshes" $ do
    (first, second, lent, resolved) ← owned shared $ \session → do
      first ← synchronizeMonitors session
      second ← synchronizeMonitors session
      identities ← map monitorIdentity <$> monitorsOf first
      lent ←
        forM identities $ \identity →
          withResolvedMonitor session (operation "resolve monitor for check") identity $ \_ →
            threadFacts (sharedEvidence shared)
      resolved ← mapM (resolveMonitor session) identities
      pure (first, second, lent, resolved)
    identities ← map monitorIdentity <$> monitorsOf first
    map monitorIdentity <$> monitorsOf second >>= (`shouldBe` identities)
    inventoryRevision second `shouldBe` inventoryRevision first
    lent `shouldSatisfy` all (\case MonitorAvailable facts → onOwnerThread facts; MonitorDisconnected _ → False)
    [monitorIdentity description | MonitorAvailable description ← resolved] `shouldBe` identities

  it "observes a physical attach or detach as ended identities and a refreshed inventory, when a person performs one" $
    lookupEnv "HETOIMASIA_MONITOR_HOTPLUG_SECONDS" >>= \case
      Nothing →
        pendingWith
          ( "unexercised on "
              <> os
              <> ": no automated run can attach or detach a display, and Xvfb cannot simulate it; set"
              <> " HETOIMASIA_MONITOR_HOTPLUG_SECONDS and attach or detach one during the run to exercise it"
          )
      Just requested → do
        seconds ← maybe (failed ("HETOIMASIA_MONITOR_HOTPLUG_SECONDS is not a number of seconds: " <> requested)) pure (readMaybe requested)
        before ← owned shared synchronizeMonitors
        original ← map monitorIdentity <$> monitorsOf before
        putStrLn ("glfw-native-tests: attach or detach a display within " <> show (seconds ∷ Int) <> " seconds")
        hFlush stdout
        let attempts = seconds * 4
            await attempt
              | attempt >= attempts = failed ("no monitor change was observed within " <> show seconds <> " seconds")
              | otherwise = do
                  after ← owned shared $ \session → do
                    waitEventsForCheck 0.25
                    reconcileMonitorEvents session
                    preparedValue . observedValue <$> atomically (readSnapshot (monitorInventory session))
                  if inventoryRevision after == inventoryRevision before then await (attempt + 1 ∷ Int) else pure after
        after ← await 0
        current ← monitorsOf after
        resolved ← owned shared $ \session → mapM (resolveMonitor session) original
        let ended = [identity | MonitorDisconnected identity ← resolved]
        putStrLn
          ( "glfw-native-tests monitor change: before "
              <> show original
              <> ", after "
              <> topology current
              <> ", ended "
              <> show ended
          )
        hFlush stdout
        unless (not (null ended) || length current > length original) $
          failed "the inventory changed without ending an identity or adding a monitor"

monitorsOf ∷ MonitorInventory → IO [MonitorDescription]
monitorsOf inventory = case inventoryMonitors inventory of
  Observed descriptions → pure descriptions
  Unavailable → failed "the platform's monitor enumeration was inconsistent"

modeSize ∷ Attribute VideoMode → Maybe (Int, Int)
modeSize = \case
  Observed current → Just (modeWidth current, modeHeight current)
  Unavailable → Nothing

-- | One line recording each monitor as the run observed it.
topology ∷ [MonitorDescription] → String
topology descriptions =
  show (length descriptions) <> " monitor(s): " <> intercalate "; " (map describeMonitor descriptions)
  where
    describeMonitor description =
      intercalate
        " "
        [ show (monitorIdentity description)
        , attribute (show . Text.unpack) (monitorName description)
        , "at " <> attribute (\(MonitorPosition x y) → show (x, y)) (monitorPosition description)
        , "mode " <> attribute describeMode (monitorCurrentMode description)
        , "scale " <> attribute (\(ContentScale x y) → show (x, y)) (monitorContentScale description)
        , "size " <> attribute (\(PhysicalSize width height) → show width <> "x" <> show height <> "mm") (monitorPhysicalSize description)
        , "work area " <> attribute show (monitorWorkArea description)
        , "modes " <> attribute (show . length) (monitorVideoModes description)
        , "primary " <> attribute show (monitorPrimary description)
        ]
    describeMode current =
      show (modeWidth current) <> "x" <> show (modeHeight current) <> "@" <> attribute show (modeRefreshRate current)
    attribute ∷ (a → String) → Attribute a → String
    attribute shown = \case
      Observed value → shown value
      Unavailable → "unavailable"
