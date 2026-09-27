-- | Frame acquisition, submission, presentation and safe abandonment above the
-- recording (VK-12 and VK-13): P-1's scheduling vocabulary — try to acquire,
-- submit, present, skip, and advance — and P-2's frame ownership table, with
-- D-23's abandonment of unsubmitted frames and D-9's presentation retirement.
--
-- A renderer holds an 'OwnedFrame' from 'tryAcquireFrame', records a batch
-- for it through "Hetoimasia.GPU.Vulkan.Native.Recording", and either submits
-- that batch ('submitFrames') or skips the frame ('skipFrame'). A submitted
-- frame is presented ('presentFrame'), or, if it never will be, closed
-- ('closeUnpresentedFrame'). 'progressFrames' is the graphics owner's bounded
-- step that observes completion and presentation retirement and finishes
-- abandonment; 'awaitFrames' is the same step after a finite drain wait. Every native call goes through an open
-- native layer, 'FrameOps', whose production form is
-- "Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan"; the headless examples supply a
-- stand-in. Every operation belongs to the thread that owns the recording —
-- the graphics owner's — and any other is refused with 'RefusedNotOwner'.
--
-- = Ownership
--
-- The model ("Hetoimasia.GPU.Model") decides what every frame owes and when it
-- may go; this module makes the native calls and supplies the model the facts
-- it observes, and never anything else. Each frame slot owns three
-- synchronization objects, made together the first time the slot is reserved
-- and before any acquisition, so an acquired frame always has what abandoning
-- it needs, whatever the budgets say by then: an acquisition semaphore, the
-- fence of a native submission it leads, and the fence of its cleanup
-- submissions. Each target owns a presentation pool (P-2): records of a
-- render-finished semaphore — which a frame's rendering signals and its
-- presentation, or its cleanup, waits on — and a present fence, bounded by the
-- model's derived pool capacity. A free record is bound to each frame when it
-- is reserved, before its acquisition, so presenting never makes, waits for
-- or is refused one; a record is recycled only once the model has let go of
-- the one it served, after its present fence signalled or after the explicit
-- settlement of a frame that was never presented.
--
-- = The protected handoff
--
-- Each native effect and the bookkeeping of its result are one masked step:
-- a cancellation can land only before the call or after its result has been
-- recorded, in the model and here, and it is then delivered unchanged. No
-- consumer code runs inside one, and none is ever run again: recording is
-- 'Hetoimasia.GPU.Vulkan.Native.Recording.recordFrame''s, which runs its
-- consumer once. A result whose bookkeeping cannot be committed is never
-- rolled back as though the call did nothing: the frames concerned enter an
-- uncertain state that retains them for ever, admission closes, and the
-- session fails.
--
-- = Acquisition
--
-- 'tryAcquireFrame' reserves the frame in the model — its slot, the
-- presentation-pool record and the submission record it may need — before any
-- native call, then acquires with a zero timeout. A successful acquisition,
-- suboptimal included, keeps its index; a suboptimal one requests a
-- replacement beside it. Not ready and a timeout give the reservation back
-- whole with no synchronization obligation; out of date gives it back and
-- requests the target's replacement from the generations. A foreign or stale
-- target is misuse, never pending.
--
-- = Submission
--
-- 'submitFrames' validates and reserves the whole request before any native
-- call, refusing a duplicate batch or one already consumed. It resets one
-- fence only immediately before the one native submission it is passed to,
-- submits the sealed batches in the caller's order on the session's one
-- graphics queue, and records one completion obligation every frame of the
-- request shares. Separate calls are separate submissions that settle
-- independently. A specified no-effect failure leaves nothing pending, and the
-- reset fence is never waited on; any other failure's effect is unknown.
--
-- = Abandonment
--
-- 'skipFrame' consumes an acquired, unsubmitted frame's capability,
-- invalidates its recording, and makes a cleanup submission that waits on its
-- acquisition semaphore with the slot's cleanup fence; the image goes back
-- through @vkReleaseSwapchainImagesEXT@ once that fence has signalled. It
-- neither rebuilds the swapchain nor makes the target unavailable. A frame
-- whose rendering was submitted but never presented awaits its actual
-- rendering completion, then a cleanup submission settles its render-finished
-- semaphore and, once that has completed, the image goes back. Neither
-- pretends to be the other. A cleanup submission or release that raised
-- retains the frame, its image and its synchronization, fails the session,
-- and raises 'FrameCleanupFailed'; nothing reusable is fabricated.
--
-- = Presentation
--
-- 'presentFrame' presents one submitted frame's image to the swapchain it was
-- acquired from, on the session's one graphics queue, waiting on its pool
-- record's render-finished semaphore, with the record's present fence reset
-- immediately before and chained through @VK_EXT_swapchain_maintenance1@. Its
-- rendering need not have completed. What the presentation engine answered is
-- read per swapchain from @pResults@ ('classifyPresent'): success and
-- suboptimal, and out of date and surface lost, were enqueued — the last three
-- request the target's replacement without resetting the frame's
-- synchronization — while out of memory enqueued nothing and no present
-- fence, leaving the frame submitted. An answer that cannot be read is an
-- uncertain effect. Targets present independently: a presentation delayed or
-- never made keeps its frame's obligations and its pool record, and nothing
-- else.
--
-- = Completion
--
-- Only a fence a queue operation made pending is ever asked whether it has
-- signalled, and it is asked without waiting, in 'progressFrames'. A signalled
-- submission fence is the model's completion fact for that submission; a
-- signalled present fence is the retirement fact for that presentation, and
-- the only one: a signalled render fence frees no presentation object; a
-- signalled cleanup fence, followed by a release that returned, is the frame's
-- settlement fact. Nothing else — elapsed time, a returned call, a
-- cancellation, what a fence answered before — ever becomes any of them.
-- 'awaitFrames' may first wait a finite time for one pending fence; the wait
-- is not evidence, and a timeout changes nothing.
--
-- = State
--
-- The frames' state is five maps the 'Frames' holds. Module names are
-- relative to @Hetoimasia.GPU.Vulkan.Native.Internal.Frames@, the package's
-- private implementation of this module, which clients cannot import.
--
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
-- | State                  | Owner        | Readers and writers                   | Thread | Lifetime                    | Reset or disposal           |
-- +========================+==============+=======================================+========+=============================+=============================+
-- | Slot synchronization   | @State@,     | @Acquisition@ creates a slot's and    | Owner  | The slot's first            | Destroyed by                |
-- |                        | which        | marks its acquisition; @Submission@,  |        | reservation until the       | 'retireTargetFrames' once   |
-- |                        | creates the  | @Abandonment@ and @Progress@ advance  |        | target's frames retire      | idle; kept, explicitly      |
-- |                        | map          | each object's state; @Progress@       |        |                             | uncertain, otherwise        |
-- |                        |              | removes                               |        |                             |                             |
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
-- | Presentation pool      | @State@      | @Acquisition@ creates a record and    | Owner  | The first reservation that  | Destroyed by                |
-- |                        |              | binds it to a frame; @Submission@,    |        | needs it until the target's | 'retireTargetFrames' once   |
-- |                        |              | @Presentation@, @Abandonment@ and     |        | frames retire               | free and idle; kept,        |
-- |                        |              | @Progress@ advance it; @Presentation@ |        |                             | explicitly uncertain,       |
-- |                        |              | rebinds it to its presentation;       |        |                             | otherwise                   |
-- |                        |              | @Progress@ frees and removes it       |        |                             |                             |
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
-- | Frame records          | @State@      | @Acquisition@ inserts; @Submission@,  | Owner  | Acquisition until presented | Removed by the presentation |
-- |                        |              | @Abandonment@ and @Progress@ advance; |        | or settled                  | or the settlement the model |
-- |                        |              | @Presentation@ and @Progress@ remove  |        |                             | recorded; kept failed or    |
-- |                        |              |                                       |        |                             | uncertain                   |
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
-- | Submission records     | @State@      | @Submission@ inserts; @Progress@      | Owner  | The native submission until | Removed once its fence      |
-- |                        |              | removes                               |        | its fence signalled         | signalled                   |
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
-- | Presentation records   | @State@      | @Presentation@ inserts; @Progress@    | Owner  | The enqueued presentation   | Removed once its present    |
-- |                        |              | removes                               |        | until its present fence     | fence signalled; kept,      |
-- |                        |              |                                       |        | signalled                   | uncertain, when asking it   |
-- |                        |              |                                       |        |                             | raised                      |
-- +------------------------+--------------+---------------------------------------+--------+-----------------------------+-----------------------------+
--
-- @Layer@ is the native layer's shape and holds no state. No other state
-- exists: no module keeps a registry, a worker or a ledger of its own.
module Hetoimasia.GPU.Vulkan.Native.Frames
  ( -- * The native layer
    FrameOps (..)
  , AcquireResult (..)
  , WaitStage (..)
  , SubmitBatch (..)
  , PresentRequest (..)
  , PresentStatus (..)

    -- * The frames
  , Frames
  , newFrames

    -- * Acquisition
  , tryAcquireFrame
  , Acquisition (..)
  , OwnedFrame (..)
  , PendingReason (..)

    -- * Submission
  , submitFrames
  , Submitted (..)

    -- * Presentation
  , presentFrame
  , Presented (..)
  , PresentReading (..)
  , classifyPresent

    -- * Abandonment
  , skipFrame
  , closeUnpresentedFrame
  , closeTargetFrames

    -- * Progress and retirement
  , progressFrames
  , awaitFrames
  , drainWaitLimit
  , Progress (..)
  , retireTargetFrames

    -- * Observation
  , FrameStage (..)
  , FrameStanding (..)
  , readFrameStandings
  , FenceState (..)
  , SemaphoreState (..)
  , SlotSync (..)
  , SlotView (..)
  , readSlots
  , readOutstandingSubmissions
  , PoolHolder (..)
  , PoolSync (..)
  , PoolView (..)
  , readPool
  , PresentStanding (..)
  , PresentationStanding (..)
  , readPresentations

    -- * Failures
  , FrameEffectUncertain (..)
  , FrameCleanupFailed (..)
  , FramesRetained (..)
  , PresentationUncertain (..)
  ) where

