-- | Uploads (GRS-6; resource services design D-9, D-11, D-20, D-21, D-30):
-- bytes reach a fresh managed texture, vertex buffer or index buffer through
-- one bounded, engine-owned staging buffer, with completion reported and
-- cancellation handled.
--
-- Any thread admits an upload ('submitUpload'): admission validates it,
-- reserves its target, a place in the bounded queue and a region of the
-- staging buffer, and copies the caller's bytes into that region before it
-- returns, so they are free once it has. A full queue or staging buffer is
-- 'UploadBackpressure', answered at once; an upload larger than the whole
-- staging buffer is 'UploadOversized', a distinct, permanent refusal. Its
-- 'UploadTicket' reports where it stands without a native call, and is waited
-- on explicitly, with a deadline ('awaitUploadTicket').
--
-- The graphics owner progresses uploads in its own turns ('progressUploads'),
-- recording each one's copies into frame-less batches in chunks — whole block
-- rows of one mip level, or byte ranges of a buffer — up to the configured
-- per-turn byte budget, and completes it only on its final chunk's observed
-- completion. Until then its target rests in its transfer-destination use and
-- no other batch may use it. The upload's own module,
-- "Hetoimasia.GPU.Vulkan.Native.Internal.Uploads", documents each step and
-- the state it owns; @docs/gpu_backend.md@ states the contract.
module Hetoimasia.GPU.Vulkan.Native.Uploads
  ( -- * Configuration
    UploadConfig
  , uploadStagingBytes
  , uploadTurnBudget
  , uploadQueueCapacity
  , UploadConfigRefused (..)
  , validateUploadConfig

    -- * The uploads
  , Uploads
  , newUploads
  , uploadsSupportBC7

    -- * Admission
  , UploadRequest (..)
  , UploadRefusal (..)
  , UploadPressure (..)
  , submitUpload
  , submitUploadGated

    -- * Tickets
  , UploadTicket
  , ticketUpload
  , UploadState (..)
  , readUploadTicket
  , awaitUploadTicket
  , CancelRefusal (..)
  , cancelUpload

    -- * Progress
  , UploadProgress (..)
  , progressUploads
  , uploadsWaiting
  , closeUploads
  , retireUploads

    -- * Observation
  , UploadPhase (..)
  , UploadView (..)
  , UploadsView (..)
  , readUploads
  ) where

import Hetoimasia.GPU.Vulkan.Native.Internal.Uploads
