-- | The module loader on a scheduled owner: where roots and arrived sources are left for
-- the owner, and what it published about them.
--
-- A scheduled owner created with a 'scheduledLoader' plan hosts the generic machinery of
-- "Hetoimasia.Scripting.Lua.Owner"'s module loader: ordered import chains whose modules
-- suspend on a dependency's verified source and resume on the owner's own thread. This
-- module is the side of it any thread may use, without blocking:
--
-- * 'submitRoot' leaves a root for the owner to admit, in the order submitted, due at once
--   ('DueUi') or when the owner's logical tick reaches a tick ('DueTick');
-- * 'notifySource' leaves the source (or the failure) a provider found;
-- * 'loaderOutcome' reads what the owner published.
--
-- Every compile, evaluation, resume, cache publication and Lua-reference release happens
-- on the owner's thread, between two of its scheduler turns, so hooks and stop requests
-- go on while a chain waits, and an independent owner never waits for it. A logical
-- root owes its tick from the moment it is submitted: the grant that reaches the tick stays
-- outstanding, and no later grant is applied however many are queued, until the root has an
-- outcome, so the scheduler cannot treat the tick as complete or advance past the
-- obligation. Once a stop is asked of the owner nothing is admitted, delivered, started or
-- resumed. "Hetoimasia.Scripting.Lua.Loading.State" says
-- how, and the package README says what the loader guarantees.
--
-- This is the generic machinery. The production coordinator that admits roots for the
-- engine's module requests, the filesystem workers that find sources, and the delivery of
-- a module's outcome at its request's assigned position are later slices'.
module Hetoimasia.Scripting.Lua.Loading
  ( -- * Configuring an owner
    LoaderPlan (..)
  , loaderPlan
  , defaultLoaderBound
  , RootDue (..)
  , LoaderHooks (..)
  , noLoaderHooks
  , LoaderPlanRefused (..)
  , LoaderViolation (..)
    -- * The endpoint
  , LoaderEndpoint
  , SubmitAnswer (..)
  , submitRoot
  , submitReservedRoot
  , PromoteAnswer (..)
  , promoteSubmitted
  , pokeLoader
  , NotifyAnswer (..)
  , notifySource
  , notifySourceNow
  , LoaderOutcome (..)
  , loaderOutcome
  , awaitLoaderOutcome
  , loaderRefusals
  , LoadingDiagnostics (..)
  , loaderDiagnostics
  ) where

import Hetoimasia.Scripting.Lua.Loading.State
  ( LoaderEndpoint (..)
  , LoaderHooks (..)
  , LoaderOutcome (..)
  , LoaderPlan (..)
  , LoaderPlanRefused (..)
  , LoaderViolation (..)
  , LoadingDiagnostics (..)
  , NotifyAnswer (..)
  , PromoteAnswer (..)
  , RootDue (..)
  , SubmitAnswer (..)
  , defaultLoaderBound
  , awaitOutcomeIn
  , diagnosticsIn
  , loaderPlan
  , noLoaderHooks
  , notifySourceIn
  , notifySourceSTM
  , outcomeIn
  , pokeLoadingSTM
  , promoteRootSTM
  , refusalsIn
  , submitReservedRootSTM
  , submitRootIn
  )
import Control.Concurrent.STM (STM)
import Hetoimasia.Scripting.Lua.Owner (ExportIdentity, RootRefusal, RootRequest, SourceAnswer)

-- | Leave a root for the owner to admit. Never blocks. Roots are admitted in the order
-- they were submitted; a logical root whose tick is below one already submitted is refused
-- ('SubmitOutOfOrder'), so the loader's queue is in logical order.
submitRoot ∷ LoaderEndpoint → RootRequest → RootDue → IO SubmitAnswer
submitRoot (LoaderEndpoint state) = submitRootIn state

-- | 'submitRoot' for a root whose identity the application reserved room for when it accepted it,
-- in the application's own transaction: the root is accepted if and only if that transaction
-- commits, and the loader does not ask its identity bound of it again. The place a logical root
-- stands at ('DueAt') is its tick and sequence.
submitReservedRoot ∷ LoaderEndpoint → RootRequest → RootDue → STM SubmitAnswer
submitReservedRoot (LoaderEndpoint state) = submitReservedRootSTM state

-- | Say that a root submitted and not finished is placed no later than this, in the application's
-- own transaction. A place only ever moves earlier. The owner gives it to the loader at its next
-- boundary, and the tick the earliest placed root holds follows it. No second record, interest or
-- evaluation is made.
promoteSubmitted ∷ LoaderEndpoint → ExportIdentity → RootDue → STM PromoteAnswer
promoteSubmitted (LoaderEndpoint state) = promoteRootSTM state

-- | Ask the owner to run the plan's 'hookService' at its next boundary, waking it for it: where an
-- application raises a failure that a thread of its own could only record.
pokeLoader ∷ LoaderEndpoint → STM ()
pokeLoader (LoaderEndpoint state) = pokeLoadingSTM state

-- | 'notifySource', in the provider's own transaction.
notifySourceNow ∷ LoaderEndpoint → ExportIdentity → SourceAnswer → STM NotifyAnswer
notifySourceNow (LoaderEndpoint state) = notifySourceSTM state

-- | Leave the source a provider found, or its failure, for the owner to deliver. Never
-- blocks. A second notification for an identity that is still waiting changes nothing.
notifySource ∷ LoaderEndpoint → ExportIdentity → SourceAnswer → IO NotifyAnswer
notifySource (LoaderEndpoint state) = notifySourceIn state

-- | What the owner published about an identity: admitted, ready or failed with the very
-- handle or sticky fault, or stopped. 'Nothing' for one it has said nothing of.
loaderOutcome ∷ LoaderEndpoint → ExportIdentity → IO (Maybe LoaderOutcome)
loaderOutcome (LoaderEndpoint state) = outcomeIn state

-- | The outcome of an identity once it has one (ready, failed or stopped), retrying until it
-- does: for the application to compose with its supervised wait, so that the owner ending is
-- an answer and not a hang. The loader settles no request; this is the coordinator reading
-- what the owner published.
awaitLoaderOutcome ∷ LoaderEndpoint → ExportIdentity → STM LoaderOutcome
awaitLoaderOutcome (LoaderEndpoint state) = awaitOutcomeIn state

-- | The last roots the loader refused, oldest first. Nothing was recorded for them.
loaderRefusals ∷ LoaderEndpoint → IO [(ExportIdentity, RootRefusal)]
loaderRefusals (LoaderEndpoint state) = refusalsIn state

-- | What the loading side holds right now.
loaderDiagnostics ∷ LoaderEndpoint → IO LoadingDiagnostics
loaderDiagnostics (LoaderEndpoint state) = diagnosticsIn state
