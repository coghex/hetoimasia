#include "hetoimasia_lua_values.h"

#include <lauxlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
** The collector is held across every host-side phase that allocates.
**
** Allocating in Lua can start a collection step, and a step can run pending
** `__gc` finalizers, which are script-defined Lua and can call bindings. A phase
** that is claimed to execute nothing -- reading arguments, building results,
** loading a module up to the point its chunk starts -- would then not be what it
** claims. So each of them stops the collector first and gives it back as it was
** found: `lua_gc(LUA_GCISRUNNING)` is false if a script already stopped it, or
** while a finalizer is running, and then there is nothing to hold or to give
** back. Neither call can raise an error or run Lua.
**
** Giving the collector back clears its debt, so what the held phase allocated
** would never count towards a step: a loop of crossings whose script phases do
** not allocate would grow without bound. The bytes a phase allocated are
** therefore kept as owed, in the module table at key 0, and `gc_service` pays
** them -- as a step of that many kilobytes -- at the start of a phase that is
** allowed to execute script code: the point a module's chunk starts, just before
** an entry point is called, and when a binding returns to its script.
**
** Calling a C function can itself grow the stack and so start a step, which is
** why even the entry-point lookup, which allocates nothing, is held.
*/
typedef struct {
  int was;
  long before;
} gc_hold_t;

static long heap_bytes(lua_State *L)
{
  return (long) lua_gc(L, LUA_GCCOUNT) * 1024L + (long) lua_gc(L, LUA_GCCOUNTB);
}

static gc_hold_t gc_hold(lua_State *L)
{
  gc_hold_t h;
  h.was = lua_gc(L, LUA_GCISRUNNING);
  h.before = 0;
  if (h.was) {
    h.before = heap_bytes(L);
    lua_gc(L, LUA_GCSTOP);
  }
  return h;
}

static char modules_key;

/* The table the tasks' coroutines are anchored in, by slot. */
static char tasks_key;

/* Add to (or, with a negative amount, take from) what is owed. The key exists
** from the set-up, so setting it allocates nothing. */
static long owed_add(lua_State *L, long bytes)
{
  long owed = 0;
  if (!lua_checkstack(L, 4)) {
    return 0;
  }
  lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
  if (lua_istable(L, -1)) {
    lua_rawgeti(L, -1, 0);
    if (lua_isinteger(L, -1)) {
      owed = (long) lua_tointeger(L, -1);
    }
    lua_pop(L, 1);
    owed += bytes;
    if (owed < 0) {
      owed = 0;
    }
    lua_pushinteger(L, (lua_Integer) owed);
    lua_rawseti(L, -2, 0);
  }
  lua_pop(L, 1);
  return owed;
}

static void gc_release(lua_State *L, gc_hold_t h)
{
  if (h.was) {
    long delta = heap_bytes(L) - h.before;
    lua_gc(L, LUA_GCRESTART);
    if (delta > 0) {
      owed_add(L, delta);
    }
  }
}

/* Pay what the held phases allocated, as one step of that many kilobytes. This
** can run finalizers, so it is called only where script code may run. */
static void gc_service(lua_State *L)
{
  long owed = owed_add(L, 0);
  if (owed > 0 && lua_gc(L, LUA_GCISRUNNING)) {
    long kilobytes = owed / 1024 + 1;
    owed_add(L, -owed);
    lua_gc(L, LUA_GCSTEP, (int) (kilobytes > 1000000 ? 1000000 : kilobytes));
  }
}

void hetoimasia_lua_gc_service(lua_State *L)
{
  gc_service(L);
}

/* The deepest a value may nest, whatever limit a configuration asks for. It
** sizes the path the cycle check keeps on the C stack. */
#define MAX_DEPTH_HARD 64

/* Registry keys are the addresses of these, as light userdata: reading one
** neither allocates nor can raise, and nothing a script does can name it. */
static char handle_key;

/* A handle, as Lua holds it: the VM that issued it, the application's type for
** it, and the application's key within that type. */
typedef struct {
  uint32_t magic;
  uint32_t type;
  uint64_t vm;
  uint64_t key;
} handle_block;

#define HANDLE_MAGIC 0x48544d41u

/* ------------------------------------------------------------------------ */
/* Little-endian encoding                                                    */
/* ------------------------------------------------------------------------ */

typedef struct {
  unsigned char *data;
  size_t length;
  size_t capacity;
} bytes;

static int bytes_reserve(bytes *b, size_t more)
{
  size_t want;
  size_t capacity;
  unsigned char *grown;
  if (more > ((size_t) -1) - b->length) {
    return 0;
  }
  want = b->length + more;
  if (want <= b->capacity) {
    return 1;
  }
  capacity = b->capacity == 0 ? 64 : b->capacity;
  while (capacity < want) {
    if (capacity > ((size_t) -1) / 2) {
      capacity = want;
      break;
    }
    capacity *= 2;
  }
  grown = (unsigned char *) realloc(b->data, capacity);
  if (grown == NULL) {
    return 0;
  }
  b->data = grown;
  b->capacity = capacity;
  return 1;
}

static int bytes_put(bytes *b, const void *data, size_t n)
{
  if (!bytes_reserve(b, n)) {
    return 0;
  }
  if (n > 0) {
    memcpy(b->data + b->length, data, n);
  }
  b->length += n;
  return 1;
}

static int bytes_u8(bytes *b, unsigned char v)
{
  return bytes_put(b, &v, 1);
}

static void store32(unsigned char *p, uint32_t v)
{
  p[0] = (unsigned char) (v & 0xff);
  p[1] = (unsigned char) ((v >> 8) & 0xff);
  p[2] = (unsigned char) ((v >> 16) & 0xff);
  p[3] = (unsigned char) ((v >> 24) & 0xff);
}

