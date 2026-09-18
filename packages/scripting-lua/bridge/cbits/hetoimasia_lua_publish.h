/*
** Publishing a Haskell function as a Lua global, and the C side of calling one
** back.
**
** This package owns the callback path rather than using the binding's, for two
** reasons it could not work around from outside.
**
** The first is allocation. Publication allocates twice -- the userdata that
** carries the Haskell function, and the string that names it -- and an
** allocation failure in Lua is a Lua error. Raised from a call Haskell made
** directly it finds no protected frame, reaches Lua's panic function, and ends
** the process; the binding's own `hslua_setglobal` pushes its key before
** entering its internal protected call, so it has that exposure. Here the whole
** publication is one `lua_pcall`, and nothing that could allocate crosses into
** it: the arguments go in as light userdata and an integer.
**
** The second is cancellation. The binding reaches Haskell through its own
** foreign export and runs more of its own Haskell after the called function
** returns; an asynchronous exception delivered in that stretch unwinds through
** a C frame and ends the process, and it is not code this package can mask.
** `hetoimasia_lua_enter` is this package's export, so the only Haskell between
** Lua calling in and the callback thread ending is its own, and all of it is
** masked but the callback's action.
**
** The error protocol is correspondingly this package's: a negative result count
** means the value on top is the failure marker, and `lua_error` is raised from
** C once every Haskell frame has returned.
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
