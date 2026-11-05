-- | How the native suite's helpers start a thread (#594): through "Test.Support.Owned", and nowhere else.
--
-- Every helper of this suite that used to take a fork primitive (@onThread forkOS@, @wokenWait forkIO@, the waker lists of the
-- private-session rounds) says instead whether its thread is to be 'Bound' to an OS thread or 'Unbound', and the start is
-- made here, owned: acquired and registered for its stop-and-join in one masked step, and stopped and joined on every way out
-- of the scope that needed it, a cancellation delivered while the thread is starting included. A caller can no longer supply
-- an unowned start. Which thread enters a native session is what 'Boundness' decides, so the conversion changes nothing the
-- examples assert: the four starts that were @forkOS@ are 'Bound' and run on the facility's bound start (#593).
--
-- /The scope./ A 'Scope' is the one place a helper's start is chosen. Production use is 'ownedScope', the facility itself. The
-- ownership regressions ("Test.GLFW.Native.Ownership") run each converted helper a second time in the unowned scope their
-- negative controls own, the start the helper made before it was converted, so that a regression that could not tell an
-- owned start from an unowned one cannot pass. The helpers take the scope only in their @…In@ variants, which exist for those
-- regressions; the names the examples use are fixed to 'ownedScope'.
--
-- State owner: none; this module holds nothing. Nothing here sleeps.
module Test.GLFW.Native.Threads
  ( Boundness (..)
  , Scope (..)
  , ownedScope
  , startIn
  , startOwned
  ) where

import Control.Concurrent (ThreadId)
import Test.Support.Owned (withOwnedBoundThreadOpening, withOwnedThreadOpening, withOwnedThreadOpeningOn)

-- | Whether a thread is to be an OS-bound thread. The sessions refuse entry from a bound worker and from an unbound thread, and
-- the wake examples run their waker both ways, so the choice is part of what an example asserts. 'Pinned' is an unbound thread
-- pinned to one capability (#610, "Test.Support.Owned"): an example whose point is that a cancellation is /pending/ against a
-- thread starts that thread and the cancellation's sender pinned to the same capability, where a sender seen blocked delivering
-- has an exception pending against its target, always.
data Boundness = Unbound | Bound | Pinned Int
  deriving (Eq, Show)

-- | A way to start a thread for the length of a body: the boundness wanted, what must be let go before the thread can end (a
-- gate it waits at, opened idempotently and without blocking, in the uninterruptible release before the kill), the thread's
-- action, and the body, which is given the thread and a wait for its end.
newtype Scope = Scope (forall a. Boundness → IO () → IO () → (ThreadId → IO () → IO a) → IO a)

-- | The facility itself.
ownedScope ∷ Scope
ownedScope = Scope $ \boundness open action body → case boundness of
  Unbound → withOwnedThreadOpening open action body
  Bound → withOwnedBoundThreadOpening open action body
  Pinned capability → withOwnedThreadOpeningOn capability open action body

-- | Start a thread in the given kind of scope.
startIn ∷ Scope → Boundness → IO () → IO () → (ThreadId → IO () → IO a) → IO a
startIn (Scope start) = start

-- | Start an owned thread of the given boundness for the length of the body, with nothing to let go.
startOwned ∷ Boundness → IO () → (ThreadId → IO () → IO a) → IO a
startOwned boundness = startIn ownedScope boundness (pure ())
