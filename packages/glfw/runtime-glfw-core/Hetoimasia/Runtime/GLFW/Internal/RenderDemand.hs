-- | Composing the application's simulation demand with each window's render
-- demand: which windows are offered a render opportunity this turn, and what
-- the owner loop should wait toward.
--
-- __Ownership.__ This module owns the mapping from an application's update
-- demand and a window's published demand onto the request and schedule shapes
-- "Hetoimasia.GLFW.Demand" publishes and
-- "Hetoimasia.Runtime.GLFW.Internal" schedules, and it owns that mapping
-- alone. The runtime owns the update policy itself
-- ("Hetoimasia.Runtime.UpdatePolicy"); the GLFW model owns the demand slots and
-- the observations; the owner loop owns waiting, dispatch, and the retirement
-- of closing windows. Retirement is not represented here at all and is never
-- gated by anything here: hiding or closing a window suppresses its rendering
-- and nothing else.
--
-- __State.__ A 'RenderDemand' is an immutable value the caller threads from one
-- turn to the next. It holds one 'WindowRenderState' per window it has been
-- shown, keyed by the opaque 'WindowId', and the rotation cursor that makes the
-- opportunities fair; it holds no window, no handle, no observation history, no
-- renderer, and nothing a driver could name. Nothing here reads a clock,
-- sleeps, starts a thread, allocates, or calls a native function: the caller
-- samples its own source and passes the instant in.
--
-- __No GPU knowledge.__ This helper offers opportunities. It performs no
-- drawing, calls no graphics API, and infers no device readiness whatever: a
-- future rendering backend must additionally account for presentation
-- backpressure and frame completion on top of what is decided here.
--
-- = Eligibility
--
-- 'windowRenderEligibility' reads one 'WindowObservation' and nothing else, in
-- this precedence:
--
-- 1. a window whose phase is 'WindowClosing' or terminal is 'RenderExcluded':
--    it has no normal render demand at all, and a turn shown such an
--    observation removes that window's scheduling state rather than keeping it;
-- 2. otherwise a /known/ suspending condition — @'Observed' False@ for visible,
--    @'Observed' True@ for iconified, or an @'Observed'@ framebuffer extent
--    with a zero dimension — makes it 'RenderSuspended', even when another
--    field is 'Unavailable';
-- 3. otherwise an 'Unavailable' framebuffer extent makes it 'RenderDeferred':
--    rendering waits until a usable extent is known, and the window is neither
--    offered an opportunity nor counted as suspended;
-- 4. otherwise it is 'RenderEligible'.
--
-- An 'Unavailable' visible or iconified field asserts nothing and leaves the
-- decision to the other fields, so no observation the platform could not answer
-- is ever invented.
--
-- = What a turn does
--
-- 'renderTurn' takes the sampled 'Instant', the application's simulation
-- 'Demand', and one 'WindowRender' per live window — its latest observation,
-- the demand captured from its slot this turn with that capture's revision, and
-- any explicit frame deadline the application set for it. It answers the
-- ordered 'RenderOffer's, the 'UpdateSchedule' the loop should continue with,
-- and the updated state.
--
-- A capture is /transferred/ into the window's bounded scheduling state rather
-- than left as permanent immediate work for the loop: its immediate demand
-- coalesces into one pending redraw, and its deadline is kept as the earliest
-- pending published deadline. That is separate from the frame schedule the
-- application supplies, which it may replace on any turn. An absolute frame
-- deadline is never enough to infer a recurring period: a deadline the helper
-- has already served is not recreated while the caller keeps supplying the same
-- value, and future cadence has to come from the caller's own next deadline.
-- Supplying no deadline where one was supplied before removes it.
--
-- = Suspension and resume
--
-- A suspended window keeps its latest need to redraw, its pending published
-- deadline, and its most recent frame request, but contributes nothing to the
-- wait: neither its expired deadlines, which would otherwise shorten the wait
-- to nothing every turn, nor its pending ones. A deferred window is the same in
-- this respect, and keeps its demand until a usable extent arrives.
--
-- Leaving suspension is a resume. It rebases the window's frame schedule at the
-- resume instant and owes exactly one current frame; nothing missed while
-- suspended is replayed, and no state grows with the missed frames. That
-- obligation is held apart from the caller's own frame schedule, so a resume
-- into a deferred observation still owes its frame — and still owes it however
-- many times the caller replaces that window's frame deadline while it is
-- deferred — and it is offered once the window becomes drawable.
--
-- = Fairness and acknowledgement
--
-- At most 'renderBudgetSize' opportunities are offered per turn, each window at
-- most once, in identity order starting after the window served last. The
-- rotation advances on the offers themselves, not on whatever the caller did
-- with them, so for a stable set of @n@ continuously eligible pending windows
-- and a budget of @b@ every one of them is offered within @ceiling (n \/ b)@
-- turns and a window that is dirty every turn cannot starve another.
--
-- Eligible due work left beyond the budget keeps the next schedule
-- 'UpdateImmediately'; work that was offered does not by itself, and neither
-- does a deadline that offer already covers, so a caller that serves its offers
-- returns to ordinary waiting rather than to a wake for work it has done.
--
-- 'acknowledgeRender' records the revision an opportunity served. Demand
-- published after that revision has already been folded in under a newer one
-- and stays pending, so an acknowledgement can never erase a newer request;
-- repeated dirtiness between two opportunities coalesces into one, so no
-- backlog of obsolete frames accumulates.
--
-- = Removal
--
-- A window the caller stops listing — because the host no longer holds it — is
-- removed from the state by the next turn, as is one whose observation reports
-- any phase but 'WindowOpen'. A window's demand slot closes in the same
-- transaction that publishes 'WindowClosing', so the first closing observation
-- is the last thing the helper can learn about it and its state goes then,
-- rather than lingering until the window is released. 'forgetRenderWindow'
-- removes one outright. The state therefore never holds an entry for a window
-- whose slot has closed or that the host no longer holds.
--
-- See @docs\/glfw.md@, \"Render demand\", for the same contract in prose, and
-- @docs\/runtime_scheduling_design.md@ P-5 for the design it implements.
module Hetoimasia.Runtime.GLFW.Internal.RenderDemand
  ( -- * The state
    RenderDemand
  , noRenderDemand
  , renderDemandWindows
  , windowRenderState
  , WindowRenderState (..)
  , forgetRenderWindow

    -- * The opportunity budget
  , RenderBudget
  , renderBudget
  , renderBudgetSize
  , RenderBudgetRejected (..)

    -- * Eligibility
  , RenderEligibility (..)
  , windowRenderEligibility

    -- * One turn
  , WindowRender (..)
  , RenderTurn (..)
  , renderTurn
  , RenderResult (..)
  , renderDeadline

    -- * Opportunities
  , RenderOffer (..)
  , acknowledgeRender
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust)
import Hetoimasia.Foundation.Time (Instant, deadlineReached)
import Hetoimasia.GLFW.Demand (CapturedDemand (..), demandDeadline, demandIsImmediate)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , Extent (..)
  , WindowId
  , WindowObservation
  , WindowPhase (..)
  , observedFramebufferExtent
  , observedIconified
  , observedPhase
  , observedVisible
  , observedWindow
  )
