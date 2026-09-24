/*
** The capture storage and its producer. See the header for the contract.
**
** The queue is a bounded multi-producer, single-consumer ring in which every
** slot carries a sequence number (after Vyukov's bounded queue). A producer
** claims the next position with one compare-and-swap, copies into the slot it
** claimed, and publishes it by advancing the slot's sequence; a producer that
** finds the slot at the head still holding an unconsumed record has found the
** queue full, counts the loss, and returns. Nothing waits for space, and a
** producer that loses a race for a position only retries against the position
** that beat it.
**
** A slot's sequence says, for position p: free for p is 2p, published for p is
** 2p + 1, and consuming p frees the slot for p + capacity, 2(p + capacity).
** Vyukov's own encoding (p, p + 1, p + capacity) cannot tell a record published
** for p from a slot free for p + 1 when the capacity is one, and a one-record
** queue is a valid configuration here.
**
** Every record's storage is carved out of three arrays allocated once: the
** slots, `queue_capacity * object_limit` object records, and
** `queue_capacity * text_budget` bytes of text. A record's text budget is
** shared by its message id name, its message and every object name, in that
** order, so a record never copies more than the budget in total.
**
** Closing is a Dekker handshake between `closed` and `active`. A producer
** increments `active` before it reads `closed` and decrements it only after it
** has published or given up; the closer sets `closed` before it reads `active`.
** Both use sequentially consistent operations, so either the producer sees the
** storage closed, or the closer sees the producer and waits for it.
*/
#include "hetoimasia_vulkan_capture.h"

#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* Distinguishes a live storage from anything else a user data might name. */
#define CAPTURE_MAGIC UINT64_C(0x6865746f696d7663)

typedef struct capture_object {
  int32_t type;
  uint64_t handle;
  uint32_t name_offset;
  uint32_t name_length;
  int has_name;
} capture_object;

struct hetoimasia_capture_record {
  _Atomic uint64_t sequence;
  uint32_t severity;
  uint32_t types;
  int32_t id_number;
  int has_id_name;
  uint32_t id_name_offset;
  uint32_t id_name_length;
  uint32_t message_offset;
  uint32_t message_length;
  int truncated;
  uint32_t objects_reported;
  uint32_t object_count;
  char *text;
  capture_object *objects;
};

struct hetoimasia_capture_storage {
  _Atomic uint64_t magic;
  hetoimasia_capture_limits limits;
  struct hetoimasia_capture_record *records;
  capture_object *objects;
  char *text;
  _Atomic uint64_t enqueue;
  /* The consumer's position. Only the single consumer reads or writes it. */
  uint64_t dequeue;
  _Atomic int closed;
  _Atomic uint64_t active;
  _Atomic int latches[2];
  _Atomic uint64_t counters[HETOIMASIA_CAPTURE_COUNTERS];
};

/* a * b, or 0 with *overflow set when it does not fit in a size_t. */
static size_t checked_multiply(size_t a, size_t b, int *overflow)
{
  if (a != 0 && b > SIZE_MAX / a) {
    *overflow = 1;
    return 0;
  }
  return a * b;
}

int hetoimasia_capture_create(
  const hetoimasia_capture_limits *limits, hetoimasia_capture_storage **out)
{
  *out = NULL;
  if (limits == NULL || limits->queue_capacity == 0 || limits->text_budget == 0
      || limits->object_limit == 0) {
    return HETOIMASIA_CAPTURE_INVALID_LIMIT;
  }

  int overflow = 0;
  size_t capacity = limits->queue_capacity;
  size_t record_bytes = checked_multiply(capacity, sizeof(struct hetoimasia_capture_record), &overflow);
  size_t object_slots = checked_multiply(capacity, limits->object_limit, &overflow);
  size_t object_bytes = checked_multiply(object_slots, sizeof(capture_object), &overflow);
  size_t text_bytes = checked_multiply(capacity, limits->text_budget, &overflow);
  /* Positions run on a 64-bit counter and wrap only after 2^64 records. */
  if (overflow) {
    return HETOIMASIA_CAPTURE_SIZE_OVERFLOW;
  }

  hetoimasia_capture_storage *storage = calloc(1, sizeof *storage);
  struct hetoimasia_capture_record *records = malloc(record_bytes);
  capture_object *objects = malloc(object_bytes);
  char *text = malloc(text_bytes);
  if (storage == NULL || records == NULL || objects == NULL || text == NULL) {
    free(storage);
    free(records);
    free(objects);
    free(text);
    return HETOIMASIA_CAPTURE_OUT_OF_MEMORY;
  }

  storage->limits = *limits;
  storage->records = records;
  storage->objects = objects;
  storage->text = text;
  storage->dequeue = 0;
  atomic_init(&storage->enqueue, 0);
  atomic_init(&storage->closed, 0);
  atomic_init(&storage->active, 0);
  for (int latch = 0; latch < 2; latch++) {
    atomic_init(&storage->latches[latch], 0);
  }
  for (int counter = 0; counter < HETOIMASIA_CAPTURE_COUNTERS; counter++) {
    atomic_init(&storage->counters[counter], 0);
  }
  for (size_t index = 0; index < capacity; index++) {
    struct hetoimasia_capture_record *record = &records[index];
    memset(record, 0, sizeof *record);
    atomic_init(&record->sequence, 2 * (uint64_t) index);
    record->text = text + index * limits->text_budget;
    record->objects = objects + index * limits->object_limit;
  }
  /* Published last: a user data is only ever a live storage once it is whole. */
  atomic_store(&storage->magic, CAPTURE_MAGIC);
  *out = storage;
  return HETOIMASIA_CAPTURE_CREATED;
}