static void store64(unsigned char *p, uint64_t v)
{
  int i;
  for (i = 0; i < 8; i++) {
    p[i] = (unsigned char) ((v >> (8 * i)) & 0xff);
  }
}

static uint32_t load32(const unsigned char *p)
{
  return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static uint64_t load64(const unsigned char *p)
{
  uint64_t v = 0;
  int i;
  for (i = 0; i < 8; i++) {
    v |= ((uint64_t) p[i]) << (8 * i);
  }
  return v;
}

static int bytes_u32(bytes *b, uint32_t v)
{
  unsigned char raw[4];
  store32(raw, v);
  return bytes_put(b, raw, 4);
}

static int bytes_u64(bytes *b, uint64_t v)
{
  unsigned char raw[8];
  store64(raw, v);
  return bytes_put(b, raw, 8);
}

/* ------------------------------------------------------------------------ */
/* Reading                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
  size_t max_bytes;
  size_t max_depth;
  size_t max_elements;
  uint64_t vm;
  size_t used;
  size_t elements;
  bytes out;
  int refusal;
  int argument;
  int lua_type;
  int current;
  const void *path[MAX_DEPTH_HARD + 1];
} reader;

static int refuse(reader *r, int code, int type)
{
  r->refusal = code;
  r->lua_type = type;
  r->argument = r->current;
  return 0;
}

/* Account for `n` bytes of the copy, refusing before any of them is written. */
static int charge(reader *r, size_t n)
{
  if (n > r->max_bytes - r->used) {
    return refuse(r, HETOIMASIA_READ_BYTES, -1);
  }
  r->used += n;
  return 1;
}

static int emit(reader *r, int ok)
{
  if (!ok) {
    return refuse(r, HETOIMASIA_READ_MEMORY, -1);
  }
  return 1;
}

static int read_value(lua_State *L, reader *r, int index, size_t depth);

/* A table key: an integer or a string, and nothing else. It is not an element,
** but its bytes are charged. */
static int read_key(lua_State *L, reader *r, int index)
{
  int type = lua_type(L, index);
  if (type == LUA_TNUMBER && lua_isinteger(L, index)) {
    lua_Integer v = lua_tointegerx(L, index, NULL);
    if (!charge(r, 9)) {
      return 0;
    }
    return emit(r, bytes_u8(&r->out, 0x03) && bytes_u64(&r->out, (uint64_t) v));
  }
  if (type == LUA_TSTRING) {
    size_t len;
    const char *s = lua_tolstring(L, index, &len);
    if (len > 0xffffffffu || len > r->max_bytes || 5 + len > r->max_bytes - r->used) {
      return refuse(r, HETOIMASIA_READ_BYTES, -1);
    }
    r->used += 5 + len;
    return emit(r, bytes_u8(&r->out, 0x05) && bytes_u32(&r->out, (uint32_t) len) && bytes_put(&r->out, s, len));
  }
  return refuse(r, HETOIMASIA_READ_KEY, type);
}

static int read_table(lua_State *L, reader *r, int index, size_t depth)
{
  size_t nested = depth + 1;
  const void *self;
  size_t i;
  size_t count_at;
  uint32_t count = 0;
  int table;

  /* A metatable is refused before any entry is looked at, so nothing it
  ** defines can matter and no metamethod is ever consulted. */
  if (lua_getmetatable(L, index)) {
    lua_pop(L, 1);
    return refuse(r, HETOIMASIA_READ_METATABLE, -1);
  }
  if (nested > r->max_depth) {
    return refuse(r, HETOIMASIA_READ_DEPTH, -1);
  }
  self = lua_topointer(L, index);
  for (i = 0; i < depth; i++) {
    if (r->path[i] == self) {
      return refuse(r, HETOIMASIA_READ_CYCLE, -1);
    }
  }
  r->path[depth] = self;
  if (!charge(r, 5)) {
    return 0;
  }
  if (!emit(r, bytes_u8(&r->out, 0x06))) {
    return 0;
  }
  count_at = r->out.length;
  if (!emit(r, bytes_u32(&r->out, 0))) {
    return 0;
  }
  table = lua_absindex(L, index);
  lua_pushnil(L);
  while (lua_next(L, table)) {
    if (!read_key(L, r, -2)) {
      return 0;
    }
    if (!read_value(L, r, -1, nested)) {
      return 0;
    }
    count++;
    lua_pop(L, 1);
  }
  store32(r->out.data + count_at, count);
  return 1;
}

static int read_handle(lua_State *L, reader *r, int index)
{
  if (lua_getmetatable(L, index)) {
    int same;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &handle_key);
    same = lua_rawequal(L, -1, -2);
    lua_pop(L, 2);
    if (same && lua_rawlen(L, index) == sizeof(handle_block)) {
      const handle_block *h = (const handle_block *) lua_touserdata(L, index);
      if (h != NULL && h->magic == HANDLE_MAGIC) {
        if (h->vm != r->vm) {
          return refuse(r, HETOIMASIA_READ_FOREIGN, -1);
        }
        if (!charge(r, 21)) {
          return 0;
        }
        return emit(r, bytes_u8(&r->out, 0x07) && bytes_u64(&r->out, h->vm) && bytes_u32(&r->out, h->type) && bytes_u64(&r->out, h->key));
      }
    }
  }
  return refuse(r, HETOIMASIA_READ_UNSUPPORTED, LUA_TUSERDATA);
}

