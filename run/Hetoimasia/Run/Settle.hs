-- | The small rules every wait of the launcher's shutdown follows, in one place.
--
-- * A wait for something that must finish (a child ending, a session settling, a writer ending) is /never/
--   made uninterruptible, and a cancellation delivered meanwhile is /remembered/ and raised after the wait
--   has completed, never instead of it ('remembering').
-- * Catching a failure to examine it must not swallow a cancellation: 'attemptSync' hands back only synchronous
--   failures, with their context, and lets an asynchronous exception go on ('isAsynchronous').
-- * A diagnostic that cannot be written must not replace what it reports ('bestEffort').
-- * Several failures that belong together are combined with the cleanup machinery's own evidence, so none
--   is lost ('combine').
module Hetoimasia.Run.Settle
  ( remembering
  , rememberingInterruption
  , attemptSync
  , isAsynchronous
  , bestEffort
  , combine
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , rethrowIO
  , tryWithContext
  )
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (composeCleanup)

-- | Whether a caught failure is an asynchronous exception (a cancellation).
isAsynchronous ∷ ExceptionWithContext SomeException → Bool
isAsynchronous (ExceptionWithContext _ failure) = case fromException failure of
  Just (_ ∷ SomeAsyncException) → True
  Nothing → False

-- | Run an action and hand back a /synchronous/ failure with its context. An asynchronous exception is not caught
-- here: it goes on, as itself.
attemptSync ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
attemptSync action =
  tryWithContext action >>= \case
    Left failure | isAsynchronous failure → rethrowIO failure
    other → pure other

-- | Run an action that must finish, running it again whenever an asynchronous exception interrupts it, and answer
-- the first such interruption (with its context) once the action has completed undisturbed.
rememberingInterruption ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
rememberingInterruption act = go Nothing
  where
    go pending =
      tryWithContext act >>= \case
        Right () → pure pending
        Left interruption
          | isAsynchronous interruption → go (Just (fromMaybe interruption pending))
          | otherwise → rethrowIO interruption

-- | 'rememberingInterruption', raising the interruption after the action has completed.
remembering ∷ IO () → IO ()
remembering act = rememberingInterruption act >>= traverse_ rethrowIO

-- | Run a diagnostic and ignore a synchronous failure of it, once. A cancellation still goes on.
bestEffort ∷ IO () → IO ()
bestEffort action = () <$ attemptSync action

-- | A primary failure with these further failures retained beside it, each under its label, as the cleanup
-- machinery retains evidence: none is lost, and the primary keeps its type, value and context.
combine ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
combine primary others = fromMaybe primary <$> composeCleanup (Just primary) others