size_t hetoimasia_capture_record_size(void)
{
  return sizeof(struct hetoimasia_capture_record);
}

size_t hetoimasia_capture_object_size(void)
{
  return sizeof(capture_object);
}

void hetoimasia_capture_free_records(hetoimasia_capture_storage *storage)
{
  if (storage == NULL) {
    return;
  }
  /* Only a closed storage: a producer that announces itself from here on sees
     `closed` and leaves before it could reach the records. */
  atomic_store(&storage->closed, 1);
  free(storage->records);
  free(storage->objects);
  free(storage->text);
  storage->records = NULL;
  storage->objects = NULL;
  storage->text = NULL;
}

static void saturating_increment(_Atomic uint64_t *counter)
{
  uint64_t current = atomic_load_explicit(counter, memory_order_relaxed);
  while (current != UINT64_MAX
         && !atomic_compare_exchange_weak_explicit(
           counter, &current, current + 1, memory_order_relaxed, memory_order_relaxed)) {
  }
}

static void latch(hetoimasia_capture_storage *storage, int which)
{
  atomic_store(&storage->latches[which], 1);
}

/*
** Copy a NUL-terminated string into `destination`, at most `room` bytes of it.
** Answers the number of bytes copied, and sets `*truncated` when the string
** continued past the room it was given. Reading `source[room]` is safe exactly
** when the loop stopped at `room`, because every byte before it was non-NUL.
*/
static uint32_t bounded_copy(char *destination, const char *source, uint32_t room, int *truncated)
{
  uint32_t copied = 0;
  while (copied < room && source[copied] != '\0') {
    destination[copied] = source[copied];
    copied++;
  }
  if (copied == room && source[copied] != '\0') {
    *truncated = 1;
  }
  return copied;
}

/* Fill a claimed record. Answers whether anything had to be cut. */
static int fill(
  struct hetoimasia_capture_record *record,
  const hetoimasia_capture_limits *limits,
  uint32_t severity,
  uint32_t types,
  const hetoimasia_capture_callback_data *data)
{
  int truncated = 0;
  uint32_t used = 0;
  uint32_t budget = limits->text_budget;

  record->severity = severity;
  record->types = types;
  record->id_number = data->message_id_number;

  record->has_id_name = data->message_id_name != NULL;
  record->id_name_offset = used;
  record->id_name_length = 0;
  if (record->has_id_name) {
    record->id_name_length = bounded_copy(record->text + used, data->message_id_name, budget - used, &truncated);
    used += record->id_name_length;
  }

  record->message_offset = used;
  record->message_length = 0;
  if (data->message != NULL) {
    record->message_length = bounded_copy(record->text + used, data->message, budget - used, &truncated);
    used += record->message_length;
  }

  record->objects_reported = data->object_count;
  record->object_count = 0;
  if (data->object_count > 0 && data->objects == NULL) {
    /* An array the callback promised and did not pass: nothing to copy. */
    truncated = 1;
  } else {
    uint32_t wanted = data->object_count;
    if (wanted > limits->object_limit) {
      wanted = limits->object_limit;
      truncated = 1;
    }
    for (uint32_t index = 0; index < wanted; index++) {
      const hetoimasia_capture_object_name *source = &data->objects[index];
      capture_object *object = &record->objects[index];
      object->type = source->object_type;
      object->handle = source->object_handle;
      object->has_name = source->object_name != NULL;
      object->name_offset = used;
      object->name_length = 0;
      if (object->has_name) {
        object->name_length = bounded_copy(record->text + used, source->object_name, budget - used, &truncated);
        used += object->name_length;
      }
    }
    record->object_count = wanted;
  }

  record->truncated = truncated;
  return truncated;
}

