-- | Staged acquisition, rollback, and lending over the composite
-- representation of "Hetoimasia.Foundation.Resource.Types".
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Resource.Internal" re-exports
-- it for the rest of the package. It holds the effects a composite owner's
-- construction performs — acquiring a part and covering it in one protected
-- step, running a step with the caller's masking state restored, releasing a
-- ledger in its declared order, and lending a finished value to a body — and
-- records every failed release through "Hetoimasia.Foundation.Resource.Cleanup",
-- the single owner of cleanup identity. It defines no state of its own beyond
-- the ledger each construction allocates and owns.
--
-- A module using these operations is trusted to keep the contract
-- "Hetoimasia.Foundation.Resource" documents: it must install a release for
-- every part before an interruptible gap, never hand a ledger or a release to
-- a caller, and rethrow only through the preserving paths below.
module Hetoimasia.Foundation.Resource.Assembly
  ( -- * Stages
    acquirePart
  , restoredStep

    -- * Running a construction
  , assemble
  , assembleSeparately
  , lendAssembled

    -- * Releasing a ledger
  , releaseAcquired
  , declaredOrder
  ) where

import Control.Exception
  ( ExceptionWithContext
  , SomeException
  , evaluate
  , rethrowIO
  , uninterruptibleMask_
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sortOn)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource.Cleanup
  ( CleanupFailure
  , attemptRelease
  , cleanupFailureException
  , retainCleanupFailures
  , tryScope
  )
import Hetoimasia.Foundation.Resource.Types
  ( Assembling (Assembling, assemblingParts, assemblingRestore)
  , Assembly (Assembly)
  , Ledger
  , Part (Part, partLabel, partRank, partRelease)
  , ReleaseRank
  , runAssembly
  )

-- | Acquire one part of the composite and install its rollback, under the
-- label its cleanup failures are retained with and the rank its release takes
-- in the declared final order.
--
-- The acquisition and the installation of the rollback are one protected step:
-- the whole assembly runs under 'mask' and installing a rollback cannot block,
-- so there is no interruptible gap between a part being acquired and being
-- covered. Masking still permits cancellation at an interruptible operation
-- inside the acquisition itself, which is deliberate — a blocking acquisition
-- stays cancellable — and an acquisition that throws before returning its
-- handle is responsible for releasing anything it acquired internally, exactly
-- as an acquisition passed to 'withResource' is.
--
-- After this stage returns, the one authoritative release covers every part
-- acquired so far, this one included. Nothing is unregistered to achieve that,
-- and no part is released twice: the accumulated release is taken out of the
-- construction when it runs.
--
-- The label and the rank are evaluated before the acquisition runs, because
-- the release the rollback performs needs both and must not be able to fail on
-- either. A label or rank that throws is therefore an ordinary construction
-- failure raised at this stage: it acquires nothing, the stages after it and
-- the body do not run, and the parts acquired before it are rolled back
-- exactly as any other failure here rolls them back. Deferring that evaluation
-- to the release instead would let a faulting thunk raise its exception after
-- the authoritative release had been taken out of the construction, which
-- abandons every acquired part and displaces the failure being unwound.
acquirePart ∷ Text → ReleaseRank → IO p → (p → IO ()) → Assembly p
acquirePart label rank acquire release = Assembly $ \assembling → do
  -- Both are forced exactly as far as 'Part' forces them, so a total label and
  -- rank reach the slot unchanged and a faulting one cannot reach it at all.
  declaredLabel ← evaluate label
  declaredRank ← evaluate rank
  part ← acquire
  atomicModifyIORef' (assemblingParts assembling) $ \parts →
    (Part declaredRank declaredLabel (release part) : parts, ())
  pure part

-- | Run one step of the construction that acquires nothing — querying what an
-- allocation must satisfy, binding two parts together, or assembling the
-- finished value — with the caller's masking state restored.
--
-- This is the same restoration 'withResource' performs around its body, and it
-- is legal here for the same reason: every part acquired so far is already
-- covered by the authoritative release, so a cancellation delivered inside
-- this step rolls exactly those parts back. It inherits the caller's masking
-- state rather than forcing an unmasked one, so a caller that was already
-- masked stays masked.
--
-- A step that acquires something belongs in 'acquirePart' instead. Restoring
-- the caller's state around an acquisition is the gap this arc exists to
-- close.
restoredStep ∷ IO a → Assembly a
restoredStep step = Assembly (\assembling → assemblingRestore assembling step)

