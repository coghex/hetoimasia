#include "hetoimasia_lua_bridge.h"
#include "hetoimasia_lua_values.h"

#include <lauxlib.h>
#include <stdatomic.h>
#include <stdlib.h>

/* The metatable the carrier userdata wears. Its only entry that does anything
** is __gc; __metatable keeps a script from reaching or replacing it. */
#define HETOIMASIA_CARRIER "hetoimasia.lua.carrier"

/* This package's own entry into Haskell; see the header. */
extern int hetoimasia_lua_enter(lua_State *L);

/* Counted for the fixtures. Written by whichever thread runs a collection or a
** close, read by another, so it is an atomic rather than a plain long. */
static atomic_long carriers_finalized;

long hetoimasia_lua_carriers_finalized(void)
{
  return atomic_load_explicit(&carriers_finalized, memory_order_acquire);
}

lua_State *hetoimasia_lua_newstate(void)
{
  return luaL_newstate();
}

/* A byte budget an interpreter's allocator holds itself to. */
typedef struct {
  size_t limit;
  size_t used;
} hetoimasia_budget;

/*
** The allocator of a budgeted interpreter: Lua's own contract (a free always
** succeeds; a request that cannot be met answers NULL, which Lua turns into its
** memory error), with one more reason to refuse. Growing past the budget is
** refused, shrinking and freeing never are.
**
** When `ptr` is NULL, `osize` is a type tag and not a size, so the old size is
** taken as zero then.
*/
static void *budget_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
  hetoimasia_budget *budget = (hetoimasia_budget *) ud;
  size_t old = (ptr == NULL) ? 0 : osize;
  void *grown;
  if (nsize == 0) {
    if (ptr != NULL) {
      budget->used -= old;
      free(ptr);
    }
    return NULL;
  }
  if (nsize > old && budget->used + (nsize - old) > budget->limit) {
    return NULL;
  }
  grown = realloc(ptr, nsize);
  if (grown != NULL) {
    budget->used = budget->used - old + nsize;
  }
  return grown;
}

static int budget_panic(lua_State *L)
{
  (void) L;
  return 0;
}

lua_State *hetoimasia_lua_newstate_budgeted(size_t limit)
{
  hetoimasia_budget *budget = (hetoimasia_budget *) malloc(sizeof(hetoimasia_budget));
  lua_State *L;
  if (budget == NULL) {
    return NULL;
  }
  budget->limit = limit;
  budget->used = 0;
  L = lua_newstate(budget_alloc, budget);
  if (L == NULL) {
    free(budget);
    return NULL;
  }
  /* What luaL_newstate does besides allocating: an unprotected error ends the
  ** process rather than going unnoticed, and warnings are off. */
  lua_atpanic(L, budget_panic);
  lua_setwarnf(L, NULL, NULL);
  return L;
}

void hetoimasia_lua_close(lua_State *L)
{
  void *ud = NULL;
  lua_Alloc allocator = lua_getallocf(L, &ud);
  lua_close(L);
  if (allocator == budget_alloc) {
    free(ud);
  }
}

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
    atomic_fetch_add_explicit(&carriers_finalized, 1, memory_order_release);
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
** Push the carrier metatable, building it before it is reachable.
**
** `luaL_newmetatable` registers its table and *then* fills it, so an allocation
** failure between the two leaves a metatable in the registry with no __gc --
** and the next publication finds it, believes it complete, and installs a
** carrier nothing will ever finalize. This registers only a finished table, so
** a failure anywhere before that leaves the registry as it was and the next
** attempt builds it again.
*/
static void push_carrier_metatable(lua_State *L)
{
  if (lua_getfield(L, LUA_REGISTRYINDEX, HETOIMASIA_CARRIER) == LUA_TTABLE) {
    return;
  }
  lua_pop(L, 1);
  lua_createtable(L, 0, 2);
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "__metatable");
  lua_pushcfunction(L, carrier_gc);
  lua_setfield(L, -2, "__gc");
  /* Complete, and only now reachable by name. */
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, HETOIMASIA_CARRIER);
}

