{-# LANGUAGE LambdaCase #-}

-- | How an operation over an issuer's capability ended, classified once for every adapter that delivers it.
--
-- An operation answers a value or a refusal, or raises. 'classifyExit' reads that result beside the issuer's
-- terminal standing, read after the operation, and tells apart:
--
-- * 'Completed': the operation's value;
-- * 'Refused': a refusal while the issuer lives, a transient answer a later attempt can outlive;
-- * 'Raised': a synchronous exception while the issuer lives, a recoverable failure of this operation alone;
-- * 'Cancelled': an asynchronous exception, whatever the issuer's standing;
-- * 'Terminal': a refusal or a synchronous exception once the issuer has ended (its backend failed, its owner
--   exited, or its construction escaped), which no later attempt outlives.
--
-- The original exception keeps its context in every class that carries one, so the adapter that delivers it
-- ('deliverExit', or the host's action ticket) rethrows or reports the exception it caught, not a description of it.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.Exit
  ( Exit (..)
  , IssuerStanding (..)
  , classifyExit
  , tryExit
  , deliverExit
  , exitRecoverable
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, fromException, rethrowIO, tryWithContext)

-- | Whether the issuer an operation ran against still lives, read once the operation ended.
data IssuerStanding = IssuerLive | IssuerEnded
  deriving (Eq, Show)

-- | How one operation ended.
data Exit r a
  = Completed a
  | Refused r
  | Raised (ExceptionWithContext SomeException)
  | Cancelled (ExceptionWithContext SomeException)
  | Terminal (Either r (ExceptionWithContext SomeException))

-- | Classify an operation's result by its issuer's standing. An asynchronous exception is a cancellation whatever
-- the standing; a refusal or a synchronous exception is terminal once the issuer has ended, and transient or
-- recoverable while it lives.
classifyExit ∷ IssuerStanding → Either (ExceptionWithContext SomeException) (Either r a) → Exit r a
classifyExit standing = \case
  Left raised@(ExceptionWithContext _ exception)
    | Just (_ ∷ SomeAsyncException) ← fromException exception → Cancelled raised
    | standing == IssuerEnded → Terminal (Right raised)
    | otherwise → Raised raised
  Right (Left refusal)
    | standing == IssuerEnded → Terminal (Left refusal)
    | otherwise → Refused refusal
  Right (Right value) → Completed value

-- | Run an operation, keeping a raised exception with its context.
tryExit ∷ IO (Either r a) → IO (Either (ExceptionWithContext SomeException) (Either r a))
tryExit = tryWithContext

-- | Deliver a classified exit to the caller: a value or a refusal answered, an exception rethrown with its original
-- context.
deliverExit ∷ Exit r a → IO (Either r a)
deliverExit = \case
  Completed value → pure (Right value)
  Refused refusal → pure (Left refusal)
  Raised raised → rethrowIO raised
  Cancelled raised → rethrowIO raised
  Terminal (Left refusal) → pure (Left refusal)
  Terminal (Right raised) → rethrowIO raised

-- | Whether a later attempt can outlive this exit: a value, a transient refusal or a recoverable exception.
exitRecoverable ∷ Exit r a → Bool
exitRecoverable = \case
  Completed _ → True
  Refused _ → True
  Raised _ → True
  Cancelled _ → False
  Terminal _ → False