import Hetoimasia.Runtime.GLFW.Internal (UpdateSchedule (..))
import Hetoimasia.Runtime.UpdatePolicy (Demand (..))
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Eligibility

-- | What one observation says about a window's rendering, and nothing about its
-- retirement.
data RenderEligibility
  = RenderEligible
    -- ^ Drawable as far as the observation can tell: it may be offered an
    -- opportunity, and its deadlines bound the wait.
  | RenderSuspended
    -- ^ Known hidden, known minimized, or known to have a zero framebuffer
    -- dimension. Its demand is kept and excluded from the wait, and leaving
    -- this state is a resume.
  | RenderDeferred
    -- ^ The framebuffer extent is unknown and nothing known suspends it.
    -- Rendering waits for a usable extent; this is not suspension, so becoming
    -- drawable owes no resume frame of its own.
  | RenderExcluded
    -- ^ Closing or ended: no normal render demand, and its scheduling state is
    -- removed by the turn that sees it. Retirement is the owner loop's and is
    -- never gated here.
  deriving (Eq, Show)

-- | Classify one observation. This reads the observation and nothing else, so
-- the same observation always answers the same way.
windowRenderEligibility ∷ WindowObservation → RenderEligibility
windowRenderEligibility observation
  | ended (observedPhase observation) = RenderExcluded
  | observedVisible observation == Observed False = RenderSuspended
  | observedIconified observation == Observed True = RenderSuspended
  | Observed extent ← observedFramebufferExtent observation, blank extent = RenderSuspended
  | Unavailable ← observedFramebufferExtent observation = RenderDeferred
  | otherwise = RenderEligible
  where
    blank extent = extentWidth extent <= 0 || extentHeight extent <= 0
    ended = \case
      WindowOpen → False
      WindowClosing → True
      WindowReleased → True
      WindowDisposalFailed → True
      WindowReleaseUncertain → True

