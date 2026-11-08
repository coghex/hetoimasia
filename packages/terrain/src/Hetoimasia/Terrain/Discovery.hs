-- | Compressed knowledge and resumable discovery over source plus removals: the
-- pure model behind underground fog of war (TRA-19).
--
-- The model decides and records; it performs nothing. It has no I/O, thread,
-- clock, mutable registry, Lua, graphics or game dependency. A later store
-- (TRA-20) encodes its records, and a later terrain owner (TRA-22) holds the
-- committed value, supplies the arena and revision authority and publishes
-- candidates; neither exists here.
--
-- = Three separate meanings
--
-- * /Terrain/ is what a cell holds: the immutable "Hetoimasia.Terrain.Source"
--   plus the removals this model retains. Removals only enlarge empty space, so
--   a source component stays a connected subset of the larger space after any
--   removal. Placement, reshaping and any change that could split a space are
--   outside this contract.
--
-- * /Residency/ ("Hetoimasia.Terrain.Residency", "Hetoimasia.Terrain.Resident")
--   is which detail is materialized. Loading, eviction, camera motion and cutaway
--   changes never grant knowledge, and knowledge never pins detail.
--
-- * /Knowledge/ is what the player has discovered. It belongs to a connected
--   class of empty space (see below) and is retained by compressed identity.
--   Known /solid/ and known /void/ are separate facts: the solid face of a ramp
--   is known when it is exposed to known empty space, the empty space above the
--   ramp only when its own class is known ('CellKnowledge', 'presentation').
--   Generic fog is presentation only and never changes occupancy, a logical
--   query or connectivity.
--
-- = Initial knowledge
--
-- The initial known set is exactly the compiled source's exterior
-- classification ("Hetoimasia.Terrain.Connectivity".'Hetoimasia.Terrain.Connectivity.isExterior'):
-- components connected through positive-area openings to the upper Z boundary.
-- It is computed from the compiled source without flooding sky, preloading an
-- exterior cave or using a fixed Z threshold. Every other component starts
-- unknown, and a sealed space stays unknown whatever is queried, resident or
-- raw-edited.
--
-- = The forest
--
-- A node is a source component ('SrcNode') or a run of removed levels of one
-- column ('RunNode'). Joining two classes records a child pointer and rewrites
-- the larger class's root, which holds the class size and whether it is known.
-- A class is known when it holds an exterior component or has been joined to
-- known space, so joining a known class to an unknown one makes every member of
-- the unknown class known in one record: a source range, a family of parameters
-- joined by an earlier removal, many removed runs. A range of repeated
-- components is never enumerated and uninvolved members of a family are never
-- merged because their bounds overlap; only the components a removal's faces
-- actually reach are joined. Union by size bounds a chain by 'maxLinkChain'.
--
-- Removed runs keep their identity across edits: a run whose lower end moves, or
-- two runs a new removal bridges, are joined to the run that takes their place
-- in the same candidate, so no alias is left naming a vanished run.
--
-- = Removal and its obligation
--
-- 'stageRemoval' produces one complete candidate delta: the canonical removal
-- and a retained /obligation/ naming the cell. Neither half applies alone (the
-- candidate is one value). The obligation holds the connections the removal
-- introduces: the cell's own old void and its six faces, where the full-air cell
-- meets a neighbour's portals over positive area (shared with
-- "Hetoimasia.Terrain.Opening"; edge and point contact never connects) and the
-- upper boundary of the world. Removing air or an already removed cell is
-- 'NoChange': no history, no obligation, no revision. The existing
-- "Hetoimasia.Terrain.Changes" functions are unchanged and their result is not
-- this model's authority; 'retainedRemovals' converts the other way for the
-- consumers that read 'Hetoimasia.Terrain.Changes.Changes'.
--
-- A raw removal inside a sealed unknown space records its connections and joins
-- its own classes but joins no known class, so it reveals nothing. A later
-- opening from known space joins the whole modified class and discovers it.
--
-- = Discovery batches
--
-- 'stepDiscovery' inspects connections of the oldest unfinished obligation, one
-- /structural update/ per connection: one neighbour found by exact geometry, at
-- most one pair of classes joined, and the obligation's progress. It performs at
-- most the validated 'limitBatchUpdates' (1 to 64) updates and returns a
-- candidate with the continuation implicit in the obligation record. Every
-- connection is inspected once and against the state at inspection time, so a
-- connection adjacent to an already known or already expanded region is joined,
-- a known class reached through two fronts is joined once, and reaching sky ends
-- only the outward branch: no obligation is dropped because another front found
-- an exit. An obligation is /unseen/ before its first connection, /pending/
-- while partly inspected and /expanded/ (deleted) when finished; none of the
-- three is the same as the knowledge of the class it touches, and an unfinished
-- obligation inside a known class is still inspected.
--
-- Completion means no unfinished obligation: the connected space and its exposed
-- boundary are then known by identity, with no cell, boundary tile or resident
-- detail enumerated or required.
--
-- = Exposed boundary knowledge
--
-- It is derived, not copied per chunk. 'queryCell' resolves a tile's solid
-- knowledge from exact contact geometry (a known void whose portal lies over the
-- tile's solid face section by positive area, the tile's own known void, or the
-- sky above the top level), and 'queryKnownBoundary' gives a known component's
-- compressed boundary faces one bounded page at a time: a page scans at most
-- 'limitBoundaryFaces' boxes of the component's class and returns at most as many
-- faces, with the position of the next page, and its accounted bytes are charged
-- before it is built. A chunk reloaded later resolves the same answer from the
-- retained records alone, with no per-chunk marker.
--
-- = Records, windows and missing data
--
-- All retained state is plain data in "Records"-style keys: removed runs, forest
-- links and roots, and obligations, plus a small resident 'Header' (authority,
-- the oldest and next obligation sequence, accounted bytes). An operation reads
-- through a 'Provider', a bounded window, never the whole history. A record the
-- provider has not supplied suspends the operation with its obligation intact
-- ('EditSuspended', 'Stalled', 'HaltSuspended', 'MissingRecord'); it is never read
-- as absent, as air, as newly forgotten fog or as proof that no connection
-- exists. A confirmed 'Absent' record is a different fact. The model never
-- regenerates pristine source state in place of a record it was not given.
--
-- = Authority and publication
--
-- A candidate names the 'Authority' it read: the arena incarnation (an
-- 'Hetoimasia.Terrain.Residency.ArenaId') and the content, knowledge and store
-- revisions. __The revision rule__ is stated once: content advances exactly when a
-- candidate changes terrain (an applied removal); knowledge advances exactly when a
-- candidate makes known space that was not known (a class becomes known, or a cell
-- joins a known class: an extended or bridged run, a known old void), and never
-- decreases; store advances on every candidate (obligation progress and unions that
-- change no knowledge). A reader that keyed a derived result by the knowledge
-- revision is stale as soon as the retained revision differs, one keyed by content
-- when terrain changed; a stale reader keeps the old immutable value, correct for the
-- authority it names, and a stale holder of a candidate is refused. 'applyCandidate' accepts it only against exactly that authority, so
-- a candidate from a closed incarnation, or one made stale by an applied
-- candidate (a frontier-only one included), is refused and applied nowhere. A
-- candidate says whether it changes terrain (content revision), knowledge
-- (knowledge revision) or neither (frontier or union maintenance, store
-- revision only). Revision and sequence arithmetic is checked and refuses on
-- overflow. Staging is not publication: values are immutable, a discarded
-- candidate leaks nothing, and atomic publication, file writes and cancellation
-- belong to TRA-20 to TRA-22. Retention here is session semantics, not a save
-- or crash-recovery promise.
--
-- = Limits and accounting
--
-- 'DiscoveryLimits' are validated: a figure outside its range, or too small for
-- one minimal progress step, is refused by field and never clamped. An
-- 'Allowance' can only tighten them per call. Every resource is charged through one
-- function (a provider read, a staged write and the output of a query page are each
-- a charge), checked against every cap before the work happens, and the reported peak
-- is read from the same state, so a rejected or suspended attempt reports what it had
-- been charged. Costs are conservative accounted
-- bytes and counts (a model counter proves neither final encoded pages nor
-- process RSS): keys, aliases, boundary-free obligations, container overhead and
-- scratch are charged; the shared compiled source is charged once, to the arena
-- ('envSharedBytes'), never to a candidate. A step that cannot fit is refused
-- with the resource and leaves the prior value and every obligation intact;
-- pending capacity never reads as completion. The integration envelope is P-15's
-- 64 MiB edit bank (48 MiB record caches, 8 MiB staging, 8 MiB control), at most
-- 4 MiB of RAM and 1 MiB of encoded pages per later store transaction, and at
-- most 64 structural updates per batch; the model can stop below 64 when its
-- allowance is tighter, and exact page charges and bank enforcement are later
-- slices.
module Hetoimasia.Terrain.Discovery
  ( -- * Limits
    DiscoverySpec (..)
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

    -- * Worst-case costs
  , maxLinkChain
  , worstEdgeReads
  , worstEdgeWrites
  , worstEditReads
  , worstEditWrites
  , maxRecordBytes
  , headerBytes
  , minimumDeltaBytes
  , minimumScratchBytes
  , minimumRetainedBytes
  , minimumBoundaryFaces
  , boundaryFaceBytes
  , traversalBytes
  , boundaryPageBytes
  , boundaryQueryScratch

    -- * The environment
  , Env
  , mkEnv
  , envLimits
  , envSharedBytes

    -- * Records
  , Node (..)
  , RecordKey (..)
  , Record (..)
  , Root (..)
  , Todo (..)
  , edgeCount
  , Authority (..)
  , Header (..)
  , pendingObligations
  , Fetch (..)
  , Provider (..)
  , recordProvider
  , entryBytes

    -- * Failures
  , Integrity (..)
  , Capacity (..)
  , Refusal (..)
  , Unresolved (..)
  , Observed (..)

    -- * Staging
  , Candidate
  , candidateBase
  , candidateNext
  , candidateWrites
  , candidateTerrain
  , candidateKnowledge
  , candidateFrontierOnly
  , candidateReport
  , Report (..)
  , StageOutcome (..)
  , stageRemoval
  , Halt (..)
  , Step (..)
  , stepDiscovery

    -- * Retained state
  , Retained
  , newRetained
  , retainedHeader
  , retainedRecords
  , retainedProvider
  , retainedBytes
  , retainedRemovals
  , retainedFromRecords
  , ApplyError (..)
  , applyCandidate

    -- * Knowledge
  , VoidKnowledge (..)
  , SolidKnowledge (..)
  , CellKnowledge (..)
  , Presentation (..)
  , presentation
  , queryCell
  , queryRemoved
  , queryComponentKnown
  , BoundaryPage (..)
  , queryKnownBoundary
  , queryNodeClass
  , ObligationState (..)
  , queryObligation
  ) where

import Hetoimasia.Terrain.Internal.Discovery.Core
import Hetoimasia.Terrain.Internal.Discovery.Limits
import Hetoimasia.Terrain.Internal.Discovery.Records
