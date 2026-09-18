/*
** The Lua operations this package performs itself, and why each one is here
** rather than taken from the binding.
**
** Every one of them allocates, and an allocation failure in Lua is a Lua error.
** Raised from a call Haskell made directly it finds no protected frame, reaches
** Lua's panic function, and ends the process. The binding's own wrappers put
** their protected call *after* the allocation that builds their arguments --
** `hslua_setglobal`, `hslua_getglobal`, and `hsluaL_requiref` each push a name
** with `lua_pushlstring` before entering `lua_pcall` -- so using them leaves the
** first allocation of every such operation unprotected. Here the whole
** operation is one `lua_pcall`, and nothing that could allocate crosses into
** it: the arguments go in as light userdata, C functions, and integers.
**
** Creating the state is the same question with a different answer: it cannot be
** protected, because there is no state to protect it with, so it uses the entry
** that reports failure by returning NULL instead of raising.
**
** The callback path is this package's for a second reason. The binding reaches
** Haskell through its own foreign export and runs more of its own Haskell after
** the called function returns; an asynchronous exception delivered in that
** stretch unwinds through a C frame. `hetoimasia_lua_enter` is this package's
** export, so the only Haskell between Lua calling in and the callback thread
** ending is its own. That narrows the window; it does not close it, and the
** contract does not pretend otherwise -- a callback thread is not a supported
** cancellation endpoint. See the package README.
**
** The error protocol is correspondingly this package's: a negative result count
** means the value on top is the failure marker, and `lua_error` is raised from
** C once every Haskell frame has returned.
*/
#ifndef HETOIMASIA_LUA_BRIDGE_H
#define HETOIMASIA_LUA_BRIDGE_H

#include <HsFFI.h>
#include <lua.h>
#include <stddef.h>

/*
** A new interpreter, or NULL if one could not be allocated.
**
** Nothing is registered in it: this package's carrier metatable is built on
** first use, inside a protected call, and its error protocol needs no registry
** entry.
*/
lua_State *hetoimasia_lua_newstate(void);

/*
** Set `name` in the globals table to a Lua function backed by `function`.
**
** Answers a Lua status code. On failure the error value is left on the stack,
** for the caller to render and clear as it does for any other failed call.
**
** `acquired` is set to 1 once the stable pointer is the carrier's to free, and
** left at 0 if it never became so. Ownership is not something the caller can
** infer from the status: several allocations can fail on this path and only
** some of them leave an owner behind. Free the pointer when, and only when,
** this reports 0.
*/
int hetoimasia_lua_publish(
  lua_State *L, HsStablePtr function, const char *name, size_t length, int *acquired);

/*
** Read a global, leaving its value on the stack.
**
** Answers a Lua status code, and sets `type` to the value's Lua type when it
** succeeded. Reading a global runs `__index` if the globals table has one, so
** this can fail for the same reasons any call can.
*/
int hetoimasia_lua_getglobal(
  lua_State *L, const char *name, size_t length, int *type);

/*
** Open one standard library under `name`, as `require` would, leaving the
** module on the stack.
*/
int hetoimasia_lua_requiref(
  lua_State *L, const char *name, lua_CFunction opener, int global);

/*
** How many carriers this process has finalized.
**
** For this package's own fixtures: publishing exactly as many carriers as are
** finalized is what "the stable pointer is freed exactly once" looks like from
** outside.
*/
long hetoimasia_lua_carriers_finalized(void);

#endif
