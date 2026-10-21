-- The UI behavior: a Periodic instance on an elapsed cadence.
--
-- Each update says which status it sees (once, when it changes), reads the settlements of the controls it
-- has asked for, does what the scenario asks of it, and offers the fake input: first what it was answered
-- `full` for earlier, again, because it was not accepted, then the next entries of the source, at most
-- `limit` in all. It reads only the view: every query of one update answers from the one capture its
-- segment began with. An answer of `full` shows a busy indication (`ui.busy`); an intention is offered
-- again at most three times and never once it was accepted; an answer of `closed` ends the offering.
-- When it is done it says one update has completed.
--
-- `view`, `intent` and `control` (the facades), `input` and `ui` are the UI policy's namespaces; this VM
-- has no other.
local scenario = input.scenario()
local limit = 4
if scenario == "flood" then
  limit = 16
end

local retrying = {}
local last_status
local closed = false
local paused_asked, resumed_asked = false, false

-- Offer one intention from the current view; keep it to offer again if it was answered full.
local function offer(entity, dx, dy, attempts)
  local present, _, _, version = view.entity(entity)
  if not present then
    return
  end
  local accepted, reason = intent.submit(view.session(), view.tick(), entity, version, dx, dy)
  if not accepted then
    if reason == "full" then
      ui.busy()
      if attempts < 3 then
        retrying[#retrying + 1] = {entity, dx, dy, attempts + 1}
      end
    elseif reason == "closed" then
      closed = true
    end
  end
end

function update(self, dt)
  local status = view.status()
  if status ~= last_status then
    ui.saw(status)
    last_status = status
  end
  control.settle()

  if scenario == "pause" then
    local tick = view.tick()
    if not paused_asked and tick >= 4 then
      paused_asked = true
      control.pause()
    elseif paused_asked and not resumed_asked and tick >= 9 then
      resumed_asked = true
      control.resume()
    end
  end

  local offered = 0
  local waiting = retrying
  retrying = {}
  for position = 1, #waiting do
    local item = waiting[position]
    if offered >= limit or closed then
      retrying[#retrying + 1] = item
    else
      offered = offered + 1
      ui.retried()
      offer(item[1], item[2], item[3], item[4])
    end
  end
  while offered < limit and not closed do
    local more, entity, dx, dy = input.poll()
    if not more then
      break
    end
    offered = offered + 1
    offer(entity, dx, dy, 0)
  end
  ui.updated()
end
