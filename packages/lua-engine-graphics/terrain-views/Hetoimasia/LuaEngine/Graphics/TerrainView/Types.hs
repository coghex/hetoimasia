-- | The terrain-view adapter's public values (TRA-9): its configuration, the narrow capabilities it is lent, what a
-- caller asks of a view and every answer it gives. The operations are in "Hetoimasia.LuaEngine.Graphics.TerrainView".
module Hetoimasia.LuaEngine.Graphics.TerrainView.Types
  ( -- * Configuration
    TerrainViewsConfig (..)
  , defaultTerrainViewsConfig
  , terrainGpuBankBytes

    -- * Targets
  , ViewTarget (..)

    -- * Attachment
  , AttachRequest (..)
  , AttachRefusal (..)
  , describeAttachRefusal
  , Settled (..)

    -- * Camera and presentation intent
  , CameraIntent (..)
  , PresentationUpdate (..)
  , noPresentationUpdate
  , IntentRefusal (..)

    -- * Jumps
  , JumpRequest (..)
  , JumpOutcome (..)

    -- * Observation
  , ViewPhase (..)
  , ViewReading (..)

    -- * Picking
  , PickResult (..)
  , PickRef
  , pickRefCell
  , pickRefPart
  , mkPickRef
  , pickRefIdentity
  , PickIdentity (..)
  ) where

import Control.Concurrent.STM (STM)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.World (WorldTag)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style (StyleRefusal, StyleRequest, describeStyleRefusal)
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..))
import Hetoimasia.Terrain.Changes (ChangeLimits (..))
import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord)
import Hetoimasia.Terrain.Render2D.Camera (CameraConfig, Command, defaultCameraConfig)
import Hetoimasia.Terrain.Render2D.Cells (CellConfig (..), CellLimits (..), PartKind, defaultCellConfig)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput)
import Hetoimasia.Terrain.Residency (ArenaId, Revision)
import Hetoimasia.Terrain.Runtime (ArenaLease)

-- | The adapter's configuration. Every bound is the approved figure by default; a test lowers them.
data TerrainViewsConfig = TerrainViewsConfig
  { tvMaxViews ∷ !Int
    -- ^ Views a service holds at once (eight).
  , tvCpuPins ∷ !Int
    -- ^ Pinned CPU view revisions per view (two): a published plan stays pinned while it may be adopted or picked.
  , tvGpuBytes ∷ !Word64
    -- ^ The terrain GPU-data bank (128 MiB): every retained region's device bytes, live and retiring.
  , tvCellConfig ∷ !CellConfig
    -- ^ The planner's band, slack, prefetch margin and bounds.
  , tvCameraConfig ∷ !CameraConfig
  , tvChangeLimits ∷ !ChangeLimits
    -- ^ The bound on removed intervals one plan's facts may hold.
  , tvStepsPerQuantum ∷ !Int
    -- ^ Planner steps the worker takes for one view before it serves the others.
  , tvRequestQueue ∷ !Int
    -- ^ Attach and jump requests awaiting the worker, across the service.
  , tvClear ∷ !ClearColour
    -- ^ What a terrain frame clears to before its quads.
  , tvCopyRegions ∷ !Int
    -- ^ Regions one regional copy asks for: at most the terrain service's per-hold region bound.
  , tvOnStage ∷ Word64 → Text → IO ()
    -- ^ Run on the worker each time a view (by its incarnation) enters a preparation stage ("copying", "planning", "building",
    -- "uploading"), after the stage is recorded: a test seam (to hold the worker there, or end it there). Production
    -- runs nothing.
  , tvOnTransfer ∷ Word64 → Text → IO ()
    -- ^ Run on the worker after each transaction that hands a preparation's resources on ("reserved": the GPU bytes
    -- with the build stage; "submitted": the build's ticket; "answered": its chunks; "abandoned": a stage handed to
    -- cleanup; "requested": a copy request), before the next: a test seam (to end the worker exactly between two
    -- transfers). Production runs nothing.
  , tvBeforeAttachCommit ∷ IO ()
    -- ^ Run on the worker after an attachment's early checks and before its commit transaction: a test seam (to let a
    -- lease or a target change at exactly that point). Production runs nothing.
  , tvStopping ∷ IO ()
    -- ^ Run by the scope's end once the service takes no new work and before it waits for the worker: a test seam (to
    -- let an owner action the test holds go at exactly that point). Production runs nothing.
  , tvAccountGranule ∷ !Word64
    -- ^ The unit a view's CPU charge takes from the session's account (1 MiB): a need is covered by whole granules,
    -- reserved as it grows and returned only when a whole granule is free, so a need that moves within one leaves the
    -- account untouched. The over-reservation is the view's charge.
  }

-- | The approved terrain GPU-data bank: 128 MiB.
terrainGpuBankBytes ∷ Word64
terrainGpuBankBytes = 128 * 1024 * 1024

