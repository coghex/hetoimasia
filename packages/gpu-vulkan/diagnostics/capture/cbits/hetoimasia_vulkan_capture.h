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
** under one per-record text budget, one object limit and one label limit, and
** when the queue is full it counts the loss and returns. Every result is `VK_FALSE`, the
** non-aborting answer the API asks callbacks for.
**
** There is exactly one consumer: the drain worker, or after it has finished,
** the lifetime that owns the storage. It is not safe to peek or release from
** two threads at once.
**
** What a producer touches before it knows admission is open — its
** announcement, the close handshake, the latches and the counters — lives in a
** slot of a fixed static table, never on the heap, so a producer that is late
** by any amount always lands on live memory. The queue itself is a heap storage
** that only an announced producer finding admission open ever reaches, and
** closing waits for every such producer, so the storage can be freed whole once
** it is closed. A slot is reused only after every producer announced against it
** has left and its generation has moved on. The user data a messenger carries
** encodes the slot and the generation rather than pointing anywhere, so a stale
** or foreign one names nothing and is ignored.
**
** Announcing is the callback's first memory operation. A report that has not
** even begun when the storage closes — a Vulkan call still running when the
** lifetime that owns the storage ended, which the lifetime's contract rules
** out — is outside the verdict, but still counted: as a capture failure, in
** the slot the status query reads until the slot is claimed again.
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
** The layout of `VkDebugUtilsLabelEXT`. Only the name is read; the colour is
** mirrored so the element stride is the headers'.
*/
typedef struct hetoimasia_capture_label {
  int32_t s_type;
  const void *next;
  const char *label_name;
  float color[4];
} hetoimasia_capture_label;

/* The layout of `VkDebugUtilsMessengerCallbackDataEXT`. */
typedef struct hetoimasia_capture_callback_data {
  int32_t s_type;
  const void *next;
  uint32_t flags;
  const char *message_id_name;
  int32_t message_id_number;
  const char *message;
  uint32_t queue_label_count;
  const hetoimasia_capture_label *queue_labels;
  uint32_t cmd_buf_label_count;
  const hetoimasia_capture_label *cmd_buf_labels;
  uint32_t object_count;
  const hetoimasia_capture_object_name *objects;
} hetoimasia_capture_callback_data;

/*
** The limits one storage is built with. Every one must be at least 1. The label
** limit bounds the queue labels and the command-buffer labels separately.
*/
typedef struct hetoimasia_capture_limits {
  uint32_t queue_capacity;
  uint32_t text_budget;
  uint32_t object_limit;
  uint32_t label_limit;
} hetoimasia_capture_limits;

typedef struct hetoimasia_capture_storage hetoimasia_capture_storage;
typedef struct hetoimasia_capture_record hetoimasia_capture_record;

/* What `hetoimasia_capture_create` answers. */
#define HETOIMASIA_CAPTURE_CREATED 0
#define HETOIMASIA_CAPTURE_INVALID_LIMIT 1
#define HETOIMASIA_CAPTURE_SIZE_OVERFLOW 2
#define HETOIMASIA_CAPTURE_OUT_OF_MEMORY 3
#define HETOIMASIA_CAPTURE_NO_SLOT 4

/* How many storages can be live at once in one process. */
#define HETOIMASIA_CAPTURE_SLOTS 64

/*
** Build a storage with these limits, or answer why not. On success `*out` is
** the storage; otherwise it is left NULL and nothing was allocated.
*/
int hetoimasia_capture_create(
  const hetoimasia_capture_limits *limits, hetoimasia_capture_storage **out);

/*
** The bytes one queued record occupies beside its text budget, and the bytes
** one captured object and one captured label occupy, so a configuration can be
** checked against the allocation it would need before anything is allocated.
*/
size_t hetoimasia_capture_record_size(void);
size_t hetoimasia_capture_object_size(void);
size_t hetoimasia_capture_label_size(void);

