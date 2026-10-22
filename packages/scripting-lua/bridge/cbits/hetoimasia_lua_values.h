/*
** Bounded values, application-owned modules and protected calls: the Lua
** operations the value boundary (LUA-3) performs itself.
**
** The same rule as the rest of this package's C holds here, and it is why none
** of this is written in Haskell on top of the binding's accessors. Almost every
** Lua operation that builds a value allocates, and an allocation failure in Lua
** is a Lua error, which is a `longjmp`. A `longjmp` through a Haskell frame is
** undefined behaviour, and a raise with no protected frame at all ends the
** process. So every operation below is one `lua_pcall` whose body may raise
** freely, because the only frames between the body and its `lua_pcall` are C,
** and it answers a status instead. Reading a value, writing one, loading a
** module and looking up an entry point are each such a call. The callback entry
** (see hetoimasia_lua_bridge.h) reaches them from inside a Haskell frame, which
** is what makes them the only way a binding can touch a Lua value there.
**
** Reading runs no Lua. Tables are read by raw access only, so no metamethod is
** consulted; a table carrying a metatable is refused before any of its entries
** are looked at; strings are read where they already are, and numbers are never
** converted. Nothing a read does can raise a Lua error: it takes no registry
** reference, converts no number to a string, and iterates with `lua_next` over
** keys it was handed by the previous step. What it allocates is C memory, and
** that is released on every path, including the one where a Lua error does
** occur after all, because the wrapper frees what the body left in its output.
**
** Values cross as a byte encoding, little endian throughout:
**
**   0x00                    nil
**   0x01 / 0x02             false / true
**   0x03 <8 bytes>          integer, two's complement
**   0x04 <8 bytes>          float, IEEE 754 binary64
**   0x05 <u32> <bytes>      string (Lua strings are byte strings; text is a
**                           schema's reading of one)
**   0x06 <u32 N> N x (key value)
**                           table; a key is an integer or a string
**   0x07 <u64> <u32> <u64>  handle: the VM that issued it, its type, its key
**
** The size of a copy is the size of its encoding, and the limits below are
** limits on that.
*/
#ifndef HETOIMASIA_LUA_VALUES_H
#define HETOIMASIA_LUA_VALUES_H

#include <HsFFI.h>
#include <lua.h>
#include <stddef.h>
#include <stdint.h>

/* Why a read refused. Zero is no refusal. */
enum {
  HETOIMASIA_READ_BYTES = 1,       /* the copy would pass the byte limit */
  HETOIMASIA_READ_DEPTH = 2,       /* tables nest deeper than the depth limit */
  HETOIMASIA_READ_ELEMENTS = 3,    /* more values than the element limit */
  HETOIMASIA_READ_CYCLE = 4,       /* a table contains itself */
  HETOIMASIA_READ_UNSUPPORTED = 5, /* a function, thread or foreign userdata */
  HETOIMASIA_READ_METATABLE = 6,   /* a table carrying a metatable */
  HETOIMASIA_READ_KEY = 7,         /* a table key that is not an integer or a string */
  HETOIMASIA_READ_STACK = 8,       /* working stack could not be reserved */
  HETOIMASIA_READ_MEMORY = 9,      /* C memory for the copy could not be had */
  HETOIMASIA_READ_FOREIGN = 10     /* a handle another VM issued */
};

/*
** Read `count` consecutive values of the current frame, starting at index
** `first`, into a copy bounded by the given limits.
**
** Answers the status of the one protected call that did the work, normally
** LUA_OK. A refusal is not a failed call: it is LUA_OK with `*refusal` set.
**
** On success, `*buffer` is a C allocation of `*length` bytes holding the copies
** one after another; the caller frees it with `hetoimasia_lua_free`. In every
** other case `*buffer` is NULL. `*visited` is how many values were visited,
** which a refusal for the element limit bounds by the limit plus one.
** `*argument` is the 1-based position of the value a refusal concerns, and
** `*lua_type` the Lua type tag of an unsupported value.
*/
int hetoimasia_lua_read_values(
  lua_State *L, int first, int count,
  size_t max_bytes, size_t max_depth, size_t max_elements, uint64_t vm_identity,
  int *refusal, int *argument, int *lua_type, size_t *visited,
  unsigned char **buffer, size_t *length);

