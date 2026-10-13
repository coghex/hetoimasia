-- | Retained chunks (R2D-10, decisions D-1, D-3, D-22, D-31): static instance
-- content built once, with its routing fixed and its bounds recorded, then
-- listed by reference in the layers of the snapshots that draw it.
--
-- A 'Chunk' is an immutable, backend-independent description: the kind of layer
-- it was built for, its bounds in that layer's space, its instances in build
-- order, and the path each takes, decided once when it was built. It holds no
-- native handle and imports no GPU package. A backend that retains chunks keeps
-- one for each 'ChunkRef' it issues (see "Hetoimasia.Render.TwoD.Chunk.Backend")
-- and resolves references through the 'Chunks' it validates snapshots against
-- ("Hetoimasia.Render.TwoD.Validation"); the draw plan, the encoder and the
-- oracle read the resolved description, so nothing past validation looks
-- anything up. A 'ChunkRef' is opaque, like a 'Hetoimasia.Render.TwoD.Target.TargetRef':
-- comparable and showable only, acquiring and keeping alive nothing.
--
-- = Kinds
--
-- A chunk is built for exactly one kind of layer ('ChunkKind') and may be
-- listed only by layers of that kind; validation refuses any other, naming the
-- layer and the chunk. The kinds are a world layer with depth, a world layer
-- without it, and a UI layer, so a chunk's instances are positioned and
-- ordered in the space they will be drawn in.
--
-- = Routing at build (D-3, D-22, D-27)
--
-- Only a 'ChunkWorldDepth' chunk routes anything to the cutout path, and then
-- only an instance that meets every condition of
-- "Hetoimasia.Render.TwoD.DrawPlan"'s routing: its texture is in the marks the
-- chunk is built with, its material is cutout-capable, its tint alpha is 255
-- and neither its translucent nor its additive flag is set. A 'ChunkWorldFlat'
-- or 'ChunkUi' chunk puts every instance on the ordered path. The routing is
-- the chunk's for its life: a texture swap shows through the chunk because
-- the instance names the handle, and a swap that would change the handle's
-- registered mark is refused at the swap, so the routing stays true.
--
-- = Bounds
--
-- A chunk records its bounds in its layer's space, and every instance's
-- geometry (the unit square its transform places) lies within them. They are
-- derived from the instances ('DeriveBounds'), rounded outward to 32-bit
-- floats, or supplied ('SuppliedBounds'), in which case they are refused unless
-- they are finite, not inverted and large enough to enclose every instance,
-- checked exactly. Bounds that are larger than needed are accepted and only
-- make culling less eager. Culling ("Hetoimasia.Render.TwoD.Culling") rests on
-- this enclosure, so a chunk is never skipped while any of it is visible.
--
-- = Order inside a chunk
--
-- The instances keep the order the application gave them: their /build
-- order/, which is the tie-break of the merge order in
-- "Hetoimasia.Render.TwoD.DrawPlan". The cutout instances are held in the
-- order the chunk's device buffer will hold them, by material and then build
-- order; the ordered instances by ascending depth key and then build order, so
-- merging them with other sources needs no sort of their own.
--
-- __Dependencies.__ @base@, @array@, @containers@, @hetoimasia-math@,
-- @hetoimasia-render-api@ and this package's snapshot, validation, routing and
-- chunk-reference modules.
--
-- __State.__ The module owns none; every function is pure and total.
module Hetoimasia.Render.TwoD.Chunk
  ( -- * References
    ChunkRef

    -- * Kinds and bounds
  , ChunkKind (..)
  , layerChunkKind
  , Bounds (..)
  , BoundsRequest (..)

    -- * Building
  , Chunk
  , ChunkRefusal (..)
  , buildChunk

    -- * Reading a chunk
  , chunkKind
  , chunkBounds
  , chunkSize
  , chunkInstances
  , chunkInstanceAt
  , chunkCutoutPositions
  , chunkOrderedPositions
  , chunkTextures
  , chunkPlacementMagnitude

    -- * Resolving references
  , Chunks
  , noChunks
  , chunksFrom
  , lookupChunk
  , chunkRefsOf
  ) where

import Data.Array (bounds, listArray, (!))
import qualified Data.Array as Array
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Hetoimasia.Math.Affine2 (columns, toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Internal.Chunk
  ( Bounds (..)
  , Chunk (..)
  , ChunkKind (..)
  , Chunks (..)
  , layerChunkKind
  )
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef)
import Hetoimasia.Render.TwoD.Internal.Routing (CutoutMarks, instanceMaterialOf, routesToCutout)
import Hetoimasia.Render.TwoD.Snapshot (Instance (..))
import Hetoimasia.Render.TwoD.Validation (Reason, instanceReasons)