static int read_value(lua_State *L, reader *r, int index, size_t depth)
{
  int type = lua_type(L, index);
  r->elements++;
  if (r->elements > r->max_elements) {
    return refuse(r, HETOIMASIA_READ_ELEMENTS, -1);
  }
  switch (type) {
    case LUA_TNIL:
      return charge(r, 1) && emit(r, bytes_u8(&r->out, 0x00));
    case LUA_TBOOLEAN:
      return charge(r, 1) && emit(r, bytes_u8(&r->out, lua_toboolean(L, index) ? 0x02 : 0x01));
    case LUA_TNUMBER:
      if (!charge(r, 9)) {
        return 0;
      }
      if (lua_isinteger(L, index)) {
        return emit(r, bytes_u8(&r->out, 0x03) && bytes_u64(&r->out, (uint64_t) lua_tointegerx(L, index, NULL)));
      } else {
        lua_Number n = lua_tonumberx(L, index, NULL);
        uint64_t bits;
        memcpy(&bits, &n, sizeof bits);
        return emit(r, bytes_u8(&r->out, 0x04) && bytes_u64(&r->out, bits));
      }
    case LUA_TSTRING: {
      size_t len;
      const char *s = lua_tolstring(L, index, &len);
      if (len > 0xffffffffu || len > r->max_bytes || 5 + len > r->max_bytes - r->used) {
        return refuse(r, HETOIMASIA_READ_BYTES, -1);
      }
      r->used += 5 + len;
      return emit(r, bytes_u8(&r->out, 0x05) && bytes_u32(&r->out, (uint32_t) len) && bytes_put(&r->out, s, len));
    }
    case LUA_TTABLE:
      return read_table(L, r, index, depth);
    case LUA_TUSERDATA:
      return read_handle(L, r, index);
    default:
      return refuse(r, HETOIMASIA_READ_UNSUPPORTED, type);
  }
}

/* The protected body: its first argument is the reader, the rest are the
** values, copied onto its own frame by the wrapper. */
static int read_body(lua_State *L)
{
  reader *r = (reader *) lua_touserdata(L, 1);
  int count = lua_gettop(L) - 1;
  int i;
  if (!lua_checkstack(L, (int) (3 * r->max_depth + 12))) {
    r->refusal = HETOIMASIA_READ_STACK;
    r->argument = 1;
    return 0;
  }
  for (i = 0; i < count; i++) {
    r->current = i + 1;
    if (!read_value(L, r, 2 + i, 0)) {
      return 0;
    }
  }
  return 0;
}

int hetoimasia_lua_read_values(
  lua_State *L, int first, int count,
  size_t max_bytes, size_t max_depth, size_t max_elements, uint64_t vm_identity,
  int *refusal, int *argument, int *lua_type_out, size_t *visited,
  unsigned char **buffer, size_t *length)
{
  reader r;
  int status;
  int i;
  gc_hold_t held = gc_hold(L);

  memset(&r, 0, sizeof r);
  r.max_bytes = max_bytes;
  r.max_depth = max_depth > MAX_DEPTH_HARD ? MAX_DEPTH_HARD : max_depth;
  r.max_elements = max_elements;
  r.vm = vm_identity;
  *refusal = 0;
  *argument = 0;
  *lua_type_out = -1;
  *visited = 0;
  *buffer = NULL;
  *length = 0;

  /* A stack that cannot be had, or memory for the copy that cannot be had, is
  ** the interpreter running out of memory and is answered as Lua answers it, not
  ** as a refusal of the script's value. */
  if (count < 0 || !lua_checkstack(L, count + 6)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, read_body);
  lua_pushlightuserdata(L, &r);
  for (i = 0; i < count; i++) {
    lua_pushvalue(L, first + i);
  }
  status = lua_pcall(L, 1 + count, 0, 0);
  gc_release(L, held);

  if (status == LUA_OK && (r.refusal == HETOIMASIA_READ_STACK || r.refusal == HETOIMASIA_READ_MEMORY)) {
    status = LUA_ERRMEM;
    r.refusal = 0;
  }
  *visited = r.elements;
  *refusal = r.refusal;
  *argument = r.argument;
  *lua_type_out = r.lua_type;
  if (status != LUA_OK || r.refusal != 0) {
    free(r.out.data);
  } else {
    *buffer = r.out.data;
    *length = r.out.length;
  }
  return status;
}

void hetoimasia_lua_free(void *pointer)
{
  free(pointer);
}

