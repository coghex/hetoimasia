-- | The cutaway camera as pure state and commands.
--
-- There are no key bindings, gesture accumulators, threads or timers here: a
-- caller turns its input into 'Command's and applies them. Every function
-- returns a new 'CameraState' and leaves the old one valid; a refusal returns
-- 'Left' and changes nothing.
--
-- == The state
--
-- * The /anchor/ is an exact world tile column plus a fractional offset in
--   @[0, 1)@ on each axis ('camFrac'), so local navigation never converts the
--   absolute address to a float. Panning carries whole tiles into the anchor
--   with checked arithmetic and refuses a result outside the supported range.
-- * The /vertical reference/ ('camRef') is an exact elevation: the horizontal
--   plane that appears at the viewport centre. In follow mode it is the top
--   plane of the followed surface (@surface + 1@) once that is known; it moves
--   only when a followed surface is adopted or a jump with a Z lands. A manual
--   slice change, pan, zoom and rotation never move it, so selecting a slice
--   cuts through a stationary picture.
-- * The /mode/ ('camMode') is following or manual at an exact level.
--   'camClip' is the effective clip level the plan cuts at: while following,
--   the followed surface plus the configured automatic headroom
--   ('ccHeadroom', initially 25); while manual, the selected level exactly,
--   with no headroom. Cells with @z <= clip@ are included and the cut plane is
--   @clip + 1@.
--
-- == Transitions
--
-- * Pan, zoom and rotation retain the mode. Rotation changes only the facing,
--   so the world anchor is the same. Zoom is clamped to the validated range
--   ('ccZoomMin' to 'ccZoomMax', initially 0.125 to 8, default 1 at native
--   artwork scale); a non-finite or non-positive zoom is refused.
-- * While following, a pan re-resolves the surface of the new anchor column
--   from the facts: a present surface is adopted (reference and clip move to
--   it); a /known empty/ column keeps the current slice and reference and
--   reports the column empty; a column whose facts are /unavailable/ is not
--   empty: it keeps the current slice and reference, reports the missing
--   facts and adopts a surface only when 'refollow' is called with facts that
--   supply it.
-- * 'SelectSlice' enters manual mode at that exact level; 'SliceBy' adds a
--   whole number of levels to the current effective clip level and makes the
--   result the manual slice. Manual depth survives pan, zoom and rotation.
-- * A jump without Z restores following at the destination; a jump with Z
--   enters manual mode at that depth and moves the reference to its top plane.
--   Zoom and facing are preserved. A jump whose destination facts are not
--   ready is /pending/: the last coherent view is kept, and the pending jump
--   carries a 'JumpId'. A newer jump supersedes it and 'cancelJump' clears it;
--   a late 'completeJump' for any identity but the current pending one is
--   'JumpStale' and changes nothing, so a cancelled or superseded result can
--   never move a newer view. This is the pure transition model, not the
--   asynchronous Lua API or its execution.
--
-- State, ownership and lifetime: none here. The caller owns the one current
-- 'CameraState' and replaces it with each result; values are immutable and the
-- module starts no thread.
module Hetoimasia.Terrain.Render2D.Camera
  ( -- * Configuration
    CameraConfig (..)
  , defaultCameraConfig
  , validCameraConfig

    -- * State
  , CameraMode (..)
  , CameraState
  , camAnchorX
  , camAnchorY
  , camFrac
  , camRef
  , camMode
  , camSurface
  , camClip
  , camZoom
  , camFacing
  , camPending
  , camRevision
  , newCamera
  , clipPlaneElevation

    -- * Jumps
  , JumpId (..)
  , JumpTarget (..)
  , PendingJump (..)
  , JumpEvent (..)

    -- * Commands
  , Command (..)
  , CameraError (..)
  , FollowOutcome (..)
  , Step (..)
  , applyCommand
  , refollow
  , completeJump
  , cancelJump
  ) where

import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Coordinate
  ( AxisCoord
  , axisFromInteger
  , axisMaxValue
  , axisValue
  )
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Shape (ViewFacing (..), facingTurns, turnCount)

-- | The camera's validated settings.
data CameraConfig = CameraConfig
  { ccZoomMin ∷ !Float
  , ccZoomMax ∷ !Float
  , ccZoomDefault ∷ !Float
  , ccHeadroom ∷ !Integer
  -- ^ The automatic headroom in levels, added to the followed surface.
  }
  deriving stock (Eq, Show)

-- | 0.125 to 8 with default 1 and 25 levels of headroom.
defaultCameraConfig ∷ CameraConfig
defaultCameraConfig = CameraConfig {ccZoomMin = 0.125, ccZoomMax = 8, ccZoomDefault = 1, ccHeadroom = 25}