-- | Whether a phase removes the window's scheduling state. Every phase but
-- 'WindowOpen' does: a window's demand slot closes in the same transaction that
-- publishes 'WindowClosing', so from that observation onward there is nothing
-- left to capture for it and nothing it could be offered. Its retirement is the
-- owner loop's and needs nothing from here.
retiringPhase ∷ WindowPhase → Bool
retiringPhase = \case
  WindowOpen → False
  WindowClosing → True
  WindowReleased → True
  WindowDisposalFailed → True
  WindowReleaseUncertain → True

-- ---------------------------------------------------------------------------
-- The state

-- | One window's scheduling state, and nothing else about the window.
data WindowRenderState = WindowRenderState
  { windowRedrawPending ∷ !Bool
    -- ^ The coalesced immediate demand captured from its slot and not yet
    -- served. Repeated dirtiness between opportunities is one redraw.
  , windowDeadlinePending ∷ !(Maybe Instant)
    -- ^ The earliest deadline its publishers asked for and nothing has served.
  , windowRevisionPending ∷ !Natural
    -- ^ The newest capture revision folded into this state; zero before any.
  , windowRevisionServed ∷ !Natural
    -- ^ The newest revision an acknowledged opportunity recorded.
  , windowFrameDue ∷ !(Maybe Instant)
    -- ^ The obligation the caller's own frame deadline created, and nothing
    -- else. A changed frame request replaces it.
  , windowFrameRequested ∷ !(Maybe Instant)
    -- ^ The frame deadline the caller last supplied, so an unchanged one
    -- recreates no obsolete work and a withdrawn one removes its demand.
  , windowResumeDue ∷ !(Maybe Instant)
    -- ^ The one current frame a resume rebased at its instant. It is held apart
    -- from 'windowFrameDue' precisely so that replacing the caller's ongoing
    -- frame schedule — which a window may do on any turn, including while it is
    -- still deferred — cannot erase a resume frame that has not been served.
  , windowSuspended ∷ !Bool
    -- ^ Whether the last observation suspended it, which is what makes the next
    -- eligible or deferred observation a resume.
  }
  deriving (Eq, Show)

-- | A window nothing has been captured, requested, or served for.
freshWindowRenderState ∷ WindowRenderState
freshWindowRenderState =
  WindowRenderState
    { windowRedrawPending = False
    , windowDeadlinePending = Nothing
    , windowRevisionPending = 0
    , windowRevisionServed = 0
    , windowFrameDue = Nothing
    , windowFrameRequested = Nothing
    , windowResumeDue = Nothing
    , windowSuspended = False
    }

