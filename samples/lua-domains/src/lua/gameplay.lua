-- The gameplay behavior: a Periodic instance on `LogicalTicks 1`, so `update` runs once in every
-- tick the driver grants.
--
-- It reads the world the tick's candidate shows (the committed world with the tick's applied
-- intentions in it), draws from the application-owned stream every tick, stages one move, and says
-- its work is done. Staging changes nothing: the move is applied when the tick commits. It never
-- waits and never yields, so a tick's work ends inside the tick.
--
-- `world`, `staging` and `rand` are the namespaces gameplay's policy exposes; this VM has no other.
function update(self, dt)
  local count = world.count()
  local who = rand.below(count)
  local dx = rand.below(3) - 1
  local dy = rand.below(3) - 1
  staging.move(who, dx, dy)
  staging.finish()
end