defaultTerrainViewsConfig ∷ TerrainViewsConfig
defaultTerrainViewsConfig =
  TerrainViewsConfig
    { tvMaxViews = 8
    , tvCpuPins = 2
    , tvGpuBytes = terrainGpuBankBytes
    , -- a step evaluates at most 2,048 levels (and finishes its column), so what one quantum can add to a plan is small
      -- enough to charge to the account before it is made
      tvCellConfig = defaultCellConfig {ccLimits = (ccLimits defaultCellConfig) {clStepLevels = 2048}}
    , tvCameraConfig = defaultCameraConfig
    , tvChangeLimits = ChangeLimits 1048576
    , tvStepsPerQuantum = 4
    , tvRequestQueue = 64
    , tvClear = ClearColour 0 0 0 1
    , tvCopyRegions = 256
    , tvAccountGranule = 1024 * 1024
    , tvOnStage = \_ _ → pure ()
    , tvOnTransfer = \_ _ → pure ()
    , tvBeforeAttachCommit = pure ()
    , tvStopping = pure ()
    }

-- | The narrow capability of one target incarnation: its key in the host's one key space, whether it is still the
-- admitted incarnation, its latest-value publication as a transaction (the host's own), whether its recording supplies
-- the qualified @D32_SFLOAT@ depth image, and the metrics its frames are recorded with now. It carries no native
-- control and no disposal.
data ViewTarget k = ViewTarget
  { vtKey ∷ !k
  , vtUsable ∷ STM Bool
  , vtPublish ∷ Prepared GraphicsScene → STM Bool
    -- ^ Make the scene the target's latest value; 'False' when the host holds no such incarnation.
  , vtDepth ∷ !Bool
    -- ^ Whether every frame of this target is recorded with a @D32_SFLOAT@ depth image: a window on a host built with
    -- the host-wide window depth, or a surface-free target whose recording boundary supplies one.
  , vtMetrics ∷ STM (Maybe TargetMetrics)
    -- ^ The metrics the target's next frame is recorded with, when it has reported them.
  }

-- | What an attachment names: the target, the style (the owning instance's parents and mapping), the arena lease
-- the view reads through, where the camera starts, and its presentation settings.
data AttachRequest k = AttachRequest
  { attachTarget ∷ !(ViewTarget k)
  , attachStyle ∷ !StyleRequest
  , attachArena ∷ !ArenaLease
  , attachAnchor ∷ !(AxisCoord, AxisCoord, AxisCoord)
    -- ^ The camera's starting column and clip level.
  , attachLight ∷ !LightInput
  }

-- | Why an attachment was refused. None is busy except 'AttachBusy'; none leaves a claim, an interest, a reservation
-- or a view behind.
data AttachRefusal
  = -- | The style: a parent, its coverage or the mapping (never busy).
    AttachStyle !StyleRefusal
  | -- | The target is not the admitted incarnation, or the host holds no such target.
    AttachTargetUnusable
  | -- | The target's frames are not recorded with the qualified depth image, or the renderer's session depth format
    -- is not @D32_SFLOAT@.
    AttachNoDepth
  | -- | Another terrain view holds the target's claim.
    AttachTargetClaimed
  | -- | A parent texture's registration was released before the view's interest could be taken.
    AttachParentReleased
  | -- | The arena lease was refused by the terrain service (its text).
    AttachArena !Text
  | -- | The presentation settings are invalid.
    AttachSettings !Text
  | -- | The camera cannot start there (its text).
    AttachCamera !Text
  | -- | The service holds its maximum number of views.
    AttachTooManyViews
  | -- | Temporary pressure: the request queue, a reservation or the terrain service's own admission.
    AttachBusy !Text
  | -- | The adapter, its session or the terrain service has stopped.
    AttachStopped
  deriving (Eq, Show)

describeAttachRefusal ∷ AttachRefusal → Text
describeAttachRefusal = \case
  AttachStyle why → describeStyleRefusal why
  AttachTargetUnusable → "the target is not usable"
  AttachNoDepth → "the target's frames carry no D32_SFLOAT depth image"
  AttachTargetClaimed → "another terrain view holds the target"
  AttachParentReleased → "a parent texture was released"
  AttachArena why → "the arena refused: " <> why
  AttachSettings why → "the presentation settings are invalid: " <> why
  AttachCamera why → "the camera cannot start there: " <> why
  AttachTooManyViews → "the service holds its maximum number of views"
  AttachBusy why → "busy: " <> why
  AttachStopped → "terrain views have stopped"

-- | How an asynchronous operation settled: exactly once.
data Settled a
  = SettledOk !a
  | SettledRefused !AttachRefusal
  | SettledCancelled
  deriving (Eq, Show)

-- | A camera intent update: commands applied in order, all or none.
newtype CameraIntent = CameraIntent [Command]
  deriving (Eq, Show)

-- | A presentation update: each omitted setting keeps its value. Rejected whole when any supplied value is invalid.
data PresentationUpdate = PresentationUpdate
  { updateSunAzimuth ∷ !(Maybe Double)
  , updateSunElevation ∷ !(Maybe Double)
  , updateAmbient ∷ !(Maybe Double)
  , updateSunStrength ∷ !(Maybe Double)
  , updateDepthRange ∷ !(Maybe Integer)
  , updateDarkening ∷ !(Maybe Double)
  , updateHaze ∷ !(Maybe Double)
  , updateHazeColour ∷ !(Maybe (Double, Double, Double))
    -- ^ A complete sRGB triple, or nothing.
  }
  deriving (Eq, Show)

noPresentationUpdate ∷ PresentationUpdate
noPresentationUpdate = PresentationUpdate Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Why an intent update changed nothing.
data IntentRefusal
  = -- | The update itself is invalid (its text): nothing changed.
    IntentInvalid !Text
  | -- | The view is closed.
    IntentClosed
  | -- | The intent slot could not be admitted: nothing changed.
    IntentBusy
  deriving (Eq, Show)

-- | A jump: a column and, optionally, a depth.
data JumpRequest = JumpRequest
  { jumpColumn ∷ !(AxisCoord, AxisCoord)
  , jumpDepth ∷ !(Maybe AxisCoord)
  }
  deriving (Eq, Show)

-- | How a jump ended: landed, or superseded by a newer jump (the camera did not move for it).
data JumpOutcome = JumpLanded | JumpSuperseded
  deriving (Eq, Show)

-- | Where a view's preparation stands.
data ViewPhase
  = -- | Nothing is prepared yet.
    PhaseStarting
  | -- | Preparing the latest intent.
    PhasePreparing
  | -- | The latest intent is published; what remains is pending information.
    PhasePublished
  | -- | The view has closed.
    PhaseClosed
  deriving (Eq, Show)

-- | A reading of one view, for observation: its phase, its newest published and newest adopted revisions, its
-- pending regions and its charges.
data ViewReading = ViewReading
  { readingPhase ∷ !ViewPhase
  , readingPublished ∷ !(Maybe Word64)
  , readingAdopted ∷ !(Maybe Word64)
  , readingPendingRegions ∷ !Int
  , readingRetainedRegions ∷ !Int
  , readingCpuBytes ∷ !Word64
    -- ^ What the view holds in the session's account: whole granules, at least what its pinned revisions need.
  , readingGpuBytes ∷ !Word64
  , readingPins ∷ !Int
  , readingWaiting ∷ !Bool
    -- ^ The last preparation stopped on pressure (a bank, the shared account, the copies, the pins) and waits for
    -- something to be released or adopted.
  , readingStagedBytes ∷ !Word64
    -- ^ What the view's preparation holds of the account now: copies taken, inputs, the plan's growth, the adaptation.
  , readingRestarts ∷ !Int
    -- ^ Times the view's copies started again because copies of different committed versions met.
  }
  deriving (Eq, Show)

-- | What a pick found, mapping one-to-one onto the approved Lua answers: 'PickHit' is @hit@, 'PickNoHit' is
-- @no_hit@ and 'PickLoading' is @loading@. Nothing else is answered.
data PickResult k
  = PickHit !(PickRef k)
  | PickNoHit
  | PickLoading
  deriving (Eq, Show)

-- | Everything a pick's consistency is: the target and view incarnations, the adopted revision and its plan tag, the
-- arena incarnation and its content and knowledge revisions. Opaque to callers.
data PickIdentity k = PickIdentity
  { pickTarget ∷ !k
  , pickViewId ∷ !Word64
  , pickRevision ∷ !Word64
  , pickTag ∷ !WorldTag
  , pickArena ∷ !ArenaId
  , pickContent ∷ !Revision
  , pickKnowledge ∷ !Revision
  , pickResidency ∷ !Word64
    -- ^ The adopted plan's residency identity, checked against the arena's generation in the removal's arbitration.
  }
  deriving (Eq, Show)

-- | A hit's opaque consistency reference: the exact logical cell and part, and the identity it was picked under.
data PickRef k = PickRef
  { refCell ∷ !TileCoord
  , refPart ∷ !PartKind
  , refIdentity ∷ !(PickIdentity k)
  }
  deriving (Eq, Show)

pickRefCell ∷ PickRef k → TileCoord
pickRefCell = refCell

pickRefPart ∷ PickRef k → PartKind
pickRefPart = refPart

pickRefIdentity ∷ PickRef k → PickIdentity k
pickRefIdentity = refIdentity

-- | Made only by the adapter's picker.
mkPickRef ∷ TileCoord → PartKind → PickIdentity k → PickRef k
mkPickRef = PickRef