/* Release an allocation `hetoimasia_lua_read_values` handed over. */
void hetoimasia_lua_free(void *pointer);

/*
** Push `count` values from their encoding onto the stack of the current frame.
**
** The encoding is this package's own, so a malformed one is a bug and is
** reported (`*malformed`), never trusted. `max_depth` is how deep it may nest,
** which reserves the stack it needs up front. Answers the status of the one
** protected call; on any status other than LUA_OK nothing was pushed that the
** caller needs to keep, and it restores its own stack depth.
*/
int hetoimasia_lua_push_values(
  lua_State *L, const unsigned char *buffer, size_t length, int count,
  size_t max_depth, int *malformed);

/*
** Create what the value boundary keeps in the registry: the metatable every
** handle wears and the table module slots live in. Both are built before either
** is reachable, so a failure part way leaves the registry as it was. Idempotent.
*/
int hetoimasia_lua_values_setup(lua_State *L);

/* How many modules are loaded: the occupied slots of the module table. */
int hetoimasia_lua_module_count(lua_State *L, long *count);

/*
** Create the namespace table `name` in the globals, with a raw set so that no
** metamethod runs. A namespace that already exists as a table is kept;
** `*collision` is set when the name is already something else.
*/
int hetoimasia_lua_namespace(lua_State *L, const char *name, size_t length, int *collision);

/*
** Install a Haskell function as `namespace.name`, as `hetoimasia_lua_publish`
** installs a global, with the same ownership report for the stable pointer.
** A `yielding` binding suspends the running coroutine, with no values, once
** its handler has returned: the yield is made in C after every Haskell frame
** has gone, as the error is.
*/
int hetoimasia_lua_install_binding(
  lua_State *L, HsStablePtr function,
  const char *space, size_t space_length, const char *name, size_t length, int yielding, int *acquired);

/*
** Load a module's source in an environment of its own, run it, check the entry
** points the application requires, and keep it in slot `slot`.
**
** The environment is a new table whose metatable reads through to the globals,
** so the module's global assignments are its own and the owner's libraries and
** namespaces are visible to it. The source is text only; a precompiled chunk is
** refused. `required` is `required_count` entries of a u32 length and that many
** bytes each. Everything is one protected call run under a message handler that
** captures a bounded traceback into `trace` (`trace_capacity` bytes, the length
** in `*trace_length`) without running script-defined Lua.
**
** `*load_status` is the status loading the chunk answered (a rejected chunk is
** LUA_ERRSYNTAX with its message on the stack), `*missing` the 1-based position
** of the first required entry point that is not a function, or 0, and
** `*missing_kind` 0 when it is absent and 1 when something else is there.
** `*stored` is 1 once the module is in its slot. `*started` is 1 once the chunk
** began to run: until then nothing executed, because the collector, whose
** finalizers are script-defined Lua, is held across everything before it.
*/
int hetoimasia_lua_load_module(
  lua_State *L,
  const char *source, size_t source_length, const char *chunk, size_t chunk_length,
  const unsigned char *required, size_t required_length, int required_count,
  lua_Integer slot,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *load_status, int *missing, int *missing_kind, int *stored, int *started);

/*
** Empty module slot `slot`, so the module it held is unreachable and its
** reference is gone. Setting a key of an existing table to nil allocates
** nothing, so this cannot run out of memory; it answers a status anyway.
*/
int hetoimasia_lua_module_release(lua_State *L, lua_Integer slot);

/*
** Pay what the host-side phases that held the collector allocated, as a
** collection step. A step can run `__gc` finalizers, which are script-defined
** Lua, so this is called only where script code may run: just before an entry
** point is called, and when a binding returns to its script.
*/
void hetoimasia_lua_gc_service(lua_State *L);

/*
** Look an entry point up in a module's own environment by raw access, so no
** metamethod runs. `*kind` is 0 for absent, 1 for something that is not a
** function and 2 for a function; the stack gains exactly one value, the
** function for 2 and nil otherwise.
*/
int hetoimasia_lua_entry_lookup(
  lua_State *L, lua_Integer slot, const char *name, size_t length, int *kind, int *found_module);

