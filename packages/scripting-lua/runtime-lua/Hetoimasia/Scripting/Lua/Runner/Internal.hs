-- | What only a test, and the slice that adds the runner's events (LUA-28), reaches.
--
-- The runner's public configuration ('Hetoimasia.Scripting.Lua.Runner.RunnerConfig') offers
-- no event source, no subscription grant and no bindings of an application's own: the runner
-- hosts instances that can only be started, stopped and ended, as the contract of LUA-27 has it.
-- A callback is therefore never invoked in a public run, and the examples that cover a callback's
-- failure, output and shutdown order need an event to deliver and bindings to record through. This
-- module runs the same run, through the same reporting and output, with those added to the owner
-- and told, once the instances are admitted, the owner's endpoint and the instances' identities
-- to deliver to.
--
-- It is not part of the runner's contract, and nothing here is a way to configure a production
-- run.
module Hetoimasia.Scripting.Lua.Runner.Internal
  ( RunnerInternals (..)
  , noInternals
  , RunnerBug (..)
  , runScriptsWith
  , moduleRefFor
  , outputLines

    -- * The events and what decides them
  , AnswerClass (..)
  , Refusal (..)
  , EventDefect (..)
  , classifyAnswer
  , InstanceEvent (..)
  , eventValue
  , eventSchema
  , Registry
  , newRegistry
  , instancesEndpoint
  , produceEvents
  , Place (..)
  , tallyOf
  , busy
  , quiet
  , Gate
  , newGate
  , gateWait
  , holdGate
  , freeGate
  , permitOne
  , gateParked
  ) where

import Hetoimasia.Scripting.Lua.Runner.Events (AnswerClass (..), EventDefect (..), InstanceEvent (..), Place (..), Refusal (..), Registry, classifyAnswer, eventSchema, eventValue, instancesEndpoint, newRegistry, produceEvents, tallyOf)
import Hetoimasia.Scripting.Lua.Runner.Gate (Gate, busy, gateParked, gateWait, holdGate, newGate, freeGate, permitOne, quiet)

import Hetoimasia.Scripting.Lua.Runner.Run (RunnerBug (..), RunnerInternals (..), noInternals, runWith)
import Hetoimasia.Scripting.Lua.Runner.Render (outputLines)
import Hetoimasia.Scripting.Lua.Runner.Source (moduleRefFor)
import Hetoimasia.Scripting.Lua.Runner.Types (RunOutcome, RunnerConfig)
import Hetoimasia.Scripting.Lua.Runtime.Shared (LuaRuntime)

-- | 'Hetoimasia.Scripting.Lua.Runner.runScripts' with these seams.
runScriptsWith ∷ RunnerInternals → LuaRuntime → RunnerConfig → IO RunOutcome
runScriptsWith = runWith
