/*
** Bounded, C-only capture of Vulkan debug-utils diagnostics.
**
** This is the storage a debug-utils messenger's user data points at, and the
** producer the messenger calls. It includes no Vulkan header and links no
** loader: the one thing it knows about Vulkan is the layout of the callback's
** data, which it mirrors below and which the native backend package, the only
** code that includes both this header and the Vulkan headers, checks field by
** field at compile time.
**
** The producer runs on whatever thread the driver or a layer calls back from,
** including from inside a Vulkan call Haskell made through an `unsafe` import.
** So it runs no Haskell, allocates nothing, never waits for space, performs no
** I/O, calls no Vulkan function and cannot raise. It classifies the severity
** and latches an error before it attempts admission, copies what it admits
** under one per-record text budget and one object limit, and when the queue is
** full it counts the loss and returns. Every result is `VK_FALSE`, the
** non-aborting answer the API asks callbacks for.
**
** There is exactly one consumer: the drain worker, or after it has finished,
** the lifetime that owns the storage. It is not safe to peek or release from
** two threads at once. Everything else here — the latches, the counters, the
** producer itself — is safe from any thread at any time while the storage is
** alive.
**
** The storage is allocated with the C heap at construction and never grows.
** Its lifetime is the Haskell diagnostic lifetime's: nothing may free it while
** a messenger that names it can still call back, which is why closing waits
** for producers already inside `hetoimasia_vulkan_capture` to leave.
*/
#ifndef HETOIMASIA_VULKAN_CAPTURE_H
#define HETOIMASIA_VULKAN_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

/* The severity bits, numerically `VkDebugUtilsMessageSeverityFlagBitsEXT`. */
#define HETOIMASIA_CAPTURE_SEVERITY_VERBOSE 0x00000001u
#define HETOIMASIA_CAPTURE_SEVERITY_INFO 0x00000010u
#define HETOIMASIA_CAPTURE_SEVERITY_WARNING 0x00000100u
#define HETOIMASIA_CAPTURE_SEVERITY_ERROR 0x00001000u

/*
** The layout of `VkDebugUtilsObjectNameInfoEXT`. Only the three fields after
** the structure header are read.
*/
typedef struct hetoimasia_capture_object_name {
  int32_t s_type;
  const void *next;
  int32_t object_type;
  uint64_t object_handle;
  const char *object_name;
} hetoimasia_capture_object_name;

/*
** The layout of `VkDebugUtilsMessengerCallbackDataEXT`. Labels are not
** captured, so their element type is left opaque.
*/
typedef struct hetoimasia_capture_callback_data {
  int32_t s_type;
  const void *next;
  uint32_t flags;
  const char *message_id_name;
  int32_t message_id_number;
  const char *message;
  uint32_t queue_label_count;
  const void *queue_labels;
  uint32_t cmd_buf_label_count;
  const void *cmd_buf_labels;
  uint32_t object_count;
  const hetoimasia_capture_object_name *objects;
} hetoimasia_capture_callback_data;

/* The limits one storage is built with. Every one must be at least 1. */
typedef struct hetoimasia_capture_limits {
  uint32_t queue_capacity;
  uint32_t text_budget;
  uint32_t object_limit;
} hetoimasia_capture_limits;

typedef struct hetoimasia_capture_storage hetoimasia_capture_storage;
typedef struct hetoimasia_capture_record hetoimasia_capture_record;

/* What `hetoimasia_capture_create` answers. */
#define HETOIMASIA_CAPTURE_CREATED 0
#define HETOIMASIA_CAPTURE_INVALID_LIMIT 1
#define HETOIMASIA_CAPTURE_SIZE_OVERFLOW 2
#define HETOIMASIA_CAPTURE_OUT_OF_MEMORY 3

/*
** Build a storage with these limits, or answer why not. On success `*out` is
** the storage; otherwise it is left NULL and nothing was allocated.
*/
int hetoimasia_capture_create(
  const hetoimasia_capture_limits *limits, hetoimasia_capture_storage **out);

/*
** The bytes one queued record occupies beside its text budget, and the bytes
** one captured object occupies, so a configuration can be checked against the
** allocation it would need before anything is allocated.
*/
size_t hetoimasia_capture_record_size(void);
size_t hetoimasia_capture_object_size(void);

/*
** Free a storage. The caller must have closed it, and no producer and no
** consumer may touch it again.
*/
void hetoimasia_capture_destroy(hetoimasia_capture_storage *storage);

