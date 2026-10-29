{-# LANGUAGE OverloadedStrings #-}

-- | The Lua the engine itself runs, before any authored code: the chunk that rebinds @print@ and
-- @warn@ and builds the facade, and the export module the facade's builder is handed through.
--
-- = What it is for, and what it is not
--
-- The bindings of the engine live in a hidden namespace ('engineNamespaceName'). The initial chunk
-- reads them into local names, removes the namespace from the globals, rebinds @print@ and @warn@ to
-- bounded writers, and defines the builder that makes a facade for one instance. The builder is
-- reachable once, through a global that the first call removes ('engineBuilderName'), and the export
-- module that takes it runs at initialization, before the owner loads or runs anything authored: after
-- that nothing a script can name reaches the namespace, the builder or the original @print@ and @warn@.
-- This is trusted-code hygiene and not hostile-code isolation (there is no @debug@ library and no
-- @load@, which is what keeps the locals out of reach).
--
-- A facade's functions are closures over their instance's identity. Each calls the engine's @check@
-- binding with that identity first, which refuses a facade used by another instance or from a module's
-- top level, and then the binding that does the work, with the caller's arguments unchanged so that
-- the host's own arity and type refusals are the call's. The two optional-argument calls pass an
-- omitted optional as an explicit nil, which is how the host counts it.
module Hetoimasia.LuaEngine.Facade.Source
  ( engineChunk
  , engineChunkName
  , builderSource
  , builderIdentity
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade.Types (engineBuilderName, engineNamespaceName, stateUnavailableMessage)
import Hetoimasia.Scripting.Lua.Output (renderFunctionLinesWith)
import Hetoimasia.Scripting.Lua.Owner (ChunkName, ExportIdentity (ExportIdentity), ExportSource (..), chunkName)

-- | The name the initial chunk is loaded under.
engineChunkName ∷ ChunkName
engineChunkName = chunkName "hetoimasia-engine"

-- | The identity of the builder's export module. It cannot be a module identity: those begin with
-- the length of a root, at most 128, and this begins with a byte past it.
builderIdentity ∷ ExportIdentity
builderIdentity = ExportIdentity "\255hetoimasia-engine/facade"

-- | The export module the builder is taken from: one table, holding the builder under @build@.
builderSource ∷ ExportSource
builderSource =
  ExportSource
    { exportIdentity = builderIdentity
    , exportLabel = "hetoimasia-engine/facade"
    , exportText = Text.encodeUtf8 ("return { build = " <> engineBuilderName <> "() }")
    }

-- | The initial chunk, for a call that writes at most this many bytes.
engineChunk ∷ Int → ByteString
engineChunk limit = Text.encodeUtf8 (Text.unlines (prelude <> renderFunctionLinesWith limit <> body))
  where
    ns = engineNamespaceName
    prelude =
      [ "local E = " <> ns
      , ns <> " = nil"
      , "local tostring, concat, select, sub = tostring, table.concat, select, string.sub"
      ]
    body ∷ [Text]
    body =
      [ "local out, err = E.out, E.err"
      , "print = function(...) out(render('', ...)) end"
      , "warn = function(...) err(render('', ...)) end"
      , "local bind, check = E.bind, E.check"
      , "local content_module, content_data = E.content_module, E.content_data"
      , "local module_ops = { ready = E.ready_module, take = E.take_module, cancel = E.cancel_module, wait = E.wait_module }"
      , "local data_ops = { ready = E.ready_data, take = E.take_data, cancel = E.cancel_data, wait = E.wait_data }"
      , "local tick, tick_seconds, seconds = E.tick, E.tick_seconds, E.seconds"
      , "local prepare_ticks, wait_ticks = E.prepare_wait_ticks, E.wait_ticks"
      , "local prepare_seconds, wait_seconds = E.prepare_wait_seconds, E.wait_seconds"
      , "local yield = E.yield"
      , "local session_status, session_quit, unavailable = E.session_status, E.session_quit, E.state_unavailable"
      , "local error = error"
      , -- The unavailable-state guard (LFE-26). It names no parameter and reads no argument: whatever a script
        -- passes is dropped unread, and nothing it passes can run. The engine binding latches the whole
        -- session's failure and stop first (and writes the one diagnostic); only then is the error raised, with
        -- the fixed text and no position. It is a global before any authored module is evaluated, and the
        -- same closure is every facade's @state@, so a captured facade grants it nothing it did not have.
        "local function terminal(...)"
      , "  unavailable()"
      , "  error(\"" <> stateUnavailableMessage <> "\", 0)"
      , "end"
      , "state = terminal"
      , "local function build(ctx)"
      , "  local id = ctx.instance_id"
      , "  bind(id)"
      , "  local function guard(f)"
      , "    return function(...)"
      , "      check(id)"
      , "      return f(...)"
      , "    end"
      , "  end"
      , "  local kinds = setmetatable({}, { __mode = 'k' })"
      , "  local function starter(f, ops)"
      , "    return function(...)"
      , "      check(id)"
      , "      local request, refusal"
      , "      if select('#', ...) == 1 then request, refusal = f((...), nil) else request, refusal = f(...) end"
      , "      if request ~= nil then kinds[request] = ops end"
      , "      return request, refusal"
      , "    end"
      , "  end"
      , "  local function operation(name)"
      , "    return function(...)"
      , "      check(id)"
      , "      return (kinds[(...)] or data_ops)[name](...)"
      , "    end"
      , "  end"
      , "  return {"
      , "    role = ctx.role,"
      , "    content_id = ctx.content_id,"
      , "    instance_id = id,"
      , "    content = { module = starter(content_module, module_ops), data = starter(content_data, data_ops) },"
      , "    request = {"
      , "      ready = operation('ready'),"
      , "      take = operation('take'),"
      , "      cancel = operation('cancel'),"
      , "      wait = operation('wait'),"
      , "    },"
      , "    session = { status = guard(session_status), quit = guard(session_quit) },"
      , "    state = terminal,"
      , "    time = {"
      , "      tick = guard(tick),"
      , "      tick_seconds = guard(tick_seconds),"
      , "      seconds = guard(seconds),"
      , "      wait_ticks = function(...)"
      , "        check(id)"
      , "        return wait_ticks(prepare_ticks(...))"
      , "      end,"
      , "      wait_seconds = function(...)"
      , "        check(id)"
      , "        local high, low = prepare_seconds(...)"
      , "        return wait_seconds(high, low)"
      , "      end,"
      , "      yield = guard(yield),"
      , "    },"
      , "  }"
      , "end"
      , "local pending = build"
      , engineBuilderName <> " = function()"
      , "  local taken = pending"
      , "  pending = nil"
      , "  " <> engineBuilderName <> " = nil"
      , "  return taken"
      , "end"
      ]