uint32_t hetoimasia_capture_callback(
  uint32_t severity,
  uint32_t types,
  const hetoimasia_capture_callback_data *data,
  void *user_data)
{
  hetoimasia_capture_storage *storage = user_data;
  /* The header is never freed, so reading it is safe however late this is. */
  if (storage == NULL || atomic_load(&storage->magic) != CAPTURE_MAGIC) {
    return 0;
  }

  atomic_fetch_add(&storage->active, 1);
  saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_OFFERED]);

  /* Before anything else can fail or be dropped: a full queue, a closed
     storage and a missing payload must none of them hide an error. */
  if (severity & HETOIMASIA_CAPTURE_SEVERITY_ERROR) {
    latch(storage, HETOIMASIA_CAPTURE_ERROR_LATCH);
    saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_ERRORS]);
  }

  if (atomic_load(&storage->closed) || data == NULL) {
    latch(storage, HETOIMASIA_CAPTURE_FAILURE_LATCH);
    saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_FAILED]);
    atomic_fetch_sub(&storage->active, 1);
    return 0;
  }

  uint64_t capacity = storage->limits.queue_capacity;
  uint64_t position = atomic_load_explicit(&storage->enqueue, memory_order_relaxed);
  struct hetoimasia_capture_record *record;
  for (;;) {
    record = &storage->records[position % capacity];
    uint64_t sequence = atomic_load_explicit(&record->sequence, memory_order_acquire);
    int64_t difference = (int64_t) (sequence - 2 * position);
    if (difference == 0) {
      if (atomic_compare_exchange_weak_explicit(
            &storage->enqueue, &position, position + 1, memory_order_relaxed, memory_order_relaxed)) {
        break;
      }
    } else if (difference < 0) {
      saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_DROPPED]);
      atomic_fetch_sub(&storage->active, 1);
      return 0;
    } else {
      position = atomic_load_explicit(&storage->enqueue, memory_order_relaxed);
    }
  }

  if (fill(record, &storage->limits, severity, types, data)) {
    saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_TRUNCATED]);
  }
  atomic_store_explicit(&record->sequence, 2 * position + 1, memory_order_release);
  saturating_increment(&storage->counters[HETOIMASIA_CAPTURE_ADMITTED]);
  atomic_fetch_sub(&storage->active, 1);
  return 0;
}

void hetoimasia_capture_close(hetoimasia_capture_storage *storage)
{
  atomic_store(&storage->closed, 1);
  while (atomic_load(&storage->active) != 0) {
    sched_yield();
  }
}

int hetoimasia_capture_closed(const hetoimasia_capture_storage *storage)
{
  return atomic_load(&((hetoimasia_capture_storage *) storage)->closed);
}

const hetoimasia_capture_record *hetoimasia_capture_peek(hetoimasia_capture_storage *storage)
{
  uint64_t position = storage->dequeue;
  struct hetoimasia_capture_record *record = &storage->records[position % storage->limits.queue_capacity];
  uint64_t sequence = atomic_load_explicit(&record->sequence, memory_order_acquire);
  return sequence == 2 * position + 1 ? record : NULL;
}

void hetoimasia_capture_release(hetoimasia_capture_storage *storage)
{
  uint64_t position = storage->dequeue;
  uint64_t capacity = storage->limits.queue_capacity;
  struct hetoimasia_capture_record *record = &storage->records[position % capacity];
  atomic_store_explicit(&record->sequence, 2 * (position + capacity), memory_order_release);
  storage->dequeue = position + 1;
}

uint32_t hetoimasia_capture_record_severity(const hetoimasia_capture_record *record)
{
  return record->severity;
}

uint32_t hetoimasia_capture_record_types(const hetoimasia_capture_record *record)
{
  return record->types;
}

