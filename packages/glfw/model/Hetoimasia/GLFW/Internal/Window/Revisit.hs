-- | The follow-up of a window's visible attribute after an iconify transition.
--
-- Visible has no GLFW callback, so the observation holds it only from a
-- sample. The restore control's own post-call sample can read the transient
-- @False@ of a restore that completes asynchronously (Cocoa), and the iconify
-- callback that reports the restore folds without sampling, so nothing would
-- read visible again. This module holds the pure state of the mechanism that
-- does; the owner boundary that performs the re-read is
-- 'Hetoimasia.GLFW.Internal.Window.Boundary.revisitVisible', and the host's
-- owner turn offers it once per window per turn.
--
-- = The mechanism
--
-- An iconify transition (the platform's iconify callback, folded at whichever
-- owner boundary consumes the capture) starts the quick phase, or stops the
-- mechanism when the window was iconified. In the quick phase the window's
-- visible attribute is re-read on its next owner turns until a read reports
-- @True@ or 'visibleQuickReads' reads are spent. If the window is then still
-- 'Hetoimasia.GLFW.Internal.Attribute.Observed' @False@, the slow phase
-- re-reads it on the first owner turn whose clock reading is at least one
-- host idle wait after its previous re-read. The reads stop when one reports
-- @True@ or the field becomes @Unavailable@, when a hide control settles, when
-- the window is iconified again, and when the window closes or ends. A window
-- in any other state holds 'RevisitIdle' and is never re-read.
--
-- = State
--
-- +--------------------+------------+--------------------------+--------+-----------------+----------------------------+
-- | State              | Owner      | Readers and writers      | Thread | Lifetime        | Reset or disposal          |
-- +====================+============+==========================+========+=================+============================+
-- | Visible follow-up  | The window | Reconciliation arms or   | Owner  | The window      | 'RevisitIdle' at creation; |
-- | phase              |            | stops it with the        |        |                 | every stop returns to it   |
-- |                    |            | capture it consumes, a   |        |                 |                            |
-- |                    |            | re-read advances it, a   |        |                 |                            |
-- |                    |            | hide control stops it;   |        |                 |                            |
-- |                    |            | the host turn reads it   |        |                 |                            |
-- +--------------------+------------+--------------------------+--------+-----------------+----------------------------+
module Hetoimasia.GLFW.Internal.Window.Revisit
  ( Revisit (..)
  , visibleQuickReads
  , armedBy
  , afterReread
  , stampsAfterFalse
  , rereadDue
  ) where

import Hetoimasia.Foundation.Time (Duration, Instant, elapsedBetween)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..))
import Numeric.Natural (Natural)

-- | Where a window is in the follow-up of its visible attribute.
data Revisit
  = RevisitIdle
    -- ^ Nothing is owed: the window is re-read by no rule.
  | RevisitQuick !Natural
    -- ^ The quick phase, with this many re-reads still owed (at least one).
  | RevisitSlow !Instant
    -- ^ The slow phase, with the host clock's reading at the previous re-read.
  deriving (Eq, Show)

-- | How many quick re-reads follow an iconify transition: eight owner turns.
--
-- A re-read is one native attribute query on the owner turn, so the bound is
-- a count of turns and never a deadline. On the default idle wait of 0.1
-- seconds, eight idle turns cover about 0.8 seconds, enough for a platform's
-- restore to finish and report the window visible; a window that is really
-- hidden after the restore costs at most eight reads before the slow phase,
-- at the idle-wait pace, takes over. The value only decides how soon a
-- recovery lands; recovery itself is guaranteed by the slow phase.
visibleQuickReads ∷ Natural
visibleQuickReads = 8

-- | The phase after a reconciliation consumed the iconify capture of this
-- value, if it consumed one: a restore starts the quick phase afresh, an
-- iconify stops the mechanism. Without a capture the phase is unchanged.
armedBy ∷ Maybe Bool → Revisit → Revisit
armedBy = \case
  Nothing → id
  Just True → const RevisitIdle
  Just False → const (RevisitQuick visibleQuickReads)

-- | The phase after a re-read of visible reported this value, given the
-- clock's reading of the turn that made it when one was needed
-- ('Nothing' otherwise). Only a report of @False@ keeps the mechanism going;
-- @True@ and @Unavailable@ stop it, since neither is a stale not-visible.
afterReread ∷ Attribute Bool → Maybe Instant → Revisit → Revisit
afterReread reported reading phase = case reported of
  Observed False → case (phase, reading) of
    (RevisitQuick remaining, Just now)
      | remaining <= 1 → RevisitSlow now
    -- Without a reading the last owed re-read cannot enter the slow phase, so
    -- it stays owed; the re-read that spends it is always given one.
    (RevisitQuick remaining, _) → RevisitQuick (max 1 (remaining - 1))
    (RevisitSlow _, Just now) → RevisitSlow now
    (other, _) → other
  _ → RevisitIdle

-- | Whether a re-read that reports @False@ in this phase needs the clock's
-- reading: the one that spends the quick bound, and every slow one.
stampsAfterFalse ∷ Revisit → Bool
stampsAfterFalse = \case
  RevisitQuick remaining → remaining <= 1
  RevisitSlow _ → True
  RevisitIdle → False

-- | Whether a slow re-check is due: the host clock has advanced at least one
-- host idle wait since the previous re-read. A clock that stood still or went
-- backwards makes it not due.
rereadDue ∷ Duration → Instant → Instant → Bool
rereadDue interval previous now = elapsedBetween previous now >= interval
