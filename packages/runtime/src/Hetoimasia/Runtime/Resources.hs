-- | The console application's owned-resource demonstration.
--
-- This module is the consumer that composes the two peer contracts: the scopes
-- of "Hetoimasia.Foundation.Resource" and the logging of
-- "Hetoimasia.Foundation.Log". Neither knows about the other — the resource
-- module imports no logger and the logging module owns no scope — so the
-- composition, and every rule it has to respect, belongs here.
--
-- 'resourceSmoke' is that composition as one named function with its work, its
-- cleanup outcomes, and its logger injected, so the body @docs\/resources.md@
-- shows is the body the suite runs and the executable calls.
--
-- Three rules shape it, and each is visible in the code below:
--
-- * __No logger call sits between an acquisition and its protection.__ Every
--   acquisition record is emitted from the scope's continuation, which the
--   facade only reaches once that allocation's release is installed.
--
-- * __A release never writes to a sink.__ Releases run under
--   'Control.Exception.uninterruptibleMask_' and must have a controlled
--   blocking duration, while a sink write has none. Each release appends one
--   bounded entry to an in-memory ledger instead, and those entries are emitted
--   after the scope has unwound. A failing diagnostic therefore cannot skip a
--   destruction, because no diagnostic runs inside one.
--
-- * __The boundary reports once and keeps its failure.__ An ordinary failure
--   of a resource or of the work gets exactly one guarded @Error@ attempt
--   through 'Hetoimasia.Runtime.Reporting.reportTerminalFailure', carrying the
--   cleanup evidence and origin the exception's own context holds; the original
--   exception then propagates with its type, its value, and that context
--   intact, whether the report succeeded or failed. A cancellation escapes with
--   no record at all, and no successful completion is ever reported for a run
--   that threw.
--
-- * __A diagnostic's own failure is never reported.__ A resource failure and a
--   diagnostic failure are different things. When the sink a lifecycle record
--   was written to is what failed, there is no second sink to say so through
--   and the one that just failed is not it: the run still releases everything,
--   and the sink's exception then propagates with no reporting attempt at all.
--   Every lifecycle emission below is marked with 'DiagnosticFailure' so the
--   boundary can tell the two apart.
--
-- Unlike the terminal worker boundary of @docs\/logging.md@, this one has a
-- caller. It reports and then rethrows rather than swallowing, so the caller
-- still receives the structured outcome.
module Hetoimasia.Runtime.Resources
  ( -- * The demonstration
    resourceSmoke
  , managedResourceSmoke
  , resourceComponent
  , DiagnosticFailure (..)

    -- * Injected work
  , SmokeWork
  , smokeWork
  , SmokeResources (..)

    -- * Borrowed values
  , Slot
  , slotName
  , slotId
  , slotCount
  , writeSlot
  , Channel
  , channelBuffer
  , channelStore

    -- * Injected cleanup outcomes
  , ReleaseOutcomes (..)
  , workingReleases
  ) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log
  ( Component
  , Logger
  , logInfo
  , unsafeComponent
  , withBreadcrumb
  )
import Hetoimasia.Foundation.Resource
  ( Assembly
  , Scoped
  , acquirePart
  , allocComposite
  , allocResource
  , releaseRank
  , restoredStep
  , withScoped
  )
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, recordReport)
import Hetoimasia.Runtime.Reporting
  ( DiagnosticFailure (..)
  , markDiagnostic
  , reportTerminalFailure
  , reportTerminalFailureWith
  )

-- | The stable component name every record from this demonstration carries.
resourceComponent ∷ Component
resourceComponent = unsafeComponent "runtime.resources"

-- | Emit one lifecycle diagnostic, marking a synchronous failure it raises with
-- 'DiagnosticFailure'.
--
-- The mark rides on the exception's context, which every rethrow inside the
-- resource scopes preserves, so it is still directly reachable at the boundary
-- after the scope has unwound and attached its own cleanup evidence.
lifecycle ∷ IO () → IO ()
lifecycle = markDiagnostic

