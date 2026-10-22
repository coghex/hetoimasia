-- | Turning an ordinary failure into a value without hiding anything else.
--
-- A scan or a verified read runs inside the content layer's scopes, which throw
-- a 'ContentFailure' for an ordinary problem (an unreadable file, a link, a
-- type that changed) and retain beside any exception the failures of the
-- cleanup that ran while it unwound. 'ordinarily' returns an ordinary failure
-- as a value, and only when nothing else went wrong with it:
--
-- * a cancellation, a defect, or any exception the classifier does not name
--   propagates untouched;
-- * an ordinary failure that carries retained cleanup evidence also propagates,
--   as the exception it was captured as, so the failed close travels with the
--   primary failure and is never reported as an expected content error.
module Hetoimasia.Content.Internal.Inventory.Outcome
  ( ordinarily
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , rethrowIO
  , tryWithContext
  )
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)

-- | Run an action; a failure the classifier names, and that has no retained
-- cleanup evidence, becomes a 'Left'. Everything else is rethrown with its
-- context.
ordinarily ∷ (SomeException → Maybe e) → IO a → IO (Either e a)
ordinarily classify action =
  tryWithContext @SomeException action >>= \case
    Right result → pure (Right result)
    Left caught@(ExceptionWithContext context exception)
      | not (null (cleanupFailuresInContext context)) → rethrowIO caught
      | Just ordinary ← classify exception → pure (Left ordinary)
      | otherwise → rethrowIO caught
