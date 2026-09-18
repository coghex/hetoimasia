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
**
** `acquired` is set to 1 the moment the stable pointer becomes the userdata's
** to free, and left at 0 if it never did. Ownership is not something the caller
** can infer from the status: the allocation that creates the userdata and the
** one that wraps it in a closure can each fail, and only the second of them
** leaves an owner behind. Free the pointer when, and only when, this reports 0.
*/
int hetoimasia_lua_publish(
  lua_State *L, HsStablePtr function, const char *name, size_t length, int *acquired);

#endif
