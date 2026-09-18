#include "hetoimasia_lua_publish.h"

#include <lauxlib.h>

/*
** Two of the binding's own symbols. The `lua` package installs Lua's four
** headers and not its own, so the prototypes and the metatable's name are
** declared here; the symbols are the ones this program links.
**
** `hslua_call_hs` is the C closure Lua calls, which reaches Haskell through the
** binding's foreign export; the metatable named below is the one its userdata
** must carry, and carries the `__gc` that frees the stable pointer.
*/
#define HETOIMASIA_HSFUN_NAME "HsLuaFunction"

extern int hslua_call_hs(lua_State *L);

/*
** Everything that allocates, in one place, called through lua_pcall.
**
** The arguments arrive as values that cost nothing to push: the stable pointer,
** the name, and the ownership flag as light userdata, the length as an integer.
**
** The userdata is built here rather than through the binding's
** `hslua_newhsfunction`, for one reason: the exact instruction at which the
** stable pointer stops being the caller's to free. It is the store below, and
** nothing outside this function can observe it.
*/
static int publish_body(lua_State *L)
{
  HsStablePtr function = lua_touserdata(L, 1);
  const char *name = (const char *) lua_touserdata(L, 2);
  size_t length = (size_t) lua_tointeger(L, 3);
  int *acquired = (int *) lua_touserdata(L, 4);
  HsStablePtr *slot;

  lua_settop(L, 0);

  /* Allocates; a failure here leaves the pointer the caller's. */
  slot = (HsStablePtr *) lua_newuserdatauv(L, sizeof(HsStablePtr), 0);
  *slot = function;
  /* From this instruction the userdata's __gc owns it, whatever fails next. */
  *acquired = 1;

  luaL_setmetatable(L, HETOIMASIA_HSFUN_NAME);
  /* Allocates the closure. */
  lua_pushcclosure(L, hslua_call_hs, 1);
  lua_pushglobaltable(L);
  /* Allocates the key. */
  lua_pushlstring(L, name, length);
  lua_pushvalue(L, -3);
  /* Honours __newindex, exactly as setting a global does. */
  lua_settable(L, -3);
  return 0;
}

int hetoimasia_lua_publish(
  lua_State *L, HsStablePtr function, const char *name, size_t length, int *acquired)
{
  *acquired = 0;
  /* Room for the call and its four arguments. lua_checkstack reports failure
  ** rather than raising it, which is what lets it be asked from here at all. */
  if (!lua_checkstack(L, 8)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, publish_body);
  lua_pushlightuserdata(L, function);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  lua_pushlightuserdata(L, acquired);
  return lua_pcall(L, 4, 0, 0);
}
