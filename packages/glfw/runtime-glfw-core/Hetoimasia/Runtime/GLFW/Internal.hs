-- | The implementation of "Hetoimasia.Runtime.GLFW", with the test-only host
-- hooks the package's own dynamic window examples use to deliver a cancellation
-- at a precise point.
--
-- This module belongs to the private @runtime-glfw-core@ sublibrary, so no
-- package outside @hetoimasia-glfw@ can import it. The public
-- "Hetoimasia.Runtime.GLFW" re-exports everything here except 'HostHooks',
-- 'noHostHooks', and 'allocWindowHostWith', and carries the contract.
--
-- = Where each part lives
--
-- This module is the composition the facade, the examples, and the native
-- suite import; it defines nothing. Every part is a private module beneath it,
-- with its own thread and state owner named in its header. The host is one
-- lifetime owned by the process main thread; the graphics owner in
-- "Hetoimasia.Runtime.GLFW.Internal.Owner" is a separate lifetime joined to it
-- by composition, and no host module imports it.
--
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Config": what a host is built
--   from, validated before anything is acquired. Values only.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.State": the one host handle, its
--   registry, its private hooks, and what clients may observe. Representation
--   only.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Progress": the retirement demand
--   and graphics cells a protected host publishes from its attachment model.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Windows" and
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Commands": window registration,
--   borrowing and the close protocol, and fair command dispatch.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Construction",
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Wake" and
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Demand": building and quiescing a
--   host, the wake path's one report, and the demand slots.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Turn",
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Loop" and
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Pacing": the one turn both owner
--   loops share, the loops themselves, and the scheduled loop's pure pacing
--   decisions.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Application" and
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Lifetime": the ordinary runner, and
--   the protected lifetime whose exit retires every attachment first.
-- * "Hetoimasia.Runtime.GLFW.Internal.Host.Seam" and
--   "Hetoimasia.Runtime.GLFW.Internal.Host.Attachments": the private
--   attachment seam and the public attachment contract.
--
-- New code inside this sublibrary imports the part it needs directly.
module Hetoimasia.Runtime.GLFW.Internal
  ( -- * Hosts
    WindowHost
  , allocWindowHost
  , allocWindowHostIn
  , allocWindowHostWith
  , HostHooks (..)
  , noHostHooks
  , hostMonitors
  , hostCommandPort
  , hostCommandStatistics
  , quiesceWindowHost
  , HostActivity (..)
  , hostActivity
  , hostWindowCapabilities

    -- * The wake path
  , hostWakePath
  , hostNotificationsInFlight
  , reportHostWakeDegradation

    -- * Demand
  , hostDemandPublisher
  , captureHostDemand
  , captureWindowDemand
  , hostDemandStatus
  , windowDemandStatus

    -- * Windows
  , hostWindowIdentities
  , hostWindowClient
  , withHostWindow
  , closeHostWindow
  , honourHostCloseRequest
  , CloseStart (..)
  , HostBookkeeping (..)
  , hostBookkeeping

    -- * Configuration
  , HostConfig (..)
  , defaultHostConfig
  , validateHostConfig
  , HostConfigRejected (..)
  , maximumWindowLimit
  , hostComponent

    -- * The owner loop
  , runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , Turn (..)
  , TurnStep (..)
  , rejectHostCloseRequest

    -- * The scheduled owner loop
  , runScheduledOwnerLoop
  , ScheduledHooks (..)
  , defaultScheduledHooks
  , noApplicationReadiness
  , ScheduledTurn (..)
  , TurnPacing (..)
  , UpdateSchedule (..)
  , ScheduledStep (..)

    -- * The protected host lifetime
  , withProtectedWindowHost
  , withProtectedWindowHostIn
  , withProtectedWindowHostWith
  , withProtectedWindowHostOver
  , ProtectedExit (..)
  , noProtectedExit
  , RetirementEnvironment (..)
  , retirementEnvironmentOf
  , runProtectedWindowApplication
  , hostConfiguration
  , hostWakeNotifier

    -- * What the surface bridge reads of a host
  , hostSessionOf
  , hostRetirementOf
  , hostWindowClosing

    -- * The private attachment seam
  , hostAttachmentIdentity
  , attachHostWindow
  , hostCompletionPublisher
  , hostPendingAttachments
  , hostAttachmentView
  , reportHostRetirementFact
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , RetirementProgress (..)
  , AttachmentOutcome (..)
  , RolledBack (..)
  , MetadataRejection (..)
  , faultHostAttachmentMetadata

    -- * The public attachment contract
  , AttachmentId
  , attachmentWindow
  , attachmentIncarnation
  , Acknowledgement
  , acknowledgedAttachment
  , GraphicsRefusal (..)
  , RetirementFact (..)
  , allRetirementFacts
  , RollbackOutcome (..)
  , FactAnswer (..)
  , CompletionNotice
  , completionNotice
  , NoticeAdmission (..)
  , CompletionPublisher
  , CompletionPublication (..)
  , publishCompletion
  , GraphicsService
  , graphicsWindow
  , graphicsAttachment
  , graphicsIncarnation
  , readGraphicsService
  , GraphicsObservation (..)
  , SlotState (..)
  , NativeDisposal (..)
  , WindowGraphics (..)
  , windowGraphicsService
  , GraphicsAttachment (..)
  , attachWindowGraphics
  , detachWindowGraphics
  , DetachAnswer (..)
  , windowGraphicsStatus
  , hostGraphicsPublisher
  , certifyGraphicsFact
  , RetirementDemand (..)
  , noRetirementDemand
  , hostRetirementDemand

    -- * Applications
  , runWindowApplication
  ) where