-- | Whether a configuration is usable: a finite positive ordered zoom range
-- holding the default, and a nonnegative headroom.
validCameraConfig ∷ CameraConfig → Bool
validCameraConfig c =
  finitePositive (ccZoomMin c)
    && finitePositive (ccZoomMax c)
    && ccZoomMin c <= ccZoomDefault c
    && ccZoomDefault c <= ccZoomMax c
    && ccHeadroom c >= 0
    && ccHeadroom c <= 2 ^ (62 ∷ Int)

finitePositive ∷ Float → Bool
finitePositive x = not (isNaN x || isInfinite x) && x > 0

-- | Following the terrain, or a manual slice at an exact level.
data CameraMode = Following | Manual !AxisCoord
  deriving stock (Eq, Show)

-- | A jump's identity, unique within one camera.
newtype JumpId = JumpId Word64
  deriving stock (Eq, Ord, Show)

-- | A jump destination: a tile column and, optionally, a depth.
data JumpTarget = JumpTarget
  { jumpX ∷ !AxisCoord
  , jumpY ∷ !AxisCoord
  , jumpZ ∷ !(Maybe AxisCoord)
  }
  deriving stock (Eq, Show)

-- | A jump waiting for its destination facts.
data PendingJump = PendingJump
  { pendingId ∷ !JumpId
  , pendingTarget ∷ !JumpTarget
  }
  deriving stock (Eq, Show)

-- | The camera. The constructor is private; 'newCamera' and the transitions
-- are the only ways to make or change one.
data CameraState = CameraState
  { csAnchorX ∷ !AxisCoord
  , csAnchorY ∷ !AxisCoord
  , csFrac ∷ !(Rational, Rational)
  , csRef ∷ !Integer
  , csMode ∷ !CameraMode
  , csSurface ∷ !(Maybe AxisCoord)
  -- ^ The last followed surface, if one has been adopted.
  , csClip ∷ !AxisCoord
  , csZoom ∷ !Float
  , csFacing ∷ !ViewFacing
  , csPending ∷ !(Maybe PendingJump)
  , csJumps ∷ !Word64
  , csRevision ∷ !Word64
  -- ^ Increased by every transition that changes the state.
  }
  deriving stock (Eq, Show)

-- Plain functions, not field labels, so a client cannot rewrite a camera with
-- record-update syntax and bypass the transitions' checks.

camAnchorX ∷ CameraState → AxisCoord
camAnchorX = csAnchorX

camAnchorY ∷ CameraState → AxisCoord
camAnchorY = csAnchorY

camFrac ∷ CameraState → (Rational, Rational)
camFrac = csFrac

camRef ∷ CameraState → Integer
camRef = csRef

camMode ∷ CameraState → CameraMode
camMode = csMode

camSurface ∷ CameraState → Maybe AxisCoord
camSurface = csSurface

camClip ∷ CameraState → AxisCoord
camClip = csClip

camZoom ∷ CameraState → Float
camZoom = csZoom

camFacing ∷ CameraState → ViewFacing
camFacing = csFacing

camPending ∷ CameraState → Maybe PendingJump
camPending = csPending

camRevision ∷ CameraState → Word64
camRevision = csRevision

-- | A following camera at the centre of a tile column, facing South, at the
-- default zoom, cutting at the given level until a surface is adopted. The
-- reference starts at the clip level's cut plane, clamped to the elevation range.
newCamera ∷ CameraConfig → AxisCoord → AxisCoord → AxisCoord → Either CameraError CameraState
newCamera config x y clip
  | not (validCameraConfig config) = Left InvalidConfig
  | otherwise =
      Right
        CameraState
          { csAnchorX = x
          , csAnchorY = y
          , csFrac = (1 / 2, 1 / 2)
          , csRef = clipPlaneElevation clip
          , csMode = Following
          , csSurface = Nothing
          , csClip = clip
          , csZoom = ccZoomDefault config
          , csFacing = FaceSouth
          , csPending = Nothing
          , csJumps = 0
          , csRevision = 0
          }

-- | The elevation of the cut plane for a clip level: @clip + 1@.
clipPlaneElevation ∷ AxisCoord → Integer
clipPlaneElevation clip = toInteger (axisValue clip) + 1

-- | A camera command.
data Command
  = -- | Move the anchor by a number of tiles on the world axes.
    Pan !Double !Double
  | -- | Multiply the zoom by a factor, clamped to the configured range.
    ZoomBy !Float
  | -- | Set the zoom, clamped to the configured range.
    SetZoom !Float
  | -- | Set the facing; the world anchor is unchanged.
    SetFacing !ViewFacing
  | -- | Turn the facing by whole quarter turns, positive as 'facingTurns'.
    RotateBy !Int
  | -- | Enter manual mode at an exact level.
    SelectSlice !AxisCoord
  | -- | Add whole levels to the effective clip level and enter manual mode there.
    SliceBy !Integer
  | -- | Jump to a column, with or without a depth.
    Jump !JumpTarget
  deriving stock (Eq, Show)