/* ------------------------------------------------------------------------ */
/* Writing                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
  const unsigned char *p;
  const unsigned char *end;
  size_t max_depth;
  int malformed;
} writer;

static int have(const writer *w, size_t n)
{
  return (size_t) (w->end - w->p) >= n;
}

static int write_value(lua_State *L, writer *w, size_t depth)
{
  unsigned tag;
  if (!have(w, 1)) {
    return 0;
  }
  tag = *w->p++;
  switch (tag) {
    case 0x00:
      lua_pushnil(L);
      return 1;
    case 0x01:
      lua_pushboolean(L, 0);
      return 1;
    case 0x02:
      lua_pushboolean(L, 1);
      return 1;
    case 0x03:
      if (!have(w, 8)) {
        return 0;
      }
      lua_pushinteger(L, (lua_Integer) load64(w->p));
      w->p += 8;
      return 1;
    case 0x04: {
      uint64_t bits;
      lua_Number n;
      if (!have(w, 8)) {
        return 0;
      }
      bits = load64(w->p);
      w->p += 8;
      memcpy(&n, &bits, sizeof n);
      lua_pushnumber(L, n);
      return 1;
    }
    case 0x05: {
      uint32_t len;
      if (!have(w, 4)) {
        return 0;
      }
      len = load32(w->p);
      w->p += 4;
      if (!have(w, len)) {
        return 0;
      }
      lua_pushlstring(L, (const char *) w->p, len);
      w->p += len;
      return 1;
    }
    case 0x06: {
      uint32_t n;
      uint32_t i;
      if (depth + 1 > w->max_depth || !have(w, 4)) {
        return 0;
      }
      n = load32(w->p);
      w->p += 4;
      lua_createtable(L, 0, 0);
      for (i = 0; i < n; i++) {
        if (!have(w, 1) || (*w->p != 0x03 && *w->p != 0x05)) {
          return 0;
        }
        if (!write_value(L, w, depth + 1) || !write_value(L, w, depth + 1)) {
          return 0;
        }
        lua_rawset(L, -3);
      }
      return 1;
    }
    case 0x07: {
      handle_block *h;
      if (!have(w, 20)) {
        return 0;
      }
      h = (handle_block *) lua_newuserdatauv(L, sizeof(handle_block), 0);
      h->magic = HANDLE_MAGIC;
      h->vm = load64(w->p);
      h->type = load32(w->p + 8);
      h->key = load64(w->p + 12);
      w->p += 20;
      lua_rawgetp(L, LUA_REGISTRYINDEX, &handle_key);
      if (!lua_istable(L, -1)) {
        return 0;
      }
      lua_setmetatable(L, -2);
      return 1;
    }
    default:
      return 0;
  }
}

static int push_body(lua_State *L)
{
  writer *w = (writer *) lua_touserdata(L, 1);
  int count = (int) lua_tointeger(L, 2);
  int i;
  if (!lua_checkstack(L, count + (int) w->max_depth * 2 + 8)) {
    w->malformed = 2;
    return 0;
  }
  for (i = 0; i < count; i++) {
    if (!write_value(L, w, 0)) {
      w->malformed = 1;
      return 0;
    }
  }
  return count;
}

int hetoimasia_lua_push_values(
  lua_State *L, const unsigned char *buffer, size_t length, int count,
  size_t max_depth, int *malformed)
{
  writer w;
  int status;
  gc_hold_t held = gc_hold(L);
  w.p = buffer;
  w.end = buffer + length;
  w.max_depth = max_depth > MAX_DEPTH_HARD ? MAX_DEPTH_HARD : max_depth;
  w.malformed = 0;
  *malformed = 0;
  if (!lua_checkstack(L, 8)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, push_body);
  lua_pushlightuserdata(L, &w);
  lua_pushinteger(L, count);
  status = lua_pcall(L, 2, count, 0);
  gc_release(L, held);
  /* Stack that could not be reserved is memory running out, as above. */
  if (status == LUA_OK && w.malformed == 2) {
    status = LUA_ERRMEM;
    w.malformed = 0;
  }
  *malformed = w.malformed;
  return status;
}

/* ------------------------------------------------------------------------ */
/* The registry's share                                                      */
/* ------------------------------------------------------------------------ */

static int handle_tostring(lua_State *L)
{
  lua_pushliteral(L, "<handle>");
  return 1;
}

static int handle_eq(lua_State *L)
{
  const handle_block *a = (const handle_block *) lua_touserdata(L, 1);
  const handle_block *b = (const handle_block *) lua_touserdata(L, 2);
  int same = a != NULL && b != NULL && lua_rawlen(L, 1) == sizeof(handle_block) && lua_rawlen(L, 2) == sizeof(handle_block)
             && a->magic == HANDLE_MAGIC && b->magic == HANDLE_MAGIC && a->vm == b->vm && a->type == b->type && a->key == b->key;
  lua_pushboolean(L, same);
  return 1;
}

static int setup_body(lua_State *L)
{
  int present;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &handle_key);
  present = lua_istable(L, -1);
  lua_pop(L, 1);
  if (present) {
    return 0;
  }
  /* Both are built before either is reachable, and the handle metatable is
  ** registered last: it is what "already set up" is read from, so a failure
  ** anywhere before it leaves the next call to build both again. */
  lua_createtable(L, 0, 3);
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_pushcfunction(L, handle_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_pushcfunction(L, handle_eq);
  lua_setfield(L, -2, "__eq");
  lua_createtable(L, 1, 0);
  /* What the held collector owes (see `gc_service`); present from the start so
  ** that updating it allocates nothing. */
  lua_pushinteger(L, 0);
  lua_rawseti(L, -2, 0);
  /* The coroutines of the tasks the host has started, by slot. */
  lua_createtable(L, 0, 0);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &tasks_key);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &modules_key);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &handle_key);
  return 0;
}

int hetoimasia_lua_values_setup(lua_State *L)
{
  gc_hold_t held = gc_hold(L);
  int status;
  if (!lua_checkstack(L, 8)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, setup_body);
  status = lua_pcall(L, 0, 0, 0);
  gc_release(L, held);
  return status;
}

static int count_body(lua_State *L)
{
  long *out = (long *) lua_touserdata(L, 1);
  long n = 0;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
  if (lua_istable(L, -1)) {
    lua_pushnil(L);
    while (lua_next(L, -2)) {
      /* Key 0 is not a module: it is what the collector owes. */
      if (!(lua_isinteger(L, -2) && lua_tointeger(L, -2) == 0)) {
        n++;
      }
      lua_pop(L, 1);
    }
  }
  *out = n;
  return 0;
}

int hetoimasia_lua_module_count(lua_State *L, long *count)
{
  gc_hold_t held = gc_hold(L);
  int status;
  *count = 0;
  if (!lua_checkstack(L, 8)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, count_body);
  lua_pushlightuserdata(L, count);
  status = lua_pcall(L, 1, 0, 0);
  gc_release(L, held);
  return status;
}

static int namespace_body(lua_State *L)
{
  const char *name = (const char *) lua_touserdata(L, 1);
  size_t length = (size_t) lua_tointeger(L, 2);
  int *collision = (int *) lua_touserdata(L, 3);
  lua_settop(L, 0);
  lua_pushglobaltable(L);
  lua_pushlstring(L, name, length);
  lua_pushvalue(L, -1);
  lua_rawget(L, -3);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_createtable(L, 0, 0);
    lua_rawset(L, -3);
  } else if (!lua_istable(L, -1)) {
    *collision = 1;
  }
  return 0;
}