/*
** Describe where the running Lua code is, from inside a function Lua called: the
** short source of the Lua function that called it into `chunk`
** (`chunk_capacity` bytes, the length in `*chunk_length`), and a traceback from
** that level into `trace`. Neither runs script-defined Lua: `lua_getinfo` and
** `luaL_traceback` consult no metamethod. One protected call, so failing to
** build either leaves its length at zero and is never a different failure.
*/
int hetoimasia_lua_context(
  lua_State *L,
  char *chunk, size_t chunk_capacity, size_t *chunk_length,
  char *trace, size_t trace_capacity, size_t *trace_length);

/*
** Call the function below `nargs` arguments at the top of the stack under a
** message handler that captures a bounded traceback, leaving `nresults` results
** (or all of them for LUA_MULTRET) in its place.
*/
int hetoimasia_lua_call(
  lua_State *L, int nargs, int nresults,
  char *trace, size_t trace_capacity, size_t *trace_length);

/* ------------------------------------------------------------------------ */
/* Export modules and captured behaviors                                     */
/* ------------------------------------------------------------------------ */

/* What an export module's chunk returned. */
enum {
  HETOIMASIA_EXPORT_OK = 0,        /* exactly one table with no metatable: kept */
  HETOIMASIA_EXPORT_NO_RESULT = 1, /* no result */
  HETOIMASIA_EXPORT_NIL = 2,       /* a single nil */
  HETOIMASIA_EXPORT_NOT_TABLE = 3, /* a single value that is not a table */
  HETOIMASIA_EXPORT_MULTIPLE = 4,  /* more than one result, an extra nil included */
  HETOIMASIA_EXPORT_METATABLE = 5  /* a table with a metatable */
};

/*
** Evaluate an export module: load the text `source` (a precompiled chunk is
** refused) in an environment of its own that reads through to the globals, run
** it, and keep the one plain table it returns in slot `slot` of a table the
** bridge keeps in the registry. One protected call, under a message handler that
** captures a bounded traceback, with the collector held until the chunk starts.
**
** `*load_status` is the status loading the chunk answered (a rejected chunk is
** LUA_ERRSYNTAX with its message on the stack), `*shape` what the chunk returned
** (an HETOIMASIA_EXPORT_ value) and `*result_type` the Lua type of a result that
** is not a table. `*stored` is 1 once the table is in its slot; `*started` is 1
** once the chunk began to run. The stack gains one value, the error or nil.
*/
int hetoimasia_lua_export_load(
  lua_State *L,
  const char *source, size_t source_length, const char *chunk,
  lua_Integer slot,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *load_status, int *shape, int *result_type, int *stored, int *started);

/* Empty an export slot, or a capture slot. Setting a key of an existing table to
** nil allocates nothing; a status is answered anyway. */
int hetoimasia_lua_export_release(lua_State *L, lua_Integer slot);
int hetoimasia_lua_capture_release(lua_State *L, lua_Integer slot);

/* How many export slots, or capture slots, are occupied. */
int hetoimasia_lua_export_count(lua_State *L, long *count);
int hetoimasia_lua_capture_count(lua_State *L, long *count);

/* The fields of a behavior table: three hooks and two cadence fields. */
#define HETOIMASIA_HOOKS 3
#define HETOIMASIA_BEHAVIOR_KEYS 5

/* How a cadence field read. */
enum {
  HETOIMASIA_FIELD_ABSENT = 0,
  HETOIMASIA_FIELD_INTEGER = 1,
  HETOIMASIA_FIELD_FLOAT = 2,
  HETOIMASIA_FIELD_OTHER = 3 /* its Lua type is in the integer field */
};

/* The fields of the report a capture fills in. */
enum {
  HETOIMASIA_REPORT_PROBLEM = 0,
  HETOIMASIA_REPORT_STORED = 1,
  HETOIMASIA_REPORT_HOOKS = 2, /* bit 0 init, bit 1 update, bit 2 shutdown */
  HETOIMASIA_REPORT_TICKS_KIND = 3,
  HETOIMASIA_REPORT_TICKS_INTEGER = 4,
  HETOIMASIA_REPORT_TICKS_BITS = 5, /* the float's bits */
  HETOIMASIA_REPORT_SECONDS_KIND = 6,
  HETOIMASIA_REPORT_SECONDS_INTEGER = 7,
  HETOIMASIA_REPORT_SECONDS_BITS = 8,
  HETOIMASIA_REPORT_DETAIL = 9,      /* a Lua type, or the index of a hook */
  HETOIMASIA_REPORT_DETAIL_TYPE = 10, /* the Lua type of a hook that is not a function */
  HETOIMASIA_REPORT_NAME_LENGTH = 11,
  HETOIMASIA_REPORT_FIELDS = 12
};

