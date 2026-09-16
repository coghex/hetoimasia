-- | A window's ordered input, read by one logical consumer, with a visible,
-- acknowledged reset after overflow or temporary suspension.
--
-- Each window the host in "Hetoimasia.Runtime.GLFW" holds has one input feed.
-- Its 'Hetoimasia.GLFW.Command.WindowClient' hands out two opaque capabilities:
-- an 'InputReader', which reads events and acknowledges resets, and an
-- 'InputControl', which enables the application's input admission once it is
-- ready and may suspend it again later. Neither exposes the feed's channel, its
-- state, or a way to produce input; producing, warning, resuming, and closing
-- belong to the window's owner.
--
-- A delivered 'InputEvent' carries its window, its 'InputEpoch', and a payload:
-- a key transition, a Unicode character, a button transition with the cursor
-- position and modifiers captured for it, scroll offsets, or a focus transition.
-- Native callbacks copy those payloads and return; the owner boundary publishes
-- them into the feed. Cursor motion coalesces into the window observation.
-- When ordered admission is full, or input is suspended, the feed discards its
-- backlog and every read answers 'InputResetRequired' until the consumer —
-- having finished or abandoned its current handler and cleared its own held keys,
-- buttons, and gestures — acknowledges that 'ResetToken'. Input resumes only in
-- a fresh epoch, after the owner resumes it, and only a fresh press establishes
-- held state there. Closure ends every read at once.
--
-- See "Hetoimasia.GLFW.Internal.Input"'s contract, repeated in prose in
-- @docs/glfw.md@, for the phase model, the gates, the held-state rules, the
-- acknowledgement order, and closure precedence.
--
-- @
-- consume ∷ InputReader → (InputEvent → IO ()) → IO () → IO ()
-- consume reader handle clearDerivedState = loop
--   where
--     loop =
--       atomically (awaitInput reader) >>= \\case
--         InputDelivered event → handle event >> loop
--         InputResetRequired token → do
--           clearDerivedState
--           _ ← atomically (acknowledgeReset reader token)
--           loop
--         InputClosed → clearDerivedState
--         _ → loop
-- @
module Hetoimasia.GLFW.Input
  ( -- * Reading
    InputReader
  , inputReaderWindow
  , InputRead (..)
  , readInput
  , awaitInput

    -- * Events
  , InputEvent
  , inputWindow
  , inputEpoch
  , inputPayload
  , InputEpoch
  , epochNumber
  , InputPayload (..)
  , KeyEvent (..)
  , KeyAction (..)
  , ButtonEvent (..)
  , ButtonAction (..)
  , ScrollEvent (..)
  , CursorPosition (..)
  , Modifiers (..)
  , noModifiers
  , keyDomainLast
  , buttonDomainLast

    -- * Resets
  , ResetToken
  , resetWindow
  , resetEpoch
  , resetReason
  , ResetReason (..)
  , Acknowledgement (..)
  , InputMisuse (..)
  , acknowledgeReset

    -- * Application admission
  , InputControl
  , inputControlWindow
  , ApplicationAdmission (..)
  , AdmissionChange (..)
  , enableInput
  , suspendInput

    -- * Statistics
  , InputStatistics (..)
  , InputPhase (..)
  , ResetSummary (..)
  , WarningState (..)
  , inputStatistics
  ) where

import Hetoimasia.GLFW.Internal.Input
