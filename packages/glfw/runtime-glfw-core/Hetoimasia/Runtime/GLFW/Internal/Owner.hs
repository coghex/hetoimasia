-- | The supervised graphics owner: one foundation worker that owns the
-- rendering backend's targets and shared state, beside a protected window host
-- that keeps every GLFW call on the process main thread.
--
-- It is the machinery D-32 asks for and nothing more: worker ownership,
-- explicit bounded handoffs, cancellation and retirement. The backend
-- operations are injected as 'GraphicsOperations', so this package gains no
-- GPU dependency and VK-7 supplies Vulkan operations to this same
-- implementation rather than replacing it.
--
-- = What the owner is, and is not
--
-- It is a 'Hetoimasia.Foundation.Worker.WorkerDefinition' started into a
-- worker group this component owns — separate from the application's ordinary
-- worker group and from the diagnostics worker — so ordinary worker drain does
-- not end it and no automatic join can run before the main thread has
-- serviced retirement.
--
-- It performs __no GLFW operation__. It enters no session, creates no window
-- and no surface, processes no event, and issues no window command: all of
-- those stay on the main thread, and a platform modal loop there still stalls
-- them. The one thing it reaches across is the session's existing cross-thread
-- wake, through 'publishCompletion' and 'wakeGraphicsHost', exactly as any
-- other publishing thread does. That wake is authorized publication, not an
-- owner GLFW operation, and the examples assert the difference.
--
-- = Where each part lives
--
-- This module is the composition the facade and the examples import; it
-- defines nothing. Every part is a private module beneath it, with its own
-- thread and state owner named in its header:
--
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Operations" and
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Config": the injected backend
--   contract and what one owner is built from. Values only.
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff": the bounded cross-thread
--   publications, in both directions.
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.State",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Custody",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Observation" and
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Wake": the one owner handle, its
--   custody ledger, read-only views of it, and the authorized wake.
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.Worker",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Targets",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Terminal",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Latch" and
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Drain": worker progress, on the
--   owner thread. None of them imports the handover or the lifetime.
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.Handover",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Release",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Protocol",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded" and
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Reservation": the client-side
--   attachment path, on the main thread.
-- * "Hetoimasia.Runtime.GLFW.Internal.Owner.Start",
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Lifetime" and
--   "Hetoimasia.Runtime.GLFW.Internal.Owner.Exit": starting the owner, its
--   composition with the protected host, and the exit. The exit order, which
--   is D-33's, is documented in the lifetime module.
--
-- = What is never permission
--
-- The owner's completion is not evidence. Neither is an empty target set, a
-- cancellation, a timeout, or a cleanup failure. A target is released only
-- against the terminal record its own injected retirement returned, and the
-- owner's borrowed parents are released only against the injected whole-owner
-- destruction's. An owner that ends without the second answers
-- 'OwnerDestructionUnverified', which retains that fact and authorizes
-- nothing — never a disposal, and never a replay of the work that failed.
module Hetoimasia.Runtime.GLFW.Internal.Owner
  ( -- * The injected backend operations
    GraphicsOperations (..)
  , OwnerStart (..)
  , OwnerReady
  , ownerReady
  , TargetStart (..)
  , TargetHandoff (..)
  , TargetEvidence
  , targetEvidence
  , RollbackEvidence
  , rollbackEvidence
  , OwnerStep (..)
  , TargetStepView (..)
  , StepReport (..)
  , noStepWork
  , NextDeadline (..)
  , TargetRetire (..)
  , RetirementReadiness (..)
  , TargetRetired
  , targetRetired
  , OwnerRetire (..)
  , OwnerRetired
  , ownerRetired
  , OwnerDestroy (..)
  , OwnerDestroyed
  , ownerDestroyed
  , HasEvidence (..)

    -- * Configuration
  , GraphicsOwnerConfig (..)
  , graphicsOwnerConfig
  , OwnerTimer
  , ownerTimer
  , realtimeOwnerTimer
  , graphicsOwnerComponent

    -- * The owner
  , GraphicsOwner
  , ownerHandoff
  , graphicsOwnerWorker
  , readOwnerStatusNow
  , readOwnerTerminalNow
  , readTargetTerminalsNow
  , readOwnerGeometry
  , readOwnerFailure
  , readOwnerFailures
  , retainedFailureBound
  , readOwnerTargets
  , readOwnerAcknowledged
  , Stage (..)
  , custodyOf
  , readOwnerCustody
  , TargetStanding (..)
  , readTargetStanding
  , ownerTargetAcknowledgement
  , awaitOwnerRound
  , readOwnerDemandTaken
  , wakeGraphicsHost

    -- * The additive protected-host constructor
  , withGraphicsOwnerHost
  , withGraphicsOwnerHostIn
  , withGraphicsOwnerHostWith
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner

    -- * Handing targets over, and taking them back
  , GraphicsHandover (..)
  , handOverGraphicsTarget
  , announceGraphicsTarget
  , graphicsTargetProtocol
  , releaseGraphicsTarget
  , ReleaseAnswer (..)
  , publishGraphicsObservation

    -- * Independent whole-owner evidence
  , publishOwnerRetirement
  , publishOwnerDestruction

    -- * Failures
  , OwnerDestructionUnverified (..)
  , OwnerHostUnprotected (..)
  , OwnerHandleMissing (..)
  , OwnerHandoverUnsettled (..)
  ) where

import Hetoimasia.Runtime.GLFW.Internal.Owner.Config
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (custodyOf, readOwnerCustody)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence
import Hetoimasia.Runtime.GLFW.Internal.Owner.Exit
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handover
import Hetoimasia.Runtime.GLFW.Internal.Owner.Lifetime
import Hetoimasia.Runtime.GLFW.Internal.Owner.Observation
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
import Hetoimasia.Runtime.GLFW.Internal.Owner.Protocol
import Hetoimasia.Runtime.GLFW.Internal.Owner.Release
import Hetoimasia.Runtime.GLFW.Internal.Owner.Start
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner, Stage (..), TargetStanding (..), retainedFailureBound)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Wake
