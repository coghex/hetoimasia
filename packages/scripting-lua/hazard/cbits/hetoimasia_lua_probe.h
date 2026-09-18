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

/* Publish a Haskell function into a state whose allocator fails after `budget`
** allocations, and answer the Lua status that came back. */
int hetoimasia_lua_publish_under_budget(void *function, size_t budget);

#endif
