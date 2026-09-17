-- | A bound on a test call that must return.
--
-- Shared by suites whose examples wait on a call that a failure could leave
-- blocked. The bound turns a stuck example into a failure instead of a hung
-- run; it is never a timing assumption an example's correctness depends on.
module Test.Support.Bounded
  ( boundMicroseconds
  , bounded
  ) where

import Control.Exception (ErrorCall (ErrorCall), throwIO)
import System.Timeout (timeout)

-- | Long enough to bound a stuck test, never long enough to matter otherwise.
boundMicroseconds ∷ Int
boundMicroseconds = 10000000

-- | A call that must return rather than wait on state a failed or interrupted
-- operation should have released. Timing out is a test failure, not an
-- exception the assertion under it could mistake for the expected one.
bounded ∷ IO a → IO a
bounded action =
  timeout boundMicroseconds action
    >>= maybe (throwIO (ErrorCall "a bounded test call never returned")) pure
