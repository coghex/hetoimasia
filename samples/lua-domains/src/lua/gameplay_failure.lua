
-- The `failure` scenario's gameplay behavior: the one above, which raises at tick six. It is appended to
-- `gameplay.lua`, so `update` below wraps the normal one.
local normal = update

function update(self, dt)
  if world.tick() == 6 then
    error("scripted failure at tick 6")
  end
  normal(self, dt)
end
