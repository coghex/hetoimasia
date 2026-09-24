-- | Failure-preserving CPU resource scopes.
--
-- 'withResource' pairs an acquisition with a release and runs a body between
-- them. It takes the acquisition first and the release second, matching
-- 'Control.Exception.bracket', but it is not an alias for it: when the body
-- and the release both fail, @bracket@ reports one of them and discards the
-- other, while this scope preserves the body's failure and retains every
-- cleanup failure beside it as ordered, structured, inspectable evidence.
--
-- The outcomes are exactly these:
--
-- * body and release both succeed: the body's result is returned;
-- * the body fails or is cancelled and the release succeeds: the original
--   exception propagates with its own type, value, and attached context;
-- * the body succeeds and the release fails: the scope fails with the
--   release's exception and the body's result is discarded;
-- * both fail: the body's failure propagates and every cleanup failure is
--   retained as secondary evidence.
--
-- A failed acquisition propagates and runs no release, because no value exists
-- to release. Successful cleanup is never reported for a body that threw.
--
-- Acquisition runs under 'mask', so a blocking acquisition stays cancellable
-- unless the caller already imposed an uninterruptible mask, and there is no
-- unmasked gap between a successful acquisition and its cleanup protection.
-- The body runs with the caller's masking state restored. Each release runs
-- under 'uninterruptibleMask_', so an asynchronous exception aimed at the
-- thread from elsewhere is not delivered until the release and the remaining
-- releases of that unwind have finished. An exception a release raises itself
-- is a cleanup failure rather than an interruption, even when its type belongs
-- to the asynchronous-exception hierarchy. A release must therefore have a
-- controlled blocking duration.
--
-- 'withComposite' is the same scope for an owner built from several parts.
-- Its 'Assembly' acquires each part and installs that part's rollback as one
-- protected step, so at every moment after an acquisition returns exactly one
-- authoritative release covers every part acquired so far; a failure at any
-- stage releases exactly those and no more. The order that release runs in is
-- declared with 'releaseRank', because the correct order is a property of the
-- API the parts come from rather than the reverse of acquisition. A part's
-- declared label and rank are evaluated before its acquisition runs, so the
-- release covering an acquired part can always be ordered and labelled, and a
-- faulting label or rank is a construction failure at its own stage rather
-- than a failure of the rollback.
--
-- 'Scoped' is the continuation facade over these scopes. 'allocResource' pairs
-- an acquisition with a release and yields a scope value that composes in @do@
-- notation instead of nesting one callback per resource, and 'allocComposite'
-- does the same for a composite's 'Assembly'. The facade changes no lifetime:
-- a resource allocated this way is released when the enclosing 'withScoped'
-- continuation returns or throws, not at the end of the @do@ block that
-- allocated it, and 'locally' is the only way to end a group of lifetimes
-- early. One scope releases its own allocations in reverse allocation order,
-- while a composite allocated inside it keeps the order its constructor
-- declared.
--
-- Retained evidence is read back with 'cleanupFailures', which needs no
-- logger. Every rethrow inside this module preserves the primary exception's
-- 'Control.Exception.Context.ExceptionContext', so an annotation attached
-- inside a scope stays directly reachable above it.
--
-- This module owns no application state and imports no logger, runtime
-- environment, graphics, or scripting module. Its representations live in a
-- hidden implementation module of this library, which lets
-- 'Hetoimasia.Foundation.Recovery.allocComponent' build a 'Scoped' value from
-- inside the library while this module exports every type closed.
--
-- See @docs/resources.md@ for the same contract in prose, including the caller
-- patterns that discard evidence and the preserving path to use instead.
module Hetoimasia.Foundation.Resource
  ( -- * Scopes
    withResource
  , withResourceLabelled

    -- * Composite construction
  , withComposite
  , Assembly
  , acquirePart
  , restoredStep
  , ReleaseRank
  , releaseRank

    -- * Continuation facade
  , Scoped
  , withScoped
  , allocResource
  , allocComposite
  , locally

    -- * Retained cleanup failures
  , CleanupFailure
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailureException
  , CleanupFailureId
  , displayCleanupFailure

    -- * Inspection
  , cleanupFailures
  , cleanupFailuresInContext
  ) where

import Control.Exception
  ( SomeException
  , mask
  , rethrowIO
  , someExceptionContext
  )
import Data.Text (Text)
import Hetoimasia.Foundation.Resource.Internal
  ( Assembly
  , CleanupFailure
  , CleanupFailureId
  , ReleaseRank
  , Scoped (Scoped)
  , acquirePart
  , assemble
  , attemptRelease
  , cleanupFailureException
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , displayCleanupFailure
  , lendAssembled
  , releaseRank
  , restoredStep
  , retainCleanupFailure
  , tryScope
  , withScoped
  )

-- | The label 'withResource' records for a release it did not see a name for.
defaultResourceLabel ∷ Text
defaultResourceLabel = "resource release"

-- | Acquire a resource, run a body with it, and release it, preserving the
-- body's failure and retaining every cleanup failure.
--
-- The acquisition comes first and the release second, as in
-- 'Control.Exception.bracket'. The body borrows the value: it is released when
-- the body returns or throws, so returning it, or anything derived from it
-- whose validity depends on it, hands the caller something already released.
--
-- Cleanup failures are recorded under a default label. Use
-- 'withResourceLabelled' to name the operation instead.
withResource ∷ IO a → (a → IO ()) → (a → IO r) → IO r
withResource = withResourceLabelled defaultResourceLabel