int hetoimasia_lua_namespace(lua_State *L, const char *name, size_t length, int *collision)
{
  *collision = 0;
  if (!lua_checkstack(L, 10)) {
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, namespace_body);
  lua_pushlightuserdata(L, (void *) (size_t) name);
  lua_pushinteger(L, (lua_Integer) length);
  lua_pushlightuserdata(L, collision);
  return lua_pcall(L, 3, 0, 0);
}

/* ------------------------------------------------------------------------ */
/* Protected calls with a bounded traceback                                  */
/* ------------------------------------------------------------------------ */

/*
** A traceback built from the debug interface's records alone.
**
** Not `luaL_traceback`: finding a function's global name there reads the
** registry's loaded-module table with `lua_getfield`, which honours metamethods,
** and a script that has the debug library can make that run Lua while a fault is
** being recorded. `lua_getstack` and `lua_getinfo` with "Sln" read only the call
** records and the function's prototype, allocate nothing and run nothing, so
** neither can fail or be hooked. The text is bounded by `capacity` and the depth
** by `TRACE_LEVELS`.
*/
#define TRACE_LEVELS 22

static size_t put(char *buffer, size_t capacity, size_t length, const char *text)
{
  size_t n = strlen(text);
  if (length >= capacity) {
    return length;
  }
  if (n > capacity - length) {
    n = capacity - length;
  }
  memcpy(buffer + length, text, n);
  return length + n;
}

static size_t build_traceback(lua_State *L, int first, char *buffer, size_t capacity)
{
  lua_Debug ar;
  int level;
  size_t length = put(buffer, capacity, 0, "stack traceback:");
  for (level = first; level < first + TRACE_LEVELS; level++) {
    char number[32];
    if (!lua_getstack(L, level, &ar)) {
      return length;
    }
    lua_getinfo(L, "Sln", &ar);
    length = put(buffer, capacity, length, "\n\t");
    length = put(buffer, capacity, length, ar.short_src);
    length = put(buffer, capacity, length, ":");
    if (ar.currentline > 0) {
      snprintf(number, sizeof number, "%d:", ar.currentline);
      length = put(buffer, capacity, length, number);
    }
    length = put(buffer, capacity, length, " in ");
    if (ar.namewhat[0] != '\0' && ar.name != NULL) {
      length = put(buffer, capacity, length, ar.namewhat);
      length = put(buffer, capacity, length, " '");
      length = put(buffer, capacity, length, ar.name);
      length = put(buffer, capacity, length, "'");
    } else if (ar.what[0] == 'm') {
      length = put(buffer, capacity, length, "main chunk");
    } else if (ar.what[0] == 'C') {
      length = put(buffer, capacity, length, "?");
    } else {
      snprintf(number, sizeof number, "<%d>", ar.linedefined);
      length = put(buffer, capacity, length, "function ");
      length = put(buffer, capacity, length, number);
    }
  }
  if (lua_getstack(L, level, &ar)) {
    length = put(buffer, capacity, length, "\n\t...");
  }
  return length;
}

int hetoimasia_lua_context(
  lua_State *L,
  char *chunk, size_t chunk_capacity, size_t *chunk_length,
  char *trace, size_t trace_capacity, size_t *trace_length)
{
  lua_Debug ar;
  int level;
  *chunk_length = 0;
  *trace_length = 0;
  /* Level 0 is the C function Lua called; from level 1 the callers, and the first
  ** that is Lua code is the chunk the call was made from, however many C
  ** functions (a pcall, say) lie between. */
  for (level = 1; level < 1 + TRACE_LEVELS; level++) {
    if (!lua_getstack(L, level, &ar)) {
      break;
    }
    if (lua_getinfo(L, "Sl", &ar) && ar.what[0] != 'C' && ar.short_src[0] != '\0') {
      size_t n = strlen(ar.short_src);
      if (n > chunk_capacity) {
        n = chunk_capacity;
      }
      memcpy(chunk, ar.short_src, n);
      *chunk_length = n;
      break;
    }
  }
  *trace_length = build_traceback(L, 1, trace, trace_capacity);
  return LUA_OK;
}

typedef struct {
  char *buffer;
  size_t capacity;
  size_t *length;
} trace_context;

/*
** The message handler. It returns the error value it was given, unchanged: the
** traceback travels in the caller's buffer instead, so building it cannot change
** what the call reports, and rendering the error stays what it was. The
** traceback is built from the call records alone (see `build_traceback`), so no
** script-defined Lua runs here and nothing can fail.
*/
static int traceback_handler(lua_State *L)
{
  trace_context *t = *(trace_context **) lua_getextraspace(L);
  if (t != NULL) {
    /* Level 0 is this handler, level 1 the function that raised the error. */
    *t->length = build_traceback(L, 1, t->buffer, t->capacity);
  }
  lua_settop(L, 1);
  return 1;
}

int hetoimasia_lua_call(
  lua_State *L, int nargs, int nresults,
  char *trace, size_t trace_capacity, size_t *trace_length)
{
  int base;
  int status;
  trace_context context;
  trace_context **slot;
  trace_context *saved;

  *trace_length = 0;
  if (!lua_checkstack(L, 4)) {
    return LUA_ERRMEM;
  }
  base = lua_gettop(L) - nargs;
  lua_pushcfunction(L, traceback_handler);
  lua_insert(L, base);
  context.buffer = trace;
  context.capacity = trace_capacity;
  context.length = trace_length;
  slot = (trace_context **) lua_getextraspace(L);
  saved = *slot;
  *slot = &context;
  status = lua_pcall(L, nargs, nresults, base);
  *slot = saved;
  lua_remove(L, base);
  return status;
}

