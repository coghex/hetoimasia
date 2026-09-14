{-# LANGUAGE RoleAnnotations #-}

-- | Payloads prepared to normal form before they cross a thread boundary.
--
-- A message a producer publishes is read on another thread, usually by a
-- worker that did not build it. If the value still holds an unevaluated thunk,
-- a failure inside that thunk would first appear in the consumer, far from the
-- code that caused it, and the consumer would also pay for evaluation the
-- producer deferred. 'prepare' closes that gap: it fully evaluates a value
-- through its 'NFData' instance, in 'IO', on the producer's own thread, and only
-- then returns an opaque 'Prepared' handle to it. Later messaging slices accept
-- only a 'Prepared' payload, so there is no weak-head-only or unprepared route
-- into a transport.
--
-- Evaluation guarantees:
--
-- * __Full evaluation, once.__ 'prepare' forces the value to normal form before
--   it returns. A failure nested anywhere the 'NFData' instance reaches — an
--   element of a lazy list inside a strict record, say — is raised by 'prepare'
--   and not by a later read. 'preparedValue' is a pure projection that
--   evaluates nothing, and holding, reading, or forwarding a handle needs no
--   'NFData' instance and never runs one again.
--
-- * __Failures are the producer's.__ An exception raised during preparation
--   propagates from 'prepare' with its original type and context, and no handle
--   is returned. Inside 'Hetoimasia.Foundation.Failure.withOperationContext'
--   the failure gains that boundary's operation context as any other
--   synchronous failure would. Cancellation delivered during preparation
--   propagates as cancellation. Preparation catches nothing, retries nothing,
--   and logs nothing.
--
-- * __Lawful instances.__ Normal form is exactly what the payload type's own
--   'NFData' instance forces. The component that owns the type owns that
--   instance; one that skips a field leaves that field lazy, and nothing here
--   can detect it.
--
-- * __Producer-side cost.__ Evaluation is proportional to the size of the value
--   and happens on the calling thread, before publication. That is the point:
--   the cost and any failure are charged to the producer.
--
-- * __No resource scope.__ Preparation evaluates a value; it does not own
--   anything the value refers to. A closure or a borrowed native handle inside
--   a prepared payload is still only valid within the scope that owns it, and
--   preparing it does not extend that scope.
--
-- A 'Prepared' handle cannot be built, rewritten, or re-typed from outside this
-- module. The constructor is not exported, the reader is a function rather than
-- a record field, the type's role is nominal so 'Data.Coerce.coerce' can neither
-- wrap a value nor change the payload type, and there is no 'Functor' or
-- 'Traversable' instance. A transformed value is prepared again.
--
-- State: the module owns none. A 'Prepared' value is immutable, owned by
-- whoever holds it, readable from any thread, and lives as long as it is
-- referenced; there is no reset or disposal. It adds no queue, snapshot, or
-- other transport state and no STM operation. Bounded FIFO channels live in
-- "Hetoimasia.Foundation.Messaging.Channel"; snapshots and the runtime inbox
-- adapter arrive in later slices.
--
-- See @docs/messaging.md@ for the same contract in prose.
module Hetoimasia.Foundation.Messaging.Payload
  ( Prepared
  , prepare
  , preparedValue
  ) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)

-- | A payload fully evaluated through its 'NFData' instance by 'prepare'.
--
-- The role is nominal: a handle for one payload type is never coercible to a
-- handle for another, even when the two share a representation, because the
-- second type's 'NFData' instance was never the one that ran.
type role Prepared nominal

newtype Prepared a = Prepared a

-- | Fully evaluate a value through its 'NFData' instance on the calling thread
-- and return a handle to it.
--
-- Any exception raised during evaluation propagates with its own type and
-- context, and no handle is returned. Nothing is caught, retried, or logged.
prepare ∷ NFData a ⇒ a → IO (Prepared a)
prepare value = Prepared <$> evaluate (force value)

-- | The prepared value. Reading it evaluates nothing and needs no 'NFData'
-- instance, so an unchanged payload can be forwarded without preparing it
-- again.
preparedValue ∷ Prepared a → a
preparedValue (Prepared value) = value
