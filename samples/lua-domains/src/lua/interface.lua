-- The UI behavior: a Periodic instance on an elapsed cadence.
--
-- Each update polls the fake input source (at most `limit` entries), and for each one reads the
-- entity in the view this segment was captured with and submits an intention carrying the view's
-- session, its committed tick, the entity and the entity's version in that view. It reads only the
-- view: every query of one update answers from the one capture its segment began with. When it is
-- done it says one update has completed.
--
-- `view`, `intent` (the facade), `input` and `ui` are the UI policy's namespaces; this VM has no
-- other.
local limit = 4

function update(self, dt)
  local polled = 0
  while polled < limit do
    local more, entity, dx, dy = input.poll()
    if not more then
      break
    end
    polled = polled + 1
    local present, _, _, version = view.entity(entity)
    if present then
      intent.submit(view.session(), view.tick(), entity, version, dx, dy)
    end
  end
  ui.updated()
end
