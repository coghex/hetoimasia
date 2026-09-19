-- | The identities the GPU retention model issues, and the misuse it answers.
--
-- Every identity is abstract here: this module exports the types and their
-- accessors, never their constructors. A client cannot build one, so a value it
-- holds was issued by some model, and the model it is handed to can decide
-- whether that model was this one. The three answers — foreign, unknown, stale —
-- are kept apart because they are different mistakes.
--
-- The one exception is 'SessionIdentity', which the owning boundary supplies
-- from a 'Data.Unique.Unique' it created for that session alone. That premise
-- is the boundary's to establish; everything else follows from it.
--
-- See @docs/gpu_model.md@ for the same contract in prose.
module Hetoimasia.GPU.Model.Identity
  ( -- * The session premise
    SessionIdentity
  , sessionIdentity

    -- * Issued identities
  , DeviceId
  , deviceSession
  , TargetId
  , targetSession
  , targetNumber
  , targetIncarnation
  , GenerationId
  , generationTarget
  , generationNumber
  , ImageId
  , imageGeneration
  , imageIndex
  , FrameSlotId
  , frameTarget
  , frameSlotNumber
  , frameUse
  , BatchId
  , batchTarget
  , batchNumber
  , SubmissionId
  , submissionSession
  , submissionNumber
  , PresentationId
  , presentationTarget
  , presentationNumber
  , ResourceId
  , resourceSession
  , resourceNumber
  , resourceGeneration
  , AllocationId
  , allocationSession
  , allocationNumber

    -- * Classification and subjects
  , TargetClass (..)
  , HoldSubject (..)

    -- * Misuse
  , IdentityKind (..)
  , Misuse (..)
  ) where

import Hetoimasia.GPU.Model.Internal.Identity
