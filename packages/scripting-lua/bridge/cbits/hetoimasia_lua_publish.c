#include "hetoimasia_lua_publish.h"

#include <lauxlib.h>

/* The metatable the carrier userdata wears. Its only entry that does anything
** is __gc; __metatable keeps a script from reaching or replacing it. */
#define HETOIMASIA_FUNCTION_NAME "hetoimasia.lua.function"

/* This package's own entry into Haskell; see the header. */
extern int hetoimasia_lua_enter(lua_State *L);

/*
** Free the stable pointer the carrier holds. Lua runs this when the carrier is
** collected, and for every carrier still alive when the state is closed.
*/
static int carrier_gc(lua_State *L)
{
  HsStablePtr *slot = (HsStablePtr *) lua_touserdata(L, 1);
  if (slot != NULL && *slot != NULL) {
    hs_free_stable_ptr(*slot);
    *slot = NULL;
  }
  return 0;
}

/*
** The C closure Lua calls. Upvalue 1 is the carrier.
**
** It puts the carrier where the entry expects it, runs Haskell, and raises the
** failure marker as a Lua error afterwards -- in C, with every Haskell frame
** already returned, because a longjmp through one is undefined.
*/
static int invoke(lua_State *L)
{
  int results;
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  results = hetoimasia_lua_enter(L);
  if (results < 0) {
    return lua_error(L);
  }
  return results;
}

/*
** Register the carrier metatable, once per state. Allocates, so it is only ever
** called from inside the protected body below.
*/
static void register_carrier(lua_State *L)
{
  if (luaL_newmetatable(L, HETOIMASIA_FUNCTION_NAME)) {
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "__metatable");
    lua_pushcfunction(L, carrier_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

/*
** Everything that allocates, in one place, called through lua_pcall.
**
** The arguments arrive as values that cost nothing to push: the stable pointer,
** the name, and the ownership flag as light userdata, the length as an integer.
*/
static int publish_body(lua_State *L)
{
  HsStablePtr function = lua_touserdata(L, 1);
  const char *name = (const char *) lua_touserdata(L, 2);
  size_t length = (size_t) lua_tointeger(L, 3);
  int *acquired = (int *) lua_touserdata(L, 4);
  HsStablePtr *slot;

  lua_settop(L, 0);
  register_carrier(L);

  /* Allocates; a failure here leaves the pointer the caller's. */
  slot = (HsStablePtr *) lua_newuserdatauv(L, sizeof(HsStablePtr), 0);
  *slot = function;
  /* From this instruction the carrier's __gc owns it, whatever fails next. */
  *acquired = 1;

  luaL_setmetatable(L, HETOIMASIA_FUNCTION_NAME);
  /* Allocates the closure. */
  lua_pushcclosure(L, invoke, 1);
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
