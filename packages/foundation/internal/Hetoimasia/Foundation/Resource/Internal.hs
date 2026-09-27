-- | The representations behind "Hetoimasia.Foundation.Resource", shared inside
-- the foundation package and nowhere else.
--
-- This module belongs to the package's private @internal@ sublibrary, so no
-- client of the package can import it. It exists so that a scoped constructor
-- defined in another foundation module —
-- 'Hetoimasia.Foundation.Recovery.allocComponent',
-- 'Hetoimasia.Foundation.Worker.allocWorkerGroup', and the member ledger of
-- "Hetoimasia.Foundation.Resource.Collection" — can build a 'Scoped' value and
-- drive a composite's part ledger without the public module exporting either
-- constructor. The public module re-exports only the closed types and the
-- operations over them, so the opacity that module documents is unchanged:
-- a client still has no name for the continuation, the ledger, or a
-- 'CleanupFailure'\'s fields.
--
-- It defines nothing. It is the package-private facade over four hidden
-- modules of the same sublibrary, each owning one responsibility, and
-- re-exports exactly what the rest of the package uses from them:
--
-- * "Hetoimasia.Foundation.Resource.Cleanup" owns cleanup identity and
--   evidence: 'CleanupFailureId', 'CleanupFailure', the counter that issues
--   identities, the readers, rendering, and inspection, and the release and
--   retention primitives.
-- * "Hetoimasia.Foundation.Resource.Types" owns release ranks and the
--   assembly representation: 'ReleaseRank', 'Part', 'Assembling', 'Assembly',
--   and the 'Ledger'.
-- * "Hetoimasia.Foundation.Resource.Assembly" owns staged acquisition,
--   rollback, and lending over those types.
-- * "Hetoimasia.Foundation.Resource.Scoped" owns the 'Scoped' continuation
--   type, its instances, and its runner.
--
-- Those modules import one another directly and never this facade; code
-- outside the sublibrary imports only this facade.
--
-- Everything here keeps the contract "Hetoimasia.Foundation.Resource"
-- documents. A module using this seam is trusted to keep it too: it must
-- install a release for every part before an interruptible gap, never hand a
-- ledger or a release to a caller, and rethrow only through the preserving
-- paths "Hetoimasia.Foundation.Resource.Assembly" and
-- "Hetoimasia.Foundation.Resource.Cleanup" provide.
module Hetoimasia.Foundation.Resource.Internal
  ( -- * Retained cleanup failures
    CleanupFailureId (..)
  , CleanupFailure (..)
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailureException
  , displayCleanupFailure
  , cleanupFailuresInContext

    -- * Release primitives
  , tryScope
  , attemptRelease
  , retainCleanupFailure
  , retainCleanupFailures

    -- * Composite ledger
  , ReleaseRank (..)
  , releaseRank
  , Part (..)
  , Assembling (..)
  , Assembly (..)
  , runAssembly
  , acquirePart
  , restoredStep
  , Ledger
  , assemble
  , assembleSeparately
  , lendAssembled
  , releaseAcquired
  , declaredOrder

    -- * Continuation facade
  , Scoped (..)
  , withScoped
  ) where

import Hetoimasia.Foundation.Resource.Assembly
  ( acquirePart
  , assemble
  , assembleSeparately
  , declaredOrder
  , lendAssembled
  , releaseAcquired
  , restoredStep
  )
import Hetoimasia.Foundation.Resource.Cleanup
  ( CleanupFailure (..)
  , CleanupFailureId (..)
  , attemptRelease
  , cleanupFailureException
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , displayCleanupFailure
  , retainCleanupFailure
  , retainCleanupFailures
  , tryScope
  )
import Hetoimasia.Foundation.Resource.Scoped (Scoped (..), withScoped)
import Hetoimasia.Foundation.Resource.Types
  ( Assembling (..)
  , Assembly (..)
  , Ledger
  , Part (..)
  , ReleaseRank (..)
  , releaseRank
  , runAssembly
  )