-- | The helper's whole state: per-window scheduling state and the rotation
-- cursor. Its representation is private, so no caller can build an entry for a
-- window no turn has seen.
data RenderDemand = RenderDemand
  { demandWindows ∷ !(Map WindowId WindowRenderState)
  , demandCursor ∷ !(Maybe WindowId)
    -- ^ The window the last offer served, which the next turn's rotation starts
    -- after.
  }
  deriving (Eq, Show)

-- | State that has seen no window and served no opportunity.
noRenderDemand ∷ RenderDemand
noRenderDemand = RenderDemand Map.empty Nothing

-- | The windows the state holds an entry for, in identity order.
renderDemandWindows ∷ RenderDemand → [WindowId]
renderDemandWindows = Map.keys . demandWindows

-- | One window's scheduling state, if the state holds one.
windowRenderState ∷ WindowId → RenderDemand → Maybe WindowRenderState
windowRenderState target = Map.lookup target . demandWindows

-- | Delete a window's scheduling state. A window the state does not hold is
-- unchanged, so this is idempotent and safe to repeat for a window already
-- removed by its closure.
forgetRenderWindow ∷ WindowId → RenderDemand → RenderDemand
forgetRenderWindow target state =
  state {demandWindows = Map.delete target (demandWindows state)}

-- ---------------------------------------------------------------------------
-- The opportunity budget

-- | A validated bound on how many render opportunities one turn offers.
newtype RenderBudget = RenderBudget Int
  deriving (Eq, Show)

-- | Why a budget was refused.
data RenderBudgetRejected
  = OpportunityBudgetNotPositive
  deriving (Eq, Show)

-- | A budget from the number of opportunities one turn may offer, which must be
-- strictly positive: a budget of none would offer nothing however dirty a
-- window became.
renderBudget ∷ Int → Either RenderBudgetRejected RenderBudget
renderBudget opportunities
  | opportunities <= 0 = Left OpportunityBudgetNotPositive
  | otherwise = Right (RenderBudget opportunities)

-- | The opportunities the budget allows per turn.
renderBudgetSize ∷ RenderBudget → Int
renderBudgetSize (RenderBudget opportunities) = opportunities

-- ---------------------------------------------------------------------------
-- One turn

-- | What the caller knows about one live window this turn.
data WindowRender = WindowRender
  { renderedObservation ∷ !WindowObservation
    -- ^ Its latest observation, which decides its eligibility and carries its
    -- identity.
  , renderedCapture ∷ !(Maybe CapturedDemand)
    -- ^ What this turn captured from its demand slot, with the revision, or
    -- 'Nothing' when nothing was pending.
  , renderedFrame ∷ !(Maybe Instant)
    -- ^ The absolute frame deadline the application currently wants for it, or
    -- 'Nothing' for none.
  }
  deriving (Eq, Show)

-- | One turn's inputs.
data RenderTurn = RenderTurn
  { renderNow ∷ !Instant
    -- ^ The instant the caller sampled, in its own clock domain.
  , renderSimulation ∷ !Demand
    -- ^ The application's simulation demand, carried independently of every
    -- window: an explicit pause is the application's own and is expressed as
    -- 'NoDemand' here. A window's visibility never changes it.
  , renderLive ∷ ![WindowRender]
    -- ^ Every window the host still holds. A window left out is removed.
  }
  deriving (Eq, Show)

-- | One offered render opportunity. It names the work the offer covers, so an
-- acknowledgement can clear exactly that and no more.
data RenderOffer = RenderOffer
  { offeredWindow ∷ !WindowId
  , offeredRevision ∷ !Natural
    -- ^ The newest capture revision the offer covers; zero when the window owed
    -- only a frame.
  , offeredFrame ∷ !(Maybe Instant)
    -- ^ The caller's own frame obligation the offer serves, when one was due.
  , offeredResume ∷ !(Maybe Instant)
    -- ^ The resume frame the offer serves, when one was owed and due. It is
    -- named separately from 'offeredFrame' so an acknowledgement clears exactly
    -- the obligations that opportunity covered.
  }
  deriving (Eq, Show)

