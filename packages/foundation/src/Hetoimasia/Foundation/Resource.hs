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
-- Retained evidence is read back with 'cleanupFailures', which needs no
-- logger. Every rethrow inside this module preserves the primary exception's
-- 'Control.Exception.Context.ExceptionContext', so an annotation attached
-- inside a scope stays directly reachable above it.
--
-- This module owns no application state and imports no logger, runtime
-- environment, graphics, or scripting module.
--
-- See @docs/resources.md@ for the same contract in prose, including the caller
-- patterns that discard evidence and the preserving path to use instead.
module Hetoimasia.Foundation.Resource
  ( -- * Scopes
    withResource
  , withResourceLabelled

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
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , WhileHandling (WhileHandling)
  , displayException
  , mask
  , rethrowIO
  , someExceptionContext
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , getExceptionAnnotations
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import System.IO.Unsafe (unsafePerformIO)

-- | The identity of one retained cleanup failure, and its position in the
-- order the failures were observed while the scopes unwound.
--
-- Identifiers are issued in increasing order, so sorting by this key recovers
-- observation order no matter which route through an exception's context an
-- entry was found on, and comparing it distinguishes one failure from another
-- that merely renders the same way.
newtype CleanupFailureId = CleanupFailureId Integer
  deriving (Eq, Ord, Show)

-- | One release that was attempted and threw.
--
-- The failure keeps the operation's label and the exception together with the
-- context that exception had when it was caught, rather than a rendered
-- message, so a caller can re-examine the failure's own annotations and
-- backtrace.
data CleanupFailure = CleanupFailure
  { cleanupFailureId ∷ !CleanupFailureId
    -- ^ Identity and observation order of this failure.
  , cleanupFailureLabel ∷ !Text
    -- ^ The label of the operation whose release threw.
  , cleanupFailureException ∷ !(ExceptionWithContext SomeException)
    -- ^ The exception the release threw, with the context it was caught with.
  }

instance ExceptionAnnotation CleanupFailure where
  displayExceptionAnnotation = displayCleanupFailure

-- | Render one retained cleanup failure as a single line naming its operation
-- and its exception. The failure's own context is left for the caller to
-- inspect through 'cleanupFailureException'.
displayCleanupFailure ∷ CleanupFailure → String
displayCleanupFailure failure =
  case cleanupFailureException failure of
    ExceptionWithContext _ exception →
      "cleanup failed in "
        <> Text.unpack (cleanupFailureLabel failure)
        <> ": "
        <> displayException exception

-- | Issues 'CleanupFailureId's.
--
-- This counter carries no resource, owns no cleanup, and is never read as
-- application state. It exists so that the identity and the observation order
-- of retained evidence are properties this module defines, rather than
-- consequences of how @base@ happens to store annotations in an
-- 'ExceptionContext'.
cleanupFailureCounter ∷ IORef Integer
cleanupFailureCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE cleanupFailureCounter #-}

nextCleanupFailureId ∷ IO CleanupFailureId
nextCleanupFailureId =
  atomicModifyIORef' cleanupFailureCounter $ \issued →
    let next = issued + 1 in (next, CleanupFailureId next)

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

-- | Catch anything the body raises, including a cancellation, keeping the
-- exception together with the context it carried.
tryScope ∷ IO r → IO (Either (ExceptionWithContext SomeException) r)
tryScope = tryWithContext

-- | Attempt one release exactly once, uninterruptibly.
--
-- Asynchronous exceptions from other threads cannot be delivered here, so an
-- exception caught below was raised by the release itself and is a cleanup
-- failure under the scope's failure policy. A release that throws is never
-- retried.
attemptRelease ∷ Text → IO () → IO (Maybe CleanupFailure)
attemptRelease label release = uninterruptibleMask_ $ do
  outcome ← tryScope release
  case outcome of
    Right () → pure Nothing
    Left caught → do
      identifier ← nextCleanupFailureId
      pure (Just (CleanupFailure identifier label caught))

-- | Append one cleanup failure to the evidence an exception already carries.
--
-- The primary exception itself is never rebuilt, so its type, its value, and
-- every annotation already attached to it survive, and a nested scope adds to
-- what it received rather than replacing it.
retainCleanupFailure
  ∷ CleanupFailure
  → ExceptionWithContext SomeException
  → ExceptionWithContext SomeException
retainCleanupFailure failure (ExceptionWithContext context exception) =
  ExceptionWithContext (addExceptionAnnotation failure context) exception

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
cleanupFailures ∷ SomeException → [CleanupFailure]
cleanupFailures = cleanupFailuresInContext . someExceptionContext

-- | 'cleanupFailures' for a caller holding an exception's context directly,
-- such as one from 'tryWithContext' or 'Control.Exception.catchNoPropagate'.
cleanupFailuresInContext ∷ ExceptionContext → [CleanupFailure]
cleanupFailuresInContext = dropRepeatedFailures . sortOn cleanupFailureId . gatherFailures

-- | Collect every reachable cleanup failure, following the two ways evidence
-- can sit below the context being inspected.
gatherFailures ∷ ExceptionContext → [CleanupFailure]
gatherFailures context =
  direct
    <> concatMap belowHandled (getExceptionAnnotations context)
    <> concatMap belowFailure direct
  where
    direct = getExceptionAnnotations context

    belowHandled (WhileHandling handled) = gatherFailures (someExceptionContext handled)

    belowFailure failure = case cleanupFailureException failure of
      ExceptionWithContext failureContext _ → gatherFailures failureContext

-- | Drop repeats of a failure reached by more than one route. The input is
-- sorted by identity, so repeats are adjacent.
dropRepeatedFailures ∷ [CleanupFailure] → [CleanupFailure]
dropRepeatedFailures (earlier : later : rest)
  | cleanupFailureId earlier == cleanupFailureId later = dropRepeatedFailures (earlier : rest)
  | otherwise = earlier : dropRepeatedFailures (later : rest)
dropRepeatedFailures failures = failures