-- | A borrowed in-memory slot: an identifier, and the bounded list of entries
-- written into it while it is held.
--
-- It is deliberately not a file, a thread, or a service. What it demonstrates
-- is ownership, and ownership is visible without any of those: the slot is
-- created by an acquisition, borrowed by a body, and closed by a release that
-- the scope runs exactly once.
data Slot = Slot
  { slotName ∷ !Text
    -- ^ The resource name this slot's records use.
  , slotId ∷ !Text
    -- ^ This slot's identifier, unique within one run.
  , slotEntries ∷ !(IORef [Text])
  , slotOpen ∷ !(IORef Bool)
  }

-- | How many entries have been written into this slot.
slotCount ∷ Slot → IO Int
slotCount slot = length <$> readIORef (slotEntries slot)

-- | Write one entry into a borrowed slot.
--
-- A slot whose scope has already released it is spent: writing to it fails
-- rather than silently succeeding, so the documented misuse of returning a
-- borrowed value out of its scope is caught rather than hidden.
writeSlot ∷ Slot → Text → IO ()
writeSlot slot entry = do
  open ← readIORef (slotOpen slot)
  if open
    then atomicModifyIORef' (slotEntries slot) (\entries → (entries <> [entry], ()))
    else ioFailure ("slot " <> slotId slot <> " is released")

-- | A composite owner: a buffer slot with its backing store bound behind it.
--
-- It is built by 'Hetoimasia.Foundation.Resource.withComposite' through the
-- facade, so a failure at any construction stage releases exactly the parts
-- acquired so far, and the finished value's parts are released in the order the
-- constructor declared rather than the reverse of acquisition.
data Channel = Channel
  { channelBuffer ∷ !Slot
    -- ^ The slot a caller writes into.
  , channelStore ∷ !Slot
    -- ^ The backing store the buffer is bound to.
  }

-- | The resources 'resourceSmoke' lends to its injected work: one plain
-- allocation and one composite.
data SmokeResources = SmokeResources
  { smokeWorkspace ∷ !Slot
  , smokeChannel ∷ !Channel
  }

-- | The work a run performs while it holds its resources.
--
-- It receives the derived logger and the borrowed resources and returns an
-- ordinary result. It must not return a borrowed value or anything whose
-- validity depends on one: by the time 'resourceSmoke' returns, every slot has
-- been released.
type SmokeWork = Logger → SmokeResources → IO Int

-- | What each release does beyond closing its slot, injected so a suite can
-- observe that a release was attempted and can fail one without a resource
-- that can fail on its own.
--
-- Each action runs inside an uninterruptible release, so it must have a
-- controlled blocking duration: record, signal, or throw, and do not wait on
-- something another thread has to provide.
data ReleaseOutcomes = ReleaseOutcomes
  { onReleaseWorkspace ∷ IO ()
  , onReleaseBuffer ∷ IO ()
  , onReleaseStore ∷ IO ()
  }

-- | Releases that do nothing beyond closing their slot. The executable uses
-- these; a suite overrides one field.
workingReleases ∷ ReleaseOutcomes
workingReleases = ReleaseOutcomes
  { onReleaseWorkspace = pure ()
  , onReleaseBuffer = pure ()
  , onReleaseStore = pure ()
  }

-- | Acquire a workspace and a channel through the continuation facade, run the
-- injected work with both, release everything, and report the lifecycle.
--
-- On the normal path this emits an @Info@ record for each acquisition, whatever
-- the work emits, one for each release, and one completion record, all through
-- a logger derived from the caller's, all under 'resourceComponent', and all
-- with the resource identifiers in fields rather than interpolated into
-- messages. The work's result is returned.
--
-- On every other path nothing reports completion. An ordinary failure — from
-- the work or from a release — produces exactly one @Error@ record naming what
-- was released, what cleanup evidence the exception carries, and where the
-- failure came from, and then propagates with its context intact so the caller
-- can inspect that evidence itself through
-- 'Hetoimasia.Foundation.Resource.cleanupFailures'. If that one report also
-- fails, its exception is discarded in favour of the original.
--
-- A cancellation propagates unchanged and unreported, and so does a failure
-- raised by a lifecycle diagnostic itself: there is no reporting attempt for a
-- sink that has already failed.
--
-- Either way every resource acquired has been released before this returns.
resourceSmoke ∷ Logger → ReleaseOutcomes → SmokeWork → IO Int
resourceSmoke = smokeReportedBy reportTerminalFailure