/* ------------------------------------------------------------------------ */
/* Modules                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
  const char *source;
  size_t source_length;
  const char *chunk;
  const unsigned char *required;
  size_t required_length;
  int required_count;
  lua_Integer slot;
  int load_status;
  int missing;
  int missing_kind;
  int stored;
  gc_hold_t gc_held;
  int started;
} load_arguments;

/* Give the collector back, once, at the point the chunk is about to start or the
** load is over without it. */
static void load_release(lua_State *L, load_arguments *a)
{
  if (a->gc_held.was) {
    gc_release(L, a->gc_held);
    a->gc_held.was = 0;
  }
}

static int load_body(lua_State *L)
{
  load_arguments *a = (load_arguments *) lua_touserdata(L, 1);
  const unsigned char *p;
  const unsigned char *end;
  int i;

  lua_settop(L, 0);
  luaL_checkstack(L, 12, "loading a module");
  /* The module's own environment, reading through to the globals. */
  lua_createtable(L, 0, 8);
  lua_createtable(L, 0, 1);
  lua_pushglobaltable(L);
  lua_setfield(L, 2, "__index");
  lua_setmetatable(L, 1);

  a->load_status = luaL_loadbufferx(L, a->source, a->source_length, a->chunk, "t");
  if (a->load_status != LUA_OK) {
    load_release(L, a);
    return 1;
  }
  lua_pushvalue(L, 1);
  if (lua_setupvalue(L, 2, 1) == NULL) {
    lua_pop(L, 1);
  }
  /* Everything up to here executed nothing. */
  load_release(L, a);
  a->started = 1;
  /* The chunk may run script code, so what the load allocated is paid now. */
  gc_service(L);
  lua_call(L, 0, 0);

  p = a->required;
  end = a->required + a->required_length;
  for (i = 1; i <= a->required_count; i++) {
    uint32_t len;
    int type;
    if ((size_t) (end - p) < 4) {
      break;
    }
    len = load32(p);
    p += 4;
    if ((size_t) (end - p) < len) {
      break;
    }
    lua_pushlstring(L, (const char *) p, len);
    p += len;
    lua_rawget(L, 1);
    type = lua_type(L, -1);
    lua_pop(L, 1);
    if (type != LUA_TFUNCTION) {
      a->missing = i;
      a->missing_kind = type == LUA_TNIL ? 0 : 1;
      lua_pushnil(L);
      return 1;
    }
  }

  lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
  if (!lua_istable(L, -1)) {
    return luaL_error(L, "the module table is missing");
  }
  lua_pushvalue(L, 1);
  lua_rawseti(L, -2, a->slot);
  a->stored = 1;
  lua_pushnil(L);
  return 1;
}

int hetoimasia_lua_load_module(
  lua_State *L,
  const char *source, size_t source_length, const char *chunk, size_t chunk_length,
  const unsigned char *required, size_t required_length, int required_count,
  lua_Integer slot,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *load_status, int *missing, int *missing_kind, int *stored, int *started)
{
  load_arguments a;
  int base;
  int status;
  trace_context context;
  trace_context **extra;
  trace_context *saved;

  (void) chunk_length;
  a.source = source;
  a.source_length = source_length;
  a.chunk = chunk;
  a.required = required;
  a.required_length = required_length;
  a.required_count = required_count;
  a.slot = slot;
  a.load_status = LUA_OK;
  a.missing = 0;
  a.missing_kind = 0;
  a.stored = 0;
  a.started = 0;
  a.gc_held.was = 0;
  a.gc_held.before = 0;
  *started = 0;
  *trace_length = 0;
  *load_status = LUA_OK;
  *missing = 0;
  *missing_kind = 0;
  *stored = 0;

  /* Held from here until the chunk is about to run (see `load_release`): the
  ** environment is made and the source parsed without executing anything. */
  a.gc_held = gc_hold(L);
  if (!lua_checkstack(L, 6)) {
    load_release(L, &a);
    return LUA_ERRMEM;
  }
  base = lua_gettop(L) + 1;
  lua_pushcfunction(L, traceback_handler);
  lua_pushcfunction(L, load_body);
  lua_pushlightuserdata(L, &a);
  context.buffer = trace;
  context.capacity = trace_capacity;
  context.length = trace_length;
  extra = (trace_context **) lua_getextraspace(L);
  saved = *extra;
  *extra = &context;
  status = lua_pcall(L, 1, 1, base);
  *extra = saved;
  load_release(L, &a);
  lua_remove(L, base);
  *started = a.started;
  *load_status = a.load_status;
  *missing = a.missing;
  *missing_kind = a.missing_kind;
  *stored = a.stored;
  return status;
}

static int release_body(lua_State *L)
{
  lua_Integer slot = lua_tointeger(L, 1);
  lua_settop(L, 0);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
  if (lua_istable(L, -1)) {
    lua_pushnil(L);
    lua_rawseti(L, -2, slot);
  }
  return 0;
}

int hetoimasia_lua_module_release(lua_State *L, lua_Integer slot)
{
  gc_hold_t held = gc_hold(L);
  int status;
  if (!lua_checkstack(L, 6)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, release_body);
  lua_pushinteger(L, slot);
  status = lua_pcall(L, 1, 0, 0);
  gc_release(L, held);
  return status;
}

typedef struct {
  lua_Integer slot;
  const char *name;
  size_t length;
  int kind;
  int found;
} lookup_arguments;