import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , CompletionNotice
  , FactAnswer (..)
  , NoticeAdmission (..)
  , RetirementFact (..)
  , RollbackOutcome (..)
  , acknowledgedAttachment
  , allRetirementFacts
  , attachmentIncarnation
  , attachmentWindow
  , completionNotice
  )
import Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( GraphicsObservation (..)
  , GraphicsService
  , NativeDisposal (..)
  , SlotState (..)
  , WindowGraphics (..)
  , graphicsAttachment
  , graphicsIncarnation
  , graphicsWindow
  , readGraphicsService
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Application (runWindowApplication)
import Hetoimasia.Runtime.GLFW.Internal.Host.Attachments
  ( GraphicsAttachment (..)
  , GraphicsRefusal (..)
  , attachWindowGraphics
  , certifyGraphicsFact
  , detachWindowGraphics
  , hostGraphicsPublisher
  , windowGraphicsService
  , windowGraphicsStatus
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Commands (HostBookkeeping (..), hostBookkeeping)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config
  ( HostConfig (..)
  , HostConfigRejected (..)
  , defaultHostConfig
  , hostComponent
  , maximumWindowLimit
  , validateHostConfig
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Construction
  ( allocWindowHost
  , allocWindowHostIn
  , allocWindowHostWith
  , hostActivity
  , hostCommandPort
  , hostCommandStatistics
  , hostMonitors
  , hostWindowCapabilities
  , quiesceWindowHost
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Demand
  ( captureHostDemand
  , captureWindowDemand
  , hostDemandPublisher
  , hostDemandStatus
  , windowDemandStatus
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Lifetime
  ( ProtectedExit (..)
  , noProtectedExit
  , retirementEnvironmentOf
  , runProtectedWindowApplication
  , withProtectedWindowHost
  , withProtectedWindowHostIn
  , withProtectedWindowHostOver
  , withProtectedWindowHostWith
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Loop
  ( LoopHooks (..)
  , ScheduledHooks (..)
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , TurnStep (..)
  , defaultScheduledHooks
  , noApplicationEvents
  , noApplicationReadiness
  , runOwnerLoop
  , runScheduledOwnerLoop
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Pacing (TurnPacing (..), UpdateSchedule (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (hostRetirementDemand)
import Hetoimasia.Runtime.GLFW.Internal.Host.Seam
  ( attachHostWindow
  , faultHostAttachmentMetadata
  , hostAttachmentIdentity
  , hostAttachmentView
  , hostCompletionPublisher
  , hostPendingAttachments
  , reportHostRetirementFact
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.State
  ( HostActivity (..)
  , HostHooks (..)
  , RetirementDemand (..)
  , WindowHost
  , hostConfiguration
  , hostRetirementOf
  , hostSessionOf
  , noHostHooks
  , noRetirementDemand
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Turn (Turn (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake
  ( hostNotificationsInFlight
  , hostWakeNotifier
  , hostWakePath
  , reportHostWakeDegradation
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows
  ( CloseStart (..)
  , closeHostWindow
  , honourHostCloseRequest
  , hostWindowClient
  , hostWindowClosing
  , hostWindowIdentities
  , rejectHostCloseRequest
  , withHostWindow
  )
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( AttachmentOutcome (..)
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , CompletionPublication (..)
  , CompletionPublisher
  , DetachAnswer (..)
  , MetadataRejection (..)
  , RetirementEnvironment (..)
  , RetirementProgress (..)
  , RolledBack (..)
  , publishCompletion
  )
