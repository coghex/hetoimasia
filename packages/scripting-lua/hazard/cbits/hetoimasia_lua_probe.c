#include <lua.h>
#include "hetoimasia_lua_probe.h"

/*
** One probe per process: the hazard runner arms exactly one, in one mode.
*/
static volatile long *watched = 0;
static long samples[2] = {0, 0};
static int taken = 0;

/*
** Lua calls this from inside its own instruction loop. It reads the counter
** and returns; it allocates nothing, calls no Lua API that can raise, and
** never re-enters Haskell.
*/
static void sample_progress(lua_State *L, lua_Debug *activation)
{
  (void) L;
  (void) activation;
  if (taken < 2 && watched != 0) {
    samples[taken] = *watched;
    taken++;
  }
}

void hetoimasia_lua_arm_probe(lua_State *L, volatile long *counter, int instructions)
{
  watched = counter;
  samples[0] = 0;
  samples[1] = 0;
  taken = 0;
  lua_sethook(L, sample_progress, LUA_MASKCOUNT, instructions);
}

int hetoimasia_lua_probe_samples(long *first, long *second)
{
  *first = samples[0];
  *second = samples[1];
  return taken;
}
