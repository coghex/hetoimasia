-- | Cleanup identity and evidence: what a failed release leaves behind, how
-- each one is identified, and how it is attempted, retained, and read back.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Resource.Internal" re-exports
-- it for the rest of the package, and "Hetoimasia.Foundation.Resource.Assembly"
-- imports it directly. It is the single owner of cleanup identity. It alone
-- defines 'CleanupFailureId', 'CleanupFailure', and the counter that issues
-- identities, and 'attemptRelease' is the only place an entry is created, so
-- the invariant 'gatherFailures' relies on is established by this module and
-- no other.
--
-- It imports no other resource module: evidence does not depend on how the
-- scopes that retain it are composed.
--
-- = State
--
-- One piece of state, owned by this module: the process-wide counter behind
-- 'nextCleanupFailureId'. Every thread that attempts a release writes it
-- atomically, nothing reads it except to issue the next identity, and it lives
-- as long as the process and is never reset, so identities are never reused.
module Hetoimasia.Foundation.Resource.Cleanup
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
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , WhileHandling (WhileHandling)
  , displayException
  , someExceptionContext
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, addExceptionAnnotation, getExceptionAnnotations)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
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
--
-- The representation is closed to clients: "Hetoimasia.Foundation.Resource"
-- exports the type without its constructor, the module defining it is private
-- to the package, and none of the three carried values is a record field, so
-- no field label reaches a client either. A client of the package cannot build
-- a 'CleanupFailure' of its own and cannot rewrite one it was handed, because
-- record construction and record-update syntax both need a field label in
-- scope and this type declares none. Entries are therefore read-only evidence:
-- they are created only by 'attemptRelease', which issues each identity as it
-- retains the failure it names.
--
-- That boundary is what the inspection guarantee rests on. 'gatherFailures'
-- treats a 'CleanupFailureId' as standing for one fixed payload, expanding
-- that payload's own context the first time the identity is seen and skipping
-- the identity afterwards. An entry whose label or carried exception could be
-- replaced while its identity stayed the same would make two different
-- payloads answer to one key, and the evidence reachable only through the
-- replacement would never be expanded. Reattaching an /unchanged/ entry any
-- number of times, which is what nested scopes do as they unwind, is exactly
-- the case that invariant permits.
--
-- Nothing here counts entries or rejects a rewrite at run time. The guarantee
-- is the absence of a way to express one, checked when the client is compiled.
data CleanupFailure
  = CleanupFailure
      !CleanupFailureId
      -- ^ Identity and observation order of this failure.
      !Text
      -- ^ The label of the operation whose release threw.
      !(ExceptionWithContext SomeException)
      -- ^ The exception the release threw, with the context it was caught with.

instance ExceptionAnnotation CleanupFailure where
  displayExceptionAnnotation = displayCleanupFailure

-- | The identity and observation order of one retained cleanup failure.
--
-- This and the two readers below are ordinary functions over the closed
-- representation rather than field selectors, so they read an entry without
-- also giving a client a way to write one. Their names and types are unchanged
-- by that.
cleanupFailureId ∷ CleanupFailure → CleanupFailureId
cleanupFailureId (CleanupFailure identifier _ _) = identifier

-- | The label of the operation whose release threw.
cleanupFailureLabel ∷ CleanupFailure → Text
cleanupFailureLabel (CleanupFailure _ label _) = label

-- | The exception the release threw, with the context it was caught with.
cleanupFailureException ∷ CleanupFailure → ExceptionWithContext SomeException
cleanupFailureException (CleanupFailure _ _ exception) = exception

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

-- | 'Hetoimasia.Foundation.Resource.cleanupFailures' for a caller holding an exception's context directly,
-- such as one from 'tryWithContext' or 'Control.Exception.catchNoPropagate'.
cleanupFailuresInContext ∷ ExceptionContext → [CleanupFailure]
cleanupFailuresInContext context = Map.elems (gatherFailures [context] Map.empty)

-- | Collect every reachable cleanup failure, following the two ways evidence
-- can sit below the context being inspected.
--
-- The accumulator is keyed by 'CleanupFailureId', so it is at once the record
-- of which failures have already been expanded and the deduplicated result:
-- 'Map.elems' returns entries in increasing key order, which is the order the
-- failures were observed. Expanding each distinct failure's own context at
-- most once is what keeps the cost proportional to the evidence retained
-- rather than to the number of routes that reach it; nested releases each
-- carrying the prior cleanup context offer exponentially many such routes.
--
-- Skipping an identity already in the accumulator is sound because a
-- 'CleanupFailure' is read-only outside the foundation package: an identity
-- reached a second time carries the same label and the same exception, and
-- therefore the same context, as the first time it was expanded.
-- 'CleanupFailure' records why no client can break that correspondence.
--
-- The traversal is a worklist rather than a recursion so that the record of
-- expanded failures is shared by every branch instead of being rebuilt per
-- route. Pending contexts are expanded in no particular order, which the
-- ordering by identity above makes irrelevant to the result.
gatherFailures
  ∷ [ExceptionContext]
  → Map CleanupFailureId CleanupFailure
  → Map CleanupFailureId CleanupFailure
gatherFailures [] found = found
gatherFailures (context : pending) found =
  gatherFailures (handled <> below <> pending) found'
  where
    -- Both kinds of nesting below this context are followed even when every
    -- failure attached to it has been seen already: one repeated identity
    -- must not hide the new evidence standing beside it.
    handled =
      [ someExceptionContext handled'
      | WhileHandling handled' ← getExceptionAnnotations context
      ]

    (found', below) = foldl' expandOnce (found, []) (getExceptionAnnotations context)

    expandOnce (seen, contexts) failure
      | Map.member identifier seen = (seen, contexts)
      | otherwise =
          ( Map.insert identifier failure seen
          , failureContext failure : contexts
          )
      where
        identifier = cleanupFailureId failure

    failureContext failure = case cleanupFailureException failure of
      ExceptionWithContext carried _ → carried

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

-- | Retain several cleanup failures on one primary exception, in the order
-- they were observed. As in 'retainCleanupFailure', the primary exception is
-- never rebuilt.
retainCleanupFailures
  ∷ [CleanupFailure]
  → ExceptionWithContext SomeException
  → ExceptionWithContext SomeException
retainCleanupFailures failures primary = foldl' retain primary failures
  where
    retain carried failure = retainCleanupFailure failure carried