-- | Where a chunk's bounds come from.
data BoundsRequest
  = -- | The tightest 32-bit float rectangle that encloses every instance.
    DeriveBounds
  | -- | These bounds, refused unless they are valid and enclose every instance.
    SuppliedBounds !Bounds
  deriving stock (Eq, Show)

-- | Why a chunk was not built. Every reason found is reported, instance
-- refusals first.
data ChunkRefusal
  = -- | An instance validation would refuse, by build position.
    ChunkInstanceInvalid !Int !Reason
  | -- | Bounds with a NaN or infinite component.
    ChunkBoundsNotFinite
  | -- | Bounds whose lower corner is beyond the upper on an axis.
    ChunkBoundsInverted
  | -- | Bounds that do not enclose the geometry of every instance.
    ChunkBoundsInsufficient
  | -- | Bounds were to be derived from a chunk with no instance, which has no
    -- geometry.
    ChunkBoundsUnderivable
  | -- | The geometry of the instances reaches beyond what a 32-bit float can
    -- hold.
    ChunkBoundsNotRepresentable
  deriving stock (Eq, Show)

-- | Build a chunk for one kind of layer from its instances, in build order,
-- routing them once against the registered marks (decisions D-3, D-22). Every
-- instance is validated as a snapshot's would be, and the bounds are derived or
-- checked; either every reason is reported or a chunk is built.
buildChunk ∷ CutoutMarks → ChunkKind → BoundsRequest → [Instance] → Either (NonEmpty ChunkRefusal) Chunk
buildChunk marks kind request instances =
  case NonEmpty.nonEmpty (instanceRefusals <> boundsRefusals) of
    Just refusals → Left refusals
    Nothing → case resolvedBounds of
      Nothing → Left (NonEmpty.singleton ChunkBoundsNotRepresentable)
      Just enclosing →
        Right
          Chunk
            { chunkKindField = kind
            , chunkBoundsField = enclosing
            , chunkInstanceArray = held
            , chunkCutoutOrder = map fst (sortOn (\(position, candidate) → (instanceMaterialOf candidate, position)) cutouts)
            , chunkOrderedOrder = map fst (sortOn (\(position, candidate) → (instanceDepthKey candidate, position)) ordered)
            , chunkTextureSet = Set.fromList (map instanceTexture instances)
            , chunkMagnitudeField = maximum (0 : map placementMagnitude instances)
            }
  where
    count = length instances
    held = listArray (0, count - 1) instances
    numbered = zip [0 ..] instances
    instanceRefusals = [ChunkInstanceInvalid position reason | (position, candidate) ← numbered, reason ← instanceReasons candidate]
    (cutouts, ordered) = case kind of
      ChunkWorldDepth → partitionBy (routesToCutout marks True . snd) numbered
      _ → ([], numbered)
    geometry = enclosure [candidate | candidate ← instances, all finiteFloat (toColumnMajor (instanceTransform candidate))]
    (boundsRefusals, resolvedBounds) = case request of
      DeriveBounds → case geometry of
        Nothing → ([ChunkBoundsUnderivable], Nothing)
        Just (lowX, lowY, highX, highY) →
          case (floatBelow lowX, floatBelow lowY, floatAbove highX, floatAbove highY) of
            (Just x0, Just y0, Just x1, Just y1) → ([], Just (Bounds (V2 x0 y0) (V2 x1 y1)))
            _ → ([ChunkBoundsNotRepresentable], Nothing)
      SuppliedBounds supplied@(Bounds (V2 x0 y0) (V2 x1 y1))
        | not (all finiteFloat [x0, y0, x1, y1]) → ([ChunkBoundsNotFinite], Nothing)
        | x0 > x1 || y0 > y1 → ([ChunkBoundsInverted], Nothing)
        | Just (lowX, lowY, highX, highY) ← geometry
        , toRational x0 > lowX || toRational y0 > lowY || toRational x1 < highX || toRational y1 < highY →
            ([ChunkBoundsInsufficient], Nothing)
        | otherwise → ([], Just supplied)

partitionBy ∷ (a → Bool) → [a] → ([a], [a])
partitionBy keep items = (filter keep items, filter (not . keep) items)

finiteFloat ∷ Float → Bool
finiteFloat value = not (isNaN value || isInfinite value)

