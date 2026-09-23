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

The canonical design is `exploring` under D-11. LUA-1 established the binding,
but LUA-14/LUA-15 delivered inconclusive
[Linux](lua_linux_confinement_verdict.md) and
[macOS](macos_confinement_verdict.md) confinement verdicts.
[Q-5](lua_runtime_design.md#q-5-verified-platform-confinement-and-resource-enforcement-profile)
and renewed readiness gate further issue processing; closing the proof issues did not
establish supported confinement. Resume in the canonical document, never this
pointer as a separate epic.
