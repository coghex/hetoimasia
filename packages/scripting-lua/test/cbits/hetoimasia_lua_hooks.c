#include <lauxlib.h>
#include <lua.h>

/*
** A return hook that raises, for an example that needs a Lua error at a point no
** script can reach: the return of the first C function after it is armed.
**
** The hook disarms itself before raising, so it fires once. It is the test
** suite's fixture, set from Haskell directly because the debug library an owner
** opens has no `sethook`; it is not part of any shipped component.
*/
static void fail_on_c_return(lua_State *L, lua_Debug *ar)
{
  lua_getinfo(L, "S", ar);
  if (ar->what[0] == 'C') {
    lua_sethook(L, NULL, 0, 0);
    luaL_error(L, "return hook failure");
  }
}

void hetoimasia_test_arm_return_hook(lua_State *L)
{
  lua_sethook(L, fail_on_c_return, LUA_MASKRET, 0);
}

void hetoimasia_test_disarm_hook(lua_State *L)
{
  lua_sethook(L, NULL, 0, 0);
}