-- | Why a command was refused. Nothing changes.
data CameraError
  = InvalidConfig
  | -- | A zoom or a pan that is not finite (or a zoom not positive).
    NonFiniteInput
  | -- | A pan that would leave the supported coordinate range.
    PanOutOfRange
  | -- | A slice outside the supported range.
    SliceOutOfRange
  deriving stock (Eq, Show)

-- | What following the surface did on this step.
data FollowOutcome
  = -- | Not following, or the step did not touch the surface.
    FollowNotApplied
  | -- | A surface was adopted at this level.
    FollowAdopted !AxisCoord
  | -- | A known empty column: the slice is preserved.
    FollowColumnEmpty
  | -- | The column's facts are not ready: the slice is preserved and these
    -- facts are missing.
    FollowUnavailable !Demand
  deriving stock (Eq, Show)

-- | What a jump did on this step.
data JumpEvent
  = NoJump
  | -- | The jump landed.
    JumpApplied !JumpId
  | -- | The destination is not ready; the view is unchanged and these facts
    -- are missing.
    JumpPending !JumpId !Demand
  | -- | A completion for a jump that is no longer the pending one; ignored.
    JumpStale !JumpId
  deriving stock (Eq, Show)

-- | The result of one transition.
data Step = Step
  { stepCamera ∷ !CameraState
  , stepFollow ∷ !FollowOutcome
  , stepJump ∷ !JumpEvent
  }
  deriving stock (Eq, Show)

-- | Apply one command with the current facts.
applyCommand ∷ CameraConfig → TerrainFacts → Command → CameraState → Either CameraError Step
applyCommand config facts command camera
  | not (validCameraConfig config) = Left InvalidConfig
  | otherwise = case command of
      Pan dx dy → do
        moved ← pan dx dy camera
        pure (stamp camera (followIfFollowing config facts moved))
      ZoomBy factor
        | bad factor → Left NonFiniteInput
        | otherwise → Right (plain (camera {csZoom = clampZoom config (csZoom camera * factor)}))
      SetZoom zoom
        | bad zoom → Left NonFiniteInput
        | otherwise → Right (plain (camera {csZoom = clampZoom config zoom}))
      SetFacing facing → Right (plain (camera {csFacing = facing}))
      RotateBy count →
        Right (plain (camera {csFacing = facingFromTurns (turnCount (facingTurns (csFacing camera)) + count)}))
      SelectSlice level → Right (plain (camera {csMode = Manual level, csClip = level}))
      SliceBy delta → do
        let target = toInteger (axisValue (csClip camera)) + delta
        level ← either (const (Left SliceOutOfRange)) Right (axisFromInteger target)
        Right (plain (camera {csMode = Manual level, csClip = level}))
      Jump target → Right (stamp camera (beginJump config facts target camera))
  where
    bad x = isNaN x || isInfinite x || x <= 0
    plain next = stamp camera (Step next FollowNotApplied NoJump)

-- | Re-resolve the followed surface with new facts (for example after the
-- residency generation changes). A camera that is not following is unchanged.
refollow ∷ CameraConfig → TerrainFacts → CameraState → Either CameraError Step
refollow config facts camera
  | not (validCameraConfig config) = Left InvalidConfig
  | otherwise = Right (stamp camera (followIfFollowing config facts camera))

-- | Deliver a late jump completion with the facts now available. Only the
-- current pending jump can move the camera.
completeJump ∷ CameraConfig → TerrainFacts → JumpId → CameraState → Either CameraError Step
completeJump config facts jump camera
  | not (validCameraConfig config) = Left InvalidConfig
  | otherwise = Right $ case csPending camera of
      Just PendingJump {pendingId = pid, pendingTarget = target}
        | pid == jump → stamp camera (landOrWait config facts pid target camera)
      _ → Step camera FollowNotApplied (JumpStale jump)

-- | Cancel the pending jump with this identity; any other identity is ignored.
cancelJump ∷ JumpId → CameraState → CameraState
cancelJump jump camera = case csPending camera of
  Just PendingJump {pendingId = pid}
    | pid == jump → bump camera (camera {csPending = Nothing})
  _ → camera

-- Increase the revision when a step changed the camera.
stamp ∷ CameraState → Step → Step
stamp old step = step {stepCamera = bump old (stepCamera step)}

bump ∷ CameraState → CameraState → CameraState
bump old new
  | new == old = old
  | otherwise = new {csRevision = csRevision old + 1}

clampZoom ∷ CameraConfig → Float → Float
clampZoom config = max (ccZoomMin config) . min (ccZoomMax config)

