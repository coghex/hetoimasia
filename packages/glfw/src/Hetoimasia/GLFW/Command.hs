-- | Bounded window command admission and persistent completion.
--
-- The owner creates a 'WindowCommandHost' for a live 'Session' on its owner
-- thread and hands clients its 'WindowCommandPort'. A client submits prepared
-- 'WindowCommand's through the port from any thread: 'submitWindowCommand'
-- answers at once with a 'CompletionTicket', 'SubmitFull', or 'SubmitClosed',
-- and 'awaitSubmitWindowCommand' is the separate, cancellable wait for
-- capacity. Every admitted command settles exactly once to a 'Disposition',
-- which the ticket reports as often as asked. 'closeWindowCommands' ends
-- admission and settles everything still queued as 'NotExecuted'.
--
-- 'observeWindowCommand' asks the owner to sample a window and publish a fresh
-- observation of it; its result names the committed revision. The control
-- commands — title, size, position, size constraints, show, hide, focus and
-- attention requests, and minimize, maximize, and restore — are validated on
-- the owner thread before any native call and settle as 'Rejected',
-- 'Unsupported', or 'Attempted', naming the revision a sample taken after the
-- call published. A returned native call is never reported as the state the
-- window reached, and a size outside the window's constraints is never sent to
-- the platform to clamp.
-- 'closeWindowCommand' and 'createWindowCommand' change which windows exist, so
-- only the window host's owner loop in "Hetoimasia.Runtime.GLFW" performs them;
-- every other executor rejects them. A successful creation settles as
-- 'WindowCreated', and its ticket then hands over the new window's
-- 'WindowClient' through 'pollWindowClient': that window's own command port,
-- read-only observations, and "Hetoimasia.GLFW.Input" reader and admission
-- control, separate from the prepared completion data. The owner
-- thread never waits for a ticket or for capacity, since it is the thread that
-- would have to provide either: there it uses 'performWindowCommand'.
--
-- Ports, tickets, and hosts are opaque and carry no native handle. Executing
-- queued commands is private to this package: the window host's owner loop in
-- "Hetoimasia.Runtime.GLFW", from the @runtime-glfw@ sublibrary, drains them.
--
-- See "Hetoimasia.GLFW.Internal.Command"'s contract, repeated in prose in
-- @docs/glfw.md@, for the admission, disposition, ticket, bookkeeping, and
-- closure rules.
--
-- @
-- request ∷ WindowCommandPort → Window → IO (Maybe Disposition)
-- request port window =
--   submitWindowCommand port [("client", "tool")] (observeWindowCommand (windowIdentity window)) >>= \\case
--     SubmitAccepted ticket → Just \<$\> awaitCompletion ticket
--     SubmitFull → pure Nothing
--     SubmitClosed → pure Nothing
-- @
module Hetoimasia.GLFW.Command
  ( -- * Hosts
    WindowCommandHost
  , newWindowCommandHost
  , windowCommandPort
  , closeWindowCommands
  , CommandStatistics (..)
  , commandStatistics
  , performWindowCommand

    -- * Ports and submission
  , WindowCommandPort
  , SubmitResult (..)
  , submitWindowCommand
  , WaitedSubmission (..)
  , awaitSubmitWindowCommand

    -- * Commands
  , WindowCommand
  , observeWindowCommand
  , closeWindowCommand
  , createWindowCommand
  , commandWindow

    -- * Control commands
  , setWindowTitleCommand
  , setWindowSizeCommand
  , setWindowPositionCommand
  , setSizeConstraintsCommand
  , showWindowCommand
  , hideWindowCommand
  , requestFocusCommand
  , requestAttentionCommand
  , minimizeWindowCommand
  , maximizeWindowCommand
  , restoreWindowCommand
  , SizeConstraints
  , sizeConstraints
  , constraintMinimum
  , constraintMaximum
  , constraintAspectRatio
  , AspectRatio (..)
  , WindowOperation (..)

    -- * Mode commands
  , setWindowModeCommand
  , ModeTransition (..)

    -- * Origins
  , RequestId
  , requestLocalIdentity
  , CommandOrigin
  , submittedRequest
  , submittedWindow
  , submittedAt
  , submittedContext

    -- * Completion
  , CompletionTicket
  , ticketOrigin
  , pollCompletion
  , awaitCompletion
  , Disposition (..)
  , CommandResult (..)
  , CommandRejection (..)
  , UnsupportedControl (..)
  , ControlAttempt (..)
  , ControlRejection (..)
  , ControlOutcome (..)
  , ConstraintCall (..)
  , constraintCallOrder
  , PostCallObservation (..)

    -- * Window clients
  , WindowClient
  , clientWindow
  , clientCommandPort
  , clientObservations
  , clientInputReader
  , clientInputControl
  , pollWindowClient

    -- * Misuse
  , WindowCommandMisuse (..)
  ) where

import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio (..)
  , ConstraintCall (..)
  , ControlOutcome (..)
  , ControlRejection (..)
  , PostCallObservation (..)
  , SizeConstraints
  , WindowOperation (..)
  , constraintAspectRatio
  , constraintCallOrder
  , constraintMaximum
  , constraintMinimum
  , sizeConstraints
  )
import Hetoimasia.GLFW.Internal.Command
  ( CommandOrigin
  , CommandRejection (..)
  , CommandResult (..)
  , CommandStatistics (..)
  , CompletionTicket
  , ControlAttempt (..)
  , Disposition (..)
  , ModeTransition (..)
  , RequestId
  , SubmitResult (..)
  , UnsupportedControl (..)
  , WaitedSubmission (..)
  , WindowCommand
  , WindowCommandHost
  , WindowCommandMisuse (..)
  , WindowClient
  , WindowCommandPort
  , awaitCompletion
  , awaitSubmitWindowCommand
  , clientCommandPort
  , clientInputControl
  , clientInputReader
  , clientObservations
  , clientWindow
  , closeWindowCommand
  , closeWindowCommands
  , commandStatistics
  , commandWindow
  , createWindowCommand
  , hideWindowCommand
  , maximizeWindowCommand
  , minimizeWindowCommand
  , newWindowCommandHost
  , observeWindowCommand
  , performWindowCommand
  , pollCompletion
  , pollWindowClient
  , requestAttentionCommand
  , requestFocusCommand
  , requestLocalIdentity
  , restoreWindowCommand
  , setSizeConstraintsCommand
  , setWindowPositionCommand
  , setWindowSizeCommand
  , setWindowModeCommand
  , setWindowTitleCommand
  , showWindowCommand
  , submitWindowCommand
  , submittedAt
  , submittedContext
  , submittedRequest
  , submittedWindow
  , ticketOrigin
  , windowCommandPort
  )
