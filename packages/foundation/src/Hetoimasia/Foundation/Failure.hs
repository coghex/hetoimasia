-- | Origin and operation context for engine failures, retained on the
-- exception itself.
--
-- An aborted engine operation fails by throwing an ordinary typed exception.
-- 'throwFailure' throws it with origin evidence attached to its
-- 'ExceptionContext': the owning component, the operation, caller-supplied
-- identifiers, and the caller's source information. 'withOperationContext'
-- lets an outer boundary add the operation it was performing to a failure
-- passing through it, whether that failure was raised by 'throwFailure' or by a
-- native or library call. 'failureEvidence' reads both back.
-- 'throwFailureSTM' raises the same failure, with the same evidence, inside a
-- transaction.
--
-- Nothing here wraps the exception. Its type, its value, and every annotation
-- already attached to it are kept, so a caller's @catch@, @try@, or
-- 'Control.Exception.fromException' on the component's own exception type
-- matches exactly as it would without this module, and the resource scopes of
-- "Hetoimasia.Foundation.Resource" carry the evidence through their preserving
-- rethrows beside the cleanup failures they retain.
--
-- Recognizing an exception by type and keeping its context are separate
-- properties. Inspection needs the context: a caught 'SomeException', or the
-- context a context-aware catch such as 'tryWithContext' returns. A bare typed
-- @try@, or a @try@ followed by a plain 'throwIO', keeps the type and discards
-- the evidence.
--
-- The origin is attributed to the outermost call-stack frame, the call site
-- outside every function that declared 'HasCallStack', which is the policy the
-- logger uses for an entry's source. A component wrapper that declares the
-- constraint is therefore attributed to its own caller. The origin is where the
-- failure was raised; a log entry's source is where it was reported, and the two
-- are different facts.
--
-- A native exception carries no origin. Its throw site is reported as unknown
-- rather than guessed at, and the exception is never converted into a textual
-- engine exception.
--
-- Cancellation is not annotated: 'throwFailure', 'throwFailureSTM', and a
-- boundary all rethrow an asynchronous exception with the context it already
-- had.
--
-- Raising and inspecting a failure need no logger. This module owns no state,
-- defines no central error type, and works over any 'Exception' instance. It
-- defines raising, the operation boundary, and inspection, and re-exports the
-- rest from private modules of the foundation package:
--
-- * @Hetoimasia.Foundation.Failure.Base@: the abstract 'Operation' and its
--   naming operations.
-- * @Hetoimasia.Foundation.Failure.Types@: the evidence records, and the
--   private annotation that carries them together with its rendering.
--
-- Both import only the validated 'Component' and the 'SourceLocation' record,
-- from the logging family's private @Log.Component@ and @Log.Base@ modules, so
-- failure attribution depends on no logger, filter, format, or sink.
--
-- See @docs/failures.md@ for the same contract in prose.
module Hetoimasia.Foundation.Failure
  ( -- * Operations
    Operation
  , operation
  , operationText

    -- * Raising
  , throwFailure
  , throwFailureSTM

    -- * Operation boundaries
  , withOperationContext

    -- * Evidence
  , FailureEvidence (..)
  , FailureCause (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , FailureSite (..)

    -- * Inspection
  , failureEvidence
  , failureEvidenceInContext
  ) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , evaluate
  , fromException
  , mask_
  , rethrowIO
  , someExceptionContext
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Exception.Context
  ( ExceptionContext
  , addExceptionAnnotation
  , getExceptionAnnotations
  )
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.STM (STM, throwSTM)
import Data.List (sortOn)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Void (Void, absurd)
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  )
import Hetoimasia.Foundation.Failure.Base (Operation, operation, operationText)
import Hetoimasia.Foundation.Failure.Types
  ( Evidence (..)
  , FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , FailureSite (..)
  , OperationContext (..)
  , entryPosition
  )
import Hetoimasia.Foundation.Log.Base (SourceLocation (..))
import Hetoimasia.Foundation.Log.Component (Component)

-- | Throw an engine failure with its origin attached.
--
-- The exception is thrown with its own type and value; the origin rides on its
-- context. The origin names the component, the operation, the identifiers, and
-- the call site outside every function that declared 'HasCallStack', so a
-- component's own wrapper that declares the constraint is attributed to that
-- wrapper's caller.
--
-- The identifiers and the source information are evaluated before the failure
-- is raised, so the evidence holds no thunk that could fail or reach a closed
-- resource later. A faulting identifier raises its own exception in place of
-- the failure.
--
-- An asynchronous exception, including one passed here as the cause, is thrown
-- with the context 'throwIO' gave it and no origin: a cancellation is never
-- recorded as an engine origin.
--
-- No logger is involved, and nothing is written before the failure is raised.
throwFailure
  ∷ (HasCallStack, MonadIO m, Exception e)
  ⇒ Component → Operation → [(Text, Text)] → e → m a
throwFailure component operationName identifiers cause = liftIO $ do
  origin ← evaluate (originAt component operationName identifiers callStack)
  -- Nothing between the throw and the rethrow is interruptible, so no
  -- cancellation can arrive in between and replace the failure.
  mask_ $ do
    raised ← tryWithContext (throwIO cause ∷ IO Void)
    case raised of
      Right impossible → absurd impossible
      Left caught@(ExceptionWithContext context exception)
        | isAsynchronous exception → rethrowIO caught
        | otherwise →
            rethrowIO
              (ExceptionWithContext (attach (`OriginEntry` origin) context) (exception ∷ SomeException))