/* Why a behavior was refused. */
enum {
  HETOIMASIA_BEHAVIOR_NONE = 0,
  HETOIMASIA_BEHAVIOR_NO_EXPORT = 1,
  HETOIMASIA_BEHAVIOR_MISSING = 2,
  HETOIMASIA_BEHAVIOR_NOT_TABLE = 3,
  HETOIMASIA_BEHAVIOR_METATABLE = 4,
  HETOIMASIA_BEHAVIOR_NON_TEXT_KEY = 5,
  HETOIMASIA_BEHAVIOR_UNKNOWN_KEY = 6,
  HETOIMASIA_BEHAVIOR_HOOK_NOT_FUNCTION = 7
};

/*
** Validate the field `select` of the export table in export slot `export_slot`
** as a behavior, and capture it in capture slot `capture_slot`. Everything is
** raw access and one bounded raw traversal of the behavior table: no
** metamethod, indexing function or conversion runs, and at most six of its
** entries are visited. The behavior must be a table with no metatable, and its
** only fields `init`, `update`, `shutdown`, `every_ticks` and `every_seconds`,
** each hook absent or a function.
**
** On success the capture holds the very hook functions and a fresh `self` table;
** the facade is attached next, by `hetoimasia_lua_capture_attach`. `report` is
** HETOIMASIA_REPORT_FIELDS values; `name` is where a key that is not in the
** schema is named, `name_capacity` bytes. Nothing is stored unless the report's
** problem is HETOIMASIA_BEHAVIOR_NONE and its stored flag is 1.
*/
int hetoimasia_lua_behavior_capture(
  lua_State *L,
  lua_Integer export_slot, const char *select, size_t select_length,
  lua_Integer capture_slot,
  int64_t *report, char *name, size_t name_capacity);

/*
** Make the value on top of the stack, which is left there, the capture's facade:
** the capture's `api`, and the `api` field of its `self`, the same value. `*attached`
** is 1 when there was a capture to attach it to.
*/
int hetoimasia_lua_capture_attach(lua_State *L, lua_Integer slot, int *attached);

/*
** Push the value the export table in `slot` holds under `key`, by raw access, and set
** `*type` to its Lua type (LUA_TNONE when the export is not held, nil pushed).
*/
int hetoimasia_lua_export_field(lua_State *L, lua_Integer slot, const char *key, size_t length, int *type);

/* What pushing a captured hook found. */
enum {
  HETOIMASIA_CAPTURE_GONE = 0,    /* no capture in the slot: nothing was kept */
  HETOIMASIA_CAPTURE_NO_HOOK = 1, /* the capture has no such hook */
  HETOIMASIA_CAPTURE_PUSHED = 2   /* the hook is a function */
};

/*
** Push, in this order, the captured hook `which` (0 init, 1 update, 2 shutdown),
** the capture's `self` and its facade: exactly three values, nil where there is
** none. `*present` says what was found. One protected call, no script code.
*/
int hetoimasia_lua_capture_push(lua_State *L, lua_Integer slot, int which, int *present);

/* ------------------------------------------------------------------------ */
/* Tasks                                                                     */
/* ------------------------------------------------------------------------ */

/* How a segment of a task ended. */
enum {
  HETOIMASIA_TASK_COMPLETED = 0,   /* returned; the results are on the stack */
  HETOIMASIA_TASK_YIELDED = 1,     /* suspended by a yield */
  HETOIMASIA_TASK_FAILED = 2,      /* raised an error; the coroutine is dead, not yet closed */
  HETOIMASIA_TASK_UNRESUMABLE = 3, /* the slot holds nothing resumable */
  HETOIMASIA_TASK_ARITY = 4        /* returned a number of results other than expected */
};

/*
** Create the coroutine of a task, anchor it in `slot` of a table the bridge
** keeps in the registry, and move into it the function and `nargs` arguments
** that are on top of the stack. One protected call, with the collector held, so
** nothing executes while it is made; what it allocated is paid when the task
** first runs. On any status other than LUA_OK the error value is on the stack in
** the place of the function and its arguments.
*/
int hetoimasia_lua_task_new(lua_State *L, lua_Integer slot, int nargs);

