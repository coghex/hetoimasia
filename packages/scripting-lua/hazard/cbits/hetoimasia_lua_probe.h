/*
** Two fixtures the hazard runner needs and Haskell cannot provide.
**
** The first is a vantage point inside a pure-Lua interval. The question is
** whether Haskell work happened *while Lua was executing instructions*, as
** opposed to while Lua was inside one of this bridge's callbacks. Every signal
** Haskell can observe from a running chunk arrives through a callback, so every
** such signal is outside the interval being asked about. Lua's own count hook
** is inside it: this arms one and has it sample a counter Haskell advances,
** twice. Both samples are taken from within `luaV_execute` with nothing but Lua
** instructions between them, so growth between them happened while Lua was
** executing.
**
** The counter and the samples are read and written by two threads, so they are
** C11 atomics with release/acquire ordering, not plain memory with `volatile`.
**
** The second is a Lua state whose allocator fails on demand, which the `lua`
** package exposes no way to build. It is what proves that publishing a callback
** reports memory exhaustion instead of ending the process.
**
** Both are test fixtures. They live in the hazard runner, not in the bridge.
*/
#ifndef HETOIMASIA_LUA_PROBE_H
#define HETOIMASIA_LUA_PROBE_H

#include <lua.h>
#include <stddef.h>

/* Arm the hook on this state to sample the counter every `instructions` Lua
** instructions, keeping the first two samples, and reset the counter. */
void hetoimasia_lua_arm_probe(lua_State *L, int instructions);

/* Advance the counter, and answer its new value. */
long hetoimasia_lua_probe_advance(void);

/* The two samples, and how many were actually taken. */
int hetoimasia_lua_probe_samples(long *first, long *second);

/* Publish into a state whose allocator fails after `budget` allocations, then
** publish again on that same state with room to spare, close it, and report
** everything observed: the first status (returned), whether each publication
** took ownership of its stable pointer, the second status, and how many
** carriers the state finalized.
**
** Ownership and finalization together are the question. A caller frees only a
** pointer that was never acquired; a state finalizes exactly the carriers that
** were. The two counts agreeing at every budget is what says no intermediate
** failure left a carrier nothing would ever finalize. */
int hetoimasia_lua_publish_sweep(
  void *first, void *second, size_t budget,
  int *first_acquired, int *second_status, int *second_acquired, long *finalized);

#endif
