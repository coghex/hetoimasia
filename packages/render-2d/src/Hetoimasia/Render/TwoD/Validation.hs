-- | Pure validation of a candidate snapshot.
--
-- 'validateSnapshot' turns a candidate into a 'ValidSnapshot', or refuses it
-- with every reason found, each naming where it was found: the pass, the view,
-- the layer and the instance, by index. Nothing is clamped, wrapped or
-- corrected, and a valid snapshot holds exactly the candidate's values in the
-- candidate's order ('validSnapshot'). Validation is total and deterministic:
-- the same candidate gives the same answer, with the refusals in the order of
-- the passes, views, layers and instances they concern.
--
-- __Refusals.__ See 'Reason' for each, and 'Location' for where it is named.
-- Everything is checked wherever it sits, so invalid data inside a zero-size
-- viewport is refused like any other. A zero-size viewport itself is accepted
-- and draws nothing, and a snapshot holding only offscreen passes is valid,
-- for window-free rendering and evidence. That a snapshot published to a
-- window holds a window pass is a publication rule, not a validation one.
--
-- __Validated values.__ A 'ValidSnapshot' and a 'ValidLayer' can be made only
-- by this module, so a function that takes one can rely on every check above.
-- 'validLayers' gives each layer, with its location, for the encoder in
-- "Hetoimasia.Render.TwoD.Encoding".
--
-- __Chunks__ (R2D-10). A layer may list retained chunks by reference. A
-- reference resolves, exactly, through the 'Chunks' the caller validates
-- against ('validateSnapshotWith'): one the set does not hold, whether it was
-- never issued, is stale or names a chunk since released, is refused
-- ('ChunkUnresolved'), and so is one built for another kind of layer than the
-- one that lists it ('ChunkKindMismatch'), each at an 'AtChunk' location that
-- names the layer and the chunk. The valid snapshot keeps what each listing
-- resolved to, so planning, encoding and the oracle need no lookup of their own
-- and the snapshot means the same thing wherever it is read. 'validateSnapshot'
-- validates against no chunks, so it refuses any layer that lists one.
--
-- __Dependencies.__ @base@, @containers@ for the set of chunks, @hetoimasia-math@
-- for the affine type, and this package's snapshot, chunk and settings modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Validation
  ( -- * Validation
    validateSnapshot
  , validateSnapshotWith

    -- * Refusals
  , viewReasons
  , instanceReasons
  , Refusal (..)
  , Location (..)
  , Reason (..)

    -- * Validated values
  , ValidSnapshot
  , validSnapshot
  , validLayers
  , validChunkRefs
  , ValidLayer
  , validLayerLocation
  , validLayerContents
  , validLayerChunks
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Hetoimasia.Math.Affine2 (toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Internal.Check (allFinite, finite, positiveFinite, withinClosed)
import Hetoimasia.Render.TwoD.Internal.Chunk (Chunk (..), ChunkKind, Chunks (..), layerChunkKind)
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef)
import Hetoimasia.Render.TwoD.Settings
  ( ViewSettings (..)
  , ZoomMode (..)
  , brightnessRange
  , uiScaleRange
  )
import Hetoimasia.Render.TwoD.Snapshot
  ( Camera (..)
  , ClearColour (..)
  , Instance (..)
  , Layer
  , Pass (..)
  , Snapshot (..)
  , Target (..)
  , UvRect (..)
  , View (..)
  , Viewport (..)
  , depthKeyLimit
  , layerChunks
  , layerInstances
  )

-- | Where a refusal was found, by index counting from zero.
data Location
  = -- | The pass at this index.
    AtPass !Int
  | -- | The view at this index of the pass at this index.
    AtView !Int !Int
  | -- | The layer: pass, view, layer.
    AtLayer !Int !Int !Int
  | -- | The instance: pass, view, layer, instance.
    AtInstance !Int !Int !Int !Int
  | -- | The chunk a layer lists: pass, view, layer, its position in the layer's
    -- list, and the reference listed there.
    AtChunk !Int !Int !Int !Int !ChunkRef
  | -- | An instance of a chunk a layer lists: pass, view, layer, the chunk's
    -- position in the layer's list, and the instance's build position in the
    -- chunk.
    AtChunkInstance !Int !Int !Int !Int !Int
  deriving stock (Eq, Ord, Show)

-- | Why a candidate was refused. A reason names no value; the location says
-- which part of the candidate to read.
data Reason
  = -- | A window pass after another window pass: a snapshot has at most one.
    MultipleWindowPasses
  | -- | A window pass followed by another pass: the window's pass comes last.
    WindowPassNotLast
  | -- | A clear colour component that is NaN, infinite or outside [0, 1].
    ClearColourInvalid
  | -- | A camera position with a NaN or infinite component.
    CameraPositionNotFinite
  | -- | A camera zoom that is NaN, infinite, zero or negative.
    CameraZoomInvalid
  | -- | A camera rotation that is NaN or infinite.
    CameraRotationNotFinite
  | -- | A viewport origin or extent with a NaN or infinite component.
    ViewportNotFinite
  | -- | A viewport with a negative extent component, which includes negative
    -- infinity: this is checked independently of 'ViewportNotFinite', so a
    -- viewport can be refused for both.
    ViewportExtentNegative
  | -- | A UI scale that is NaN, infinite or outside [0.5, 4.0].
    UiScaleOutOfRange
  | -- | A brightness that is NaN, infinite or outside [0.5, 3.0].
    BrightnessOutOfRange
  | -- | A fixed half-height that is NaN, infinite, zero or negative.
    HalfHeightInvalid
  | -- | An instance transform with a NaN or infinite coefficient.
    TransformNotFinite
  | -- | An instance UV rectangle with a NaN or infinite value.
    UvNotFinite
  | -- | A depth key of 2²⁴ or more.
    DepthKeyTooLarge
  | -- | A non-zero clip index, refused until clip tables exist.
    ClipIndexNotZero
  | -- | A chunk the chunks validated against do not hold: never issued, stale
    -- (another generation), or released.
    ChunkUnresolved
  | -- | A chunk built for another kind of layer than the one that lists it.
    ChunkKindMismatch
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | One reason a candidate was refused, and where.
data Refusal = Refusal
  { refusalLocation ∷ !Location
  , refusalReason ∷ !Reason
  }
  deriving stock (Eq, Ord, Show)

-- | A snapshot every check accepted. The constructor is private.
data ValidSnapshot = ValidSnapshot !Snapshot [ValidLayer]
  deriving stock (Eq, Show)

-- | A layer every check accepted, with where it sits in its snapshot and what
-- each chunk it lists resolved to. The constructor is private.
data ValidLayer = ValidLayer !Location Layer [(ChunkRef, Chunk)]
  deriving stock (Eq, Show)

-- | The candidate, exactly as validated: the same values in the same order.
validSnapshot ∷ ValidSnapshot → Snapshot
validSnapshot (ValidSnapshot snapshot _) = snapshot

-- | Every layer of the snapshot, in pass, view and layer order, each ready for
-- the encoder.
validLayers ∷ ValidSnapshot → [ValidLayer]
validLayers (ValidSnapshot _ layers) = layers

-- | Where the layer sits: an 'AtLayer' location.
validLayerLocation ∷ ValidLayer → Location
validLayerLocation (ValidLayer location _ _) = location

-- | The layer, with its dynamic instances in submission order and the chunks
-- it lists by reference.
validLayerContents ∷ ValidLayer → Layer
validLayerContents (ValidLayer _ layer _) = layer

-- | What each chunk the layer lists resolved to, in the order the layer lists
-- them: a chunk listed twice appears twice.
validLayerChunks ∷ ValidLayer → [(ChunkRef, Chunk)]
validLayerChunks (ValidLayer _ _ chunks) = chunks

-- | Every chunk the snapshot lists in any layer of any view, once each, in the
-- order each is first listed.
validChunkRefs ∷ ValidSnapshot → [ChunkRef]
validChunkRefs valid = go [] [reference | held ← validLayers valid, (reference, _) ← validLayerChunks held]
  where
    go _ [] = []
    go seen (reference : rest)
      | reference `elem` seen = go seen rest
      | otherwise = reference : go (reference : seen) rest

-- | Validate a candidate that lists no chunk, refusing it with every reason
-- found. A layer that lists one is refused: nothing resolves it.
validateSnapshot ∷ Snapshot → Either (NonEmpty Refusal) ValidSnapshot
validateSnapshot = validateSnapshotWith (Chunks Map.empty)

-- | Validate a candidate against the chunks it may list, refusing it with every
-- reason found.
validateSnapshotWith ∷ Chunks → Snapshot → Either (NonEmpty Refusal) ValidSnapshot
validateSnapshotWith (Chunks held) snapshot@(Snapshot passes) =
  case NonEmpty.nonEmpty (concat refusalsByPass) of
    Just refusals → Left refusals
    Nothing → Right (ValidSnapshot snapshot layers)
  where
    lastIndex = length passes - 1
    windowsBefore = scanl (\count pass → if isWindow pass then count + 1 else count) (0 ∷ Int) passes
    refusalsByPass =
      [ passRefusals held index pass before (index == lastIndex)
      | (index, pass, before) ← zip3 [0 ..] passes windowsBefore
      ]
    layers =
      [ ValidLayer (AtLayer passIndex viewIndex layerIndex) layer [(reference, chunk) | reference ← layerChunks layer, Just chunk ← [Map.lookup reference held]]
      | (passIndex, pass) ← zip [0 ..] passes
      , (viewIndex, view) ← zip [0 ..] (passViews pass)
      , (layerIndex, layer) ← zip [0 ..] (viewLayers view)
      ]

isWindow ∷ Pass → Bool
isWindow pass = case passTarget pass of
  WindowTarget → True
  OffscreenTarget _ → False

passRefusals ∷ Map.Map ChunkRef Chunk → Int → Pass → Int → Bool → [Refusal]
passRefusals held index pass windowsBefore isLast =
  [at MultipleWindowPasses | isWindow pass, windowsBefore > 0]
    <> [at WindowPassNotLast | isWindow pass, not isLast]
    <> [at ClearColourInvalid | not (validClear (passClear pass))]
    <> concat
      [viewRefusals held index viewIndex view | (viewIndex, view) ← zip [0 ..] (passViews pass)]
  where
    at = Refusal (AtPass index)

validClear ∷ ClearColour → Bool
validClear (ClearColour r g b a) = all (withinClosed 0 1) [r, g, b, a]

viewRefusals ∷ Map.Map ChunkRef Chunk → Int → Int → View → [Refusal]
viewRefusals held passIndex viewIndex view =
  viewOwnRefusals (Refusal (AtView passIndex viewIndex)) view
    <> concat
      [ layerRefusals held passIndex viewIndex layerIndex layer
      | (layerIndex, layer) ← zip [0 ..] (viewLayers view)
      ]

-- | The reasons a view's camera, viewport and settings are refused, in the order
-- 'validateSnapshot' reports them and without looking at its layers. Empty
-- exactly when those parts are valid, so a function that needs only the view's
-- geometry, as the mappings in "Hetoimasia.Render.TwoD.Mapping" do, applies the
-- same checks as validation without a snapshot around it.
viewReasons ∷ View → [Reason]
viewReasons = map refusalReason . viewOwnRefusals (Refusal (AtView 0 0))

-- | Everything about a view but its layers, refused with the given location.
viewOwnRefusals ∷ (Reason → Refusal) → View → [Refusal]
viewOwnRefusals at view =
  [at CameraPositionNotFinite | not (allFinite [px, py])]
    <> [at CameraZoomInvalid | not (positiveFinite (cameraZoom camera))]
    <> [at CameraRotationNotFinite | Just rotation ← [cameraRotation camera], not (finite rotation)]
    <> viewportRefusals
    <> [at UiScaleOutOfRange | not (uncurry withinClosed uiScaleRange (settingUiScale settings))]
    <> [at BrightnessOutOfRange | not (uncurry withinClosed brightnessRange (settingBrightness settings))]
    <> [at HalfHeightInvalid | FixedHalfHeight half ← [settingZoomMode settings], not (positiveFinite half)]
  where
    camera = viewCamera view
    V2 px py = cameraPosition camera
    settings = viewSettings view
    Viewport (V2 ox oy) (V2 width height) = viewViewport view
    -- Independent: a NaN origin does not hide a finite negative extent.
    viewportRefusals =
      [at ViewportNotFinite | not (allFinite [ox, oy, width, height])]
        <> [at ViewportExtentNegative | width < 0 || height < 0]

-- | The chunks a layer lists come first, in the order it lists them, then its
-- dynamic instances.
layerRefusals ∷ Map.Map ChunkRef Chunk → Int → Int → Int → Layer → [Refusal]
layerRefusals held passIndex viewIndex layerIndex layer =
  concat
    [ chunkRefusals (AtChunk passIndex viewIndex layerIndex position reference) (layerChunkKind layer) (Map.lookup reference held)
    | (position, reference) ← zip [0 ..] (layerChunks layer)
    ]
    <> concat
      [ instanceRefusals (AtInstance passIndex viewIndex layerIndex index) candidate
      | (index, candidate) ← zip [0 ..] (layerInstances layer)
      ]

chunkRefusals ∷ Location → ChunkKind → Maybe Chunk → [Refusal]
chunkRefusals location expected = \case
  Nothing → [Refusal location ChunkUnresolved]
  Just built → [Refusal location ChunkKindMismatch | chunkKindField built /= expected]

instanceRefusals ∷ Location → Instance → [Refusal]
instanceRefusals location = map (Refusal location) . instanceReasons

-- | The reasons an instance is refused, in the order validation reports them:
-- empty exactly when every one of its values is acceptable. A retained chunk
-- validates its instances with the same function when it is built.
instanceReasons ∷ Instance → [Reason]
instanceReasons candidate =
  [TransformNotFinite | not (allFinite (toColumnMajor (instanceTransform candidate)))]
    <> [UvNotFinite | not (allFinite [u0, v0, u1, v1])]
    <> [DepthKeyTooLarge | instanceDepthKey candidate >= depthKeyLimit]
    <> [ClipIndexNotZero | instanceClip candidate /= 0]
  where
    UvRect u0 v0 u1 v1 = instanceUv candidate
