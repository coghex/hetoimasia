-- | The representations behind "Hetoimasia.Foundation.Resource", shared inside
-- the foundation library and nowhere else.
--
-- This module is listed under @other-modules@, so no client of the package can
-- import it. It exists so that a scoped constructor defined in another module
-- of this library — 'Hetoimasia.Foundation.Recovery.allocComponent' today, the
-- trusted worker adapter later — can build a 'Scoped' value and drive a
-- composite's part ledger without the public module exporting either
-- constructor. The public module re-exports only the closed types and the
-- operations over them, so the opacity that module documents is unchanged:
-- a client still has no name for the continuation, the ledger, or a
-- 'CleanupFailure'\'s fields.
--
-- Everything here keeps the contract "Hetoimasia.Foundation.Resource"
-- documents. A module using this seam is trusted to keep it too: it must
-- install a release for every part before an interruptible gap, never hand a
-- ledger or a release to a caller, and rethrow only through the preserving
-- paths below.
module Hetoimasia.Foundation.Resource.Internal
  ( -- * Retained cleanup failures
    CleanupFailureId (..)
  , CleanupFailure (..)
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailureException
  , displayCleanupFailure

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
  , lendAssembled
  , releaseAcquired
  , declaredOrder

    -- * Continuation facade
  , Scoped (..)
  , withScoped
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , evaluate
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation)
import Control.Monad.IO.Class (MonadIO (liftIO))
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
--
-- The representation is closed to clients: "Hetoimasia.Foundation.Resource"
-- exports the type without its constructor, this module is hidden, and none of
-- the three carried values is a record field, so no field label reaches a
-- client either. A client of the package cannot build a 'CleanupFailure'
-- of its own and cannot rewrite one it was handed, because record
-- construction and record-update syntax both need a field label in scope and
-- this type declares none. Entries are therefore read-only evidence: they are
-- created only by 'attemptRelease', which issues each identity as it retains
-- the failure it names.
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
--
-- Both metadata fields are already evaluated when 'acquirePart' builds this,
-- so the ordering and the labelling the release needs cannot fail while the
-- construction is being rolled back or the scope is exiting.
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

-- | A scoped allocation, composed in @do@ notation.
--
-- A 'Scoped' value is a scope that has not been entered yet: it knows how to
-- acquire something, lend it to a continuation, and release it afterwards.
-- Binding two of them nests the second scope inside the first, so an
-- allocation reads as one line of a @do@ block rather than one more level of
-- callback indentation, and the lifetimes are exactly the ones the nested
-- callbacks would have given.
--
-- The representation is closed to clients: "Hetoimasia.Foundation.Resource"
-- exports the type without its constructor, this module is hidden, and the
-- continuation is not a record field, so no field label reaches a client
-- either. A client of the package cannot build a 'Scoped' from a
-- continuation of its own and cannot rewrite the continuation of one it was
-- given, because record construction and record-update syntax both need a
-- field label in scope and this type declares none. There is therefore no way
-- to resume a scope's continuation, to take a scope apart, or to install
-- cleanup for a resource acquired elsewhere; a scope is built with
-- 'allocResource', 'allocComposite', 'locally', 'pure', 'liftIO', and the
-- instances below, and it is consumed by running it with 'withScoped', the
-- only runner.
--
-- Nothing here counts entries or rejects a second one at run time. The
-- guarantee is the absence of a way to express the rewrite, checked when the
-- client is compiled.
newtype Scoped a = Scoped (∀ r. (a → IO r) → IO r)

-- | Enter the scope, run the continuation with what it allocated, and release
-- everything it allocated when that continuation returns or throws.
--
-- This is an ordinary function over the closed representation rather than a
-- field selector, so it reads a scope without also giving a client a way to
-- write one. Its name and type are unchanged by that: it is still applied to a
-- scope and a continuation, and still the only runner.
--
-- The continuation borrows the values under the borrowing rules of
-- 'withResource'. Running a scope with 'pure' as the continuation is the
-- documented misuse: it returns a handle whose cleanup has already run. Return
-- ordinary, fully evaluated results instead.
withScoped ∷ Scoped a → ∀ r. (a → IO r) → IO r
withScoped (Scoped enter) = enter

instance Functor Scoped where
  fmap change scope = Scoped (\continue → withScoped scope (continue . change))

instance Applicative Scoped where
  -- A scope that allocates nothing: the continuation runs directly, so there
  -- is no release and no masking to impose.
  pure value = Scoped (\continue → continue value)
  change <*> scope =
    Scoped $ \continue →
      withScoped change (\apply → withScoped scope (continue . apply))

instance Monad Scoped where
  -- The rest of the block runs inside the first scope, which is what makes the
  -- release point the end of the enclosing continuation rather than the end of
  -- this bind, and what unwinds the allocations of one scope in reverse.
  scope >>= rest =
    Scoped $ \continue →
      withScoped scope (\value → withScoped (rest value) continue)

instance MonadIO Scoped where
  -- An ordinary action in the middle of a block. It owns nothing, so a failure
  -- here unwinds the allocations made before it and runs no later acquisition.
  liftIO action = Scoped (\continue → action >>= continue)

-- | The one authoritative release of a composite: every part acquired so far,
-- newest first. It is private to the construction or scope that created it.
type Ledger = IORef [Part]

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
  slot ← newIORef []
  built ← tryScope (runAssembly assembly (Assembling restore slot))
  case built of
    -- Rollback: the current authoritative release covers exactly the parts
    -- acquired so far, and the failure that triggered it stays primary.
    Left primary → do
      failures ← releaseAcquired slot
      pure (Left (retainCleanupFailures failures primary))
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