-- | What one turn decided.
data RenderResult = RenderResult
  { renderOffers ∷ ![RenderOffer]
    -- ^ The windows offered an opportunity, in the order they were offered.
  , renderSchedule ∷ !UpdateSchedule
    -- ^ What the loop should continue with: 'UpdateImmediately' when eligible
    -- due work is still owed beyond the budget or the simulation wants a turn
    -- now, 'UpdateBy' the earliest deadline anything eligible still holds that
    -- this turn's offers do not already serve, and 'NoUpdateDemand' when
    -- nothing is owed at all, so the loop waits its fallback bound.
  }
  deriving (Eq, Show)

-- | The deadline the schedule named, if it named one.
renderDeadline ∷ RenderResult → Maybe Instant
renderDeadline result = case renderSchedule result of
  UpdateBy due → Just due
  UpdateImmediately → Nothing
  NoUpdateDemand → Nothing

-- | Compose one turn: fold what was captured and requested into each window's
-- scheduling state, classify each window, offer the budget's opportunities
-- fairly, and answer the schedule the loop should continue with.
renderTurn ∷ RenderBudget → RenderTurn → RenderDemand → (RenderResult, RenderDemand)
renderTurn (RenderBudget allowance) turn state = (result, RenderDemand kept cursor)
  where
    now = renderNow turn

    -- Every window the caller still holds, minus the ones whose phase removes
    -- them, with its scheduling state advanced by this turn's inputs.
    inspected ∷ Map WindowId (RenderEligibility, WindowRenderState)
    inspected =
      Map.fromList
        [ (observedWindow observation, advanceWindow now input previous)
        | input ← renderLive turn
        , let observation = renderedObservation input
              previous =
                Map.findWithDefault
                  freshWindowRenderState
                  (observedWindow observation)
                  (demandWindows state)
        , not (retiringPhase (observedPhase observation))
        ]

    kept = Map.map snd inspected

    -- Eligible windows owing work now, in identity order.
    candidates = [target | (target, (RenderEligible, window)) ← Map.toAscList inspected, dueNow now window]

    -- Rotated to start strictly after the window the last offer served, so no
    -- window is offered twice while another waits.
    rotated = case demandCursor state of
      Nothing → candidates
      Just served → case span (<= served) candidates of
        (before, after) → after <> before

    (offering, beyond) = splitAt allowance rotated

    offers =
      [ RenderOffer
          { offeredWindow = target
          , offeredRevision = windowRevisionPending window
          , offeredFrame = reachedBy now (windowFrameDue window)
          , offeredResume = reachedBy now (windowResumeDue window)
          }
      | target ← offering
      , Just (_, window) ← [Map.lookup target inspected]
      ]

    cursor = case offering of
      [] → demandCursor state
      _ → Just (last offering)

    -- Only deadlines still in the future, and only the ones this turn's offers
    -- do not already serve. An offer covers the window's whole pending request,
    -- including a deadline that had not been reached, so reporting that
    -- deadline as well would wake the loop for work it had just handed out. A
    -- frame deadline the offer did not serve, because it was not yet due, is
    -- still owed and is still reported.
    upcoming =
      [ due
      | (target, (RenderEligible, window)) ← Map.toAscList inspected
      , due ←
          catMaybes
            [ if target `elem` offering then Nothing else windowDeadlinePending window
            , windowFrameDue window
            , windowResumeDue window
            ]
      , not (deadlineReached now due)
      ]

    simulated = case renderSimulation turn of
      DeadlineDemand due → [due]
      ImmediateDemand → []
      NoDemand → []

    immediate = renderSimulation turn == ImmediateDemand || not (null beyond)

    schedule
      | immediate = UpdateImmediately
      | due : rest ← simulated <> upcoming = UpdateBy (foldr min due rest)
      | otherwise = NoUpdateDemand

    result = RenderResult {renderOffers = offers, renderSchedule = schedule}