/* The coroutine anchored in `slot`, or NULL. Allocates nothing. */
lua_State *hetoimasia_lua_task_thread(lua_State *L, lua_Integer slot);

/* Whether the running function could yield: false inside a metamethod, a
** finalizer, a library callback that does not support it, and on a main
** thread. */
int hetoimasia_lua_yieldable(lua_State *L);

/* Whether the collector is running: 1 if it is, 0 if not. It is not while a Lua
** finalizer runs, which Lua holds it for, nor when a script stopped it, so 0 is
** the conservative reading of "a finalizer may be the caller". Runs no Lua. */
int hetoimasia_lua_collector_running(lua_State *L);

/*
** Run the next segment of the task in `slot`. See the definition for what each
** outcome leaves on the stack. The result is the status of a failure, LUA_OK
** otherwise.
*/
int hetoimasia_lua_task_resume(
  lua_State *L, lua_Integer slot, int starting, int expected,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *outcome, int *count, int *cleanup_error);

/*
** Close the coroutine in `slot` that is not suspended where the host left it,
** running its pending to-be-closed variables, and unanchor it. See the
** definition for what it leaves on the stack.
*/
int hetoimasia_lua_task_cleanup(
  lua_State *L, lua_Integer slot, int *present, int *errored, int *cleanup_error, int *cleanup_marker);

/*
** Close the task in `slot` and unanchor it. `*marker` says that the error closing
** raised, on top of the stack, is only the placeholder of a failed callback.
*/
int hetoimasia_lua_task_close(lua_State *L, lua_Integer slot, int *present, int *failed, int *marker);

/* How many tasks are anchored. */
int hetoimasia_lua_task_count(lua_State *L, long *count);

/* ------------------------------------------------------------------------ */
/* Loader frames                                                             */
/* ------------------------------------------------------------------------ */

/*
** Make the coroutine of an export module that may suspend on an `import`: load the
** text `source` (a precompiled chunk is refused) in an environment of its own that
** reads through to the globals and holds an `import` closure bound to `context`,
** anchor a coroutine for it in task slot `task_slot` and move the chunk into it. One
** protected call with the collector held, so nothing executes. `*load_status` is the
** status loading the chunk answered (a rejected chunk is LUA_ERRSYNTAX with its
** message on the stack), `*created` is 1 once the coroutine is anchored. The stack
** gains one value: the message of a rejected chunk, the error of a failed call, or nil.
*/
int hetoimasia_lua_loader_new(
  lua_State *L, const char *source, size_t source_length, const char *chunk,
  lua_Integer task_slot, lua_Integer context, int *load_status, int *created);

/* How a loader frame is resumed. */
enum {
  HETOIMASIA_RESUME_START = 0,  /* run the chunk from its start */
  HETOIMASIA_RESUME_EXPORTS = 1,/* answer a suspended `import` with an export table */
  HETOIMASIA_RESUME_ERROR = 2   /* answer a suspended `import` with a message to raise */
};

/*
** Run the next segment of the loader frame in `task_slot`: from its start, or from
** the `import` it suspended in, answered with the export table in `resume_slot` or
** with `message`. One protected call; the coroutine runs inside it under
** `lua_resume`, which contains its errors.
**
** `*outcome` says how the segment ended (an HETOIMASIA_TASK_ value). A chunk that
** returned is judged as an export module's is: `*shape` is what it returned, and
** when it returned exactly one plain table that table is kept in export slot
** `export_slot` (`*stored`). A failed segment leaves its coroutine dead and anchored,
** closed by `hetoimasia_lua_task_cleanup`, with `*segment_status` the status and
** `trace` the traceback. `*resumed` is 1 once the coroutine ran: a failure before
** then executed nothing.
*/
int hetoimasia_lua_loader_resume(
  lua_State *L, lua_Integer task_slot, lua_Integer export_slot, int mode, lua_Integer resume_slot,
  const char *message, size_t message_length,
  char *trace, size_t trace_capacity, size_t *trace_length,
  int *outcome, int *segment_status, int *shape, int *result_type, int *stored, int *resumed);

/* Push the export table kept in `slot` by raw access (nil when none), and set `*type`
** to its Lua type (LUA_TNONE when the export table is missing). */
int hetoimasia_lua_export_push(lua_State *L, lua_Integer slot, int *type);

#endif