-- | 'resourceSmoke' inside a logging lifetime, with the same work, records, and
-- single terminal report, over the lifetime's logger.
--
-- The one difference is where the reporting attempt's outcome goes: it is
-- recorded on the lifetime before the original failure is rethrown, including
-- when the report itself failed. The lifetime then knows this path's
-- diagnostics have already failed and makes no final flush through it, which
-- inferring from the rethrown failure alone could not tell it. This is the path
-- the console executable's @--resource-smoke@ runs.
managedResourceSmoke ∷ LoggingLifetime → ReleaseOutcomes → SmokeWork → IO Int
managedResourceSmoke lifetime =
  smokeReportedBy (reportTerminalFailureWith (recordReport lifetime)) (lifetimeLogger lifetime)

-- | The terminal reporting boundary a run uses: the adapter's
-- 'reportTerminalFailure', or the same boundary with a recorder attached.
type Reporter = ∀ a. Logger → Component → Text → IO [(Text, Text)] → IO a → IO a

-- | The demonstration with its one terminal reporter injected.
smokeReportedBy ∷ Reporter → Logger → ReleaseOutcomes → SmokeWork → IO Int
smokeReportedBy report logger outcomes work = do
  ledger ← newLedger
  -- The adapter classifies what the run threw: a cancellation and a marked
  -- diagnostic's own failure propagate unreported, and anything else gets its
  -- one guarded report. The released names are read from the ledger inside
  -- that attempt, after the scope has unwound.
  report scoped resourceComponent "Resource smoke abandoned"
    (releasedFields <$> recordedReleases ledger)
    (runSmoke scoped ledger outcomes work)
  where
    -- The derived logger the whole demonstration uses. The caller's logger is
    -- unchanged, and every record below carries this breadcrumb.
    scoped = withBreadcrumb "resource-smoke" logger

-- | The demonstration itself: the scope, then the diagnostics the scope could
-- not safely emit from inside its own releases.
--
-- Everything here runs inside the reporting boundary above, including the
-- emission below, so a sink that fails while the lifecycle is being reported is
-- handled exactly like any other ordinary failure.
runSmoke ∷ Logger → Ledger → ReleaseOutcomes → SmokeWork → IO Int
runSmoke scoped ledger outcomes work = do
  entries ← withScoped (smokeScope scoped ledger outcomes) (work scoped)
  -- The scope has unwound: every release has run, and the records they left
  -- behind are emitted here, where a blocking write is allowed.
  released ← recordedReleases ledger
  lifecycle (emitReleases scoped released)
  lifecycle $
    logInfo scoped resourceComponent "Resource smoke completed"
      [("entries", number entries)]
  pure entries

-- | The two allocations, composed in @do@ notation.
--
-- Each acquisition record is emitted from the continuation the facade enters
-- after that allocation's release is installed, which is why there is no
-- logging call inside an acquisition: between acquiring a resource and
-- protecting it, nothing may run that can fail on its own.
smokeScope ∷ Logger → Ledger → ReleaseOutcomes → Scoped SmokeResources
smokeScope scoped ledger outcomes = do
  workspace ←
    allocResource
      (openSlot ledger "workspace")
      (closeSlot ledger (onReleaseWorkspace outcomes))
  liftIO . lifecycle $
    logInfo scoped resourceComponent "Acquired resource"
      [("resource", slotName workspace), ("id", slotId workspace)]
  channel ← allocComposite (channelAssembly ledger outcomes)
  liftIO . lifecycle $
    logInfo scoped resourceComponent "Acquired composite"
      [ ("resource", "channel")
      , ("buffer", slotId (channelBuffer channel))
      , ("store", slotId (channelStore channel))
      ]
  pure (SmokeResources workspace channel)

