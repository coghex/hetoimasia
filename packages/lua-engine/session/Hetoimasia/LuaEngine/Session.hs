-- | The M1 session coordinator (LFE-13): one or two roles' VMs composed into one session, how they
-- start, advance, fail and stop together.
--
-- = What a composition does
--
-- > outcome ← runSession spec $ \session → …   -- the handle: status, stop, terminal failure
--
-- 'runSession' takes the services a composition injects ('SessionSpec': the validated profile and boot
-- checkpoint, the anchored content and its read pool, the logger, the authored output, the monotonic
-- clock and its timer, the Lua runtime and its supervision control), hands the caller the 'Session'
-- handle before any VM exists, and runs the session to its end on the calling thread. That thread must be
-- the one that owns the supervision control, because the coordinator's waits are supervised ones; the
-- handle's endpoints are nonblocking and are safe from any thread, so a native event loop, a signal
-- handler or a future Lua binding never waits on a VM.
--
-- The session:
--
-- 1. builds each selected role's VM (a module coordinator, the data service, the facade, a scheduled
--    owner hosting instances) and evaluates its entry and imports, running no root;
-- 2. admits each role's root instance; no root's @init@ is dispatched until every selected entry,
--    export, hook and cadence has been validated, and then the roots' @init@s run on their own owners
--    without either waiting for the other;
-- 3. runs the presentation role from its own @init@'s success, and the gameplay role from the joint
--    start gate, with real-time ticks of exactly the manifest's duration, none skipped or shortened,
--    each followed by the owner's own accounting; and
-- 4. applies the failure policy, drains through actual retirement, and answers 'SessionOutcome'.
--
-- = The failure policy (D-42)
--
-- A failure of either @init@, or of the presentation role before the joint gate opens, is a boot
-- failure: admission closes, both owners are asked to stop and their pending interests withdrawn at once,
-- and no late success reopens a gate. After boot, a logical failure (a script error, a module, a required
-- request that failed, whether or not Lua ever looked at it) closes the logical role's admission and tick
-- grants and stops its work, while a healthy presentation role goes on with its own services until the
-- whole session exits. A presentation failure, the failure of a session's only role, and any engine,
-- host, provider, output or cleanup failure end the whole session. The first failure of a role stays
-- the role's failure whatever follows; an eventual stop cannot erase it; the outcome ranks failure over
-- interruption over a normal quit.
--
-- = What this module does not do
--
-- It installs no signal handler, exits no process and writes nothing to a standard stream: its
-- diagnostics are the logger's, and the bounded failure records are data for whoever composes it. It
-- adds no Lua binding (the status, quit and unavailable-state guard are LFE-26's, which consume the
-- endpoints below), no world, no progress channel and no event API.
module Hetoimasia.LuaEngine.Session
  ( -- * Running a session
    runSession
  , SessionSpec (..)
  , Harness
  , noHarness
  , SessionRefused (..)

    -- * The handle
  , Session
  , sessionStatus
  , sessionOutcomeNow
  , requestStop
  , latchTerminalFailure

    -- * What it publishes
  , StopKind (..)
  , Phase (..)
  , RoleStatus (..)
  , SessionStatus (..)
  , Verdict (..)
  , SessionOutcome (..)
  , FailureCode (..)
  , FailureStage (..)
  , RoleFailure (..)
  , newRoleFailure
  , codeWord
  , stageWord
  , roleWord
  , EngineEntry (..)
  , EngineReport (..)
  ) where

import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.Run
import Hetoimasia.LuaEngine.Session.State
import Hetoimasia.LuaEngine.Session.Types
