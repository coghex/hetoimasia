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
-- API the parts come from rather than the reverse of acquisition.
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

    -- * Composite construction
  , withComposite
  , Assembly
  , acquirePart
  , restoredStep
  , ReleaseRank
  , releaseRank

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

-- | Where one part falls in the composite's declared final release order.
--
-- Lower ranks are released first, and parts sharing a rank are released in
-- acquisition order. A rank is a declaration about the API the parts come
-- from, not a consequence of when a stage happened to run: a handle created
-- before the allocation behind it is often destroyed before that allocation is
-- freed, which is acquisition order rather than the reverse of it.
newtype ReleaseRank = ReleaseRank Int
  deriving (Eq, Ord, Show)

-- | Build a 'ReleaseRank' from an ordering key the constructor chooses.
releaseRank ∷ Int → ReleaseRank
releaseRank = ReleaseRank

-- | One acquired part, together with the release that covers it and the label
-- a failure of that release is retained under.
data Part = Part
  { partRank ∷ !ReleaseRank
  , partLabel ∷ !Text
  , partRelease ∷ IO ()
  }

-- | What a stage may reach while a composite is being constructed: the
-- caller's masking state, and the slot holding the one authoritative release.
--
-- The slot is not application state and is never observed outside the
-- construction it belongs to. It exists so that the release covering every
-- part acquired so far is a single value that later stages extend, rather than
-- a chain of nested handlers a stage could step outside of.
data Assembling = Assembling
  { assemblingRestore ∷ ∀ x. IO x → IO x
  , assemblingParts ∷ !(IORef [Part])
  }

-- | A staged construction of one composite value.
--
-- A composite owner acquires several parts in sequence, may fail between any
-- two of them, and must release them in an order its own API dictates. An
-- 'Assembly' is that sequence and nothing more: it is not a dependency
-- scheduler, it registers no delayed cleanup, and it hands no release action
-- to a caller.
--
-- Stages are written in @do@ notation, so a later stage may use what an
-- earlier one produced. 'acquirePart' takes a part and installs its rollback
-- as one protected step; 'restoredStep' runs work that acquires nothing with
-- the caller's masking state restored. 'withComposite' runs the whole
-- assembly and owns what it produced.
newtype Assembly a = Assembly (Assembling → IO a)

instance Functor Assembly where
  fmap change (Assembly stages) = Assembly (fmap change . stages)

instance Applicative Assembly where
  pure value = Assembly (\_ → pure value)
  Assembly change <*> Assembly stages =
    Assembly (\assembling → change assembling <*> stages assembling)

instance Monad Assembly where
  Assembly stages >>= continue = Assembly $ \assembling → do
    value ← stages assembling
    runAssembly (continue value) assembling

runAssembly ∷ Assembly a → Assembling → IO a
runAssembly (Assembly stages) = stages

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
acquirePart ∷ Text → ReleaseRank → IO p → (p → IO ()) → Assembly p
acquirePart label rank acquire release = Assembly $ \assembling → do
  part ← acquire
  atomicModifyIORef' (assemblingParts assembling) $ \parts →
    (Part rank label (release part) : parts, ())
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

-- | Construct a composite value in stages, lend it to a body, and release
-- every part it acquired in the constructor's declared order.
--
-- This is 'withResource' for an owner with several parts, and it keeps the
-- same contract. A failure before the first acquisition releases nothing. A
-- failure at any later stage — inside an acquisition, inside a restored step,
-- or at the final binding or publication step — releases exactly the parts
-- acquired so far, each exactly once, and propagates the triggering failure as
-- primary, so no finished value ever reaches the body. Cleanup failures are
-- retained under each part's own label as ordered, structured evidence that
-- 'cleanupFailures' reads back.
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
  slot ← newIORef []
  built ← tryScope (runAssembly assembly (Assembling restore slot))
  case built of
    -- Rollback: the current authoritative release covers exactly the parts
    -- acquired so far, and the failure that triggered it stays primary.
    Left primary → do
      failures ← releaseAcquired slot
      rethrowIO (retainCleanupFailures failures primary)
    Right value → do
      outcome ← tryScope (restore (body value))
      failures ← releaseAcquired slot
      case (outcome, failures) of
        (Right result, []) → pure result
        (Right _, first : rest) →
          rethrowIO
            (retainCleanupFailures (first : rest) (cleanupFailureException first))
        (Left primary, _) → rethrowIO (retainCleanupFailures failures primary)

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
declaredOrder ∷ [Part] → [Part]
declaredOrder = sortOn partRank . reverse

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
