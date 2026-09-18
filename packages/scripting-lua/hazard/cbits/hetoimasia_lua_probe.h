/*
** A sampling hook for the independent-progress example, and nothing else.
**
** The question it answers cannot be answered from Haskell: did Haskell work
** happen *while Lua was executing instructions*, as opposed to while Lua was
** inside one of this bridge's callbacks? Every signal Haskell can observe comes
** from a callback, so every such signal is outside the interval being asked
** about.
**
** Lua's own count hook is inside it. This arms one and has it sample a counter
** Haskell increments, twice. Both samples are taken from within
** `luaV_execute`, with nothing but Lua instructions between them, so growth
** between them happened while Lua was executing and could not have happened in
** a callback.
**
** This is a test fixture. It lives in the hazard runner, not in the bridge.
*/
#ifndef HETOIMASIA_LUA_PROBE_H
#define HETOIMASIA_LUA_PROBE_H

#include <lua.h>

/* Arm the hook on this state to sample `counter` every `instructions` Lua
** instructions, keeping the first two samples. */
void hetoimasia_lua_arm_probe(lua_State *L, volatile long *counter, int instructions);

/* The two samples, and how many were actually taken. */
int hetoimasia_lua_probe_samples(long *first, long *second);

#endif
