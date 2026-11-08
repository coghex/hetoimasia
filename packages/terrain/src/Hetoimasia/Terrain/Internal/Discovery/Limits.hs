-- | Validated limits and the worst-case step costs of the discovery model.
--
-- The constructor of 'DiscoveryLimits' and its fields are private, as in
-- "Hetoimasia.Terrain.Internal.Connectivity.Limits" and
-- "Hetoimasia.Terrain.Residency": a plain 'DiscoverySpec' goes through one
-- checked constructor, a figure outside its documented range is refused by field
-- and nothing is clamped. A configuration too small for one minimal progress
-- step (one removal with the continuation it needs, or one structural update
-- with its worst-case inspected input) is refused too, with the figure it needs,
-- so a limit that can never fit gives a typed refusal and never an indefinite
-- pending state.
--
-- State, ownership and lifetime: none. Limits are immutable values.
module Hetoimasia.Terrain.Internal.Discovery.Limits
  ( DiscoverySpec (..)
  , LimitField (..)
  , LimitError (..)
  , DiscoveryLimits
  , mkDiscoveryLimits
  , defaultDiscoveryLimits
  , limitBatchUpdates
  , limitInspectedRecords
  , limitDeltaRecords
  , limitDeltaBytes
  , limitScratchBytes
  , limitPendingObligations
  , limitRetainedBytes
  , limitBoundaryFaces
  , Allowance (..)
  , allowanceOf
  , maxBatchUpdates

    -- * Worst-case costs of one step
  , maxLinkChain
  , findReadsBound
  , worstEdgeReads
  , worstEdgeWrites
  , worstEditReads
  , worstEditWrites
  , maxRecordBytes
  , headerBytes
  , worstEdgeBytes
  , worstEditBytes
  , worstEdgeScratch
  , worstEditScratch
  , minimumDeltaBytes
  , minimumScratchBytes
  , minimumRetainedBytes
  , minimumBoundaryFaces
  , boundaryFaceBytes
  , traversalBytes
  , boundaryPageBytes
  , boundaryQueryScratch
  ) where

-- | The most hops a union-find chain may take. Union by size bounds a chain by
-- the base-two logarithm of the number of nodes it joins, at most 63 for a
-- 64-bit size, so a longer chain is a corrupt record, not a legitimate state.
maxLinkChain ∷ Int
maxLinkChain = 64

-- | The most records one root lookup reads: every child link and the root.
findReadsBound ∷ Int
findReadsBound = maxLinkChain + 1

-- | The most records one edge inspection reads: the floor lookups of the removed
-- cell's own run and of the neighbour's, and two root lookups for the union.
worstEdgeReads ∷ Int
worstEdgeReads = 2 + 2 * findReadsBound

-- | The most records one edge inspection writes: the loser's child link, the
-- winner's root and the obligation record.
worstEdgeWrites ∷ Int
worstEdgeWrites = 3

-- | The most records one removal reads: the floor lookup that finds the cell and
-- the run below it, the lookup of the run above, the root lookups when the
-- removal joins two runs and the root lookup that joins the new run to the
-- cell's own old void.
worstEditReads ∷ Int
worstEditReads = 2 + 3 * findReadsBound

-- | The most records one removal writes: the merged run, the absorbed run's
-- deletion, the two unions' four records and the new obligation.
worstEditWrites ∷ Int
worstEditWrites = 7

-- | A conservative accounted size of the largest single record entry: the key,
-- the value and the container overhead.
maxRecordBytes ∷ Int
maxRecordBytes = 256

-- | The accounted size of the control header, which is always resident.
headerBytes ∷ Int
headerBytes = 128

-- | The most accounted bytes one edge inspection adds to a candidate.
worstEdgeBytes ∷ Int
worstEdgeBytes = worstEdgeWrites * maxRecordBytes

-- | The most accounted bytes one removal adds to a candidate.
worstEditBytes ∷ Int
worstEditBytes = worstEditWrites * maxRecordBytes

-- | The most scratch bytes one edge inspection holds: every record it reads and
-- every record it stages.
worstEdgeScratch ∷ Int
worstEdgeScratch = (worstEdgeReads + worstEdgeWrites) * maxRecordBytes

-- | The most scratch bytes one removal holds.
worstEditScratch ∷ Int
worstEditScratch = (worstEditReads + worstEditWrites) * maxRecordBytes

-- | The smallest candidate payload that holds one removal.
minimumDeltaBytes ∷ Int
minimumDeltaBytes = worstEditBytes + headerBytes

-- | The smallest scratch allowance that holds one removal.
minimumScratchBytes ∷ Int
minimumScratchBytes = max worstEditScratch worstEdgeScratch

-- | The smallest retained-record allowance that holds one removal.
minimumRetainedBytes ∷ Int
minimumRetainedBytes = headerBytes + worstEditBytes

