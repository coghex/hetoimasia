/*
** Publishing a Haskell function as a Lua global, with every allocation inside
** a protected Lua call.
**
** Publication allocates twice: the userdata that carries the Haskell function,
** and the string that names it. Either can fail, and a Lua allocation failure
** is a Lua error. Raised from a call Haskell made directly, that error finds no
** protected frame, reaches Lua's panic function, and ends the process; the
** binding's own `hslua_setglobal` pushes its key before entering its internal
** protected call, so it has the same exposure.
**
** So the whole of it runs inside one `lua_pcall` here, and the caller is
** answered with a status. Nothing crosses into this file that could allocate on
** the way: the arguments are a light userdata, a pointer, and an integer.
*/
#ifndef HETOIMASIA_LUA_PUBLISH_H
#define HETOIMASIA_LUA_PUBLISH_H

#include <HsFFI.h>
#include <lua.h>
#include <stddef.h>

/*
** Set `name` in the globals table to a Lua function backed by `function`.
**
** Answers a Lua status code. On failure the error value is left on the stack,
** for the caller to render and clear as it does for any other failed call.
*/
int hetoimasia_lua_publish(lua_State *L, HsStablePtr function, const char *name, size_t length);

#endif
