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
-- viewport, an unused clip entry or a view with no layers is refused like any
-- other.
--
-- __Clip tables__ (R2D-12). A view's clip table is checked entry by entry, then
-- the references to it. An entry's rectangle must be finite with an extent that
-- is not negative ('ClipRectInvalid'); its parent, when it names one, must be an
-- earlier entry of the same table, a zero-based index @p@ with @0 ≤ p < i@
-- ('ClipParentInvalid'), so a chain only runs toward lower indices and cannot
-- close on itself. Each of those is named by the entry, with its pass and view
-- ('AtClipEntry'). An instance's clip index @k > 0@ must select an entry the
-- table holds, @k ≤ n@ for a table of @n@ entries ('ClipIndexUnknown'), and is
-- named by the instance. Finally the space each referencing layer is in, world
-- or UI, is carried through the whole parent chain of the entry it selects: an
-- entry reached from both spaces, directly or through different descendants, is
-- refused ('ClipSpaceMixed', named by the entry), since nesting would intersect
-- coordinates of different units. An entry reached from one space only, or from
-- none, is accepted. Within a view the refusals come in this order: its own
-- parts, the table's entries, its layers' instances, then the mixed spaces. A zero-size viewport itself is accepted
-- and draws nothing, and a snapshot holding only offscreen passes is valid,
-- for window-free rendering and evidence. That a snapshot published to a
-- window holds a window pass is a publication rule, not a validation one.
--
-- __Validated values.__ A 'ValidSnapshot' and a 'ValidLayer' can be made only
-- by this module, so a function that takes one can rely on every check above.
-- 'validLayers' gives each layer, with its location, for the encoder in
-- "Hetoimasia.Render.TwoD.Encoding".
--
-- __Dependencies.__ @base@, @containers@ for the clip table's reach,
-- @hetoimasia-math@ for the affine type, and this package's clip, snapshot and
-- settings modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Validation
  ( -- * Validation
    validateSnapshot

    -- * Refusals
  , viewReasons
  , Refusal (..)
  , Location (..)
  , Reason (..)

    -- * Validated values
  , ValidSnapshot
  , validSnapshot
  , validLayers
  , ValidLayer
  , validLayerLocation
  , validLayerContents
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Hetoimasia.Math.Affine2 (toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..), clipEntryOfIndex)
import Hetoimasia.Render.TwoD.Internal.Check (allFinite, finite, positiveFinite, withinClosed)
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
  , Layer (..)
  , Pass (..)
  , Snapshot (..)
  , Target (..)
  , UvRect (..)
  , View (..)
  , Viewport (..)
  , depthKeyLimit
  , layerInstances
  )

-- | Where a refusal was found, by index counting from zero.
data Location
  = -- | The pass at this index.
    AtPass !Int
  | -- | The view at this index of the pass at this index.
    AtView !Int !Int
  | -- | The clip table's entry: pass, view, entry.
    AtClipEntry !Int !Int !Int
  | -- | The layer: pass, view, layer.
    AtLayer !Int !Int !Int
  | -- | The instance: pass, view, layer, instance.
    AtInstance !Int !Int !Int !Int
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
  | -- | A clip index beyond the view's table: an instance with index @k@ in a
    -- view whose table holds fewer than @k@ entries.
    ClipIndexUnknown
  | -- | A clip entry whose parent is not an earlier entry of its table.
    ClipParentInvalid
  | -- | A clip rectangle with a NaN or infinite coordinate, or a negative extent.
    ClipRectInvalid
  | -- | A clip entry referenced, directly or through a descendant, from both a
    -- world layer and a UI layer.
    ClipSpaceMixed
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

-- | A layer every check accepted, with where it sits in its snapshot. The
-- constructor is private.
data ValidLayer = ValidLayer !Location Layer
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
validLayerLocation (ValidLayer location _) = location

-- | The layer, with its instances in submission order.
validLayerContents ∷ ValidLayer → Layer
validLayerContents (ValidLayer _ layer) = layer

-- | Validate a candidate, refusing it with every reason found.
validateSnapshot ∷ Snapshot → Either (NonEmpty Refusal) ValidSnapshot
validateSnapshot snapshot@(Snapshot passes) =
  case NonEmpty.nonEmpty (concat refusalsByPass) of
    Just refusals → Left refusals
    Nothing → Right (ValidSnapshot snapshot layers)
  where
    lastIndex = length passes - 1
    windowsBefore = scanl (\count pass → if isWindow pass then count + 1 else count) (0 ∷ Int) passes
    refusalsByPass =
      [ passRefusals index pass before (index == lastIndex)
      | (index, pass, before) ← zip3 [0 ..] passes windowsBefore
      ]
    layers =
      [ ValidLayer (AtLayer passIndex viewIndex layerIndex) layer
      | (passIndex, pass) ← zip [0 ..] passes
      , (viewIndex, view) ← zip [0 ..] (passViews pass)
      , (layerIndex, layer) ← zip [0 ..] (viewLayers view)
      ]