-- | The accounted bytes of one boundary face in a query page.
boundaryFaceBytes ∷ Int
boundaryFaceBytes = 128

-- | The accounted bytes of a boundary page's traversal state.
traversalBytes ∷ Int
traversalBytes = 64

-- | The fewest faces a boundary page may hold: one box of a class has up to six.
minimumBoundaryFaces ∷ Int
minimumBoundaryFaces = 6

-- | The accounted scratch of a boundary page of at most @n@ faces, charged
-- before the page is built.
boundaryPageBytes ∷ Int → Int
boundaryPageBytes n = n * boundaryFaceBytes + traversalBytes

-- | The accounted scratch a boundary query needs in the worst case: the lookup of
-- the component's class (a chain of at most 'findReadsBound' records, each charged
-- the largest record) and then a page of at most @n@ faces. Validation requires the
-- scratch limit to cover it, so no accepted configuration refuses every query.
boundaryQueryScratch ∷ Int → Int
boundaryQueryScratch n = findReadsBound * maxRecordBytes + boundaryPageBytes n

-- | The most structural updates one discovery batch performs: P-15 clause 4.
maxBatchUpdates ∷ Int
maxBatchUpdates = 64

-- | Unvalidated limits, as a caller states them. Every field is an 'Integer' so
-- that an unrepresentable figure is refused by name instead of wrapping.
data DiscoverySpec = DiscoverySpec
  { specBatchUpdates ∷ !Integer
  -- ^ Structural updates in one discovery batch, @1 .. 64@.
  , specInspectedRecords ∷ !Integer
  -- ^ Records one operation may read from the supplied provider.
  , specDeltaRecords ∷ !Integer
  -- ^ Records one candidate delta may write or delete.
  , specDeltaBytes ∷ !Integer
  -- ^ Accounted bytes of one candidate delta.
  , specScratchBytes ∷ !Integer
  -- ^ Accounted bytes of the scratch one operation holds.
  , specPendingObligations ∷ !Integer
  -- ^ Unfinished obligations the frontier may hold.
  , specRetainedBytes ∷ !Integer
  -- ^ Accounted bytes of all retained records and the header.
  , specBoundaryFaces ∷ !Integer
  -- ^ Boxes scanned and faces returned in one page of a boundary query, at least
  -- 6; the query's accounted bytes (lookup and page) must fit the scratch.
  }
  deriving stock (Eq, Show)

