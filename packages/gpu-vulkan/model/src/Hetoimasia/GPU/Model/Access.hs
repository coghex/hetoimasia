-- | The ordering rules for managed resources (GRS-3): each kind's legal uses
-- and its resting use, the explicit transitions a batch may make, the
-- boundary barriers it owes on its first and last touch of a resource, and
-- whether it may seal.
--
-- The rules are pure and stated in engine terms. A batch's accesses are a
-- 'BatchAccess' its recorder threads while it records; the backend maps each
-- 'ResourceUse' onto its own layouts, stages and accesses. Whether an image
-- has been initialized is the model's: see
-- 'Hetoimasia.GPU.Model.enterResource'. @docs/gpu_model.md@ states the same
-- contract in prose.
module Hetoimasia.GPU.Model.Access
  ( -- * Kinds and uses
    ResourceKind (..)
  , isImageKind
  , ResourceUse (..)
  , restingUse
  , legalUses
  , Contents (..)
  , TransitionSource (..)

    -- * A batch's accesses
  , BatchAccess
  , emptyAccess
  , accessUse
  , touchedResources
  , BarrierRole (..)
  , Barrier (..)
  , AccessRefusal (..)
  , touch
  , transition
  , sealAccess
  , entryInitializes
  ) where

import Hetoimasia.GPU.Model.Internal.Access