-- | Throw an engine failure with its origin attached, inside a transaction.
--
-- This is 'throwFailure' for 'STM'. It takes the same arguments and attaches the
-- same origin evidence: the exception keeps its own type, its value, and every
-- annotation it already carried, and the origin is attributed to the call site
-- outside every function that declared 'HasCallStack'. A cause that already
-- carries an origin keeps reporting that earlier origin, as inspection always
-- does. As with 'throwFailure', a caught failure keeps its annotations when it
-- is passed on as an 'ExceptionWithContext' value rather than a bare
-- 'SomeException'.
--
-- The identifiers and the source information are evaluated before the failure
-- is raised. A faulting identifier raises its own exception in place of the
-- failure. An asynchronous cause is raised with the context it already had and
-- no origin.
--
-- Nothing else happens: no IO, no logging, no recovery. Unlike 'throwIO',
-- 'throwSTM' collects no backtrace, so the origin's site is the only source
-- information a failure raised here gains.
--
-- A failure that escapes 'Control.Monad.STM.atomically' rolls that transaction
-- back and arrives in 'IO' with its evidence, where an enclosing
-- 'withOperationContext' adds its context as usual. A failure caught with
-- 'Control.Monad.STM.catchSTM' discards the writes of the action that handler
-- guarded, and only those. Reading the evidence inside the handler needs a
-- 'SomeException' handler: one typed at the component's own exception receives
-- the bare value, without its context.
throwFailureSTM
  ∷ (HasCallStack, Exception e)
  ⇒ Component → Operation → [(Text, Text)] → e → STM a
throwFailureSTM component operationName identifiers cause = do
  origin ← pure $! originAt component operationName identifiers callStack
  let raised = toException cause
      context = someExceptionContext raised
  -- 'throwSTM' would give a bare 'SomeException' a fresh context, so the
  -- context travels beside it, including on the asynchronous branch.
  throwSTM $
    if isAsynchronous raised
      then ExceptionWithContext context raised
      else ExceptionWithContext (attach (`OriginEntry` origin) context) raised

-- | Run an operation, adding its context to a synchronous failure that passes
-- through.
--
-- The failure is rethrown with its own type, value, and context, with one
-- 'OperationContext' added. An origin already attached is untouched, so this
-- boundary never becomes the failure's origin, and a native exception stays
-- native: the boundary records the operation and where it was observed, not a
-- throw site.
--
-- An asynchronous exception, including one thrown synchronously with an
-- asynchronous type, is rethrown with the context it already had and nothing
-- added.
--
-- The identifiers and the boundary's source information are evaluated before
-- the operation runs, so a faulting identifier fails the boundary before the
-- operation starts rather than displacing a failure being propagated.
withOperationContext
  ∷ HasCallStack
  ⇒ Component → Operation → [(Text, Text)] → IO a → IO a
withOperationContext component operationName identifiers action = do
  boundary ←
    evaluate $
      forced
        (OperationContext component operationName identifiers (siteOf callStack))
        [forceIdentifiers identifiers, forceSite (siteOf callStack)]
  outcome ← tryWithContext action
  case outcome of
    Right result → pure result
    Left caught@(ExceptionWithContext context exception)
      | isAsynchronous exception → rethrowIO caught
      | otherwise →
          rethrowIO
            (ExceptionWithContext (attach (`ContextEntry` boundary) context) (exception ∷ SomeException))

-- | The evidence on an exception a caller caught as 'SomeException'.
failureEvidence ∷ SomeException → FailureEvidence
failureEvidence = failureEvidenceInContext . someExceptionContext

-- | The evidence on a context a caller holds directly, such as the one
-- 'tryWithContext' or 'Control.Exception.catchNoPropagate' returns.
--
-- This is a pure read. If more than one origin is present, the earliest
-- attached is the origin: a later site never becomes it.
failureEvidenceInContext ∷ ExceptionContext → FailureEvidence
failureEvidenceInContext context =
  FailureEvidence
    { failureCause = case [origin | OriginEntry _ origin ← entries] of
        origin : _ → EngineOrigin origin
        [] → NativeCause
    , failureContexts = [boundary | ContextEntry _ boundary ← entries]
    }
  where
    entries = sortOn entryPosition (getExceptionAnnotations context)

attach ∷ (Int → Evidence) → ExceptionContext → ExceptionContext
attach entry context =
  addExceptionAnnotation (entry (length (getExceptionAnnotations context ∷ [Evidence]))) context

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- | An origin whose identifiers and site are forced as soon as it is.
originAt ∷ Component → Operation → [(Text, Text)] → CallStack → FailureOrigin
originAt component operationName identifiers stack =
  forced
    (FailureOrigin component operationName identifiers site)
    [forceIdentifiers identifiers, forceSite site]
  where
    site = siteOf stack

-- | The outermost frame and the whole stack, matching the logger's source
-- attribution.
siteOf ∷ CallStack → Maybe FailureSite
siteOf stack = case frames of
  [] → Nothing
  _ → Just (FailureSite (last frames) frames)
  where
    frames = map frame (getCallStack stack)
    frame (name, location) =
      SourceLocation
        { sourceFile = Text.pack (srcLocFile location)
        , sourceLine = srcLocStartLine location
        , sourceFunction = Text.pack name
        }

forced ∷ a → [()] → a
forced value obligations = foldr seq value obligations

forceIdentifiers ∷ [(Text, Text)] → ()
forceIdentifiers = foldr (\(key, value) rest → key `seq` value `seq` rest) ()

forceSite ∷ Maybe FailureSite → ()
forceSite Nothing = ()
forceSite (Just (FailureSite location frames)) = location `seq` foldr seq () frames
