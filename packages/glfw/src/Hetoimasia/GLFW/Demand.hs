-- | Bounded demand: how a worker asks a window host's owner for a turn.
--
-- A worker holds a 'DemandPublisher' — the application's, from
-- @Hetoimasia.Runtime.GLFW@'s @hostDemandPublisher@, or one window's, from
-- 'Hetoimasia.GLFW.Command.clientDemandPublisher' — and calls 'publishDemand'
-- with a 'DemandRequest' built from 'immediateDemand', 'deadlineDemand', or
-- both combined with @<>@. The request is recorded and coalesced into the
-- slot, the slot's revision advances, and only then is the owner woken, so the
-- state that matters is always authoritative before the hint that announces it.
--
-- Requests combine, rather than replace: immediate demand if any publisher
-- asked for it, and the earliest deadline any of them requested. One worker's
-- 'noDemand' therefore cannot cancel another's request, and a later deadline
-- cannot postpone an earlier pending one. There is one slot for the application
-- and one per live window — never one per worker or per request — so the
-- notification state stays bounded however many publishers there are.
--
-- The owner captures the pending request with its revision in one operation
-- that clears exactly what it captured; a publication committed after that
-- capture stays pending for the next one. A closed slot answers
-- 'DemandSlotClosed' and makes no native call, so a publisher retained after
-- its window ended or its host quiesced is safe and can resurrect nothing.
--
-- Deadlines are opaque 'Hetoimasia.Foundation.Time.Instant' values in the
-- publisher's own clock domain; nothing here reads a clock or decides what a
-- deadline means for the owner's next wait.
--
-- See "Hetoimasia.GLFW.Internal.Demand"'s contract, repeated in prose in
-- @docs/glfw.md@, for the combination, capture, and closure rules.
module Hetoimasia.GLFW.Demand
  ( -- * Requests
    DemandRequest
  , noDemand
  , immediateDemand
  , deadlineDemand
  , demandIsImmediate
  , demandDeadline
  , demandRequested

    -- * Publishing
  , DemandPublisher
  , publishDemand
  , PublishResult (..)

    -- * What the owner captures
  , CapturedDemand (..)
  , DemandStatus (..)
  ) where

import Hetoimasia.GLFW.Internal.Demand
  ( CapturedDemand (..)
  , DemandPublisher
  , DemandRequest
  , DemandStatus (..)
  , PublishResult (..)
  , deadlineDemand
  , demandDeadline
  , demandIsImmediate
  , demandRequested
  , immediateDemand
  , noDemand
  , publishDemand
  )
