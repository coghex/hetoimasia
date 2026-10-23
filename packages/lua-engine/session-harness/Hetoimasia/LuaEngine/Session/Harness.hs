-- | The harness's seams of the session coordinator: what a test composes to place a stop or a failure in
-- an exact window, to ask for the second instance of a role the design keeps for qualifying reusable
-- bindings, and to start the tick counter near the Lua integer ceiling.
--
-- None of it is reachable from a manifest, from Lua or from a real composition, which passes
-- 'Hetoimasia.LuaEngine.Session.noHarness'. A probe is told, on the thread that reaches the point, at
-- each named point of the session's life and may block (to hold a window open until a test has acted) or
-- raise (to inject a failure at that step); it is never called with a lock held that a stop needs.
module Hetoimasia.LuaEngine.Session.Harness
  ( Harness (..)
  , noHarness
  , Point (..)
  , BuildStep (..)
  , InstanceKey (..)
  ) where

import Hetoimasia.LuaEngine.Session.State (InstanceKey (..))
import Hetoimasia.LuaEngine.Session.Types