facingFromTurns ∷ Int → ViewFacing
facingFromTurns count = case count `mod` 4 of
  0 → FaceSouth
  1 → FaceEast
  2 → FaceNorth
  _ → FaceWest

-- Move the anchor, carrying whole tiles with checked arithmetic.
pan ∷ Double → Double → CameraState → Either CameraError CameraState
pan dx dy camera
  | any (\d → isNaN d || isInfinite d) [dx, dy] = Left NonFiniteInput
  | otherwise = do
      let (fx, fy) = csFrac camera
          tx = fx + toRational dx
          ty = fy + toRational dy
          wholeX = floor tx ∷ Integer
          wholeY = floor ty ∷ Integer
      x ← either (const (Left PanOutOfRange)) Right (axisFromInteger (toInteger (axisValue (csAnchorX camera)) + wholeX))
      y ← either (const (Left PanOutOfRange)) Right (axisFromInteger (toInteger (axisValue (csAnchorY camera)) + wholeY))
      pure camera {csAnchorX = x, csAnchorY = y, csFrac = (tx - fromInteger wholeX, ty - fromInteger wholeY)}

anchorColumn ∷ CameraState → Column
anchorColumn camera = Column (csAnchorX camera) (csAnchorY camera)

-- Resolve the followed surface when following.
followIfFollowing ∷ CameraConfig → TerrainFacts → CameraState → Step
followIfFollowing config facts camera = case csMode camera of
  Manual _ → Step camera FollowNotApplied NoJump
  Following → resolveSurface config facts camera

resolveSurface ∷ CameraConfig → TerrainFacts → CameraState → Step
resolveSurface config facts camera = case surfaceAt facts (anchorColumn camera) of
  SurfacePresent h →
    Step
      camera
        { csSurface = Just h
        , csClip = clipFor config h
        , csRef = clipPlaneElevation h
        }
      (FollowAdopted h)
      NoJump
  SurfaceAbsent → Step camera {csSurface = Nothing} FollowColumnEmpty NoJump
  SurfaceUnavailable key level → Step camera (FollowUnavailable (demandFrom [surfaceWant key level])) NoJump

-- The fact a surface lookup is missing: the level of the highest solid cell
-- when the column has one, otherwise the chunk's column summaries, named by
-- the lowest level of its first region.
surfaceWant ∷ ChunkKey → Maybe AxisCoord → (ChunkKey, Integer, Integer)
surfaceWant key (Just h) = (key, toInteger (axisValue h), toInteger (axisValue h) + 1)
surfaceWant key Nothing = (key, 0, 1)

-- The automatic clip level: the surface plus headroom. A level above the
-- highest supported one includes the same cells as the highest, so the sum is
-- capped there rather than refused.
clipFor ∷ CameraConfig → AxisCoord → AxisCoord
clipFor config surface = case axisFromInteger (min axisMaxValue (toInteger (axisValue surface) + ccHeadroom config)) of
  Right level → level
  Left _ → surface

-- Start a jump: land at once when the destination is ready, otherwise wait.
beginJump ∷ CameraConfig → TerrainFacts → JumpTarget → CameraState → Step
beginJump config facts target camera = landOrWait config facts jid target camera {csJumps = csJumps camera + 1, csPending = Nothing}
  where
    jid = JumpId (csJumps camera + 1)

landOrWait ∷ CameraConfig → TerrainFacts → JumpId → JumpTarget → CameraState → Step
landOrWait config facts jid target camera = case missing of
  [] →
    let landed = land target camera {csPending = Nothing}
        step = case jumpZ target of
          Just _ → Step landed FollowNotApplied NoJump
          Nothing → resolveSurface config facts landed
     in step {stepJump = JumpApplied jid}
  wants →
    Step
      camera {csPending = Just (PendingJump jid target)}
      FollowNotApplied
      (JumpPending jid (demandFrom wants))
  where
    column = Column (jumpX target) (jumpY target)
    key = chunkOfColumn column
    missing = case jumpZ target of
      Just z →
        let level = toInteger (axisValue z)
         in [(key, a, b) | (a, b) ← unknownPieces (factsAvailability facts) key level (level + 1)]
      Nothing → case surfaceAt facts column of
        SurfaceUnavailable k level → [surfaceWant k level]
        _ → []

-- Move the anchor to a jump destination, keeping zoom and facing.
land ∷ JumpTarget → CameraState → CameraState
land target camera =
  base
    { csMode = case jumpZ target of
        Just z → Manual z
        Nothing → Following
    , csClip = maybe (csClip camera) id (jumpZ target)
    , csRef = maybe (csRef camera) clipPlaneElevation (jumpZ target)
    }
  where
    base =
      camera
        { csAnchorX = jumpX target
        , csAnchorY = jumpY target
        , csFrac = (1 / 2, 1 / 2)
        }
