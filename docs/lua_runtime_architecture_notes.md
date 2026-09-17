# Lua runtime architecture notes — superseded

Use [Lua scripting runtime design](lua_runtime_design.md) for further design
and eventual issue processing. It replaces this exploratory handoff and records
the accepted decisions, Synarchy evidence, runtime boundaries, delivery slices,
and deferred simulation/persistence ideas.

The canonical design now requires independent UI and gameplay execution in its
first system milestone, plus untrusted-mod isolation per mod and execution
domain. It also records the owner's restricted-capability, enforced-limit, and
failed-gameplay-session policies. The earlier suggestion to defer those choices
is no longer the implementation plan.

The canonical design is now `ready for issue processing` under D-11's staged
plan. Binding and platform confinement remain technical proof gates: LUA-1
establishes the binding baseline and LUA-14/LUA-15 must both succeed before
dependent process work is drafted. Process the canonical document, never this
pointer as a separate epic.