-- | Run the authoritative release covering every part acquired so far, in the
-- declared order, attempting each exactly once.
--
-- Taking the parts out of the slot is what makes a second release impossible:
-- a rollback and a scope exit cannot both reach the same part, and neither can
-- run twice.
releaseAcquired ∷ IORef [Part] → IO [CleanupFailure]
releaseAcquired slot = uninterruptibleMask_ $ do
  acquired ← atomicModifyIORef' slot (\parts → ([], parts))
  attemptEach (declaredOrder acquired)
  where
    attemptEach [] = pure []
    attemptEach (part : remaining) = do
      attempted ← attemptRelease (partLabel part) (partRelease part)
      later ← attemptEach remaining
      pure (maybe later (: later) attempted)

-- | The declared final release order of the parts acquired so far. The slot
-- holds them newest first, so reversing recovers acquisition order, and the
-- stable sort below leaves parts of equal rank in it.
--
-- Sorting demands every part's rank, which 'acquirePart' evaluated before that
-- part was acquired, so ordering the release of an acquired part cannot fail.
declaredOrder ∷ [Part] → [Part]
declaredOrder = sortOn partRank . reverse

-- | Run one assembly against a fresh 'Ledger'.
--
-- The caller must already be masked and passes the @restore@ its 'mask'
-- handed it, which 'restoredStep' uses. On success the returned ledger covers
-- every part the value was built from, and nothing between the last
-- acquisition and this return is interruptible, so the caller receives the
-- value and its release together. On failure the parts acquired so far have
-- been released in the declared order, each exactly once, and the returned
-- failure is the triggering one with every cleanup failure retained beside
-- it; no ledger survives it.
assemble
  ∷ (∀ x. IO x → IO x)
  → Assembly a
  → IO (Either (ExceptionWithContext SomeException) (Ledger, a))
assemble restore assembly = do
  built ← assembleSeparately restore assembly
  pure $ case built of
    Left (primary, failures) → Left (retainCleanupFailures failures primary)
    Right owned → Right owned

-- | 'assemble', handing back a failed construction's rollback failures beside
-- the untouched primary instead of already retained on it.
--
-- The rollback is the same one 'assemble' performs, attempted before this
-- returns. An owner that must remember whether a rollback failed — the
-- collection in "Hetoimasia.Foundation.Resource.Collection" latches such a
-- failure — reads the list here rather than recovering it from the primary's
-- context, where it would be indistinguishable from evidence the construction's
-- own exception already carried. The caller is responsible for retaining the
-- failures on the primary before rethrowing it.
assembleSeparately
  ∷ (∀ x. IO x → IO x)
  → Assembly a
  → IO (Either (ExceptionWithContext SomeException, [CleanupFailure]) (Ledger, a))
assembleSeparately restore assembly = do
  slot ← newIORef []
  built ← tryScope (runAssembly assembly (Assembling restore slot))
  case built of
    -- Rollback: the current authoritative release covers exactly the parts
    -- acquired so far, and the failure that triggered it stays primary.
    Left primary → do
      failures ← releaseAcquired slot
      pure (Left (primary, failures))
    Right value → pure (Right (slot, value))

-- | Lend a value built by 'assemble' to a body, then release its ledger.
--
-- The caller must still be masked, with nothing interruptible since
-- 'assemble' returned. The body's failure handler is installed while masked,
-- and only then is the caller's masking state restored around the body, so a
-- cancellation delivered at that handoff — before the body's first effect —
-- is caught here and still releases every part. The release is attempted
-- exactly once when the body returns or throws, and the failure table is
-- 'Hetoimasia.Foundation.Resource.withComposite'\'s.
lendAssembled ∷ (∀ x. IO x → IO x) → Ledger → v → (v → IO r) → IO r
lendAssembled restore slot value body = do
  outcome ← tryScope (restore (body value))
  failures ← releaseAcquired slot
  case (outcome, failures) of
    (Right result, []) → pure result
    (Right _, first : rest) →
      rethrowIO
        (retainCleanupFailures (first : rest) (cleanupFailureException first))
    (Left primary, _) → rethrowIO (retainCleanupFailures failures primary)
