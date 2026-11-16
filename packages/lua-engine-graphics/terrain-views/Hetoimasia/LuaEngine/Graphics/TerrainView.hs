-- | The terrain-view adapter (TRA-9), the Haskell operations a Lua terrain-view binding wraps: attach a view of a
-- borrowed arena to a target under an exclusive claim, submit camera and presentation intent, jump, observe
-- preparation and adoption, pick from the adopted frame with an opaque consistency reference and its removal
-- precondition, and close with a real empty handback.
--
-- The ownership, threads and invariants are in "Hetoimasia.LuaEngine.Graphics.TerrainView.Service"; the style's
-- authority in "Hetoimasia.LuaEngine.Graphics.TerrainView.Style"; the planning inputs in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs"; the graphics owner's capability in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Owner".
module Hetoimasia.LuaEngine.Graphics.TerrainView
  ( -- * The service
    TerrainViewsConfig (..)
  , defaultTerrainViewsConfig
  , terrainGpuBankBytes
  , TerrainViewsPorts (..)
  , TerrainViews
  , withTerrainViews
  , terrainViewsFailures

    -- * The graphics owner
  , ViewOwner (..)
  , RegionBuild (..)
  , productionViewOwner

    -- * Targets
  , ViewTarget (..)
  , windowViewTarget
  , offscreenViewTarget

    -- * Styles
  , StyleRequest (..)
  , StyleRefusal (..)
  , ParentRole (..)
  , describeStyleRefusal

    -- * Attaching and closing
  , AttachRequest (..)
  , AttachRefusal (..)
  , describeAttachRefusal
  , Settled (..)
  , TerrainView
  , viewIncarnation
  , PendingAttach
  , attachView
  , attachSettled
  , awaitAttach
  , cancelAttach
  , closeView
  , viewClosed

    -- * Intent
  , CameraIntent (..)
  , PresentationUpdate (..)
  , noPresentationUpdate
  , IntentRefusal (..)
  , updateCamera
  , updatePresentation
  , JumpRequest (..)
  , JumpOutcome (..)
  , PendingJump
  , jumpView
  , jumpSettled
  , cancelJumpView

    -- * Observation
  , ViewPhase (..)
  , ViewReading (..)
  , readView

    -- * Picking
  , PickResult (..)
  , PickRef
  , pickRefCell
  , pickRefPart
  , pickView
  , pickPrecondition
  ) where

import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
import Hetoimasia.LuaEngine.Graphics.TerrainView.Service
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style
import Hetoimasia.LuaEngine.Graphics.TerrainView.Target
import Hetoimasia.LuaEngine.Graphics.TerrainView.Types