-- | The exact rectangle the unit squares of these instances cover, as the
-- lowest and highest x and y: the transform @x' = a·x + c·y + tx@ over the
-- corners of [0, 1]² is lowest at @tx + min 0 a + min 0 c@ and highest at
-- @tx + max 0 a + max 0 c@, and likewise for y. 'Nothing' for no instance.
enclosure ∷ [Instance] → Maybe (Rational, Rational, Rational, Rational)
enclosure [] = Nothing
enclosure (first : rest) = Just (foldl' widen (extent first) (map extent rest))
  where
    extent candidate =
      let (V2 a b, V2 c d, V2 tx ty) = columns (instanceTransform candidate)
          (ra, rb, rc, rd, rtx, rty) = (toRational a, toRational b, toRational c, toRational d, toRational tx, toRational ty)
       in ( rtx + min 0 ra + min 0 rc
          , rty + min 0 rb + min 0 rd
          , rtx + max 0 ra + max 0 rc
          , rty + max 0 rb + max 0 rd
          )
    widen (lowX, lowY, highX, highY) (lowX', lowY', highX', highY') =
      (min lowX lowX', min lowY lowY', max highX highX', max highY highY')

-- | The greatest 32-bit float that is not above the value, 'Nothing' when there
-- is none finite.
floatBelow ∷ Rational → Maybe Float
floatBelow value
  | isInfinite nearest = Nothing
  | toRational nearest <= value = Just nearest
  | isInfinite below = Nothing
  | otherwise = Just below
  where
    nearest = fromRational value ∷ Float
    below = nextDown nearest

-- | The least 32-bit float that is not below the value, 'Nothing' when there is
-- none finite.
floatAbove ∷ Rational → Maybe Float
floatAbove value
  | isInfinite nearest = Nothing
  | toRational nearest >= value = Just nearest
  | isInfinite above = Nothing
  | otherwise = Just above
  where
    nearest = fromRational value ∷ Float
    above = nextUp nearest

-- | The next float toward positive infinity.
nextUp ∷ Float → Float
nextUp value
  | isNaN value || (isInfinite value && value > 0) = value
  | value == 0 = castWord32ToFloat 1
  | value > 0 = castWord32ToFloat (castFloatToWord32 value + 1)
  | otherwise = castWord32ToFloat (castFloatToWord32 value - 1)

-- | The next float toward negative infinity.
nextDown ∷ Float → Float
nextDown = negate . nextUp . negate

-- | The kind of layer the chunk was built for.
chunkKind ∷ Chunk → ChunkKind
chunkKind = chunkKindField

-- | The chunk's bounds in its layer's space.
chunkBounds ∷ Chunk → Bounds
chunkBounds = chunkBoundsField

-- | The number of instances.
chunkSize ∷ Chunk → Int
chunkSize built = let (low, high) = bounds (chunkInstanceArray built) in high - low + 1

-- | Every instance, in build order.
chunkInstances ∷ Chunk → [Instance]
chunkInstances = Array.elems . chunkInstanceArray

-- | The instance at a build position, 'Nothing' past either end.
chunkInstanceAt ∷ Chunk → Int → Maybe Instance
chunkInstanceAt built position
  | position < 0 || position >= chunkSize built = Nothing
  | otherwise = Just (chunkInstanceArray built ! position)

-- | The build positions of the instances on the cutout path, in the order the
-- chunk's device buffer holds them: by material, then build order. Empty unless
-- the chunk is a 'ChunkWorldDepth' one.
chunkCutoutPositions ∷ Chunk → [Int]
chunkCutoutPositions = chunkCutoutOrder

-- | The build positions of the instances on the ordered path, by ascending depth
-- key and then build order.
chunkOrderedPositions ∷ Chunk → [Int]
chunkOrderedPositions = chunkOrderedOrder

-- | Every texture any instance of the chunk names, whether or not it is
-- visible.
chunkTextures ∷ Chunk → Set TextureHandle
chunkTextures = chunkTextureSet

-- | The largest magnitude any term of placing an instance reaches, over the
-- chunk's instances: what the shader's 32-bit arithmetic rounds at, however
-- much of it cancels. Culling widens its margin by the rounding this allows.
chunkPlacementMagnitude ∷ Chunk → Double
chunkPlacementMagnitude = chunkMagnitudeField

-- | The magnitude of the terms of one instance's placement.
placementMagnitude ∷ Instance → Double
placementMagnitude candidate = max (abs a + abs c + abs tx) (abs b + abs d + abs ty)
  where
    (V2 fa fb, V2 fc fd, V2 ftx fty) = columns (instanceTransform candidate)
    (a, b, c, d, tx, ty) = (realToFrac fa, realToFrac fb, realToFrac fc, realToFrac fd, realToFrac ftx, realToFrac fty) ∷ (Double, Double, Double, Double, Double, Double)

-- | No chunk: every reference is unresolved.
noChunks ∷ Chunks
noChunks = Chunks Map.empty

-- | The chunks a backend holds, each under the reference it issued. A
-- reference listed twice keeps the last.
chunksFrom ∷ [(ChunkRef, Chunk)] → Chunks
chunksFrom = Chunks . Map.fromList

-- | The chunk a reference was issued for, exactly: a reference of another
-- generation, or one never issued, finds nothing.
lookupChunk ∷ Chunks → ChunkRef → Maybe Chunk
lookupChunk (Chunks held) reference = Map.lookup reference held

-- | The references held.
chunkRefsOf ∷ Chunks → [ChunkRef]
chunkRefsOf (Chunks held) = Map.keys held
