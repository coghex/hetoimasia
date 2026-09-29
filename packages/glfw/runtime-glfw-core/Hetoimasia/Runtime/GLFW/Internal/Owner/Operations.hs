-- | The narrow operation set a rendering backend injects into the graphics
-- owner, and the values those operations are given and answer.
--
-- This module owns no state. Every operation in 'GraphicsOperations' runs on
-- the owner thread, and only there; the one transaction, 'graphicsWake', is
-- read by the owner's own wait. Nothing here names a GLFW capability, so a
-- backend implementing it cannot reach the main thread's session, windows, or
-- event pump.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
  ( GraphicsOperations (..)
  , OwnerStart (..)
  , TargetStart (..)
  , TargetHandoff (..)
  , OwnerStep (..)
  , TargetStepView (..)
  , StepReport (..)
  , noStepWork
  , NextDeadline (..)
  , TargetRetire (..)
  , RetirementReadiness (..)
  , OwnerRetire (..)
  , OwnerDestroy (..)
  ) where

import Control.Concurrent.STM (STM)
import Data.Text (Text)
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence
  ( OwnerDestroyed
  , OwnerReady
  , OwnerRetired
  , RollbackEvidence
  , TargetEvidence
  , TargetRetired
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (OwnerDemand, TargetGeometry)
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility)
import Numeric.Natural (Natural)

-- | What the owner tells its backend when it starts. It carries the owner's
-- own label and nothing else: no session, no window, no native handle, and no
-- GLFW capability of any kind.
newtype OwnerStart = OwnerStart {startingOwner ∷ Text}
  deriving (Eq, Show)

-- | What the owner tells its backend about one target it is to construct.
--
-- The window is an /identity/, not a handle: the backend cannot reach the
-- window through it, and the main thread remains the only thread that can.
data TargetStart = TargetStart
  { startingTarget ∷ !AttachmentId
  , startingWindow ∷ !WindowId
  , startingIncarnation ∷ !Natural
  }
  deriving (Eq, Show)

-- | How a target's construction and its handoff settled.
--
-- The owner retains ownership of whatever a construction left behind until one
-- of exactly two things happens: the backend accepts the target, or the
-- backend verifies its own rollback. 'TargetPartial' is the first case with
-- less built than intended — the owner owns what exists, publishes nothing
-- usable, and must still retire it — and a construction that raises or is
-- cancelled is neither, so the owner keeps the target as unverified and
-- retires it too.
data TargetHandoff
  = TargetConstructed !TargetEvidence
  | TargetPartial !TargetEvidence
    -- ^ Construction did not complete and left resources the owner now owns.
  | TargetRolledBack !RollbackEvidence
    -- ^ Construction failed and the backend verified that nothing remains.
    -- Only this answer lets the owner certify the target's retirement facts
    -- without a retirement of its own.
  deriving (Eq, Show)

-- | What the owner knows about one target when it offers a step.
data TargetStepView = TargetStepView
  { viewTarget ∷ !AttachmentId
  , viewEligibility ∷ !RenderEligibility
  , viewGeometry ∷ !TargetGeometry
  , viewRevision ∷ !Natural
    -- ^ The observation revision this view was folded from, so a backend can
    -- tell a repeated view from a fresh one without comparing observations.
    -- Zero until the main thread has published one.
  , viewConstructed ∷ !Bool
    -- ^ Whether the backend's own construction accepted this target. A view
    -- for a partial or unverified target is offered so the backend can see it,
    -- never as a claim that it is usable.
  }
  deriving (Eq, Show)

-- | One bounded progress step's inputs.
data OwnerStep scene = OwnerStep
  { stepNow ∷ !Instant
  , stepScene ∷ scene
    -- ^ The latest scene any application thread published. It is a
    -- latest-value snapshot, so a stalled publisher leaves the owner the last
    -- coherent one rather than nothing.
  , stepSceneRevision ∷ !Natural
    -- ^ The revision of that scene's publication, so a backend can tell a
    -- newly published scene from the one it last rendered. Zero until an
    -- application thread has published one.
  , stepDemand ∷ !OwnerDemand
  , stepDemandRevision ∷ !Natural
    -- ^ The revision of the demand's publication: two publications of equal
    -- demand are two requests, which only the revision tells apart. Zero
    -- until the main thread has published any.
  , stepTargets ∷ ![TargetStepView]
  }

-- | What one bounded step reports.
--
-- The owner records this; it infers none of it. In particular it never decides
-- from a step's return value that anything retired.
data StepReport = StepReport
  { stepAdvanced ∷ !Bool
    -- ^ Whether this step did work. Status only.
  , stepImmediateWork ∷ !Bool
    -- ^ Whether further work is owed at once, so the owner takes another round
    -- without waiting.
  }
  deriving (Eq, Show)

