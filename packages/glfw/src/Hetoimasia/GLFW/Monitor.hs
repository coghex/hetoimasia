-- | The monitor inventory a GLFW session owns.
--
-- A live 'Session' publishes one immutable 'MonitorInventory' at a time through
-- a latest-value snapshot, read with 'monitorInventory' and the operations of
-- "Hetoimasia.Foundation.Messaging.Snapshot" from any thread. It holds a copied
-- 'MonitorDescription' of every connected monitor — identity, name, desktop
-- position, work area, physical size, content scale, current video mode, and
-- available video modes — each attribute as reported or explicitly
-- 'Unavailable'. An empty inventory is an observation, not a failure. No public
-- type holds a native monitor pointer, and nothing here selects or assumes a
-- primary monitor: the platform's designation is only an attribute.
--
-- A 'MonitorId' is issued per connection and ends when that monitor
-- disconnects, even if a later monitor reuses the same native object. A copied
-- description stays readable after its identity ends. On the session's owner
-- thread, 'resolveMonitor' re-resolves an identity against the monitors GLFW
-- reports at that moment and answers 'MonitorDisconnected' for an ended one,
-- before any native operation targets it.
--
-- The inventory is sampled when the session is entered, refreshed by
-- 'synchronizeMonitors' and 'resolveMonitor', and refreshed by the window host's
-- owner loop in "Hetoimasia.Runtime.GLFW" after native events whenever GLFW's
-- monitor callback reported a change. When the session ends, every identity
-- ends and the snapshot closes holding the last descriptions.
--
-- See "Hetoimasia.GLFW.Internal.Monitor"'s contract, repeated in prose in
-- @docs/glfw.md@, for identity lifetime, validation, callback containment, and
-- platform restrictions.
--
-- @
-- withSession defaultSessionConfig $ \\session → do
--   inventory ← synchronizeMonitors session
--   case inventoryMonitors inventory of
--     Observed monitors → mapM_ (print . monitorPosition) monitors
--     Unavailable → putStrLn "the platform's monitor enumeration was inconsistent"
-- @
module Hetoimasia.GLFW.Monitor
  ( -- * The inventory
    monitorInventory
  , synchronizeMonitors
  , MonitorInventory
  , inventoryRevision
  , inventoryPhase
  , inventoryMonitors
  , InventoryPhase (..)

    -- * Identities
  , MonitorId
  , monitorLocalIdentity
  , resolveMonitor
  , MonitorResult (..)

    -- * Descriptions
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
  , Attribute (..)
  , ContentScale (..)
  ) where

import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..))
import Hetoimasia.GLFW.Internal.Monitor
  ( InventoryPhase (..)
  , MonitorDescription
  , MonitorId
  , MonitorInventory
  , MonitorPosition (..)
  , MonitorResult (..)
  , PhysicalSize (..)
  , VideoMode (..)
  , WorkArea (..)
  , inventoryMonitors
  , inventoryPhase
  , inventoryRevision
  , monitorContentScale
  , monitorCurrentMode
  , monitorIdentity
  , monitorLocalIdentity
  , monitorName
  , monitorPhysicalSize
  , monitorPosition
  , monitorPrimary
  , monitorVideoModes
  , monitorWorkArea
  )
import Hetoimasia.GLFW.Internal.Session (monitorInventory, resolveMonitor, synchronizeMonitors)
