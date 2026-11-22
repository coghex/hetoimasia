-- | Terrain views (TRA-9), the Haskell operations a Lua binding (#646) wraps: open a view of a borrowed arena on a
-- target under the exclusive claim it shares with M1, move it, configure it, close it, and read which revision its
-- target drew.
--
-- A client composes the service only through 'productionPorts', over the running host and its composed graphics
-- session: 'TerrainViewsPorts' is opaque. The graphics owner's capabilities, the copy hooks and the target readers
-- the service runs inside its own transactions are the package's own and are not reachable from here, so nothing a
-- client supplies runs in a transaction that commits an ownership fact. A target is made only by 'windowViewTarget'
-- or 'offscreenViewTarget'.
--
-- The ownership, threads and endings are documented in the package's implementation; the limits and the allowance
-- with 'ViewProfile'; the style's authority with 'StyleRequest'.
module Hetoimasia.LuaEngine.Graphics.TerrainView
  ( -- * The service
    TerrainViewsConfig (..)
  , defaultTerrainViewsConfig
  , TerrainViewsPorts
  , productionPorts
  , TerrainViewsRefused (..)
  , TerrainViews
  , withTerrainViews

    -- * Targets
  , ViewTarget
  , windowViewTarget
  , offscreenViewTarget
  , drawOffscreenView
  , OffscreenFacts
  , newOffscreenFacts
  , setOffscreenUsable
  , setOffscreenMetrics
  , Authority (..)
  , ViewGeometry (..)
  , geometryOfMetrics
  , windowGeometryOf

    -- * Styles
  , ViewStyle (..)
  , retainedStyle
  , StyleRequest (..)
  , ParentRole (..)
  , StyleRefusal (..)
  , describeStyleRefusal
  , AcquiredStyle
  , styleAssets
  , styleTextures
  , styleIdentities
  , styleColourHandle
  , styleNormalHandle
  , styleNominalBytes
  , styleMappedMaterials
  , acquireStyle
  , releaseStyle
  , StyleParent (..)
  , checkStyle
  , parentNominalBytes

    -- * Limits
  , ViewProfile (..)
  , defaultViewProfile
  , ProfileRefusal (..)
  , checkProfile
  , chunkInstances
  , Reservation (..)
  , reservation
  , gpuVertexBound
  , gpuVertexCeiling
  , declaredQuadBytes
  , declaredPendingBytes
  , declaredRegionBytes
  , declaredRunBytes
  , declaredSlotBytes
  , declaredControlBytes

    -- * Opening and closing
  , OpenRequest (..)
  , OpenRefusal (..)
  , TerrainView
  , viewIncarnation
  , viewTargetKey
  , openView
  , CloseOutcome (..)
  , closeView

    -- * Controls
  , ControlRefusal (..)
  , MoveOutcome (..)
  , PendingMove
  , moveView
  , moveSettled
  , Configure (..)
  , noConfigure
  , configureView

    -- * Observation
  , ViewStatus (..)
  , Ending (..)
  , BindingLimit (..)
  , ViewReading (..)
  , readView
  , viewReadings
  , DrawnPlan (..)
  , viewDrawn
  , viewCellConfig
  , viewSetup
  , ServiceReading (..)
  , readTerrainViews
  ) where

import Hetoimasia.LuaEngine.Graphics.TerrainView.Internal