isWindow ∷ Pass → Bool
isWindow pass = case passTarget pass of
  WindowTarget → True
  OffscreenTarget _ → False

passRefusals ∷ Int → Pass → Int → Bool → [Refusal]
passRefusals index pass windowsBefore isLast =
  [at MultipleWindowPasses | isWindow pass, windowsBefore > 0]
    <> [at WindowPassNotLast | isWindow pass, not isLast]
    <> [at ClearColourInvalid | not (validClear (passClear pass))]
    <> concat
      [viewRefusals index viewIndex view | (viewIndex, view) ← zip [0 ..] (passViews pass)]
  where
    at = Refusal (AtPass index)

validClear ∷ ClearColour → Bool
validClear (ClearColour r g b a) = all (withinClosed 0 1) [r, g, b, a]

viewRefusals ∷ Int → Int → View → [Refusal]
viewRefusals passIndex viewIndex view =
  viewOwnRefusals (Refusal (AtView passIndex viewIndex)) view
    <> clipEntryRefusals passIndex viewIndex (viewClips view)
    <> concat
      [ layerRefusals passIndex viewIndex (length (viewClips view)) layerIndex layer
      | (layerIndex, layer) ← zip [0 ..] (viewLayers view)
      ]
    <> mixedSpaceRefusals passIndex viewIndex view

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

-- | The refusals of a view's clip table, entry by entry: the rectangle, then the
-- parent.
clipEntryRefusals ∷ Int → Int → [ClipEntry] → [Refusal]
clipEntryRefusals passIndex viewIndex entries =
  concat
    [ [at ClipRectInvalid | not (validClipRect (clipRect entry))]
        <> [at ClipParentInvalid | Just parent ← [clipParent entry], parent < 0 || parent >= index]
    | (index, entry) ← zip [0 ..] entries
    , let at = Refusal (AtClipEntry passIndex viewIndex index)
    ]

-- | A finite rectangle whose extent is not negative.
validClipRect ∷ ClipRect → Bool
validClipRect (ClipRect (V2 x y) (V2 width height)) =
  allFinite [x, y, width, height] && width >= 0 && height >= 0

-- | The entries reached from both spaces, in table order. A layer's space is
-- carried through the parent chain of every entry its instances select, up to
-- the first parent that is not an earlier entry (which 'ClipParentInvalid'
-- refuses on its own); an index beyond the table reaches nothing
-- ('ClipIndexUnknown' refuses it).
mixedSpaceRefusals ∷ Int → Int → View → [Refusal]
mixedSpaceRefusals passIndex viewIndex view =
  [ Refusal (AtClipEntry passIndex viewIndex entry) ClipSpaceMixed
  | (entry, (True, True)) ← Map.toAscList reached
  ]
  where
    entries = viewClips view
    count = length entries
    parents = Map.fromList [(index, parent) | (index, ClipEntry {clipParent = Just parent}) ← zip [0 ..] entries, parent >= 0, parent < index]
    chain entry = entry : maybe [] chain (Map.lookup entry parents)
    reached =
      Map.fromListWith
        (\(world, ui) (world', ui') → (world || world', ui || ui'))
        [ (entry, (isWorld, not isWorld))
        | layer ← viewLayers view
        , let isWorld = case layer of
                WorldLayer _ _ → True
                UiLayer _ → False
        , candidate ← layerInstances layer
        , Just start ← [clipEntryOfIndex (instanceClip candidate)]
        , start < count
        , entry ← chain start
        ]

layerRefusals ∷ Int → Int → Int → Int → Layer → [Refusal]
layerRefusals passIndex viewIndex tableSize layerIndex layer =
  concat
    [ instanceRefusals tableSize (AtInstance passIndex viewIndex layerIndex index) candidate
    | (index, candidate) ← zip [0 ..] (layerInstances layer)
    ]

instanceRefusals ∷ Int → Location → Instance → [Refusal]
instanceRefusals tableSize location candidate =
  [at TransformNotFinite | not (allFinite (toColumnMajor (instanceTransform candidate)))]
    <> [at UvNotFinite | not (allFinite [u0, v0, u1, v1])]
    <> [at DepthKeyTooLarge | instanceDepthKey candidate >= depthKeyLimit]
    <> [at ClipIndexUnknown | Just entry ← [clipEntryOfIndex (instanceClip candidate)], entry >= tableSize]
  where
    at = Refusal location
    UvRect u0 v0 u1 v1 = instanceUv candidate