static int lookup_body(lua_State *L)
{
  lookup_arguments *a = (lookup_arguments *) lua_touserdata(L, 1);
  int type;
  lua_settop(L, 0);
  a->kind = 0;
  a->found = 0;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &modules_key);
  if (!lua_istable(L, -1)) {
    lua_pushnil(L);
    return 1;
  }
  lua_rawgeti(L, -1, a->slot);
  if (!lua_istable(L, -1)) {
    lua_pushnil(L);
    return 1;
  }
  a->found = 1;
  /* Found by walking the environment and comparing string keys in place, so that
  ** nothing is allocated: building the key to look it up with could start a
  ** collection step, and a step can run finalizers. Raw, like a lookup by key. */
  lua_pushnil(L); /* the answer, if there is none */
  lua_pushnil(L); /* the traversal's key */
  while (lua_next(L, -3)) {
    if (lua_type(L, -2) == LUA_TSTRING) {
      size_t n;
      const char *key = lua_tolstring(L, -2, &n);
      if (n == a->length && (n == 0 || memcmp(key, a->name, n) == 0)) {
        lua_copy(L, -1, 3);
        break;
      }
    }
    lua_pop(L, 1);
  }
  /* The environment is at 2, the answer at 3. */
  lua_settop(L, 3);
  type = lua_type(L, 3);
  if (type == LUA_TNIL) {
    a->kind = 0;
  } else if (type == LUA_TFUNCTION) {
    a->kind = 2;
    return 1;
  } else {
    a->kind = 1;
  }
  lua_pushnil(L);
  return 1;
}

int hetoimasia_lua_entry_lookup(
  lua_State *L, lua_Integer slot, const char *name, size_t length, int *kind, int *found_module)
{
  lookup_arguments a;
  int status;
  gc_hold_t held = gc_hold(L);
  a.slot = slot;
  a.name = name;
  a.length = length;
  a.kind = 0;
  a.found = 0;
  *kind = 0;
  *found_module = 0;
  if (!lua_checkstack(L, 8)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, lookup_body);
  lua_pushlightuserdata(L, &a);
  status = lua_pcall(L, 1, 1, 0);
  *kind = a.kind;
  *found_module = a.found;
  gc_release(L, held);
  return status;
}

/* ------------------------------------------------------------------------ */
/* Tasks: coroutines the host starts, resumes and closes                      */
/* ------------------------------------------------------------------------ */

/*
** A task is a Lua thread of the VM, anchored by slot in a table the bridge owns
** so that the collector cannot take it while the host holds a handle. Only the
** owner's thread starts, resumes or closes one, and every operation below is
** made while that thread holds the VM's gate.
**
** Nothing here lets a Lua error out of a C frame the Haskell caller sits in.
** Creating the thread is the one step that allocates, and it is one protected
** call. Resuming is `lua_resume`, which contains its errors and answers a
** status; the rest only moves values and reads call records, none of which
** allocates or can raise once the stack has been reserved with
** `lua_checkstack`, which reports failure rather than raising it.
*/

