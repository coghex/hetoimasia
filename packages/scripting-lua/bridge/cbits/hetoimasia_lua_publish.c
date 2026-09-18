#include "hetoimasia_lua_publish.h"

#include <lauxlib.h>

/*
** The binding's own constructor for a Lua function backed by a Haskell one.
** The `lua` package installs Lua's four headers and not its own, so the
** prototype is declared here; the symbol is the one this program links.
*/
extern void hslua_newhsfunction(lua_State *L, HsStablePtr function);

/*
** Everything that allocates, in one place, called through lua_pcall.
**
** The arguments arrive as values that cost nothing to push: the stable pointer
** and the name as light userdata, the length as an integer.
*/
static int publish_body(lua_State *L)
{
  HsStablePtr function = lua_touserdata(L, 1);
  const char *name = (const char *) lua_touserdata(L, 2);
  size_t length = (size_t) lua_tointeger(L, 3);

  lua_settop(L, 0);
  /* Allocates the userdata that owns the stable pointer. Once it exists, its
  ** __gc owns freeing that pointer; a failure after this point therefore leaks
  ** it rather than risking a double free, which is the right way round on a
  ** path that is only reached when memory has run out. */
  hslua_newhsfunction(L, function);
  lua_pushglobaltable(L);
  /* Allocates the key. */
  lua_pushlstring(L, name, length);
  lua_pushvalue(L, -3);
  /* Honours __newindex, exactly as setting a global does. */
  lua_settable(L, -3);
  return 0;
}

int hetoimasia_lua_publish(lua_State *L, HsStablePtr function, const char *name, size_t length)
{
  /* Room for the call and its three arguments. lua_checkstack reports failure
  ** rather than raising it, which is what lets it be asked from here at all. */
  if (!lua_checkstack(L, 8)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, publish_body);
  lua_pushlightuserdata(L, function);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  return lua_pcall(L, 3, 0, 0);
}
