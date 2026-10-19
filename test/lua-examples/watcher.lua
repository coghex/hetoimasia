-- An event-only watcher: it reacts to the runner's events about the other instances, printing each
-- as it is delivered, and stops itself once every other instance has ended or failed.
-- Reproduce, on logical ticks:
--   hetoimasia lua --tick 0.001 --ticks 20 \
--     --script test/lua-examples/watcher.lua --script test/lua-examples/oneshot.lua
function init(self, api)
  api.subscribe("instances", function(self, event)
    local payload = event.payload
    local line = "watcher: " .. payload.event .. " " .. payload.name
    if payload.outcome then line = line .. " " .. payload.outcome end
    print(line)
    if payload.event == "ended" then
      local me = lifecycle.self()
      local owner = lifecycle.owners().owners[1]
      local seen = lifecycle.inspect_owner({ runtime = owner.runtime, owner = owner.owner })
      for _, snapshot in ipairs(seen.instances) do
        local over = snapshot.status == "completed" or snapshot.status == "stopped" or snapshot.status == "failed"
        if snapshot.tid.id ~= me.id and not over then return end
      end
      print("watcher: every other instance has ended")
      lifecycle.stop(me)
    end
  end)
end