/* Look a task's coroutine up. The thread stays anchored; nothing is left on the
** stack. NULL when the slot holds nothing. */
static lua_State *task_thread(lua_State *L, lua_Integer slot)
{
  lua_State *co = NULL;
  if (!lua_checkstack(L, 4)) {
    return NULL;
  }
  lua_rawgetp(L, LUA_REGISTRYINDEX, &tasks_key);
  if (lua_istable(L, -1)) {
    lua_rawgeti(L, -1, slot);
    co = lua_tothread(L, -1);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return co;
}

/* Empty a task's slot, so the coroutine can be collected. The key exists, so
** setting it to nil allocates nothing. */
static void task_unanchor(lua_State *L, lua_Integer slot)
{
  if (!lua_checkstack(L, 4)) {
    return;
  }
  lua_rawgetp(L, LUA_REGISTRYINDEX, &tasks_key);
  if (lua_istable(L, -1)) {
    lua_pushnil(L);
    lua_rawseti(L, -2, slot);
  }
  lua_pop(L, 1);
}

/* The arguments are the function, its arguments and the slot. */
static int task_new_body(lua_State *L)
{
  int total = lua_gettop(L);
  lua_Integer slot = lua_tointeger(L, total);
  lua_State *co;

  lua_settop(L, total - 1);
  luaL_checkstack(L, 4, "creating a task");
  lua_rawgetp(L, LUA_REGISTRYINDEX, &tasks_key);
  if (!lua_istable(L, -1)) {
    return luaL_error(L, "the task table is missing");
  }
  co = lua_newthread(L);
  lua_pushvalue(L, -1);
  lua_rawseti(L, -3, slot);
  if (!lua_checkstack(co, total + LUA_MINSTACK)) {
    return luaL_error(L, "too many arguments for a task");
  }
  /* The function and its arguments move to the coroutine, the thread being
  ** anchored by now. */
  lua_pop(L, 2);
  lua_xmove(L, co, total - 1);
  return 0;
}

int hetoimasia_lua_task_new(lua_State *L, lua_Integer slot, int nargs)
{
  gc_hold_t held = gc_hold(L);
  int status;
  if (!lua_checkstack(L, 4)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, task_new_body);
  /* Below the function, which is nargs + 1 values down. */
  lua_insert(L, -(nargs + 2));
  lua_pushinteger(L, slot);
  status = lua_pcall(L, nargs + 2, 0, 0);
  gc_release(L, held);
  return status;
}

lua_State *hetoimasia_lua_task_thread(lua_State *L, lua_Integer slot)
{
  return task_thread(L, slot);
}

int hetoimasia_lua_yieldable(lua_State *L)
{
  return lua_isyieldable(L);
}

/* A failed segment's coroutine is dead and its stack intact. Close it, which
** runs the to-be-closed variables it still holds, keeping the error it failed
** with on its stack for them as Lua requires. The failure is copied to `L` and,
** when closing raised an error of its own, that error is copied above it.
**
** Answers 1 when closing raised an error other than the one it failed with. */
/* Whether the value on top of the stack is the placeholder a failed callback
** raises in Lua's terms: a light userdata carrying no address. Nothing a script
** can build is one. */
static int is_marker(lua_State *L)
{
  return lua_islightuserdata(L, -1) && lua_touserdata(L, -1) == NULL;
}

static int task_cleanup(lua_State *L, lua_State *co, lua_Integer slot, int *marker)
{
  int own = 0;
  int different = 0;
  *marker = 0;
  if (lua_gettop(co) >= 1 && lua_checkstack(L, 4)) {
    lua_xmove(co, L, 1);
    lua_pushvalue(L, -1);
    lua_xmove(L, co, 1);
    own = 1;
  }
  if (lua_closethread(co, L) != LUA_OK && lua_gettop(co) >= 1 && lua_checkstack(L, 4)) {
    lua_xmove(co, L, 1);
    if (own && lua_rawequal(L, -1, -2)) {
      lua_pop(L, 1);
    } else {
      different = 1;
      *marker = is_marker(L);
    }
  }
  task_unanchor(L, slot);
  return different;
}

/*
** Run the next segment of the task in `slot`: from the start when `starting`
** (the function and its arguments are on the coroutine's stack), else from
** where it yielded, with no values.
**
** `*outcome` says how the segment ended. For a completed task the results are
** moved onto `L`'s stack when there are `expected` of them. For a failed one the
** coroutine is left dead and anchored, with the error it failed with on its own
** stack, and `trace` holds the traceback of the failure.
*/
int hetoimasia_lua_task_resume(
  lua_State *L, lua_Integer slot, int starting, int expected,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *outcome, int *count, int *cleanup_error)
{
  lua_State *co;
  int status;
  int nresults = 0;
  int nargs;

  *trace_length = 0;
  *outcome = HETOIMASIA_TASK_UNRESUMABLE;
  *count = 0;
  *cleanup_error = 0;
  co = task_thread(L, slot);
  if (co == NULL) {
    return LUA_OK;
  }
  status = lua_status(co);
  if (starting ? !(status == LUA_OK && lua_gettop(co) >= 1) : status != LUA_YIELD) {
    return LUA_OK;
  }
  nargs = starting ? lua_gettop(co) - 1 : 0;
  /* What the host-side phases allocated is paid before script code runs. */
  gc_service(L);
  status = lua_resume(co, L, nargs, &nresults);
  if (status == LUA_OK) {
    task_unanchor(L, slot);
    *count = nresults;
    if (nresults != expected) {
      lua_pop(co, nresults);
      *outcome = HETOIMASIA_TASK_ARITY;
      return LUA_OK;
    }
    if (nresults > 0 && !lua_checkstack(L, nresults)) {
      lua_pop(co, nresults);
      *outcome = HETOIMASIA_TASK_ARITY;
      return LUA_ERRMEM;
    }
    lua_xmove(co, L, nresults);
    *outcome = HETOIMASIA_TASK_COMPLETED;
    return LUA_OK;
  }
  if (status == LUA_YIELD) {
    lua_pop(co, nresults);
    *count = nresults;
    *outcome = HETOIMASIA_TASK_YIELDED;
    return LUA_OK;
  }
  /* The coroutine is dead and its stack intact. It is closed by a call of its
  ** own (`hetoimasia_lua_task_cleanup`), so that what closing raises can be told
  ** from what the segment raised. */
  *trace_length = build_traceback(co, 0, trace, trace_capacity);
  *outcome = HETOIMASIA_TASK_FAILED;
  *cleanup_error = 0;
  return status;
}

/*
** Close the coroutine in `slot` that is not suspended where the host left it --
** one that failed, or that a script resumed itself -- running the to-be-closed
** variables it still holds, and unanchor it. The error it died with, if any, is
** on top of `L`'s stack afterwards, and above it the error closing raised if that
** was another (`*cleanup_error`). `*errored` says whether it had died with an
** error, which is whether it can have held anything to run.
*/
int hetoimasia_lua_task_cleanup(
  lua_State *L, lua_Integer slot, int *present, int *errored, int *cleanup_error, int *cleanup_marker)
{
  lua_State *co;
  *present = 0;
  *errored = 0;
  *cleanup_error = 0;
  *cleanup_marker = 0;
  co = task_thread(L, slot);
  if (co == NULL) {
    return LUA_OK;
  }
  *present = 1;
  *errored = lua_status(co) > LUA_YIELD;
  *cleanup_error = task_cleanup(L, co, slot, cleanup_marker);
  return LUA_OK;
}

/*
** Close the task in `slot`, running the to-be-closed variables of a suspended
** coroutine, and unanchor it either way. `*present` is 0 when the slot held
** nothing. `*failed` is 1 when closing raised an error, which is then on top of
** `L`'s stack unless that could not be reserved.
*/
int hetoimasia_lua_task_close(lua_State *L, lua_Integer slot, int *present, int *failed, int *marker)
{
  lua_State *co;
  *present = 0;
  *failed = 0;
  *marker = 0;
  co = task_thread(L, slot);
  if (co == NULL) {
    return LUA_OK;
  }
  *present = 1;
  if (lua_closethread(co, L) != LUA_OK) {
    *failed = 1;
    if (lua_gettop(co) >= 1 && lua_checkstack(L, 4)) {
      lua_xmove(co, L, 1);
      *marker = is_marker(L);
    }
  }
  task_unanchor(L, slot);
  return LUA_OK;
}

static int task_count_body(lua_State *L)
{
  long *out = (long *) lua_touserdata(L, 1);
  long n = 0;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &tasks_key);
  if (lua_istable(L, -1)) {
    lua_pushnil(L);
    while (lua_next(L, -2)) {
      n++;
      lua_pop(L, 1);
    }
  }
  *out = n;
  return 0;
}

int hetoimasia_lua_task_count(lua_State *L, long *count)
{
  gc_hold_t held = gc_hold(L);
  int status;
  *count = 0;
  if (!lua_checkstack(L, 8)) {
    gc_release(L, held);
    return LUA_ERRMEM;
  }
  lua_pushcfunction(L, task_count_body);
  lua_pushlightuserdata(L, count);
  status = lua_pcall(L, 1, 0, 0);
  gc_release(L, held);
  return status;
}
