-- Appended to every gameplay module (after the script's own code).
--
-- The update wrapper: if the script defined an `update`, it is replaced by one that first says, through the
-- application's own binding, that an update began in this tick, and then runs the script's. A tick whose update
-- never began (the behavior is paused, or this is the tick that resumes it) is therefore told apart, by the
-- application and not by guessing from the engine's counters, from one whose update began and never finished.
if type(update) == "function" then
  local scripted = update
  function update(...)
    staging.began()
    return scripted(...)
  end
end
