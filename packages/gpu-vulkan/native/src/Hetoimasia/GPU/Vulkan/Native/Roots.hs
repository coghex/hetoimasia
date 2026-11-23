-- | The Vulkan roots of one graphics session: the instance, its explicit
-- debug messenger, the one shared device, and a record for every target
-- surface admitted to them.
--
-- This module owns their construction, admission and destruction order, and
-- nothing else. It makes no native call itself: every call goes through an
-- open native layer, 'RootOps', whose handle types are parameters. The
-- production layer is "Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan"; the
-- headless examples supply stand-ins that fail at a chosen step, and so drive
-- exactly the ownership decisions a native run obeys. It knows no window
-- system either: a surface arrives as its 64-bit handle and the action that
-- destroys it, from whoever created it.
--
-- = Ownership
--
-- * The instance, the explicit messenger, the device and the device's one
--   memory allocator belong to the roots, for the session. No target owns the device or gates its lifetime —
--   including the bootstrap target whose surface the device was selected
--   against — so closing the first-created window cannot release a device
--   another target is using (D-7, P-5).
-- * Each admitted target's surface belongs to the roots from admission until
--   'retireRootTarget' destroys it. A surface the roots refused
--   ('TargetRejection') or that an admission raised before taking is still
--   its creator's.
-- * Every handle is recorded in the same masked step that creates it, so no
--   failure and no cancellation delivered at that handoff can leave one
--   unowned; whatever exists is what retirement destroys.
--
-- = Order
--
-- Creation runs parent before child: the instance, the explicit messenger,
-- then the device — on the first admission, against that target's surface, or,
-- for a surface-free session, at its start ('startRootsDevice'), against no
-- surface at all — and right after the device, its memory allocator
-- ("Hetoimasia.GPU.Vulkan.Native.Allocator"), which every user of the device
-- shares. An allocator whose creation raised is absent, the device stays
-- recorded for retirement, and the failure is raised. Either way it is the session's one device: a surface
-- admitted after a surface-free start is checked against the queue family
-- already chosen, as any later target's is.
-- Destruction runs child before parent and is refused rather than reordered:
--
-- 1. every target's surface ('retireRootTarget');
-- 2. the allocator, and then the device ('retireRoots'), only once no target
--    record remains — which a session that never had a target satisfies from
--    the start — and the allocator only once every allocation made from it
--    has been freed ('AllocationsRemain'). What its destruction frees — the
--    empty blocks it still held — is released from the model's accounting
--    then, exactly once, and a release that disagrees with what was charged
--    fails the session;
-- 3. the explicit messenger, and then the instance ('destroyRoots'), only once
--    the device is gone. The messenger goes immediately before the instance,
--    so every child's destruction still reports somewhere, and the instance's
--    destruction is the last call that can invoke the capture's callback.
--
-- = Names
--
-- When the instance enabled @VK_EXT_debug_utils@ and the device offers its
-- naming call ('opsInstrumentation'), the roots name what they own once a
-- device exists to name it through ("Hetoimasia.GPU.Vulkan.Native.Naming"):
-- the device and its one queue where the device is created — at the first
-- admission, or at a surface-free start — and each target's
-- surface before the target is admitted, under the 'TargetId' the model is
-- about to issue it. A naming call runs on the
-- owner's thread like every other call here, and one that raised fails the
-- admission exactly as any other native failure there does: a surface whose
-- name could not be set is not admitted, so it is still its creator's, and the
-- roots' own names are attempted again at the next admission. Two roots are
-- never named. The instance: naming requires external synchronization of the
-- object named, and the surface bridge's lease lets the main thread use the
-- instance while the owner runs. The explicit messenger: the pinned loader
-- answers its own wrapper for it and forwards a naming call without
-- translating that wrapper, which MoltenVK then reads as one of its own objects
-- and crashes on (#250), so no naming call is ever made for it; its
-- diagnostics are the capture's, which names it nowhere. Without the extension
-- nothing is named and nothing fails.
--
-- A destruction that raised is uncertain: it is recorded, never attempted
-- again, and every parent that must outlive it is retained — a later step
-- answers 'RootsRetained' and destroys nothing. No timeout, cancellation or
-- cleanup failure is ever read as permission.
--
-- = Device loss
--
-- A native call the layer classifies as device loss ('opsDeviceLoss') latches
-- the loss, closes admission and fails the model's session in one
-- transaction, and then raises 'GraphicsDeviceLost' in its place, so the loss
-- is the failure its caller sees first. Nothing is recreated or replayed. The
-- retirement that follows is the ordinary child-before-parent one, and Vulkan
-- permits destroying a lost device's objects without waiting for work that may
-- never complete: what only the lost device could have discharged is released
-- by the frames' device-loss release, never completed. An outcome that is
-- unknown rather than lost is not loss: it is an uncertain destruction, and it
-- retains its parents.
--
-- = The terminal latch
--
-- The loss is one source of the session's terminal failure. The latch
-- ('latchTerminal') keeps the first failure from any source — the loss, a
-- validation error or sink failure a checkpoint learns from the diagnostic
-- watch, an uncertain effect, a failed cleanup, a required target's exhausted
-- recovery — as the primary, closes admission and fails the model's session
-- with it, and keeps every later failure, and what teardown retained, as
-- evidence beside it. The loss itself is kept apart from the primary, so a
-- later loss switches the teardown to its rules without displacing an earlier
-- failure. A checkpoint ('checkpointRoots', 'checkRoots') asks the watch and
-- answers the primary; retirement never passes through one.
--
-- = State
--
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | State            | Owner     | Readers and writers         | Thread     | Lifetime         | Reset or disposal         |
-- +==================+===========+=============================+============+==================+===========================+
-- | Each root's slot | The roots | Written by the operations   | Written on | 'newRoots' until | Only advances: absent,    |
-- |                  |           | below; any thread reads     | the owning | the session ends | live, then destroyed or   |
-- |                  |           |                             | thread     |                  | uncertain                 |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Target records   | The roots | Admission inserts;          | As above   | Admission until  | Removed only by a         |
-- |                  |           | retirement removes; recovery|            | destroyed        | destruction that returned |
-- |                  |           | releases and replaces a lost|            |                  |                           |
-- |                  |           | surface in place            |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Live allocations | The roots | The allocation protocol     | The owner  | The session      | Counts down as each       |
-- |                  |           | counts each allocation made |            |                  | allocation is freed       |
-- |                  |           | and freed; retirement reads |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The model        | The roots | Admission, retirement and   | As above   | The session      | Never reset               |
-- |                  |           | loss                        |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The loss latch   | The roots | Set once; any thread reads  | Any        | The session      | Never cleared             |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Disposers        | The roots | Each layer above registers  | The owner  | The session      | Never removed             |
-- |                  |           | its own as it is made; a    |            |                  |                           |
-- |                  |           | reclamation pass reads them |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The terminal     | The roots | 'latchTerminal' sets the    | Any, in    | The session      | Never cleared; evidence   |
-- | latch            |           | primary once and appends    | STM        |                  | bounded, the rest counted |
-- |                  |           | evidence; any thread reads  |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The diagnostic   | The roots | Installed once; every       | The owner  | The session      | —                         |
-- | watch            |           | checkpoint reads it         |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Owner claims     | The roots | A claiming attempt enters a | Any; not   | The session      | An attempt is dropped     |
-- |                  |           | weak token and writes it    | STM, so an |                  | once a collection finds   |
-- |                  |           | into its log; checkpoints   | abandoned  |                  | its token gone            |
-- |                  |           | and later claims read them  | claim stays|                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
--
-- Every mutating operation is meant for one serialized owner — the graphics
-- owner's thread — and none is safe to run concurrently with another.
module Hetoimasia.GPU.Vulkan.Native.Roots
  ( -- * The native layer
    RootOps (..)
  , GenerationOps (..)
  , SwapchainRequest (..)
  , NativeFailure (..)

    -- * The roots
  , Roots
  , newRoots
  , rootsSessionIdentity
  , rootsDeviceId

    -- * Startup
  , startRoots
  , startRootsResolving
  , RootsAlreadyStarted (..)
  , startRootsDevice
  , DeviceAlreadyStarted (..)

    -- * Targets
  , TargetSurface (..)
  , SurfaceDestruction (..)
  , admitRootTarget
  , retireRootTarget
  , releaseRootSurface
  , installRootSurface
  , rootSurfaceHeld
  , SurfaceStillHeld (..)
  , RootsNotStarted (..)
  , UnknownRootTarget (..)
  , SurfaceDestructionFailed (..)
  , TargetGenerationsRemain (..)

    -- * Device loss
  , GraphicsDeviceLost (..)
  , latchDeviceLoss
  , checkRoots

    -- * The terminal latch
  , TerminalCause (..)
  , TeardownEvidence (..)
  , TerminalReport (..)
  , GraphicsSessionFailed (..)
  , DiagnosticAlarm (..)
  , Checkpoint (..)
  , terminalEvidenceLimit
  , latchTerminal
  , noteTeardownEvidence
  , watchRootsDiagnostics
  , watchRootsDiagnosticsOrdered
  , DiagnosticWatch (..)
  , DiagnosticOrder (..)
  , DiagnosticArrivals (..)
  , noDiagnosticArrivals
  , checkpointRoots
  , syncRootsDiagnostics
  , checkpointRootsSettled
  , readRootsTerminal
  , rootsFailure
  , rootsFailedCause
  , terminalFailure

    -- * Retirement
  , retireRoots
  , destroyRoots
  , RootsRetained (..)
  , RootDestructionFailed (..)

    -- * Observation
  , RootStanding (..)
  , RootsView (..)
  , readRootsView
  , RootTargetView (..)
  , readRootTargets
  , readRootsModel
  , readRootsQuiesced
  , readRootsInstance

    -- * For the generations above the roots
  , readRootsDevice
  , readRootsAllocator
  , noteRootsAllocation
  , readRootsAllocations
  , readRootsInstrumentation
  , nameRootsObject
  , rootsGenerationOps
  , rootsNativeFailure
  , rootsCall
  , requestRootsRender
  , closeRootsTarget
  , failRootsSession
  , failRootsSessionBecause
  , FailedSubmission (..)
  , failSubmission
  , reclaimRoots
  , diagnosisOf
  , deliverAfterRecord

    -- * Reclamation (VK-14)
  ) where

-- The implementation is "Hetoimasia.GPU.Vulkan.Native.Internal.Roots", hidden in this package: it also registers the
-- layers' disposers ('SubjectDisposer'), which only this package's own layers may do, so nothing outside the package
-- can supply code that a reclamation runs.
import Hetoimasia.GPU.Vulkan.Native.Internal.Roots
