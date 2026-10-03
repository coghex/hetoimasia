-- | The ordering rules for managed resources (GRS-3, D-18, D-26): what each
-- kind of resource may be used for, the one use it rests in between batches,
-- which transitions a batch may make, the boundary barriers a batch owes, and
-- whether a batch may seal.
--
-- Everything here is stated in engine terms — a resource's kind and the use a
-- command makes of it — and is pure: it names no native type, and the backend
-- maps each use onto its own layouts, stages and accesses. A batch's accesses
-- are a value ('BatchAccess') its recorder threads for as long as the batch is
-- recorded; nothing here is kept across batches, because a resource's resting
-- use is a fact of its kind, so recording order and submission order can never
-- disagree about it. Whether an image has been initialized is the model's, and
-- lives in "Hetoimasia.GPU.Model.Internal.Initialization".
module Hetoimasia.GPU.Model.Internal.Access
  ( -- * Kinds and uses
    ResourceKind (..)
  , isImageKind
  , ResourceUse (..)
  , restingUse
  , legalUses
  , Contents (..)
  , TransitionSource (..)

    -- * A batch's accesses
  , BatchAccess
  , emptyAccess
  , accessUse
  , touchedResources
  , BarrierRole (..)
  , Barrier (..)
  , AccessRefusal (..)
  , touch
  , transition
  , sealAccess
  , entryInitializes
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

-- | What a managed resource is, as far as ordering it is concerned.
data ResourceKind
  = TextureResource
    -- ^ An image shaders sample, written only by copies into it.
  | DepthTargetResource
  | ColorTargetResource
  | VertexResource
    -- ^ Static vertex data.
  | IndexResource
    -- ^ Static index data.
  | InstanceResource
    -- ^ Per-frame instance data, or the shared ring: host-written, read by
    -- vertex input and shaders.
  | LookupResource
    -- ^ A per-frame lookup table: host-written, read by shaders as storage.
  | StagingResource
    -- ^ Host-written bytes the device copies from.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Whether the kind is an image, which has a layout, and contents that can
-- be undefined.
isImageKind ∷ ResourceKind → Bool
isImageKind = (`elem` [TextureResource, DepthTargetResource, ColorTargetResource])

-- | A use a command makes of a resource. The backend maps each, for each
-- kind, onto the stages and accesses it covers and, for an image, a layout.
data ResourceUse
  = ShaderSampled
    -- ^ Sampled by the fragment shader.
  | DepthAttachment
    -- ^ Read and written by the early and late fragment tests.
  | ColorAttachment
    -- ^ Read and written as color-attachment output.
  | GeometryRead
    -- ^ Read by vertex input: as vertex attributes, or as indices.
  | InstanceRead
    -- ^ Read by vertex input and by shaders.
  | StorageRead
    -- ^ Read as storage by the vertex and fragment shaders.
  | TransferRead
    -- ^ The source of a copy.
  | TransferWrite
    -- ^ The destination of a copy.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The one use a resource of this kind rests in: what every batch finds it
-- in, and must leave it in.
restingUse ∷ ResourceKind → ResourceUse
restingUse = \case
  TextureResource → ShaderSampled
  DepthTargetResource → DepthAttachment
  ColorTargetResource → ColorAttachment
  VertexResource → GeometryRead
  IndexResource → GeometryRead
  InstanceResource → InstanceRead
  LookupResource → StorageRead
  StagingResource → TransferRead

-- | Every use a resource of this kind may be put to, its resting use first.
-- Each is one its kind's usage provides for: a texture is uploaded into and
-- copied out of (GRS-6, for verification), a color target copied out of, and
-- static geometry staged into.
legalUses ∷ ResourceKind → [ResourceUse]
legalUses = \case
  TextureResource → [ShaderSampled, TransferWrite, TransferRead]
  DepthTargetResource → [DepthAttachment]
  ColorTargetResource → [ColorAttachment, TransferRead]
  VertexResource → [GeometryRead, TransferWrite]
  IndexResource → [GeometryRead, TransferWrite]
  InstanceResource → [InstanceRead]
  LookupResource → [StorageRead]
  StagingResource → [TransferRead]

-- | Whether a command keeps a resource's contents or overwrites all of them:
-- an attachment pass that clears, for instance, discards what was there.
data Contents = KeepsContents | DiscardsContents
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Where an explicit transition starts: the use the resource is in, whose
-- contents it keeps, or undefined contents, which it discards. Only an image's
-- contents can be undefined.
data TransitionSource
  = FromUse !ResourceUse
  | FromUndefined
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- A batch's accesses

-- | The use each resource a batch has touched is in, keyed by whatever
-- identifies a resource to the caller. A resource the batch has not touched is
-- at rest.
newtype BatchAccess k = BatchAccess (Map k (ResourceKind, ResourceUse))
  deriving (Eq, Show)

-- | A batch that has touched nothing.
emptyAccess ∷ BatchAccess k
emptyAccess = BatchAccess Map.empty

-- | The use a resource is in within the batch, once the batch has touched it.
accessUse ∷ Ord k ⇒ k → BatchAccess k → Maybe ResourceUse
accessUse key (BatchAccess touched) = snd <$> Map.lookup key touched

-- | Every resource the batch has touched, with its kind and the use it is in.
touchedResources ∷ BatchAccess k → [(k, ResourceKind, ResourceUse)]
touchedResources (BatchAccess touched) = [(key, kind, use) | (key, (kind, use)) ← Map.toAscList touched]

-- | Why a batch records a barrier.
data BarrierRole
  = EntryBarrier
    -- ^ The batch's first touch of the resource: from its resting use into
    -- the use the batch first puts it to. On the one queue its first scope
    -- covers every earlier submission, so it chains to earlier batches' exit
    -- barriers.
  | TransitionBarrier
    -- ^ An explicit transition the consumer asked for.
  | ExitBarrier
    -- ^ Before the batch seals: from its resting use, where the consumer must
    -- have left it, back to the resting use.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One barrier a batch owes, in engine terms: the use whose accesses it
-- waits for, the use it makes ready, and whether the contents survive it. A
-- barrier that discards takes an image out of an undefined layout.
data Barrier k = Barrier
  { barrierResource ∷ !k
  , barrierKind ∷ !ResourceKind
  , barrierRole ∷ !BarrierRole
  , barrierAfter ∷ !ResourceUse
  , barrierBefore ∷ !ResourceUse
  , barrierDiscards ∷ !Bool
  }
  deriving (Eq, Show)

-- | Why a command or a seal was refused. Nothing changed.
data AccessRefusal k
  = UseNotLegal !ResourceKind !ResourceUse
    -- ^ The kind is never put to that use.
  | DiscardNotLegal !ResourceKind
    -- ^ Only an image's contents can be discarded.
  | UseMismatch !ResourceUse !ResourceUse
    -- ^ The resource is in the first use, and the command assumed the second.
  | KindMismatch !ResourceKind !ResourceKind
    -- ^ The batch touched the resource as the first kind, and the command
    -- names it as the second.
  | AwayFromRest !k !ResourceKind !ResourceUse
    -- ^ The batch would end with the resource in this use, which is not its
    -- kind's resting use.
  deriving (Eq, Show)

-- | A command's use of a resource in the use it is already in. The first
-- touch finds it at rest, and owes the entry barrier into it; a command that
-- discards the contents takes the entry barrier from undefined, which is how
-- an attachment pass that clears initializes an image. Any later use must be
-- the use the batch left the resource in: moving it is a 'transition'.
touch ∷ Ord k ⇒ k → ResourceKind → ResourceUse → Contents → BatchAccess k → Either (AccessRefusal k) (BatchAccess k, [Barrier k])
touch key kind use contents access@(BatchAccess touched) = do
  legal kind use
  discards ← discarding kind contents
  current ← currentUse key kind access
  if current /= use
    then Left (UseMismatch current use)
    else
      pure
        ( BatchAccess (Map.insert key (kind, use) touched)
        , [Barrier key kind EntryBarrier (restingUse kind) use discards | not (Map.member key touched)]
        )

-- | An explicit transition, from a use the resource is in, or from undefined
-- contents, into another use of its kind. A transition to the use it is in is
-- legal: it orders the batch's earlier accesses in that use before its later
-- ones, such as two passes writing one depth target.
--
-- On the batch's first touch the resource is at rest, so a transition from a
-- use must start from the resting use. Either way the first touch's
-- transition is the batch's entry barrier: one barrier from the resting
-- scope straight into its destination, which a transition from undefined
-- takes discarding the contents.
transition ∷ Ord k ⇒ k → ResourceKind → TransitionSource → ResourceUse → BatchAccess k → Either (AccessRefusal k) (BatchAccess k, [Barrier k])
transition key kind from to access@(BatchAccess touched) = do
  legal kind to
  current ← currentUse key kind access
  let first = not (Map.member key touched)
      next = BatchAccess (Map.insert key (kind, to) touched)
  case from of
    FromUse use → do
      legal kind use
      if use /= current
        then Left (UseMismatch current use)
        else pure (next, [Barrier key kind (role first) use to False])
    FromUndefined → do
      _ ← discarding kind DiscardsContents
      pure (next, [Barrier key kind (role first) current to True])
  where
    role first = if first then EntryBarrier else TransitionBarrier

-- | Whether the batch may seal, and the exit barriers it then owes: one for
-- every resource it touched, from the resting use back to it. A resource left
-- in any other use refuses the seal; an exit barrier never stands in for the
-- transition the consumer omitted.
sealAccess ∷ BatchAccess k → Either (AccessRefusal k) [Barrier k]
sealAccess access =
  case [(key, kind, use) | (key, kind, use) ← touchedResources access, use /= restingUse kind] of
    (key, kind, use) : _ → Left (AwayFromRest key kind use)
    [] → Right [Barrier key kind ExitBarrier use use False | (key, kind, use) ← touchedResources access]

-- | Whether a barrier is an entry that initializes its image: an entry that
-- discards the contents.
entryInitializes ∷ Barrier k → Bool
entryInitializes barrier = barrierRole barrier == EntryBarrier && barrierDiscards barrier

-- ---------------------------------------------------------------------------
-- Checks

legal ∷ ResourceKind → ResourceUse → Either (AccessRefusal k) ()
legal kind use
  | use `elem` legalUses kind = Right ()
  | otherwise = Left (UseNotLegal kind use)

discarding ∷ ResourceKind → Contents → Either (AccessRefusal k) Bool
discarding kind = \case
  KeepsContents → Right False
  DiscardsContents
    | isImageKind kind → Right True
    | otherwise → Left (DiscardNotLegal kind)

-- | The use the resource is in within the batch: its resting use until the
-- batch touches it. A batch that touched it as another kind refuses.
currentUse ∷ Ord k ⇒ k → ResourceKind → BatchAccess k → Either (AccessRefusal k) ResourceUse
currentUse key kind (BatchAccess touched) = case Map.lookup key touched of
  Nothing → Right (restingUse kind)
  Just (recorded, use)
    | recorded /= kind → Left (KindMismatch recorded kind)
    | otherwise → Right use
