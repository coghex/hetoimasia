-- | The exact empty-space connectivity of a validated source, compiled
-- symbolically and within bounds.
--
-- Given a 'Source' (layers shared by every column plus bounded per-column
-- patches), this module derives which empty spaces connect, which are initially
-- exterior and a canonical identity for every connected component, without
-- instantiating a column, an air cell or a buried solid cell of the world. A
-- range of repeated components is one description, never a mass of members, and
-- the work grows with the authored boundaries and the connectivity they create,
-- never with the span of an interval or the number of identical members.
--
-- = Contract
--
-- * __Exactness.__ Two empty spaces connect exactly when a chain of cells joins
--   them in which every consecutive pair shares a face and their portals on it
--   overlap over positive area, per "Hetoimasia.Terrain.Opening" (the one
--   geometric authority: shape 0 is the full block, ID 15 the central
--   half-height peak, no nonflat shape has a bottom opening of positive area).
--   Edge and point contacts do not connect; there is no tolerance and no
--   blanket 26-neighbour rule, so real diagonal paths through shaped voids
--   exist exactly where face-by-face chains do. Bounding boxes, shape bits and
--   rendered alpha are never proofs.
--
-- * __Component families.__ One rectangular range is not necessarily one space:
--   a covered uniform N-ramp layer has a separate channel per row and per
--   level, because the south face is sealed and the north face is open, and
--   stacked nonflat cells never connect between levels. A component therefore
--   has /parameters/ (the row, the column, the level) where its cells do not
--   connect along an axis, and a key spanning many members never claims the
--   members are connected. An authored patch splits a channel into fragments
--   (a full block) or joins channels and levels (a shaft of air); a join that
--   holds throughout a range of parameters removes that parameter from the
--   joined components symbolically.
--
-- * __Exterior.__ A component is initially exterior exactly when it connects
--   through positive-area openings to the /upper/ Z boundary, which includes
--   unobstructed sky. The X and Y limits and the lower Z limit open nothing, so
--   a covered air slab that spans the horizontal limits is sealed; a full block
--   at the highest cell supplies no opening, while a topmost shape's actual top
--   portal can reach the outside. The result is initial exterior metadata,
--   computed without flooding the sky or allocating a boundary cell. It is not
--   a mutable discovered-tile set: no knowledge, edit union or progress lives
--   here, and a sealed component stays sealed whatever is queried or resident.
--
-- * __Identity.__ A 'ComponentKey' is the origin of the component's class and
--   the values of the class's remaining parameters. It depends on the validated
--   source and the member's parameters only, never on chunk load order, query
--   order or how the preparation was divided into quanta. The module promises
--   no public disk encoding and no equivalence between differently authored but
--   semantically equal recipes.
--
-- * __Queries.__ 'lookupVoid' addresses a /void/ of a cell, not just a cell, so
--   it stays correct for a future shape with more than one; a full block
--   answers 'NoVoid' explicitly, never air and never unknown. 'componentRanges',
--   'componentRelations' and 'componentBoundary' describe a component by the
--   boxes of its class (a boundary face is a rectangle of cells, not a tile), so
--   later discovery can look up a component's or range's boundary without
--   enumerating exposed tiles.
--
-- = Preparation and limits
--
-- 'startPreparation' returns a suspended 'Preparation'; 'resumePreparation'
-- runs at most one /quantum/ of counted primitive steps (at most 1,024) and
-- returns 'Pending', 'Complete' or 'Refused'. Nothing is usable until
-- 'Complete': a refusal exposes no partial index, and dropping a 'Preparation'
-- discards it with no effect on any other value. There are no threads, I/O or
-- clocks; fair scheduling, cancellation acknowledgment and the release of shared
-- admission reservations belong to the later service. The defaults
-- ('defaultConnectivityLimits') are the approved initial bounds:
--
-- +------------------------------------+------------------------------+
-- | Resource                           | Bound                        |
-- +====================================+==============================+
-- | Complete result                    | 16 MiB (accounted)           |
-- | Peak, including the result         | 48 MiB (accounted)           |
-- | Structural nodes                   | 65,536                       |
-- | Portal relations                   | 262,144                      |
-- | Total work                         | 8,388,608 primitive steps    |
-- | One quantum                        | at most 1,024 steps          |
-- +------------------------------------+------------------------------+
--
-- A MiB is @2^20@ bytes. Bytes are conservative admission figures (the
-- constants exported below), not heap or process RSS. They are charged before
-- the allocation or work they pay for. A valid source whose connectivity needs
-- more than a limit is refused with a typed 'Refusal' naming the 'Resource' and
-- the needed and limit figures; the later integration maps any 'Complexity'
-- refusal to the Lua domain code @source_complexity@. An invalid configuration
-- is a different, earlier refusal ('LimitError') and never reported that way.
-- There is no dense fallback, truncated connectivity, guessed exterior or
-- silently reduced source language.
--
-- = What is charged to whom
--
-- The source definition (at most 256 KiB and 8,192 authored runs, enforced by
-- 'Hetoimasia.Terrain.Source.mkSource') is shared immutable input. Its bytes
-- stay governed by 'Hetoimasia.Terrain.Source.sourceDefinitionBytes' and the
-- existing independent source limit; they are excluded from this compiler's
-- result and peak figures, and this slice invents no resident-bank charge for
-- them (any charge for the retained source is the arena-admission integration's
-- choice). Only the newly derived metadata is accounted: the compiled result is
-- charged once per arena to the resident terrain bank by the later service, and
-- the temporaries of the one compilation active per session are charged to the
-- same bank while they exist. This module creates no bank, service, semaphore or
-- session owner.
--
-- = Counted steps
--
-- A step is one of: forcing one entry of the connection table, adding one
-- authored layer, patch column or patch interval to the cuts, classifying one
-- lattice box, testing one node against one neighbour (recording the relation
-- when they connect), folding one mark or node into the canonical result, or
-- assembling the result. Each is a constant number of operations on containers
-- the limits bound, so no step scans a coordinate extent, an unbounded container
-- or an arbitrary recipe. The lattice (the product of the cuts per axis) is
-- refused up front when it alone exceeds the remaining work.
--
-- = Ownership and lifetime
--
-- None. Every value here is immutable and every function pure: a 'Connectivity'
-- is built whole and never mutated, a 'Preparation' is a suspended pure
-- computation, and the module owns no thread, resource, queue or disposal.
module Hetoimasia.Terrain.Connectivity
  ( -- * Limits
    LimitsSpec (..)
  , LimitField (..)
  , LimitError (..)
  , ConnectivityLimits
  , mkConnectivityLimits
  , defaultConnectivityLimits
  , limitResultBytes
  , limitPeakBytes
  , limitNodes
  , limitRelations
  , limitWorkSteps
  , limitQuantumSteps

    -- * Preparing
  , Preparation
  , Progress (..)
  , ResumeError (..)
  , Resource (..)
  , Refusal (..)
  , PrepareError (..)
  , PrepareStats (..)
  , startPreparation
  , resumePreparation
  , preparationStats
  , prepareConnectivity

    -- * Accounting figures
  , headerResultBytes
  , cutResultBytes
  , nodeResultBytes
  , memberResultBytes
  , classResultBytes
  , relationResultBytes
  , nodeTempBytes
  , intervalTempBytes
  , latticeTempBytes

    -- * The compiled result
  , Connectivity
  , Stats (..)
  , connectivityStats
  , Axis (..)
  , CellRange (..)
  , rangeCells

    -- * Components
  , ComponentKey
  , keyOrigin
  , keyParameters
  , mkComponentKey
  , VoidLookup (..)
  , lookupVoid
  , componentOf
  , componentContains
  , isExterior
  , cellBox

    -- * Ranges, relations and boundaries
  , componentRanges
  , PortalRelation (..)
  , componentRelations
  , portalRelations
  , BoundaryFace (..)
  , Across (..)
  , AcrossKind (..)
  , componentBoundary
  ) where

import Hetoimasia.Terrain.Internal.Connectivity.Index
import Hetoimasia.Terrain.Internal.Connectivity.Limits
import Hetoimasia.Terrain.Internal.Connectivity.Prepare

-- | The structural figures of a compiled result: lattice boxes, nodes,
-- relations, classes and accounted result bytes.
connectivityStats ∷ Connectivity → Stats
connectivityStats = cStats
