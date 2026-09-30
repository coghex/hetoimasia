-- | The swapchain generations of every target the roots admitted: their
-- planning, construction, replacement and destruction (VK-10).
--
-- Each generation is keyed by the GPU model's 'GenerationId', and each of its
-- images by that identity and its index. The model decides what a generation
-- owes and when it may go; this module makes the native calls, through the
-- roots' open native layer ('GenerationOps'), and records each one's result in
-- the same masked step that made it. It runs on the graphics owner's thread:
-- 'stepGenerations', 'retireTargetGenerations' and 'trackTarget' are the
-- owner's. A consumer on any thread may hold a generation's CPU use
-- ('useGeneration') and report what a swapchain call answered
-- ('noteSwapchainResult'), both in 'STM'.
--
-- = Planning
--
-- A generation is planned from what the surface reports and the target's last
-- published geometry ("Hetoimasia.GPU.Vulkan.Native.Presentation"): P-15's
-- first profile, D-30's extent, and an image count reserved against the
-- configured tracking limit. The count the driver returns is checked against
-- that limit before any image view — any array that depends on it — is built;
-- a count of zero or above the limit is refused, and the candidate is retired
-- rather than published. A surface that cannot serve the profile leaves the
-- target 'PresentationUnsupported', naming the whole gap.
--
-- = Replacement
--
-- A target is rebuilt when its geometry moves, or when a swapchain call on its
-- active generation answered out of date or suboptimal. Ordinary resize is not
-- a failed construction: the extent the plan would choose is watched, and the
-- generation is rebuilt only once it has been the same for 'settlingPeriod' on
-- the owner's monotonic clock. A zero or otherwise unusable extent suspends the
-- target and creates no attempt. An out-of-date or suboptimal result whose plan
-- is the extent the active generation already has is not a resize: rebuilding
-- it is a recovery attempt, admitted by the model's episode — at most three,
-- 100 ms and then 500 ms apart — and exhausting it is reported through the
-- target's required or optional designation. So is every construction after one
-- that failed.
--
-- Replacement hands the active generation over as @oldSwapchain@. The model
-- retires it, and this module marks it retired, before the native call, and
-- nothing undoes that: a creation that then fails leaves the target without an
-- active generation, in 'ConstructionFailed', and nothing is ever acquired from
-- or handed over as the retired one again. The next construction is a fresh
-- one, begun only once every swapchain of the target that Vulkan still counts
-- as unretired has been destroyed, and it never replays the failed call.
--
-- = Bounds
--
-- A target holds at most the model's generation limit — active, constructing
-- and retired together. At capacity, every retired generation whose holds have
-- ended is destroyed first, and the newest geometry is coalesced into the one
-- replacement that follows. A replacement that still cannot fit leaves the
-- target 'Backpressured': it is suspended in the model, and the owner and every
-- other target carry on. With a limit of one, the active generation is the only
-- thing that can be in the way, so it is retired on its own, awaited, destroyed,
-- and a fresh generation built without it. No target reserves or releases
-- anything of another's.
--
-- = Names
--
-- When the roots offer naming ('readRootsInstrumentation'), a construction
-- names its swapchain, each of its images and each of its views from the
-- candidate's 'GenerationId' and the image's index
-- ("Hetoimasia.GPU.Vulkan.Native.Naming"), each immediately after the call that
-- produced it and before the generation is published, so nothing can record
-- against an unnamed image. A naming call that raised fails the construction
-- as any other of its native calls does: the candidate is retired, never
-- published, and destroyed once its holds end.
--
-- = Destruction
--
-- A retired generation keeps its swapchain, its images and its views until the
-- model reports every hold on it ended. Only then are its views destroyed, in
-- reverse order of creation, and then its swapchain — whose images go with it,
-- as they are the swapchain's and never destroyed on their own. The per-target
-- presentation pool is not a generation's and is untouched. A destruction that
-- raised is uncertain: the generation is marked so, never offered again, and
-- everything above it is retained, because the model's session fails with
-- 'CleanupFailed', and the roots close admission, and the step raises
-- 'GenerationDestructionFailed'. An effect whose bookkeeping could not be
-- committed enters the same path ('GenerationEffectUncertain'), and so does a
-- creation a cancellation interrupted inside its call: whether it created
-- anything is unknown, so its candidate is retained, never destroyed, and the
-- cancellation is delivered after the session has failed.
--
-- = A lost surface
--
-- A swapchain call that reported the surface lost ('SwapchainSurfaceLost'), or
-- a capability query or a swapchain's creation that raised it, retires the
-- active generation; nothing is built on the surface again ('SurfaceLost').
-- Once every generation of the target has been destroyed, the step destroys the
-- lost surface through the roots, keeping the target, and asks the model's
-- episode for an attempt: an admitted one leaves the target
-- 'SurfaceReplacing' and is answered by 'stepGenerations'
-- ('summarySurfacesWanted'). A replacement created on the same window is
-- offered with 'offerReplacementSurface': installed once the session's one
-- queue family can present to it, when a fresh generation is built on it, or
-- refused — a surface the device cannot present to disposes of the target
-- through its designation. 'replacementSurfaceFailed' reports one that was not
-- made. A swapchain or view creation that ran out of memory created nothing,
-- and is recovered once, as an allocation (VK-14).
--
-- = Close
--
-- Close wins: a target the model has closed begins no construction, admits no
-- recovery attempt, and a construction that completes after the close is
-- retired rather than published. 'retireTargetGenerations' retires the active
-- generation, destroys every generation whose holds have ended, and raises
-- 'GenerationsRetained' — manufacturing no evidence — if any remains.
--
-- = Implementation
--
-- This module is the entry point and holds no code of its own: it re-exports,
-- with unchanged names, signatures and constructor visibility, what eight
-- private modules under @Hetoimasia.GPU.Vulkan.Native.Internal.Generations@
-- implement (#266, and VK-14's @Surface@). Clients cannot import them; each one's Haddock states its
-- responsibility and what state it owns.
--
-- +------------------+------------------------------------------------+------------------------------------+
-- | Module           | Responsibility                                 | Depends on                         |
-- +==================+================================================+====================================+
-- | @State@          | 'Generations' and its target and generation    | —                                  |
-- |                  | records, the conditions and standings, the     |                                    |
-- |                  | constructors, 'trackTarget', the failures and  |                                    |
-- |                  | the helpers every other module shares          |                                    |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Uses@           | 'noteSwapchainResult', 'withdrawGeneration'    | @State@                            |
-- |                  | and CPU uses, in 'STM'                         |                                    |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Disposal@       | Making the generations, with their disposer;   | @State@                            |
-- |                  | destroying generations whose holds ended, child|                                    |
-- |                  | before parent, and the model's progress turn   |                                    |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Reconciliation@ | One target's planning, settling, recovery,     | @State@, @Disposal@                |
-- |                  | capacity, construction and publication         |                                    |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Step@           | 'stepGenerations' and 'generationsDeadline'    | @State@, @Disposal@,               |
-- |                  |                                                | @Reconciliation@, @Surface@        |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Surface@        | Releasing a lost surface and asking for, taking| @State@                            |
-- |                  | or refusing its replacement                    |                                    |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Retirement@     | 'retireTargetGenerations'                      | @State@, @Disposal@                |
-- +------------------+------------------------------------------------+------------------------------------+
-- | @Observation@    | 'readTargetGenerations' and its views          | @State@                            |
-- +------------------+------------------------------------------------+------------------------------------+
--
-- = State
--
-- The generations' state is one map the 'Generations' holds, from each tracked
-- target to its record, and each record's map of its generations. Module names
-- are relative to @Hetoimasia.GPU.Vulkan.Native.Internal.Generations@.
--
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | State              | Owner          | Readers and writers            | Thread | Lifetime            | Reset or disposal           |
-- +====================+================+================================+========+=====================+=============================+
-- | Target records     | @State@, which | @State@'s 'trackTarget'        | Owner  | Admission until the | Removed once every          |
-- |                    | creates the    | inserts; @Reconciliation@      |        | target's generations| generation is destroyed     |
-- |                    | map            | advances; @Retirement@ closes  |        | have gone           |                             |
-- |                    |                | and removes; @Step@ and        |        |                     |                             |
-- |                    |                | @Observation@ read             |        |                     |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Generation records | @State@, which | @Reconciliation@ inserts and   | Owner  | 'beginGeneration'   | Removed by a destruction    |
-- |                    | defines them   | advances; @Retirement@ retires | (uses: | until destroyed     | that returned; kept         |
-- |                    |                | the active one; @Disposal@     | any)   |                     | uncertain otherwise         |
-- |                    |                | destroys and removes; any      |        |                     |                             |
-- |                    |                | thread holds and ends uses     |        |                     |                             |
-- |                    |                | through @Uses@, in 'STM'       |        |                     |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Swapchain results  | @State@, which | Any thread notes through       | Any    | Until the active    | Cleared by the publication  |
-- |                    | defines them   | @Uses@; @Reconciliation@       |        | generation is       | that replaces it            |
-- |                    |                | consumes                       |        | replaced            |                             |
-- +--------------------+----------------+--------------------------------+--------+---------------------+-----------------------------+
--
-- A 'GenerationUse''s ended flag belongs to its holder, and a construction's
-- note of the creation call in progress to that one construction. No other
-- state exists: no module keeps a registry, a worker or a ledger of its own.
module Hetoimasia.GPU.Vulkan.Native.Generations
  ( -- * The generations
    Generations
  , newGenerations
  , newGenerationsCapturing
  , newGenerationsHooked
  , settlingPeriod
  , trackTarget

    -- * The owner's step
  , stepGenerations
  , StepSummary (..)
  , generationsDeadline

    -- * Reports from swapchain calls
  , SwapchainResult (..)
  , noteSwapchainResult
  , withdrawGeneration

    -- * CPU use
  , GenerationUse
  , UseRefusal (..)
  , useGeneration
  , endGenerationUse

    -- * Recovering a lost surface (VK-14)
  , ReplacementAnswer (..)
  , offerReplacementSurface
  , replacementSurfaceFailed

    -- * Retirement
  , retireTargetGenerations

    -- * Observation
  , TargetCondition (..)
  , GenerationStanding (..)
  , GenerationView (..)
  , TargetGenerationsView (..)
  , readTargetGenerations

    -- * Failures
  , GenerationDestructionFailed (..)
  , GenerationEffectUncertain (..)
  , GenerationsRetained (..)
  , AllocationNotRecovered (..)
  , RecoveryEnd (..)
  ) where

import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (AllocationNotRecovered (..), RecoveryEnd (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Observation
  ( GenerationView (..)
  , TargetGenerationsView (..)
  , readTargetGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Retirement (retireTargetGenerations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationDestructionFailed (..)
  , GenerationEffectUncertain (..)
  , GenerationStanding (..)
  , Generations
  , GenerationsRetained (..)
  , SwapchainResult (..)
  , TargetCondition (..)
  , settlingPeriod
  , trackTarget
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal
  ( newGenerations
  , newGenerationsCapturing
  , newGenerationsHooked
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Surface
  ( ReplacementAnswer (..)
  , offerReplacementSurface
  , replacementSurfaceFailed
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Step
  ( StepSummary (..)
  , generationsDeadline
  , stepGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Uses
  ( GenerationUse
  , UseRefusal (..)
  , endGenerationUse
  , noteSwapchainResult
  , useGeneration
  , withdrawGeneration
  )
