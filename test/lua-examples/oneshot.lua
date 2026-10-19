-- A one-shot: its run hook executes once, to completion, and the instance ends.
-- Reproduce: hetoimasia lua --script test/lua-examples/oneshot.lua
function run(self)
  print("one-shot: hello from run")
end
