-- A controller: a looped instance that pauses, resumes and then stops another instance, named
-- "looped", through the lifecycle controls the runner grants every script, and then stops itself.
-- Reproduce, on logical ticks so the output is the same on every run:
--   hetoimasia lua --tick 0.001 --ticks 40 \
--     --script test/lua-examples/looped.lua --every-ticks 1 \
--     --script test/lua-examples/controller.lua --every-ticks 3
local function find(name)
  local owner = lifecycle.owners().owners[1]
  local seen = lifecycle.inspect_owner({ runtime = owner.runtime, owner = owner.owner })
  for _, snapshot in ipairs(seen.instances) do
    if snapshot.name == name then return snapshot.tid end
  end
end

local step = 0

function update(self, dt)
  step = step + 1
  local target = find("looped")
  if step == 1 then
    print("controller: pause looped")
    lifecycle.pause(target)
  elseif step == 2 then
    print("controller: resume looped")
    lifecycle.resume(target)
  elseif step == 3 then
    print("controller: stop looped, then myself")
    lifecycle.stop(target)
    lifecycle.stop(lifecycle.self())
  end
end
