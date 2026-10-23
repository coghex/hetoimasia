-- | The M1 module-job coordinator (LFE-11): one VM-owned load job for each module, per-request waiters
-- that join it and receive its outcome at their own assigned positions, and the source stage that
-- feeds it from the session's pool of verified reads.
--
-- = What it is
--
-- The generic machinery is the Lua host's: the filtered library, the export tables a VM holds, and a
-- loader that evaluates one import chain at a time on the owner's thread, suspending an importer on a
-- dependency's source ("Hetoimasia.Scripting.Lua.Loading"). The request protocol is the host's too:
-- atomic admission, assigned positions, the required-failure latch and the cancellation race
-- ("Hetoimasia.Scripting.Lua.Admission"). The reads are the content package's
-- ("Hetoimasia.Content.ReadPool"). This module is the M1 composition of the three, and holds what is
-- M1's alone: the identity cache's accounting, the source bank, the join of requests onto jobs and
-- the policy for when each thing happens.
--
-- It is a composable typed endpoint, not a Lua API. The eventual @api.content.module(path [, options])@
-- and the module-bound @import@ (LFE-12) parse their arguments, resolve the address through the
-- content boundary and call 'startModule' and the 'lookupImmediate' beside 'moduleArgumentCheck'.
-- The complete facade is not here, and no production fake provider, ambient filesystem loader or
-- game-specific code is.
--
-- = A job, and its waiters
--
-- A module is one /job/ for the VM, whoever names it: a request from an instance, a request from
-- another, an import discovered by a running module, a boot load. Concurrent requests join the job,
-- including requests from one instance, and the job reads, compiles and evaluates the module once,
-- publishing a complete export table or a sticky failure, never a partial export. Another VM has its
-- own coordinator, its own jobs, its own source accounting and its own exports.
--
-- Each external request is a /waiter/ of the job with its own request and result record, its
-- instance attribution and its own assigned position (a logical request's tick and sequence, fixed
-- when it was admitted; a presentation request settles on arrival). Cancelling a request, or ending
-- its instance, withdraws only that subscription. The job goes on: even with no waiters it reads
-- what it needs, evaluates at the earliest position any request contributed, and caches its outcome
-- until the VM stops. Its dependencies, source work, effects and logical delay are not cancelled by
-- the departure of whoever first asked.
--
-- = When a job evaluates
--
-- A logical job stands at the earliest position any admitted request contributed (it is never made
-- later when that request leaves, and an earlier waiter that joins moves a queued job up without
-- duplicating it). It starts only once the scheduler stands just before the job's tick, with every
-- earlier tick finished, and holds that tick until it has an outcome, so it finishes before any work
-- of its tick begins and a hook of that tick finds the cache complete. Roots due at one tick evaluate
-- in sequence order; a presentation VM evaluates independent roots in the order their requests were
-- admitted. Arriving source never starts a job, never lets a later job overtake an earlier one, and
-- never exposes an outcome early. A dependency requested for a later position is evaluated once,
-- within the chain that imports it, at the importer's position; its own request is answered with the
-- outcome at its own.
--
-- = Reads and the bank
--
-- Source is read by the pool's workers, which overlap, into a per-VM bank of 16 MiB of which 1 MiB is
-- reserved for the active chain's next source: prefetch may use the remainder only, so unrelated ready
-- sources can never starve a dependency the chain waits for. Reads that do not fit yet wait among the
-- admitted jobs, bounded by the identity cache; accepting a request never depends on them. The
-- coordinator holds a fixed number of pool slots for its life, one of which only the active chain
-- uses, so it never waits for capacity that only finishing the chain could release, and a worker
-- never waits for anything: its sink stores and hands over what it read and returns the slot.
--
-- = Limits and refusals
--
-- 256 identities per VM count pending, evaluating, ready and failed entries; a new module at a full
-- cache is refused before any work as an ordinary catchable limit error from the argument check, with
-- no failed entry allocated. A dependency discovered at the limit fails the chain that imported it
-- (an accepted load), as does a source or depth limit. Temporary pressure on request, result or
-- identity places is the host's busy answer with nothing reserved. There is no eviction, restart or
-- retry.
--
-- = Failures
--
-- A module's own failure is data: it fails the requests that wait for it, each at its own position,
-- with the code of the cause (@not_found@, @content_changed@, @io_error@, @too_large@,
-- @module_error@, @module_cycle@ or @module_limit@) and the content that failed. Nobody waiting, it is
-- a bounded diagnostic through the logger, once, and fails no instance. A defect of the engine, the
-- pool or a worker is not a module failure: it fails the owner, whatever its waiters.
module Hetoimasia.LuaEngine.Modules
  ( -- * The coordinator
    Coordinator
  , ModuleSpec (..)
  , ModuleSpecRefused (..)
  , PoolTooSmall (..)
  , ImportResolver
  , withModuleCoordinator
  , closeModuleCoordinator
  , attachLoader
  , awaitDrained
  , coordinatorLimits
  , Limits (..)
  , BankLimits (..)

    -- * What the owner is given
  , coordinatorPlan
  , coordinatorEndpoint
  , moduleEndpointName
  , moduleValueSchema

    -- * Requests
  , ModuleRequest (..)
  , moduleKey
  , moduleArguments
  , moduleAsk
  , startModule
  , ModuleStart (..)
  , moduleArgumentCheck
  , moduleCodes

    -- * Boot loads
  , BootTicket
  , BootOutcome (..)
  , BootRefusal (..)
  , bootModule
  , awaitBoot
  , pollBoot

    -- * Lookup and observation
  , ImmediateLookup (..)
  , lookupImmediate
  , ModuleFailure (..)
  , Counts (..)
  , Peaks (..)
  , Phase (..)
  , coordinatorCounts
  , ModuleDefect (..)

    -- * Identities
  , moduleIdentity
  , identityKey
  , moduleLabel
  ) where

import Hetoimasia.LuaEngine.Modules.Address (identityKey, moduleIdentity, moduleLabel)
import Hetoimasia.LuaEngine.Modules.Bank (BankLimits (..))
import Hetoimasia.LuaEngine.Modules.Failure (ModuleFailure (..), moduleCodes)
import Hetoimasia.LuaEngine.Modules.State (ImmediateLookup (..))
import Hetoimasia.LuaEngine.Modules.Types
  ( BootOutcome (..)
  , BootTicket
  , Coordinator
  , Counts (..)
  , ImportResolver
  , Limits (..)
  , ModuleDefect (..)
  , Peaks (..)
  , Phase (..)
  )
import Hetoimasia.LuaEngine.Modules.Wiring