/* The user data every messenger registering this storage carries. */
void *hetoimasia_capture_user_data(const hetoimasia_capture_storage *storage);

/*
** Close the storage if it is not closed, and free it. The consumer must not
** touch it again. Its slot keeps its latches and counters, readable through
** `hetoimasia_capture_status`, until another storage claims it; a report still
** reaching the producer is counted there as a capture failure.
*/
void hetoimasia_capture_free(hetoimasia_capture_storage *storage);

/*
** The production producer: a debug-utils messenger callback with this storage
** as its user data. The parameters are the callback's, with the Vulkan types
** spelled by their width. Always answers 0, `VK_FALSE`.
**
** A user data that names no slot, or a slot now serving another storage, is
** ignored: there is nowhere to record it. A NULL callback data is a producer-side failure and
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

/*
** A record's labels, in the callback's order. `queue` chooses the queue labels
** when non-zero and the command-buffer labels otherwise. "Reported" is the count
** the callback carried; "count" is how many were copied.
*/
uint32_t hetoimasia_capture_record_labels_reported(const hetoimasia_capture_record *record, int queue);
uint32_t hetoimasia_capture_record_label_count(const hetoimasia_capture_record *record, int queue);
int hetoimasia_capture_record_label_has_name(const hetoimasia_capture_record *record, int queue, uint32_t index);
const char *hetoimasia_capture_record_label_name(const hetoimasia_capture_record *record, int queue, uint32_t index);
uint32_t hetoimasia_capture_record_label_name_length(const hetoimasia_capture_record *record, int queue, uint32_t index);

/* The counters, each saturating at UINT64_MAX. */
#define HETOIMASIA_CAPTURE_OFFERED 0
#define HETOIMASIA_CAPTURE_ADMITTED 1
#define HETOIMASIA_CAPTURE_DROPPED 2
#define HETOIMASIA_CAPTURE_TRUNCATED 3
#define HETOIMASIA_CAPTURE_FAILED 4
#define HETOIMASIA_CAPTURE_ERRORS 5
#define HETOIMASIA_CAPTURE_COUNTERS 6

/* The latches, which only ever go from 0 to 1. */
#define HETOIMASIA_CAPTURE_ERROR_LATCH 0
#define HETOIMASIA_CAPTURE_FAILURE_LATCH 1

/*
** Read the counters and latches of the storage this user data was issued for,
** into `counters[HETOIMASIA_CAPTURE_COUNTERS]` and `latches[2]`. Answers 1 when
** every value read was that storage's, and 0 when its slot has since been
** claimed by another — before or after the storage was freed makes no
** difference until then.
*/
int hetoimasia_capture_status(void *user_data, uint64_t *counters, int *latches);

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
** any entry in it. A label count with a NULL name array passes a NULL label
** array; a NULL entry in a name array passes a label whose name is NULL.
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
  uint32_t queue_label_count,
  const char *const *queue_label_names,
  uint32_t cmd_buf_label_count,
  const char *const *cmd_buf_label_names,
  int null_data);

/*
** Test support: offer one plain record, but only once `*gate` is non-zero,
** having first set `*arrived`. From the storage's side this is a report that has
** not yet begun, held for as long as the caller likes — across a close, and
** across freeing the storage.
*/
uint32_t hetoimasia_capture_offer_held(
  void *user_data, int *arrived, int *gate, uint32_t severity, const char *message);

/*
** Test support: offer one plain record through the production producer, pausing
** just after the producer has announced itself — the earliest point anything
** about the report is visible — until `*gate` is non-zero, having set
** `*arrived`. Closing waits for it there.
*/
uint32_t hetoimasia_capture_offer_announced(
  void *user_data, int *arrived, int *gate, uint32_t severity, const char *message);

/* Test support: set a flag, and read one, with atomic ordering. */
void hetoimasia_capture_flag_set(int *flag);
int hetoimasia_capture_flag_get(int *flag);

#endif