-- | A channel is a buffer bound to its backing store.
--
-- The buffer is acquired first and the store second, and the declared release
-- order releases the buffer first as well: acquisition order, not the reverse
-- of it, because what holds the reference is released before what it refers
-- to. Binding acquires nothing, so it is a restored step.
channelAssembly ∷ Ledger → ReleaseOutcomes → Assembly Channel
channelAssembly ledger outcomes = do
  buffer ←
    acquirePart
      "channel buffer"
      (releaseRank 0)
      (openSlot ledger "channel.buffer")
      (closeSlot ledger (onReleaseBuffer outcomes))
  store ←
    acquirePart
      "channel store"
      (releaseRank 1)
      (openSlot ledger "channel.store")
      (closeSlot ledger (onReleaseStore outcomes))
  restoredStep (writeSlot store ("bound to " <> slotId buffer))
  pure (Channel buffer store)

-- | The bounded work the executable runs: a fixed number of entries into the
-- workspace and the channel, and one record saying what it did.
--
-- It is injected rather than inlined so a suite can substitute work that fails
-- or blocks and still exercise this exact body around it.
smokeWork ∷ SmokeWork
smokeWork logger resources = do
  forM_ ["prepare", "stage", "commit"] (writeSlot (smokeWorkspace resources))
  forM_ ["first frame", "second frame"] (writeSlot (channelBuffer (smokeChannel resources)))
  staged ← slotCount (smokeWorkspace resources)
  published ← slotCount (channelBuffer (smokeChannel resources))
  lifecycle $
    logInfo logger resourceComponent "Completed bounded work"
      [("staged", number staged), ("published", number published)]
  pure (staged + published)

-- Lifecycle ledger ------------------------------------------------------------

-- | One release that was attempted, as the release recorded it.
data Released = Released
  { releasedResource ∷ !Text
  , releasedId ∷ !Text
  , releasedEntries ∷ !Int
  }

-- | The identifiers a run issues and the release entries it collects.
--
-- This is not application state: it is created per run, is never shared between
-- runs, and holds nothing after the run that created it returns.
data Ledger = Ledger
  { ledgerNextId ∷ !(IORef Int)
  , ledgerReleased ∷ !(IORef [Released])
  }

newLedger ∷ IO Ledger
newLedger = Ledger <$> newIORef 1 <*> newIORef []

-- | Acquire one slot under the given resource name, with the next identifier
-- this run issues.
openSlot ∷ Ledger → Text → IO Slot
openSlot ledger name = do
  identifier ← atomicModifyIORef' (ledgerNextId ledger) (\next → (next + 1, next))
  Slot name (number identifier) <$> newIORef [] <*> newIORef True

-- | Release one slot: record the attempt, close the slot, then run whatever the
-- caller injected.
--
-- The record is appended before anything can fail, so evidence shows every
-- release that was attempted rather than only those that succeeded, and the
-- close happens before the injected outcome, so an injected failure cannot
-- leave the slot usable. Both steps are bounded and neither writes to a sink,
-- which is what makes them legal inside an uninterruptible release.
closeSlot ∷ Ledger → IO () → Slot → IO ()
closeSlot ledger injected slot = do
  entries ← readIORef (slotEntries slot)
  atomicModifyIORef' (ledgerReleased ledger) $ \released →
    (Released (slotName slot) (slotId slot) (length entries) : released, ())
  writeIORef (slotOpen slot) False
  injected

-- | The releases attempted so far, in the order they were attempted.
recordedReleases ∷ Ledger → IO [Released]
recordedReleases ledger = reverse <$> readIORef (ledgerReleased ledger)

-- | Emit one record per release. This runs after the scope has unwound, never
-- inside a release.
emitReleases ∷ Logger → [Released] → IO ()
emitReleases scoped released = forM_ released $ \entry →
  logInfo scoped resourceComponent "Released resource"
    [ ("resource", releasedResource entry)
    , ("id", releasedId entry)
    , ("entries", number (releasedEntries entry))
    ]

-- Rendering -------------------------------------------------------------------

-- | What the run released, as the terminal report's own field. Cleanup evidence
-- and origin come from the adapter.
releasedFields ∷ [Released] → [(Text, Text)]
releasedFields released =
  [("released", Text.intercalate "," (map releasedResource released))]

number ∷ Int → Text
number = Text.pack . show

ioFailure ∷ Text → IO a
ioFailure = ioError . userError . Text.unpack