/*
** The production producer: a debug-utils messenger callback with this storage
** as its user data. The parameters are the callback's, with the Vulkan types
** spelled by their width. Always answers 0, `VK_FALSE`.
**
** A NULL user data, or one that is not a live storage, is ignored: there is
** nowhere to record it. A NULL callback data is a producer-side failure and
** latches capture failure. A record offered after the storage was closed is
** one too, because it can no longer be delivered.
*/
uint32_t hetoimasia_capture_callback(
  uint32_t severity,
  uint32_t types,
  const hetoimasia_capture_callback_data *data,
  void *user_data);

/*
** Stop admission, then wait until every producer already inside
** `hetoimasia_capture_callback` has left. Afterwards every admitted record is
** published and no new one can be. The wait never blocks on anything but a
** producer's own bounded copy.
*/
void hetoimasia_capture_close(hetoimasia_capture_storage *storage);

/* Whether admission is closed. */
int hetoimasia_capture_closed(const hetoimasia_capture_storage *storage);

/*
** The consumer's view: the oldest published record, or NULL when there is
** none yet. It stays valid until `hetoimasia_capture_release`.
*/
const hetoimasia_capture_record *hetoimasia_capture_peek(hetoimasia_capture_storage *storage);

/* Give the record `hetoimasia_capture_peek` answered back to the producers. */
void hetoimasia_capture_release(hetoimasia_capture_storage *storage);

/* A record's fields. Text is not NUL-terminated: read it with its length. */
uint32_t hetoimasia_capture_record_severity(const hetoimasia_capture_record *record);
uint32_t hetoimasia_capture_record_types(const hetoimasia_capture_record *record);
int32_t hetoimasia_capture_record_id_number(const hetoimasia_capture_record *record);
int hetoimasia_capture_record_has_id_name(const hetoimasia_capture_record *record);
const char *hetoimasia_capture_record_id_name(const hetoimasia_capture_record *record);
uint32_t hetoimasia_capture_record_id_name_length(const hetoimasia_capture_record *record);
const char *hetoimasia_capture_record_message(const hetoimasia_capture_record *record);
uint32_t hetoimasia_capture_record_message_length(const hetoimasia_capture_record *record);
int hetoimasia_capture_record_truncated(const hetoimasia_capture_record *record);
uint32_t hetoimasia_capture_record_objects_reported(const hetoimasia_capture_record *record);
uint32_t hetoimasia_capture_record_object_count(const hetoimasia_capture_record *record);
int32_t hetoimasia_capture_record_object_type(const hetoimasia_capture_record *record, uint32_t index);
uint64_t hetoimasia_capture_record_object_handle(const hetoimasia_capture_record *record, uint32_t index);
int hetoimasia_capture_record_object_has_name(const hetoimasia_capture_record *record, uint32_t index);
const char *hetoimasia_capture_record_object_name(const hetoimasia_capture_record *record, uint32_t index);
uint32_t hetoimasia_capture_record_object_name_length(const hetoimasia_capture_record *record, uint32_t index);

/* The counters, each saturating at UINT64_MAX. */
#define HETOIMASIA_CAPTURE_OFFERED 0
#define HETOIMASIA_CAPTURE_ADMITTED 1
#define HETOIMASIA_CAPTURE_DROPPED 2
#define HETOIMASIA_CAPTURE_TRUNCATED 3
#define HETOIMASIA_CAPTURE_FAILED 4
#define HETOIMASIA_CAPTURE_ERRORS 5
#define HETOIMASIA_CAPTURE_COUNTERS 6

/* A counter's value, or 0 for an index that names none. */
uint64_t hetoimasia_capture_counter(const hetoimasia_capture_storage *storage, int which);

/* The latches, which only ever go from 0 to 1. */
#define HETOIMASIA_CAPTURE_ERROR_LATCH 0
#define HETOIMASIA_CAPTURE_FAILURE_LATCH 1

int hetoimasia_capture_latch(const hetoimasia_capture_storage *storage, int which);

/*
** Test support: set a counter to a value, so saturation can be shown without
** offering 2^64 records. Nothing in production calls it.
*/
void hetoimasia_capture_preset_counter(hetoimasia_capture_storage *storage, int which, uint64_t value);

/*
** Test support: offer one record exactly as a messenger would, building the
** callback data on this frame and calling `hetoimasia_capture_callback` with
** it. `null_data` passes NULL callback data instead, which is how a
** producer-side failure is exercised. `object_names` may be NULL, and so may
** any entry in it.
*/
uint32_t hetoimasia_capture_offer(
  void *user_data,
  uint32_t severity,
  uint32_t types,
  const char *id_name,
  int32_t id_number,
  const char *message,
  uint32_t object_count,
  const int32_t *object_types,
  const uint64_t *object_handles,
  const char *const *object_names,
  int null_data);

#endif
