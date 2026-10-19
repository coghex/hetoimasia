-- A looped instance: its update hook runs at the script's interval, until the instance is stopped.
-- It prints each update and its shutdown, so the controller example shows pause, resume and stop.
-- Reproduce: see controller.lua.
local count = 0

function update(self, dt)
  count = count + 1
  print("looped: update " .. count)
end

function shutdown(self, reason)
  print("looped: shutdown " .. reason)
end
