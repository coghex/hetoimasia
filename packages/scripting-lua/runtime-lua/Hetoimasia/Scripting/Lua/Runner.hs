-- | Running Lua sources to completion: the reusable runner (LUA-27).
--
-- 'runScripts' runs a list of scripts, each a file, as instances of one named VM on the elapsed
-- clock, and answers a bounded report of the run. It is the library the @lua@ subcommand (LUA-19)
-- and a future windowed application both use, and the layer LUA-28 extends with logical ticks and
-- the instances' start and end events. It parses no arguments, installs no signal handler, never
-- calls @exit@, opens no window and imports nothing of the console, GLFW, Vulkan or a game: what
-- the outside world does is injected ('RunnerConfig').
--
-- = A run
--
-- 1. The arguments are checked for usage that needs no VM ('UsageRefusal'), and a stop request
--    that is already set ends the run as stopped before anything is read or started.
-- 2. Each distinct path is read once, in order, and handed to the host as one module. A file that
--    cannot be read, one over the host's source limit, and a module the host rejects (a syntax
--    error, an error at its top level) are each a /source that did not load/: the run ends with
--    'EndedStartupFailure' and a 'LoadFailure' naming the file, the VM, the error and the
--    traceback, and no TID. The first of them in script order is the one reported, and the top
--    level of the modules before it has run, as the host's load order has it; no instance is
--    admitted and no @init@, @run@, @update@, callback or @shutdown@ runs. The VM is retired.
-- 3. The owner asks which hooks each module defines ('Hetoimasia.Scripting.Lua.Instance.moduleHooks'),
--    running none of the module's code. A module defining @run@ is a one-shot, one defining
--    @update@ a looped instance on the script's interval, one defining neither an event-only
--    instance. A module defining both, one defining @update@ whose script has no interval, and a
--    script with an interval whose module defines no @update@ are refused as usage, naming the
--    script. The VM that was started to ask is retired and nothing was admitted.
-- 4. The instances are admitted, in script order, so their numbers ascend in it. The run's clock
--    starts: the /origin/ of the run limit is the instant read just before the first admission.
-- 5. When every instance has left its initialization (or ended without it), the start table is
--    written. Failures are written as they settle.
-- 6. The run ends at the first of: every instance has ended; the stop request fires; the limit is
--    reached. Whatever the end, every instance still unended is stopped in ascending TID order,
--    each @shutdown@ running once with reason @stopped@ if its module defines one, and then the VM
--    is retired. The end table is written, after the failures not yet written.
--
-- = Waiting
--
-- A run waits in one place: a single STM wait, composed with supervision, that sees a failure of
-- the owner as soon as supervision commits it, a failure to write, the start-table barrier, every
-- instance having ended, the stop request and the timer's wake. It polls nothing. When several are
-- ready together the order of precedence is the contract: a failure to write, then the start
-- table, then /every instance ended/, then /the stop request/, then /the limit/. So a run in which
-- every instance ended, and the stop request and the limit are also due, ended by itself
-- ('EndedAllInstances'), one the stop request and the limit both end is 'EndedStopRequest', and the
-- limit only ends a run nothing else has. The limit is waited for on the injected timer, whose
-- wake only tells the run to look at its clock again: an early or a stale wake finds the deadline
-- not reached and arms again. The timer's registration is cancelled on every way out of the run,
-- and a limit too large for the clock's range is one that is never reached.
--
-- = The VM
--
-- It opens the base, string, table, math and coroutine libraries and no other: @io@, @os@,
-- @package@ and @debug@ stay closed. The policy is @fifo@, the only built-in one. The scheduler
-- and instance bounds are the runner's own constants ('runnerSchedulerBounds',
-- 'runnerInstanceBounds'): a run admits at most 'runnerMaxScripts' scripts. The owner hosts
-- instances with no event source, no request service, no subscription grant and no tick
-- duration, and admits controls on arrival; every instance's failure is isolated from the others
-- ('Hetoimasia.Scripting.Lua.Instance.Isolate'). The lifecycle bindings are registered under the
-- name 'runnerLifecycleName' and the owner is granted every control and inspection permit over its
-- own VM's instances and nothing else, so one script can pause, resume, stop and inspect another,
-- and itself. Scripts are trusted: nothing here claims a sandbox.
--
-- = Output
--
-- Before any module loads, @print@ and @warn@ are rebound to bindings that write through Haskell,
-- and nothing a script runs writes to the process's C streams. @print@ writes to the output sink
-- and @warn@ (with the prefix @Lua warning: @) to the error sink, from a module's top level,
-- @init@, @run@, @update@, a callback and @shutdown@ alike. One call writes at most
-- 'outputCallLimit' bytes of UTF-8 in all, as it is written (each line counting one byte more for
-- its end), cut with a visible marker that is counted; any Lua string is accepted, including invalid
-- UTF-8 and embedded NUL bytes, which are replaced as the stream rules below say.
--
-- The stream rules: a sink is handed one line at a time, with no line break and no control
-- character in it but a tab; a script's text and every other text a script can influence (a name,
-- an error message, a traceback, a path) has its control characters replaced by @\\xNN@ escapes
-- and is then cut to a documented bound, which therefore holds for what is written and not for what
-- was passed before the replacement made it longer; so none can split a table or a report into forged
-- lines. The
-- runner holds one lock around every write of a table, a report or a call's lines, so a sink is
-- never called by two threads at once and a table is never cut by a script's output. The
-- /output sink/ receives the scripts' @print@ and the tables; the /error sink/ the scripts' @warn@
-- and the failure reports. The runner's own diagnostics go to the logger, under the component
-- @scripting.lua.runner@, and script output, tables and reports never do.
--
-- = The table
--
-- At the start and at the end the runner writes a title line (@instances at start@, @instances at
-- end@) and then the table of D-17: a header @TID OWNER NAME STATUS@ and a row for each instance
-- of the run, ended ones included, in ascending TID order. A TID has one text form
-- ('tidText'): the runtime's number, the owner's and the instance's, separated by dots, the three
-- integers a script reads from @lifecycle.self@ and @lifecycle.inspect@. The status is the
-- lifecycle snapshot's word: @initializing@, @active@, @paused@, @stopping@, @completed@, @stopped@
-- or @failed@. The owner and name columns are cut to 'columnLimit' characters with a visible
-- marker; a row holds no control character; a run that admitted no instance writes no table.
--
-- The start table is one coherent snapshot taken once every admitted instance has finished its
-- @init@ or failed it, or became terminal without its @init@ having run (a stop of an instance the
-- owner had not begun discards it, and nothing waits for an initializer that will never execute).
-- Every admitted instance is a row, including one that completed or failed before the last
-- initializer finished: the run reads an instance's settlement without observing it, so the owner's
-- inspection keeps it. A run asked to end before the barrier opens writes no start table. The end
-- table is taken after the VM is retired and shows each instance's final status.
--
-- = Failures
--
-- An instance's failure is written to the error sink as one report as soon as it settles
-- ('failureLines'), and is in the run report ('EndFailed'). A report names the TID, the VM, the
-- instance's name and script, the phase, the stage (@init@, @run@, @update@, @event <source>@,
-- @shutdown@, @release@), the error and the traceback if one was captured, each bounded, and up to
-- 'secondaryLimit' other failures that happened while the instance ended. A failed @init@ runs none
-- of the instance's later hooks; a failure in @run@, @update@ or a callback runs its @shutdown@
-- once with reason @failed@; a failing @shutdown@ is kept, a primary failure stays primary, and the
-- others are listed. Every failure is written exactly once whichever wake or ending finds it, and
-- failures settled together are written in ascending TID order, all before the end table.
--
-- A failure of the /host/ is not an instance's failure and is never turned into a report: an
-- exception a binding or a sink raised, one the runner itself raised and a retained cleanup
-- failure propagate unchanged, with their type and context, under the owner's policy. A host
-- failure inside the owner ends the owner, which retires protected: Lua is not entered again, so
-- the instances it left keep 'Hetoimasia.Scripting.Lua.Instance.ShutdownSkippedUnsafe' (and one
-- whose @init@ had not succeeded 'Hetoimasia.Scripting.Lua.Instance.ShutdownSkippedNoInit'). One raised
-- on the runner's own thread, a sink's while a table is written, retires the owner first, in order, as
-- the run's end would. The retirement is complete before any failure propagates, whoever latched it:
-- the run asks the owner to stop and waits for the owner's worker to have ended (its raw completion,
-- which supervision's latch of another worker's failure never makes unavailable), so what a run's sinks
-- and bindings are borrowed from is not released while the owner's Lua still uses them. That wait is
-- for arbitrary Lua segments and shutdown hooks, so it is interruptible and never runs under an
-- uninterruptible mask: a cancellation of the runner's thread reaches it, and what it interrupts keeps
-- the failure that was already propagating beside it as evidence. The wait does not raise the owner's
-- failure again: supervision delivers it, to the next supervised wait and at the boundary's exit beside
-- the body's own. When failures arise together the first is the primary and the rest are kept whole as
-- evidence beside it; a single failure is never recorded again as a failure of cleanup.
--
-- = The report and the status
--
-- A run answers 'Refused' for a usage refusal, a result distinct from a report so that a command
-- line can map it, or 'Ran' with a bounded 'RunReport': how the run ended ('RunEnding'), each
-- instance's report, the 'LoadFailure' if a source did not load, and the 'RunStatus'. The status
-- is 'StatusFailure' if any instance failed or a source did not load; otherwise
-- 'StatusInterrupted' if the stop request ended the run; otherwise 'StatusSuccess'. A limit, a Lua
-- control, and every instance completing are success. Exit numbers are the command line's.
module Hetoimasia.Scripting.Lua.Runner
  ( -- * Running
    runScripts

    -- * What a run is given
  , Script (..)
  , script
  , everyTicks
  , RunnerConfig (..)
  , runnerConfig

    -- * What a run answers
  , RunOutcome (..)
  , RunReport (..)
  , RunEnding (..)
  , RunStatus (..)
  , EventTally (..)
  , noTally
  , runStatusOf
  , InstanceReport (..)
  , InstanceEnd (..)
  , FailureReport (..)
  , SecondaryFailure (..)
  , LoadFailure (..)
  , LoadProblem (..)

    -- * Usage refusals
  , UsageRefusal (..)
  , UsageViolation (..)
  , UsageReason (..)
  , usageText

    -- * Text forms and the writers' lines
  , tidText
  , phaseWord
  , failureLines
  , loadFailureLines
  , tableLines
  , TableRow (..)
  , startTitle
  , endTitle

    -- * Bounds and names
  , runnerMaxScripts
  , runnerInstanceBounds
  , runnerSchedulerBounds
  , runnerLifecycleName
  , runnerEventsName
  , runnerSubscriptionBound
  , runnerStagingBound
  , outputCallLimit
  , truncationMarker
  , columnLimit
  , secondaryLimit
  , errorLimit
  , tracebackLimit
  , nameLimit
  , pathLimit

    -- * The runtime a run is started in
  , LuaRuntime
  ) where

import Hetoimasia.Scripting.Lua.Runner.Render
import Hetoimasia.Scripting.Lua.Runner.Run (noInternals, runWith)
import Hetoimasia.Scripting.Lua.Runner.Types
import Hetoimasia.Scripting.Lua.Runtime.Shared (LuaRuntime)

-- | Run the scripts, as the module header describes.
--
-- The runtime is the one a 'Hetoimasia.Runtime.Supervision.withSupervision' boundary made
-- ('Hetoimasia.Scripting.Lua.Runtime.newLuaRuntime'); the owner the run starts is one of its
-- workers, under supervision's policy, and a failure of the host propagates from this call as
-- supervision decides. Raises nothing for a usage or a source problem, which are answers. Do not
-- call it from a Lua callback.
runScripts ∷ LuaRuntime → RunnerConfig → IO RunOutcome
runScripts = runWith noInternals