-- | A step that did nothing and owes nothing.
noStepWork ∷ StepReport
noStepWork = StepReport False False

-- | The earliest absolute instant the backend next wants a round, or nothing.
data NextDeadline
  = NoOwnerDemand
  | OwnerDeadline !Instant
    -- ^ In the host clock's domain, which is the one domain every deadline in
    -- this lifetime belongs to.
  deriving (Eq, Show)

-- | What the owner tells its backend when it retires one target.
data TargetRetire = TargetRetire
  { retiringTarget ∷ !AttachmentId
  , retiringWindow ∷ !WindowId
  , retiringConstructed ∷ !Bool
    -- ^ Whether the backend's construction had accepted it. A partial or
    -- unverified target is retired too, and is told so here.
  }
  deriving (Eq, Show)

-- | Whether one target's retirement can be performed now.
--
-- A backend whose target holds obligations only later evidence can end — a
-- presentation whose present fence has not been observed yet — begins its
-- retirement by closing what it can, and answers 'RetirementOwed' until that
-- evidence has arrived: its retirement is then performed on a later round, and
-- nothing is certified meanwhile. It is scheduling, never evidence: an answer
-- of either kind retires nothing and certifies nothing, and only the
-- retirement operation's own record does.
data RetirementReadiness
  = RetirementReady
  | RetirementOwed !Text
    -- ^ Not yet, and why. The owner asks again at a later round — at the
    -- backend's own next deadline, or when its wake asks — and, in its exit
    -- drain, waits for that deadline between asking.
  deriving (Eq, Show)

-- | What the owner tells its backend when it retires itself.
data OwnerRetire = OwnerRetire
  { retiringStarted ∷ !Bool
    -- ^ Whether the injected startup ever returned. Whole-owner retirement is
    -- offered whatever the answer, because a startup that failed part-way may
    -- still have acquired shared state.
  , retiringUnverified ∷ ![AttachmentId]
    -- ^ Targets whose own retirement produced no evidence. Whole-owner
    -- retirement is independent of how many targets there ever were, and this
    -- names the ones it could not account for rather than hiding them.
  }
  deriving (Eq, Show)

-- | What the owner tells its backend when it destroys itself.
newtype OwnerDestroy = OwnerDestroy {destroyingRetired ∷ Bool}
  deriving (Eq, Show)

-- | The narrow, injected backend operation set.
--
-- Everything the owner can ask a backend to do is here, and nothing here
-- resembles a recording, submission, or resource API: there is no command
-- buffer, no queue, no allocation, and no handle. Nor is there any GLFW
-- capability — no session, window, surface, event pump, or window command —
-- because the owner makes no GLFW call at all.
--
-- Every operation returns /evidence/ rather than a value the owner interprets.
-- The owner records what came back; it never manufactures a record, and a
-- missing record is what "unverified" means everywhere in the owner.
data GraphicsOperations scene = GraphicsOperations
  { graphicsStartOwner ∷ OwnerStart → IO OwnerReady
    -- ^ Establish the owner's shared state. It runs on the owner thread,
    -- inside the owner's own protected retirement, before any target exists.
  , graphicsConstructTarget ∷ TargetStart → IO TargetHandoff
    -- ^ Construct one attachment's target and settle its handoff.
  , graphicsStep ∷ OwnerStep scene → IO StepReport
    -- ^ One bounded progress step. It must return finitely.
  , graphicsNextDeadline ∷ IO NextDeadline
    -- ^ The earliest absolute instant the backend next wants a round.
  , graphicsWake ∷ STM Bool
    -- ^ Whether something the backend watches, on another thread, asks for a
    -- round now — a failure its own worker recorded while the owner had no
    -- deadline, say. The waiting owner rereads it; it must stay 'False' once
    -- the round it asked for has answered it.
  , graphicsPrepareRetirement ∷ TargetRetire → IO RetirementReadiness
    -- ^ Begin retiring one target, and say whether its retirement can be
    -- performed now. The owner asks before every attempt, on every round until
    -- the answer is 'RetirementReady', and then retires the target once. It
    -- must return finitely. Raising is a failed retirement.
  , graphicsRetireTarget ∷ TargetRetire → IO TargetRetired
    -- ^ Retire one target. Returning is the evidence; raising is not.
  , graphicsRetireOwner ∷ OwnerRetire → IO OwnerRetired
  , graphicsDestroyOwner ∷ OwnerDestroy → IO OwnerDestroyed
    -- ^ Release the owner's shared state. Its evidence is the only thing that
    -- makes releasing the owner's borrowed parents safe.
  }