-- | Fold this turn's capture and frame request into one window's state, then
-- apply what its observation says about suspension.
advanceWindow ∷ Instant → WindowRender → WindowRenderState → (RenderEligibility, WindowRenderState)
advanceWindow now input previous = (eligibility, settled)
  where
    eligibility = windowRenderEligibility (renderedObservation input)
    requested = applyFrame (renderedFrame input) (foldCapture (renderedCapture input) previous)
    settled = case eligibility of
      RenderSuspended → requested {windowSuspended = True}
      RenderExcluded → requested
      _
        -- Leaving suspension rebases the frame schedule here and owes exactly
        -- one current frame, in its own field. A resume into a deferred
        -- observation keeps that obligation until the window is drawable,
        -- however often the caller replaces its frame deadline meanwhile.
        | windowSuspended requested → requested {windowSuspended = False, windowResumeDue = Just now}
        | otherwise → requested

-- | Transfer a captured publication into bounded scheduling state: its
-- immediate demand coalesces, its deadline can only be brought earlier, and the
-- revision it carried is what a later acknowledgement is weighed against.
foldCapture ∷ Maybe CapturedDemand → WindowRenderState → WindowRenderState
foldCapture Nothing window = window
foldCapture (Just captured) window =
  window
    { windowRedrawPending = windowRedrawPending window || demandIsImmediate request
    , windowDeadlinePending = earlier (windowDeadlinePending window) (demandDeadline request)
    , windowRevisionPending = max (windowRevisionPending window) (capturedRevision captured)
    }
  where
    request = capturedRequest captured

-- | Apply the caller's current frame deadline. An unchanged request creates
-- nothing, so a deadline already served is not recreated on every later turn; a
-- changed one, including a withdrawal, replaces the obligation outright.
applyFrame ∷ Maybe Instant → WindowRenderState → WindowRenderState
applyFrame requested window
  | requested == windowFrameRequested window = window
  | otherwise = window {windowFrameRequested = requested, windowFrameDue = requested}

-- | Whether a window owes work at this instant.
dueNow ∷ Instant → WindowRenderState → Bool
dueNow now window =
  windowRedrawPending window
    || any (isJust . reachedBy now) [windowDeadlinePending window, windowFrameDue window, windowResumeDue window]

-- | An obligation an offer made at this instant serves, if it is due.
reachedBy ∷ Instant → Maybe Instant → Maybe Instant
reachedBy now held = case held of
  Just due | deadlineReached now due → Just due
  _ → Nothing

earlier ∷ Maybe Instant → Maybe Instant → Maybe Instant
earlier left right = case (left, right) of
  (Nothing, other) → other
  (other, Nothing) → other
  (Just one, Just another) → Just (min one another)

-- | Record what an opportunity served.
--
-- The request is cleared only when nothing newer than the offered revision has
-- been folded in since; a newer publication stays pending and is offered again.
-- The frame obligation is cleared only when it is still the one the offer
-- carried. A window the state no longer holds is unchanged.
acknowledgeRender ∷ RenderOffer → RenderDemand → RenderDemand
acknowledgeRender offer state =
  state {demandWindows = Map.adjust served (offeredWindow offer) (demandWindows state)}
  where
    served window = frame (request window)
    request window
      | windowRevisionPending window <= offeredRevision offer =
          window
            { windowRedrawPending = False
            , windowDeadlinePending = Nothing
            , windowRevisionServed = max (windowRevisionServed window) (offeredRevision offer)
            }
      | otherwise = window {windowRevisionServed = max (windowRevisionServed window) (offeredRevision offer)}
    frame window = resumed (case offeredFrame offer of
      Just due | windowFrameDue window == Just due → window {windowFrameDue = Nothing}
      _ → window)
    resumed window = case offeredResume offer of
      Just due | windowResumeDue window == Just due → window {windowResumeDue = Nothing}
      _ → window
