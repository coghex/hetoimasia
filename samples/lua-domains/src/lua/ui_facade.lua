-- The UI VM's initial chunk: the validation facade in front of the typed intention binding, and the
-- bookkeeping facade around the engine's lifecycle calls.
--
-- The typed binding checks its six integers against a schema, and a call with the wrong arity or a
-- value of the wrong type is a fault of the call that Lua's `pcall` cannot turn into an answer:
-- it fails the instance. The recoverable answers of the intention contract (`false, reason`) are
-- therefore given here, before the typed binding is reached. The facade checks the arity and that
-- every value is an integer; the binding checks the application's bounds and answers them.
--
-- Pausing and resuming gameplay go through the lifecycle grant the UI owner has for the gameplay owner.
-- The facade brackets each call with `control_raw.begin()` and `.finish()`: until it says it is done the
-- driver begins no tick, so the place the engine's assignment gives the request is never for a tick
-- that has begun by the time the engine admits it. The brackets never wait. The facade also keeps the
-- receipts of the requests the engine accepted, and reads each once, so a settlement is observed while this
-- instance lives.
--
-- The namespaces the chunk reads the bindings from are removed from the globals, so a script reaches the
-- typed binding and the lifecycle calls only through `intent.submit` and `control`.
local submit, malformed = intent_raw.submit, intent_raw.malformed
intent_raw = nil

local lifecycle, bookkeeping = lifecycle_raw, control_raw
lifecycle_raw = nil
control_raw = nil

local select, integer_type, pcall, error = select, math.type, pcall, error

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

control = {}

-- The receipts of accepted requests this instance has not read yet, oldest first.
local held = {}

local function request(operation)
  bookkeeping.begin()
  local present, runtime, owner, id = view.gameplay_tid()
  local ok, answer
  if present then
    ok, answer = pcall(lifecycle[operation], {runtime = runtime, owner = owner, id = id})
  else
    ok, answer = true, {accepted = false, refusal = "unknown_target"}
  end
  bookkeeping.finish()
  if not ok then
    error(answer, 0)
  end
  if answer.accepted then
    held[#held + 1] = answer.receipt
    bookkeeping.note(true, "")
    return true, nil
  end
  bookkeeping.note(false, answer.refusal)
  return false, answer.refusal
end

-- control.pause(), control.resume() -> accepted, refusal
function control.pause()
  return request("pause")
end

function control.resume()
  return request("resume")
end

-- control.settle(): read each held receipt once; a settlement is reported and the receipt given up.
function control.settle()
  local index = 1
  while index <= #held do
    local kind = lifecycle.result(held[index])
    if kind == "pending" then
      index = index + 1
    else
      bookkeeping.settled(kind)
      table.remove(held, index)
    end
  end
end