-- | 'withResource', recording cleanup failures under a caller-supplied
-- operation label.
--
-- The label identifies the operation whose release threw, so evidence retained
-- from several nested scopes says which scope each entry came from.
withResourceLabelled ∷ Text → IO a → (a → IO ()) → (a → IO r) → IO r
withResourceLabelled label acquire release body = mask $ \restore → do
  resource ← acquire
  -- The handler below is installed while still masked, so nothing runs
  -- unprotected between a successful acquisition and its cleanup.
  outcome ← tryScope (restore (body resource))
  attempted ← attemptRelease label (release resource)
  case (outcome, attempted) of
    (Right result, Nothing) → pure result
    (Right _, Just failure) →
      -- The body's result is discarded and the release's own exception becomes
      -- primary. It is retained as a labelled entry as well, so inspection
      -- reports it beside any failure an enclosing scope adds later.
      rethrowIO (retainCleanupFailure failure (cleanupFailureException failure))
    (Left primary, Nothing) → rethrowIO primary
    (Left primary, Just failure) → rethrowIO (retainCleanupFailure failure primary)

-- | The cleanup failures retained by an exception a caller caught, in the
-- order they were observed while the scopes unwound.
--
-- No entry is lost or duplicated as nested scopes unwind: evidence reached
-- more than once is reported once, while two distinct failures that render
-- identically stay distinct.
--
-- Evidence nested inside a 'WhileHandling' annotation is found as well, so a
-- caller whose own @catch@ handler rethrows the received value plainly still
-- gets its evidence back. Evidence a release carried in its own exception is
-- found the same way. A caller that discards the context entirely — a bare
-- typed @try@, or a @try@ followed by a plain @throwIO@ — has nothing left to
-- inspect; @docs\/resources.md@ names the preserving path.
--
-- Inspection runs on a failure path, so its cost is part of the contract: each
-- distinct failure's own carried context is expanded once per inspection,
-- however many routes reach it. What a caller pays is a scan of the
-- annotations on each expanded context plus the ordering of the result by
-- identity, not a re-expansion per route.
cleanupFailures ∷ SomeException → [CleanupFailure]
cleanupFailures = cleanupFailuresInContext . someExceptionContext

-- | Construct a composite value in stages, lend it to a body, and release
-- every part it acquired in the constructor's declared order.
--
-- This is 'withResource' for an owner with several parts, and it keeps the
-- same contract. A failure before the first acquisition releases nothing. A
-- failure at any later stage — while evaluating a part's declared label or
-- rank, inside an acquisition, inside a restored step, or at the final binding
-- or publication step — releases exactly the parts acquired so far, each
-- exactly once, and propagates the triggering failure as primary, so no
-- finished value ever reaches the body. Cleanup failures are retained under
-- each part's own label as ordered, structured evidence that 'cleanupFailures'
-- reads back.
--
-- On success the body borrows the finished value under the borrowing rules of
-- 'withResource', and the release that runs when the body returns or throws is
-- the declared order of 'ReleaseRank', not the reverse of acquisition. When
-- the body succeeds and releases fail, the first cleanup failure becomes the
-- scope's exception and the body's result is discarded, as it is for a single
-- resource; every labelled failure is retained beside it.
--
-- Each release runs under 'uninterruptibleMask_' and the orchestration between
-- them stays masked, so an asynchronous exception aimed at the thread from
-- elsewhere is not delivered until the whole declared order has been
-- attempted. A release must therefore have a controlled blocking duration.
withComposite ∷ Assembly a → (a → IO r) → IO r
withComposite assembly body = mask $ \restore → do
  built ← assemble restore assembly
  case built of
    Left primary → rethrowIO primary
    Right (slot, value) → lendAssembled restore slot value body

-- | Allocate a resource for the rest of the enclosing scope.
--
-- The acquisition comes first and the release second, as in 'withResource',
-- and the lifetime and failure behavior are that primitive's exactly:
-- @'withScoped' ('allocResource' acquire release)@ is @'withResource' acquire
-- release@. The acquisition is protected, the release runs under
-- 'uninterruptibleMask_', the body's failure stays primary, and every cleanup
-- failure is retained as inspectable evidence.
--
-- The release runs when the enclosing 'withScoped' continuation returns or
-- throws, not at the end of the @do@ block this line appears in. A group of
-- lifetimes that must end earlier belongs in 'locally'.
allocResource ∷ IO a → (a → IO ()) → Scoped a
allocResource acquire release = Scoped (withResource acquire release)

-- | Allocate a composite owner for the rest of the enclosing scope.
--
-- This is 'allocResource' for a value built with 'withComposite': the assembly
-- is run under the same staged protection, and the enclosing scope releases
-- its parts in the order 'releaseRank' declared. Reverse allocation order
-- applies between the allocations of one scope, not inside a composite, whose
-- internal order is a property of the API its parts come from.
--
-- It allocates; it does not run a scope or resume one. Constructing the
-- assembly is still 'acquirePart' and 'restoredStep', and a scope is still
-- entered only through 'withScoped'.
allocComposite ∷ Assembly a → Scoped a
allocComposite assembly = Scoped (withComposite assembly)

-- | End a group of lifetimes before the enclosing scope does.
--
-- @'locally' inner@ runs @inner@ to completion, releases everything @inner@
-- allocated, and only then continues the enclosing scope with @inner@'s
-- result. Staging work whose buffers must be gone before the rest of a block
-- runs is the case this exists for.
--
-- The result must be an ordinary, fully evaluated value: the inner scope's
-- allocations are already released when the outer scope resumes, so a borrowed
-- handle returned from @inner@ is a handle whose cleanup has run. Cleanup
-- failures inside @inner@ propagate into the enclosing scope under the failure
-- table and are retained there as evidence 'cleanupFailures' reads back.
locally ∷ Scoped a → Scoped a
locally inner = Scoped (\continue → withScoped inner pure >>= continue)