/*
** Everything publication allocates, in one place, called through lua_pcall.
*/
static int publish_body(lua_State *L)
{
  HsStablePtr function = lua_touserdata(L, 1);
  const char *name = (const char *) lua_touserdata(L, 2);
  size_t length = (size_t) lua_tointeger(L, 3);
  int *acquired = (int *) lua_touserdata(L, 4);
  HsStablePtr *slot;

  lua_settop(L, 0);
  push_carrier_metatable(L);

  slot = (HsStablePtr *) lua_newuserdatauv(L, sizeof(HsStablePtr), 0);
  *slot = function;
  lua_pushvalue(L, -2);
  /* Neither of those allocates, so the carrier cannot be left without its
  ** finalizer; ownership passes at this instruction and not before. A failure
  ** up to here leaves the pointer the caller's, and the carrier it may have
  ** created is unreachable garbage with no __gc, which is what makes freeing it
  ** on the Haskell side safe. */
  lua_setmetatable(L, -2);
  *acquired = 1;

  lua_pushcclosure(L, invoke, 1);
  lua_pushglobaltable(L);
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
  /* Room for the call and its arguments. lua_checkstack reports failure rather
  ** than raising it, which is what lets it be asked from here at all. */
  if (!lua_checkstack(L, 10)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, publish_body);
  lua_pushlightuserdata(L, function);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  lua_pushlightuserdata(L, acquired);
  return lua_pcall(L, 4, 0, 0);
}

/*
** Everything installing a binding allocates, in one place: the carrier, the C
** closure over it, and the entry in the namespace's table.
*/
static int install_body(lua_State *L)
{
  HsStablePtr function = lua_touserdata(L, 1);
  const char *space = (const char *) lua_touserdata(L, 2);
  size_t space_length = (size_t) lua_tointeger(L, 3);
  const char *name = (const char *) lua_touserdata(L, 4);
  size_t length = (size_t) lua_tointeger(L, 5);
  int *acquired = (int *) lua_touserdata(L, 6);
  HsStablePtr *slot;

  lua_settop(L, 0);
  push_carrier_metatable(L);
  slot = (HsStablePtr *) lua_newuserdatauv(L, sizeof(HsStablePtr), 0);
  *slot = function;
  lua_pushvalue(L, -2);
  /* As in `publish_body`: ownership of the pointer passes at this instruction. */
  lua_setmetatable(L, -2);
  *acquired = 1;

  lua_pushcclosure(L, invoke, 1);
  lua_pushglobaltable(L);
  lua_pushlstring(L, space, space_length);
  /* A raw read and a raw write: no metamethod of the globals or of the
  ** namespace can run while a binding is being installed. */
  lua_rawget(L, -2);
  if (!lua_istable(L, -1)) {
    return luaL_error(L, "the binding's namespace does not exist");
  }
  lua_pushlstring(L, name, length);
  lua_pushvalue(L, 2);
  lua_rawset(L, -3);
  return 0;
}

int hetoimasia_lua_install_binding(
  lua_State *L, HsStablePtr function,
  const char *space, size_t space_length, const char *name, size_t length, int *acquired)
{
  *acquired = 0;
  if (!lua_checkstack(L, 12)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, install_body);
  lua_pushlightuserdata(L, function);
  lua_pushlightuserdata(L, (void *) (size_t) space);
  lua_pushinteger(L, (lua_Integer) space_length);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  lua_pushlightuserdata(L, acquired);
  return lua_pcall(L, 6, 0, 0);
}

static int getglobal_body(lua_State *L)
{
  const char *name = (const char *) lua_touserdata(L, 1);
  size_t length = (size_t) lua_tointeger(L, 2);

  lua_settop(L, 0);
  lua_pushglobaltable(L);
  /* Allocates the key, and the lookup runs __index. Both protected. */
  lua_pushlstring(L, name, length);
  lua_gettable(L, -2);
  lua_remove(L, -2);
  return 1;
}

int hetoimasia_lua_getglobal(
  lua_State *L, const char *name, size_t length, int *type)
{
  int status;

  *type = LUA_TNONE;
  if (!lua_checkstack(L, 8)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, getglobal_body);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  status = lua_pcall(L, 2, 1, 0);
  if (status == LUA_OK) {
    *type = lua_type(L, -1);
  }
  return status;
}

static int requiref_body(lua_State *L)
{
  const char *name = (const char *) lua_touserdata(L, 1);
  lua_CFunction opener = lua_tocfunction(L, 2);
  int global = lua_toboolean(L, 3);

  lua_settop(L, 0);
  /* Allocates the module name and whatever the opener builds. Protected. */
  luaL_requiref(L, name, opener, global);
  return 1;
}

int hetoimasia_lua_requiref(
  lua_State *L, const char *name, lua_CFunction opener, int global)
{
  if (!lua_checkstack(L, 8)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, requiref_body);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  /* A C function with no upvalues is a value, not an allocation. */
  lua_pushcfunction(L, opener);
  lua_pushboolean(L, global);
  return lua_pcall(L, 3, 1, 0);
}
