
-- Appended to every gameplay module: the entry point of the fence task the driver admits after each tick
-- (see `Hetoimasia.Sample.LuaDomains.Domains`). It does nothing, and that is the point: the owner runs it
-- only after everything the tick left to do, so its settlement says the owner has done that.
function sample_fence()
end