-- | The field a refusal names.
data LimitField
  = FieldBatchUpdates
  | FieldInspectedRecords
  | FieldDeltaRecords
  | FieldDeltaBytes
  | FieldScratchBytes
  | FieldPendingObligations
  | FieldRetainedBytes
  | FieldBoundaryFaces
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a limit configuration was refused. A configuration error is never a
-- capacity outcome of an operation.
data LimitError
  = -- | The figure is zero or negative: nothing could fit it.
    LimitNotPositive !LimitField !Integer
  | -- | The figure is above the field's ceiling, so checked arithmetic could not
    -- stay exact (or, for the batch, P-15's 64-update bound): the field, the
    -- figure and the ceiling.
    LimitUnrepresentable !LimitField !Integer !Integer
  | -- | The figure is positive but smaller than one minimal progress step needs:
    -- the field, the figure and the figure it needs. The model could never make
    -- progress under it.
    LimitBelowProgress !LimitField !Integer !Integer
  deriving stock (Eq, Show)

-- | A validated set of limits. The constructor is private.
data DiscoveryLimits = DiscoveryLimits
  { lBatch ∷ !Int
  , lReads ∷ !Int
  , lRecords ∷ !Int
  , lDeltaBytes ∷ !Int
  , lScratch ∷ !Int
  , lPending ∷ !Int
  , lRetained ∷ !Int
  , lBoundary ∷ !Int
  }
  deriving stock (Eq, Show)

countCeiling ∷ Integer
countCeiling = 2 ^ (24 ∷ Int)

byteCeiling ∷ Integer
byteCeiling = 2 ^ (40 ∷ Int)

boundaryCeiling ∷ Integer
boundaryCeiling = 2 ^ (16 ∷ Int)

pendingCeiling ∷ Integer
pendingCeiling = 2 ^ (32 ∷ Int)

-- | The initial limits. A batch of 64 updates, the reads, writes and bytes those
-- updates need in the worst case, a 1 MiB candidate payload and 4 MiB of scratch
-- (P-15's per-transaction page and RAM bounds), 65,536 unfinished obligations
-- and 48 MiB of retained records (the record-cache share of the edit bank). The
-- shared source metadata is charged once elsewhere, not to these.
defaultDiscoveryLimits ∷ DiscoveryLimits
defaultDiscoveryLimits =
  DiscoveryLimits
    { lBatch = maxBatchUpdates
    , lReads = maxBatchUpdates * worstEdgeReads
    , lRecords = maxBatchUpdates * worstEdgeWrites
    , lDeltaBytes = 1024 * 1024
    , lScratch = 4 * 1024 * 1024
    , lPending = 65536
    , lRetained = 48 * 1024 * 1024
    , lBoundary = 1024
    }

-- | Validate a specification. The first refused field, in declaration order, is
-- reported. The admissible ranges are: the batch in @[1, 64]@, the reads and
-- writes in @[need, 2^24]@, the byte figures in @[need, 2^40]@ and the
-- obligations in @[1, 2^32]@, where @need@ is what one removal costs in the
-- worst case ('worstEditReads', 'worstEditWrites', 'minimumDeltaBytes',
-- 'minimumScratchBytes' and 'minimumRetainedBytes').
mkDiscoveryLimits ∷ DiscoverySpec → Either LimitError DiscoveryLimits
mkDiscoveryLimits spec = do
  batch ← check FieldBatchUpdates (toInteger maxBatchUpdates) 1 (specBatchUpdates spec)
  reads' ← check FieldInspectedRecords countCeiling (toInteger worstEditReads) (specInspectedRecords spec)
  records ← check FieldDeltaRecords countCeiling (toInteger worstEditWrites) (specDeltaRecords spec)
  deltaBytes ← check FieldDeltaBytes byteCeiling (toInteger minimumDeltaBytes) (specDeltaBytes spec)
  scratch ← check FieldScratchBytes byteCeiling (toInteger minimumScratchBytes) (specScratchBytes spec)
  pending ← check FieldPendingObligations pendingCeiling 1 (specPendingObligations spec)
  retained ← check FieldRetainedBytes byteCeiling (toInteger minimumRetainedBytes) (specRetainedBytes spec)
  boundary ← check FieldBoundaryFaces boundaryCeiling (toInteger minimumBoundaryFaces) (specBoundaryFaces spec)
  -- A page must fit the scratch, or no boundary query could ever make progress.
  if scratch < boundaryQueryScratch boundary
    then Left (LimitBelowProgress FieldScratchBytes (toInteger scratch) (toInteger (boundaryQueryScratch boundary)))
    else pure ()
  pure (DiscoveryLimits batch reads' records deltaBytes scratch pending retained boundary)
  where
    check field top need n
      | n <= 0 = Left (LimitNotPositive field n)
      | n > top = Left (LimitUnrepresentable field n top)
      | n < need = Left (LimitBelowProgress field n need)
      | otherwise = Right (fromInteger n)

-- | Structural updates in one discovery batch.
limitBatchUpdates ∷ DiscoveryLimits → Int
limitBatchUpdates = lBatch

-- | Records one operation may read.
limitInspectedRecords ∷ DiscoveryLimits → Int
limitInspectedRecords = lReads

-- | Records one candidate may write or delete.
limitDeltaRecords ∷ DiscoveryLimits → Int
limitDeltaRecords = lRecords

-- | Accounted bytes of one candidate.
limitDeltaBytes ∷ DiscoveryLimits → Int
limitDeltaBytes = lDeltaBytes

-- | Accounted scratch bytes of one operation.
limitScratchBytes ∷ DiscoveryLimits → Int
limitScratchBytes = lScratch

-- | Unfinished obligations the frontier may hold.
limitPendingObligations ∷ DiscoveryLimits → Int
limitPendingObligations = lPending

-- | Accounted bytes of all retained records.
limitRetainedBytes ∷ DiscoveryLimits → Int
limitRetainedBytes = lRetained

-- | Faces in one page of a boundary query.
limitBoundaryFaces ∷ DiscoveryLimits → Int
limitBoundaryFaces = lBoundary

-- | What the caller can fund for one operation right now. It can only tighten
-- the validated limits, never loosen them: a step uses the smaller of each. An
-- allowance too small for one minimal step blocks the operation with a typed
-- refusal; nothing is partly done.
data Allowance = Allowance
  { allowReads ∷ !Int
  -- ^ Records the operation may read.
  , allowWrites ∷ !Int
  -- ^ Records the candidate may write or delete.
  , allowDeltaBytes ∷ !Int
  -- ^ Accounted bytes of the candidate.
  , allowScratchBytes ∷ !Int
  -- ^ Accounted scratch bytes.
  }
  deriving stock (Eq, Show)

-- | The allowance that grants every validated limit.
allowanceOf ∷ DiscoveryLimits → Allowance
allowanceOf limits =
  Allowance
    { allowReads = lReads limits
    , allowWrites = lRecords limits
    , allowDeltaBytes = lDeltaBytes limits
    , allowScratchBytes = lScratch limits
    }
