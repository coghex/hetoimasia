-- The UI VM's initial chunk: the validation facade in front of the typed intention binding.
--
-- The typed binding checks its six integers against a schema, and a call with the wrong arity or a
-- value of the wrong type is a fault of the call that Lua's `pcall` cannot turn into an answer:
-- it fails the instance. The recoverable answers of the intention contract (`false, reason`) are
-- therefore given here, before the typed binding is reached. The facade checks the arity and that
-- every value is an integer; the binding checks the application's bounds and answers them.
--
-- The namespace the chunk reads the bindings from is removed from the globals, so a script
-- reaches the typed binding only through `intent.submit`.
local submit, malformed = intent_raw.submit, intent_raw.malformed
intent_raw = nil

local select, integer_type = select, math.type

intent = {}

-- intent.submit(session, tick, entity, version, dx, dy) -> accepted, reason
function intent.submit(...)
  if select('#', ...) ~= 6 then
    malformed()
    return false, "malformed"
  end
  for position = 1, 6 do
    if integer_type((select(position, ...))) ~= "integer" then
      malformed()
      return false, "malformed"
    end
  end
  return submit(...)
end
