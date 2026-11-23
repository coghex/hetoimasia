{-# LANGUAGE LambdaCase #-}

-- | How an operation over an issuer's capability ended, classified once for every adapter that delivers it.
--
-- An operation answers a value or a refusal, or raises. 'classifyExit' reads that result beside the issuer's standing,
-- read once the operation has ended, and gives one 'Exit'.
--
-- = The decision table
--
-- Rows are what the operation did; columns are the issuer's standing. A raise is synchronous or asynchronous by the
-- exception's type ('Control.Exception.SomeAsyncException'), as everywhere in this package: a cancellation is an
-- asynchronous exception and is never reclassified.
--
-- +---------------------------+---------------------+---------------------------+-------------------------------+
-- | The operation             | 'IssuerLive'        | 'IssuerEnded'             | @'IssuerEscaped' e@           |
-- +===========================+=====================+===========================+===============================+
-- | returned a value @a@      | @'Completed' a@     | @'Completed' a@           | @'Terminal' ('Right' e)@      |
-- +---------------------------+---------------------+---------------------------+-------------------------------+
-- | returned a refusal @r@    | @'Refused' r@       | @'Terminal' ('Left' r)@   | @'Terminal' ('Right' e)@      |
-- +---------------------------+---------------------+---------------------------+-------------------------------+
-- | raised synchronously @x@  | @'Raised' x@        | @'Terminal' ('Right' x)@  | @'Terminal' ('Right' x)@      |
-- +---------------------------+---------------------+---------------------------+-------------------------------+
-- | raised asynchronously @x@ | @'Cancelled' x@     | @'Cancelled' x@           | @'Cancelled' x@               |
-- +---------------------------+---------------------+---------------------------+-------------------------------+
--
-- * A refusal from a live issuer is a refusal, a transient answer a later attempt can outlive; once the issuer has
--   ended it is terminal, and keeps the refusal value.
-- * A synchronous raise from a live issuer is a recoverable failure of this operation alone; once the issuer has ended
--   it is terminal.
-- * A cancellation is a cancellation whatever the issuer's standing: it has priority over an escape.
-- * An escaped fatal construction ('IssuerEscaped': a failure the issuer recorded as escaping a construction the
--   operation was lent, which ends the issuer however the operation handled it) is terminal. When the operation
--   caught it and returned normally (a value or a refusal), the escape is the terminal failure, with its own original
--   context; when the operation raised its own synchronous exception, that exception is.
--
-- Every exception an 'Exit' carries is the one the operation raised or the issuer recorded, with its original context,
-- unchanged; a refusal is the operation's refusal value, unchanged.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.Exit
  ( Exit (..)
  , IssuerStanding (..)
  , classifyExit
  , tryExit
  , deliverExit
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, fromException, rethrowIO, tryWithContext)

-- | The issuer's standing once the operation ended: live; ended (its backend failed or its owner exited); or ended by a
-- construction failure that escaped the construction the operation was lent, recorded with its original context.
data IssuerStanding
  = IssuerLive
  | IssuerEnded
  | IssuerEscaped !(ExceptionWithContext SomeException)

-- | How one operation ended.
data Exit r a
  = -- | Its value.
    Completed a
  | -- | Its refusal, while the issuer lives: a later attempt can outlive it.
    Refused r
  | -- | Its synchronous exception, while the issuer lives: a failure of this operation alone.
    Raised !(ExceptionWithContext SomeException)
  | -- | An asynchronous exception, whatever the issuer's standing.
    Cancelled !(ExceptionWithContext SomeException)
  | -- | The end no later attempt outlives: the refusal a terminal issuer answered, or the exception the operation raised
    -- once the issuer had ended, or the issuer's escaped construction failure.
    Terminal !(Either r (ExceptionWithContext SomeException))

-- | Classify an operation's result by its issuer's standing (the decision table above).
classifyExit ∷ IssuerStanding → Either (ExceptionWithContext SomeException) (Either r a) → Exit r a
classifyExit standing = \case
  Left raised@(ExceptionWithContext _ exception)
    | Just (_ ∷ SomeAsyncException) ← fromException exception → Cancelled raised
    | otherwise → case standing of
        IssuerLive → Raised raised
        _ → Terminal (Right raised)
  Right (Left refusal) → case standing of
    IssuerLive → Refused refusal
    IssuerEnded → Terminal (Left refusal)
    IssuerEscaped escape → Terminal (Right escape)
  Right (Right value) → case standing of
    IssuerEscaped escape → Terminal (Right escape)
    _ → Completed value

-- | Run an operation, keeping a raised exception with its context.
tryExit ∷ IO (Either r a) → IO (Either (ExceptionWithContext SomeException) (Either r a))
tryExit = tryWithContext

-- | Deliver a classified exit to its caller: a value or a refusal answered, an exception rethrown with its original
-- context.
deliverExit ∷ Exit r a → IO (Either r a)
deliverExit = \case
  Completed value → pure (Right value)
  Refused refusal → pure (Left refusal)
  Raised raised → rethrowIO raised
  Cancelled raised → rethrowIO raised
  Terminal (Left refusal) → pure (Left refusal)
  Terminal (Right raised) → rethrowIO raised