int32_t hetoimasia_capture_record_id_number(const hetoimasia_capture_record *record)
{
  return record->id_number;
}

int hetoimasia_capture_record_has_id_name(const hetoimasia_capture_record *record)
{
  return record->has_id_name;
}

const char *hetoimasia_capture_record_id_name(const hetoimasia_capture_record *record)
{
  return record->text + record->id_name_offset;
}

uint32_t hetoimasia_capture_record_id_name_length(const hetoimasia_capture_record *record)
{
  return record->id_name_length;
}

const char *hetoimasia_capture_record_message(const hetoimasia_capture_record *record)
{
  return record->text + record->message_offset;
}

uint32_t hetoimasia_capture_record_message_length(const hetoimasia_capture_record *record)
{
  return record->message_length;
}

int hetoimasia_capture_record_truncated(const hetoimasia_capture_record *record)
{
  return record->truncated;
}

uint32_t hetoimasia_capture_record_objects_reported(const hetoimasia_capture_record *record)
{
  return record->objects_reported;
}

uint32_t hetoimasia_capture_record_object_count(const hetoimasia_capture_record *record)
{
  return record->object_count;
}

int32_t hetoimasia_capture_record_object_type(const hetoimasia_capture_record *record, uint32_t index)
{
  return record->objects[index].type;
}

uint64_t hetoimasia_capture_record_object_handle(const hetoimasia_capture_record *record, uint32_t index)
{
  return record->objects[index].handle;
}

int hetoimasia_capture_record_object_has_name(const hetoimasia_capture_record *record, uint32_t index)
{
  return record->objects[index].has_name;
}

const char *hetoimasia_capture_record_object_name(const hetoimasia_capture_record *record, uint32_t index)
{
  return record->text + record->objects[index].name_offset;
}

uint32_t hetoimasia_capture_record_object_name_length(const hetoimasia_capture_record *record, uint32_t index)
{
  return record->objects[index].name_length;
}

uint64_t hetoimasia_capture_counter(const hetoimasia_capture_storage *storage, int which)
{
  if (which < 0 || which >= HETOIMASIA_CAPTURE_COUNTERS) {
    return 0;
  }
  return atomic_load(&((hetoimasia_capture_storage *) storage)->counters[which]);
}

int hetoimasia_capture_latch(const hetoimasia_capture_storage *storage, int which)
{
  if (which < 0 || which > 1) {
    return 0;
  }
  return atomic_load(&((hetoimasia_capture_storage *) storage)->latches[which]);
}

void hetoimasia_capture_preset_counter(hetoimasia_capture_storage *storage, int which, uint64_t value)
{
  if (which >= 0 && which < HETOIMASIA_CAPTURE_COUNTERS) {
    atomic_store(&storage->counters[which], value);
  }
}

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
  int null_data)
{
  hetoimasia_capture_object_name objects[object_count > 0 ? object_count : 1];
  for (uint32_t index = 0; object_types != NULL && index < object_count; index++) {
    objects[index].s_type = 0;
    objects[index].next = NULL;
    objects[index].object_type = object_types[index];
    objects[index].object_handle = object_handles[index];
    objects[index].object_name = object_names == NULL ? NULL : object_names[index];
  }
  hetoimasia_capture_callback_data data = {
    .s_type = 0,
    .next = NULL,
    .flags = 0,
    .message_id_name = id_name,
    .message_id_number = id_number,
    .message = message,
    .queue_label_count = 0,
    .queue_labels = NULL,
    .cmd_buf_label_count = 0,
    .cmd_buf_labels = NULL,
    .object_count = object_count,
    .objects = object_types == NULL ? NULL : objects,
  };
  return hetoimasia_capture_callback(severity, types, null_data ? NULL : &data, user_data);
}

uint32_t hetoimasia_capture_offer_held(
  void *user_data, int *arrived, int *gate, uint32_t severity, const char *message)
{
  __atomic_store_n(arrived, 1, __ATOMIC_SEQ_CST);
  while (__atomic_load_n(gate, __ATOMIC_SEQ_CST) == 0) {
    sched_yield();
  }
  return hetoimasia_capture_offer(user_data, severity, 0x2, NULL, 0, message, 0, NULL, NULL, NULL, 0);
}

void hetoimasia_capture_flag_set(int *flag)
{
  __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
}

int hetoimasia_capture_flag_get(int *flag)
{
  return __atomic_load_n(flag, __ATOMIC_SEQ_CST);
}
