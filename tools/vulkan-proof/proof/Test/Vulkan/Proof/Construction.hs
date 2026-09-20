{-# LANGUAGE OverloadedRecordDot #-}

-- | The two composites the proof builds from several fallible native calls,
-- written once so that the native path and the headless examples run the same
-- sequence.
--
-- Both are the places issue #182 is about. A frame slot is two semaphores, two
-- fences, a command pool and a command buffer; the capture is a buffer, an
-- allocation bound to it, a submission, a readback and a present. Each was
-- previously a run of native calls with no owner until the last of them
-- returned, so a failure partway left the children already created outside the
-- cleanup stack, and the device release registered earlier then destroyed a
-- device that still had them.
--
-- What is parameterized here is only the native layer: the handle types are
-- open and the calls are supplied by the caller. The native path instantiates
-- them with Vulkan calls; "Test.Vulkan.Proof.ConstructionSpec" instantiates
-- them with stand-ins that can be made to fail at a chosen step, and then
-- exercises the same ownership mechanism, the same cleanup stack, and the same
-- release decision the native path obeys. Nothing in this module makes a
-- native call, waits, or decides what may be released.
module Test.Vulkan.Proof.Construction
  ( -- * A frame slot
    SlotOps (..)
  , SlotPlaces
  , SlotParts (..)
  , newSlotPlaces
  , slotPlaceReleases
  , fillSlot

    -- * The capture path
  , CaptureOps (..)
  , CapturePlaces
  , newCapturePlaces
  , capturePlaceReleases
  , runCapture
  ) where

import Data.Word (Word32)

import Test.Vulkan.Proof.Ownership (Held, holding, newHeld, releaseAll, releasing)
import Test.Vulkan.Proof.Retention (Handle (..), SlotName)

-- --------------------------------------------------------------------------
-- A frame slot

-- | The native layer one frame slot is built from.
--
-- The two semaphores share a type and a destructor, as do the two fences,
-- because the distinction between them is what they are used for rather than
-- what they are. The command buffer has no destructor at all: it is freed by
-- its command pool, which is what @vkDestroyCommandPool@ says, so a separate
-- owner for it would be a second release of an object already gone.
data SlotOps semaphore fence pool commands = SlotOps
  { createSlotSemaphore ∷ IO semaphore
  , destroySlotSemaphore ∷ semaphore → IO ()
  , createSlotFence ∷ IO fence
  , destroySlotFence ∷ fence → IO ()
  , createSlotPool ∷ IO pool
  , destroySlotPool ∷ pool → IO ()
  , allocateSlotCommands ∷ pool → IO commands
  }

-- | Where one slot's children live from the instant each exists.
--
-- The command buffer has no place because it has no owner of its own: it is
-- reached through the pool that allocated it and released with it.
data SlotPlaces semaphore fence pool = SlotPlaces
  { placeAcquireSemaphore ∷ Held semaphore
  , placePresentSemaphore ∷ Held semaphore
  , placeRenderFence ∷ Held fence
  , placePresentFence ∷ Held fence
  , placePool ∷ Held pool
  }

-- | One whole slot, once every one of its children exists.
data SlotParts semaphore fence pool commands = SlotParts
  { partAcquireSemaphore ∷ semaphore
  , partPresentSemaphore ∷ semaphore
  , partRenderFence ∷ fence
  , partPresentFence ∷ fence
  , partPool ∷ pool
  , partCommands ∷ commands
  }

newSlotPlaces ∷ IO (SlotPlaces semaphore fence pool)
newSlotPlaces =
  SlotPlaces <$> newHeld <*> newHeld <*> newHeld <*> newHeld <*> newHeld

-- | One slot's releases, in the order teardown reaches them.
--
-- Three rather than one, because they are owed different evidence. The command
-- pool, the rendering fence and the acquisition semaphore are queue objects,
-- and the device-idle boundary does establish that the device has finished
-- with them. The present fence and the presentation semaphore are not: a
-- present is work for the presentation engine, and only that fence says it is
-- done. The semaphore comes after its fence, which is the order
-- @VK_EXT_swapchain_maintenance1@ names.
--
-- Every one of them reads its place rather than a handle, so the same three
-- entries are registered before the first native call of the construction and
-- release exactly the children that exist when teardown reaches them. The
-- successful path is unchanged by that: the three entries, their order, and
-- the one record entry they belong to are what they always were.
slotPlaceReleases
  ∷ SlotOps semaphore fence pool commands
  → SlotName
  → SlotPlaces semaphore fence pool
  → [(Handle, IO ())]
slotPlaceReleases ops name places =
  [
    ( SlotWorkObjects name
    , releaseAll
        [ releasing places.placePool ops.destroySlotPool
        , releasing places.placeRenderFence ops.destroySlotFence
        , releasing places.placeAcquireSemaphore ops.destroySlotSemaphore
        ]
    )
  , (SlotPresentFence name, releasing places.placePresentFence ops.destroySlotFence)
  , (SlotPresentSemaphore name, releasing places.placePresentSemaphore ops.destroySlotSemaphore)
  ]

-- | Build one slot into its places, in the order the native path builds it.
--
-- Every step but the last hands its object to a place that is already owned,
-- so a failure at any of them — including every step of the second slot, whose
-- first slot is whole by then — releases exactly what exists and nothing else.
-- The last step allocates the command buffer from the pool, which is owned
-- already, so there is no moment at which an object exists unowned.
fillSlot
  ∷ SlotOps semaphore fence pool commands
  → SlotPlaces semaphore fence pool
  → IO (SlotParts semaphore fence pool commands)
fillSlot ops places = do
  acquire ← holding places.placeAcquireSemaphore ops.createSlotSemaphore
  present ← holding places.placePresentSemaphore ops.createSlotSemaphore
  renderFence ← holding places.placeRenderFence ops.createSlotFence
  presentFence ← holding places.placePresentFence ops.createSlotFence
  pool ← holding places.placePool ops.createSlotPool
  commands ← ops.allocateSlotCommands pool
  pure
    SlotParts
      { partAcquireSemaphore = acquire
      , partPresentSemaphore = present
      , partRenderFence = renderFence
      , partPresentFence = presentFence
      , partPool = pool
      , partCommands = commands
      }

-- --------------------------------------------------------------------------
-- The capture path

-- | The native layer the capture path is built from, in the order it runs
-- them.
--
-- Everything after the allocation is fallible too, and every one of those
-- steps used to sit between the buffer's creation and the only @vkFreeMemory@
-- and @vkDestroyBuffer@ the path had: a failed bind, acquisition, submission,
-- completion wait, readback or present left both live with no owner. They are
-- named here so each can be failed on its own.
data CaptureOps buffer memory image = CaptureOps
  { captureCreateBuffer ∷ IO buffer
  , captureDestroyBuffer ∷ buffer → IO ()
  , captureAllocateMemory ∷ buffer → IO memory
  , captureFreeMemory ∷ memory → IO ()
  , captureBindMemory ∷ buffer → memory → IO ()
  , captureAcquireImage ∷ IO image
  , captureRecordAndSubmit ∷ buffer → image → IO ()
  , captureAwaitSubmission ∷ IO ()
  , captureReadBack ∷ memory → IO [Word32]
  , capturePresent ∷ image → IO ()
  }

-- | Where the capture's two handles live from the instant each exists.
data CapturePlaces buffer memory = CapturePlaces
  { placeCaptureBuffer ∷ Held buffer
  , placeCaptureMemory ∷ Held memory
  }

newCapturePlaces ∷ IO (CapturePlaces buffer memory)
newCapturePlaces = CapturePlaces <$> newHeld <*> newHeld

-- | The capture's two releases, in the order teardown reaches them.
--
-- The memory first, which is the order the successful path frees them in and
-- the one @vkFreeMemory@ explicitly permits: an allocation may be freed while
-- a buffer bound to it is still alive, provided every submitted command that
-- referred to it has completed.
capturePlaceReleases
  ∷ CaptureOps buffer memory image
  → CapturePlaces buffer memory
  → [(Handle, IO ())]
capturePlaceReleases ops places =
  [ (TheCaptureMemory, releasing places.placeCaptureMemory ops.captureFreeMemory)
  , (TheCaptureBuffer, releasing places.placeCaptureBuffer ops.captureDestroyBuffer)
  ]

-- | Run the whole capture, and on the path that reaches the end free its two
-- handles exactly once, as it always did.
--
-- The releases here go through the same places the registered releases read,
-- so the two cannot both run: whichever reaches a place first takes the object
-- out of it. The caller recalls the registrations afterwards, which is what
-- keeps a whole run's teardown at the ten entries it has always had.
runCapture
  ∷ CaptureOps buffer memory image
  → CapturePlaces buffer memory
  → IO [Word32]
runCapture ops places = do
  buffer ← holding places.placeCaptureBuffer ops.captureCreateBuffer
  memory ← holding places.placeCaptureMemory (ops.captureAllocateMemory buffer)
  ops.captureBindMemory buffer memory
  image ← ops.captureAcquireImage
  ops.captureRecordAndSubmit buffer image
  ops.captureAwaitSubmission
  observed ← ops.captureReadBack memory
  ops.capturePresent image
  releasing places.placeCaptureMemory ops.captureFreeMemory
  releasing places.placeCaptureBuffer ops.captureDestroyBuffer
  pure observed