import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Abandonment
  ( closeTargetFrames
  , closeUnpresentedFrame
  , skipFrame
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Acquisition (tryAcquireFrame)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer
  ( AcquireResult (..)
  , FrameOps (..)
  , PresentRequest (..)
  , PresentStatus (..)
  , SubmitBatch (..)
  , WaitStage (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Presentation (PresentReading (..), classifyPresent, presentFrame)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Progress (awaitFrames, drainWaitLimit, progressFrames, retireTargetFrames)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
  ( Acquisition (..)
  , FenceState (..)
  , FrameCleanupFailed (..)
  , FrameEffectUncertain (..)
  , FrameStage (..)
  , FrameStanding (..)
  , Frames
  , FramesRetained (..)
  , OwnedFrame (..)
  , PendingReason (..)
  , PoolHolder (..)
  , PoolSync (..)
  , PoolView (..)
  , PresentStanding (..)
  , Presented (..)
  , PresentationStanding (..)
  , PresentationUncertain (..)
  , Progress (..)
  , SemaphoreState (..)
  , SlotSync (..)
  , SlotView (..)
  , Submitted (..)
  , newFrames
  , readFrameStandings
  , readOutstandingSubmissions
  , readPool
  , readPresentations
  , readSlots
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Submission (submitFrames)
