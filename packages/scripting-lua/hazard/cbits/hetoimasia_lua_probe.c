#include "hetoimasia_lua_probe.h"
#include "hetoimasia_lua_publish.h"

#include <lauxlib.h>
#include <stdatomic.h>
#include <stdlib.h>

/*
** One probe per process: the hazard runner arms exactly one, in one mode.
**
** The counter is advanced by a Haskell thread and read by the thread Lua runs
** on; the samples are written there and read back by the Haskell thread. Every
** one of those is an atomic with explicit ordering, so what a reader sees is
** defined rather than left to the platform.
*/
static atomic_long counter;
static atomic_long samples[2];
static atomic_int taken;

/*
** Lua calls this from inside its own instruction loop. It allocates nothing,
** calls no Lua API that can raise, and never re-enters Haskell.
*/
static void sample_progress(lua_State *L, lua_Debug *activation)
{
  (void) L;
  (void) activation;
  int index = atomic_load_explicit(&taken, memory_order_relaxed);
  if (index < 2) {
    atomic_store_explicit(&samples[index],
                          atomic_load_explicit(&counter, memory_order_acquire),
                          memory_order_relaxed);
    /* Released after the sample, so a reader that acquires this sees it. */
    atomic_store_explicit(&taken, index + 1, memory_order_release);
  }
}

void hetoimasia_lua_arm_probe(lua_State *L, int instructions)
{
  atomic_store_explicit(&counter, 0, memory_order_relaxed);
  atomic_store_explicit(&samples[0], 0, memory_order_relaxed);
  atomic_store_explicit(&samples[1], 0, memory_order_relaxed);
  atomic_store_explicit(&taken, 0, memory_order_release);
  lua_sethook(L, sample_progress, LUA_MASKCOUNT, instructions);
}

long hetoimasia_lua_probe_advance(void)
{
  return atomic_fetch_add_explicit(&counter, 1, memory_order_release) + 1;
}

int hetoimasia_lua_probe_samples(long *first, long *second)
{
  int index = atomic_load_explicit(&taken, memory_order_acquire);
  *first = atomic_load_explicit(&samples[0], memory_order_relaxed);
  *second = atomic_load_explicit(&samples[1], memory_order_relaxed);
  return index;
}

/*
** An allocator with a budget, so the publication path can be asked what it does
** when Lua cannot allocate.
*/
static size_t remaining;

static void *budgeted(void *ud, void *block, size_t was, size_t wanted)
{
  (void) ud;
  (void) was;
  if (wanted == 0) {
    free(block);
    return NULL;
  }
  if (remaining == 0) {
    return NULL;
  }
  remaining--;
  return realloc(block, wanted);
}

/* The binding's registration of the metatable a Haskell function's userdata
** carries. Its header is not installed; the symbol is. */
extern void hslua_registerhsfunmetatable(lua_State *L);

int hetoimasia_lua_publish_under_budget(void *function, size_t budget)
{
  int status;
  lua_State *L;

  /* Generous while the state is built, so the failure lands where it is being
  ** asked about rather than before. */
  remaining = (size_t) -1;
  L = lua_newstate(budgeted, NULL);
  if (L == NULL) {
    return LUA_ERRMEM;
  }
  hslua_registerhsfunmetatable(L);
  lua_settop(L, 0);

  remaining = budget;
  status = hetoimasia_lua_publish(L, function, "starved", 7);

  remaining = (size_t) -1;
  lua_close(L);
  return status;
}
