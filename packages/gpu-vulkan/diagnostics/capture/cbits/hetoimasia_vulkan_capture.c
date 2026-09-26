/*
** The capture storage and its producer. See the header for the contract.
**
** Two kinds of memory, with two lifetimes.
**
** A slot, in a fixed static table, holds what a producer touches before it
** knows whether admission is open: the announcement count, the closed flag, the
** generation, the latches and the counters. Static memory is never freed, so a
** producer that is arbitrarily late — one that entered the callback before a
** lifetime closed and has not yet run a single instruction — always lands on
** live memory. A slot is reused only after every producer announced against it
** has left and its generation has moved on, so a straggler from an earlier
** lifetime can never count itself against a later one.
**
** The storage, on the C heap, holds the queue: the records, their object
** records and their text. Only a producer that announced itself and then found
** admission open touches it, and closing waits for every such producer before
** the storage can be freed. It is freed whole.
**
** The user data a messenger carries is not a pointer. It encodes the slot's
** index and the generation the storage was created in, so a stale or foreign
** value names nothing and is ignored.
**
** Announcing is the callback's first memory operation. Closing is a Dekker
** handshake between `closed` and `active`: a producer increments `active`
** before it reads anything else and decrements it only after it has published
** or given up; the closer sets `closed` before it reads `active`. Both use
** sequentially consistent operations, so either the producer sees the slot
** closed, or the closer sees the producer and waits for it. Reuse is the same
** handshake between the generation and `active`.
**
** The queue is a bounded multi-producer, single-consumer ring in which every
** record carries a sequence number (after Vyukov's bounded queue). A producer
** claims the next position with one compare-and-swap, copies into the record it
** claimed, and publishes it by advancing its sequence; a producer that finds the
** record at the head still holding an unconsumed report has found the queue
** full, counts the loss, and returns. Nothing waits for space, and a producer
** that loses a race for a position only retries against the position that beat
** it.
**
** A record's sequence says, for position p: free for p is 2p, published for p
** is 2p + 1, and consuming p frees it for p + capacity, 2(p + capacity).
** Vyukov's own encoding (p, p + 1, p + capacity) cannot tell a report published
** for p from a record free for p + 1 when the capacity is one, and a one-record
** queue is a valid configuration here.
**
** Every record's space is carved out of four arrays allocated once: the
** records, `queue_capacity * object_limit` object records,
** `queue_capacity * 2 * label_limit` label records — a record's queue labels
** first, then its command-buffer labels — and `queue_capacity * text_budget`
** bytes of text. A record's text budget is shared by its message id name, its
** message, every object name, every queue label name and every command-buffer
** label name, in that order, so a record never copies more than the budget in
** total. Nothing is allocated after the storage is built: the producer only
** copies into what these arrays already hold.
*/
#include "hetoimasia_vulkan_capture.h"

#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct capture_object {
  int32_t type;
  uint64_t handle;
  uint32_t name_offset;
  uint32_t name_length;
  int has_name;
} capture_object;

typedef struct capture_label {
  uint32_t name_offset;
  uint32_t name_length;
  int has_name;
} capture_label;

/* One of a record's two label arrays: what the callback reported, and what was
   copied into `labels`. */
typedef struct capture_labels {
  uint32_t reported;
  uint32_t count;
  capture_label *labels;
} capture_labels;

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
  capture_labels queue_labels;
  capture_labels cmd_buf_labels;
};

struct hetoimasia_capture_storage {
  uint32_t slot;
  uint64_t generation;
  hetoimasia_capture_limits limits;
  struct hetoimasia_capture_record *records;
  capture_object *objects;
  capture_label *labels;
  char *text;
  _Atomic uint64_t enqueue;
  /* The consumer's position. Only the single consumer reads or writes it. */
  uint64_t dequeue;
};

typedef struct capture_slot {
  _Atomic int in_use;
  _Atomic uint64_t generation;
  _Atomic uint64_t active;
  _Atomic int closed;
  _Atomic(hetoimasia_capture_storage *) storage;
  _Atomic int latches[2];
  _Atomic uint64_t counters[HETOIMASIA_CAPTURE_COUNTERS];
} capture_slot;

/* Zero-initialized: every slot free, closed with no storage, generation 0. */
static capture_slot slots[HETOIMASIA_CAPTURE_SLOTS];

/* The user data for a slot and generation. Never NULL: the index is biased. */
static void *encode_user_data(uint32_t slot, uint64_t generation)
{
  return (void *) (uintptr_t) ((generation << 8) | (uint64_t) (slot + 1));
}

/* The slot a user data names, or NULL; its generation in *generation. */
static capture_slot *decode_user_data(const void *user_data, uint64_t *generation)
{
  uintptr_t value = (uintptr_t) user_data;
  uint64_t index = value & 0xff;
  if (index == 0 || index > HETOIMASIA_CAPTURE_SLOTS) {
    return NULL;
  }
  *generation = (uint64_t) value >> 8;
  return &slots[index - 1];
}

/* a * b, or 0 with *overflow set when it does not fit in a size_t. */
static size_t checked_multiply(size_t a, size_t b, int *overflow)
{
  if (a != 0 && b > SIZE_MAX / a) {
    *overflow = 1;
    return 0;
  }
  return a * b;
}

static void wait_for_producers(capture_slot *slot)
{
  while (atomic_load(&slot->active) != 0) {
    sched_yield();
  }
}

int hetoimasia_capture_create(
  const hetoimasia_capture_limits *limits, hetoimasia_capture_storage **out)
{
  *out = NULL;
  if (limits == NULL || limits->queue_capacity == 0 || limits->text_budget == 0
      || limits->object_limit == 0 || limits->label_limit == 0) {
    return HETOIMASIA_CAPTURE_INVALID_LIMIT;
  }

  int overflow = 0;
  size_t capacity = limits->queue_capacity;
  size_t record_bytes = checked_multiply(capacity, sizeof(struct hetoimasia_capture_record), &overflow);
  size_t object_slots = checked_multiply(capacity, limits->object_limit, &overflow);
  size_t object_bytes = checked_multiply(object_slots, sizeof(capture_object), &overflow);
  size_t label_slots = checked_multiply(checked_multiply(capacity, 2, &overflow), limits->label_limit, &overflow);
  size_t label_bytes = checked_multiply(label_slots, sizeof(capture_label), &overflow);
  size_t text_bytes = checked_multiply(capacity, limits->text_budget, &overflow);
  /* Positions run on a 64-bit counter and wrap only after 2^64 records. */
  if (overflow) {
    return HETOIMASIA_CAPTURE_SIZE_OVERFLOW;
  }

  hetoimasia_capture_storage *storage = calloc(1, sizeof *storage);
  struct hetoimasia_capture_record *records = malloc(record_bytes);
  capture_object *objects = malloc(object_bytes);
  capture_label *labels = malloc(label_bytes);
  char *text = malloc(text_bytes);
  if (storage == NULL || records == NULL || objects == NULL || labels == NULL || text == NULL) {
    free(storage);
    free(records);
    free(objects);
    free(labels);
    free(text);
    return HETOIMASIA_CAPTURE_OUT_OF_MEMORY;
  }

  /* Claim a free slot. */
  capture_slot *slot = NULL;
  uint32_t index = 0;
  for (; index < HETOIMASIA_CAPTURE_SLOTS; index++) {
    int expected = 0;
    if (atomic_compare_exchange_strong(&slots[index].in_use, &expected, 1)) {
      slot = &slots[index];
      break;
    }
  }
  if (slot == NULL) {
    free(storage);
    free(records);
    free(objects);
    free(labels);
    free(text);
    return HETOIMASIA_CAPTURE_NO_SLOT;
  }

  /* Move the generation on first, then wait for stragglers: a producer from
     the slot's previous lifetime either sees the new generation and leaves, or
     is seen here and finishes counting against the old one before the reset. */
  uint64_t generation = atomic_fetch_add(&slot->generation, 1) + 1;
  wait_for_producers(slot);
  for (int latch = 0; latch < 2; latch++) {
    atomic_store(&slot->latches[latch], 0);
  }
  for (int counter = 0; counter < HETOIMASIA_CAPTURE_COUNTERS; counter++) {
    atomic_store(&slot->counters[counter], 0);
  }

  storage->slot = index;
  storage->generation = generation;
  storage->limits = *limits;
  storage->records = records;
  storage->objects = objects;
  storage->labels = labels;
  storage->text = text;
  storage->dequeue = 0;
  atomic_init(&storage->enqueue, 0);
  for (size_t position = 0; position < capacity; position++) {
    struct hetoimasia_capture_record *record = &records[position];
    memset(record, 0, sizeof *record);
    atomic_init(&record->sequence, 2 * (uint64_t) position);
    record->text = text + position * limits->text_budget;
    record->objects = objects + position * limits->object_limit;
    record->queue_labels.labels = labels + position * 2 * (size_t) limits->label_limit;
    record->cmd_buf_labels.labels = record->queue_labels.labels + limits->label_limit;
  }
  /* Published last: admission opens only once the storage is whole. */
  atomic_store(&slot->storage, storage);
  atomic_store(&slot->closed, 0);
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

size_t hetoimasia_capture_label_size(void)
{
  return sizeof(capture_label);
}

void *hetoimasia_capture_user_data(const hetoimasia_capture_storage *storage)
{
  return encode_user_data(storage->slot, storage->generation);
}

void hetoimasia_capture_free(hetoimasia_capture_storage *storage)
{
  if (storage == NULL) {
    return;
  }
  capture_slot *slot = &slots[storage->slot];
  /* Closing again is harmless and makes this safe on its own: nothing that
     announces itself from here on reaches the storage. */
  hetoimasia_capture_close(storage);
  atomic_store(&slot->storage, NULL);
  free(storage->records);
  free(storage->objects);
  free(storage->labels);
  free(storage->text);
  free(storage);
  /* The slot keeps its latches and counters until it is claimed again, so a
     status read by user data still answers until then. */
  atomic_store(&slot->in_use, 0);
}

static void saturating_increment(_Atomic uint64_t *counter)
{
  uint64_t current = atomic_load_explicit(counter, memory_order_relaxed);
  while (current != UINT64_MAX
         && !atomic_compare_exchange_weak_explicit(
           counter, &current, current + 1, memory_order_relaxed, memory_order_relaxed)) {
  }
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

/*
** Copy one of the callback's label arrays into `destination`, in the callback's
** order: at most `limit` labels, each name under what the shared budget has
** left. Excess labels, a positive count with a NULL array, and a name the budget
** cut all set `*truncated`.
*/
static void copy_labels(
  capture_labels *destination,
  char *text,
  uint32_t *used,
  uint32_t budget,
  uint32_t limit,
  uint32_t reported,
  const hetoimasia_capture_label *source,
  int *truncated)
{
  destination->reported = reported;
  destination->count = 0;
  if (reported > 0 && source == NULL) {
    *truncated = 1;
    return;
  }
  uint32_t wanted = reported;
  if (wanted > limit) {
    wanted = limit;
    *truncated = 1;
  }
  for (uint32_t index = 0; index < wanted; index++) {
    capture_label *label = &destination->labels[index];
    label->has_name = source[index].label_name != NULL;
    label->name_offset = *used;
    label->name_length = 0;
    if (label->has_name) {
      label->name_length = bounded_copy(text + *used, source[index].label_name, budget - *used, truncated);
      *used += label->name_length;
    }
  }
  destination->count = wanted;
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

  copy_labels(
    &record->queue_labels, record->text, &used, budget, limits->label_limit,
    data->queue_label_count, data->queue_labels, &truncated);
  copy_labels(
    &record->cmd_buf_labels, record->text, &used, budget, limits->label_limit,
    data->cmd_buf_label_count, data->cmd_buf_labels, &truncated);

  record->truncated = truncated;
  return truncated;
}

/*
** The producer, with an optional pause just after the announcement for the
** package's own tests. Production passes NULL and never pauses.
*/
static uint32_t capture(
  uint32_t severity,
  uint32_t types,
  const hetoimasia_capture_callback_data *data,
  void *user_data,
  int *paused,
  int *resume)
{
  uint64_t generation;
  capture_slot *slot = decode_user_data(user_data, &generation);
  if (slot == NULL) {
    return 0;
  }

  /* The announcement: the first thing done to anything. */
  atomic_fetch_add(&slot->active, 1);
  if (resume != NULL) {
    __atomic_store_n(paused, 1, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(resume, __ATOMIC_SEQ_CST) == 0) {
      sched_yield();
    }
  }
  if (atomic_load(&slot->generation) != generation) {
    /* A user data from a lifetime this slot no longer serves. */
    atomic_fetch_sub(&slot->active, 1);
    return 0;
  }

  saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_OFFERED]);

  /* Before anything else can fail or be dropped: a full queue, a closed
     storage and a missing payload must none of them hide an error. */
  if (severity & HETOIMASIA_CAPTURE_SEVERITY_ERROR) {
    atomic_store(&slot->latches[HETOIMASIA_CAPTURE_ERROR_LATCH], 1);
    saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_ERRORS]);
  }

  hetoimasia_capture_storage *storage = atomic_load(&slot->storage);
  if (atomic_load(&slot->closed) || storage == NULL || data == NULL) {
    atomic_store(&slot->latches[HETOIMASIA_CAPTURE_FAILURE_LATCH], 1);
    saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_FAILED]);
    atomic_fetch_sub(&slot->active, 1);
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
      saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_DROPPED]);
      atomic_fetch_sub(&slot->active, 1);
      return 0;
    } else {
      position = atomic_load_explicit(&storage->enqueue, memory_order_relaxed);
    }
  }

  if (fill(record, &storage->limits, severity, types, data)) {
    saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_TRUNCATED]);
  }
  atomic_store_explicit(&record->sequence, 2 * position + 1, memory_order_release);
  saturating_increment(&slot->counters[HETOIMASIA_CAPTURE_ADMITTED]);
  atomic_fetch_sub(&slot->active, 1);
  return 0;
}

uint32_t hetoimasia_capture_callback(
  uint32_t severity,
  uint32_t types,
  const hetoimasia_capture_callback_data *data,
  void *user_data)
{
  return capture(severity, types, data, user_data, NULL, NULL);
}

void hetoimasia_capture_close(hetoimasia_capture_storage *storage)
{
  capture_slot *slot = &slots[storage->slot];
  atomic_store(&slot->closed, 1);
  wait_for_producers(slot);
}

int hetoimasia_capture_closed(const hetoimasia_capture_storage *storage)
{
  return atomic_load(&slots[storage->slot].closed);
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

static const capture_labels *labels_of(const hetoimasia_capture_record *record, int queue)
{
  return queue ? &record->queue_labels : &record->cmd_buf_labels;
}

uint32_t hetoimasia_capture_record_labels_reported(const hetoimasia_capture_record *record, int queue)
{
  return labels_of(record, queue)->reported;
}

uint32_t hetoimasia_capture_record_label_count(const hetoimasia_capture_record *record, int queue)
{
  return labels_of(record, queue)->count;
}

int hetoimasia_capture_record_label_has_name(const hetoimasia_capture_record *record, int queue, uint32_t index)
{
  return labels_of(record, queue)->labels[index].has_name;
}

const char *hetoimasia_capture_record_label_name(const hetoimasia_capture_record *record, int queue, uint32_t index)
{
  return record->text + labels_of(record, queue)->labels[index].name_offset;
}

uint32_t hetoimasia_capture_record_label_name_length(const hetoimasia_capture_record *record, int queue, uint32_t index)
{
  return labels_of(record, queue)->labels[index].name_length;
}

int hetoimasia_capture_status(void *user_data, uint64_t *counters, int *latches)
{
  uint64_t generation;
  capture_slot *slot = decode_user_data(user_data, &generation);
  if (slot == NULL) {
    return 0;
  }
  /* A slot's latches and counters change owner only when it is claimed again,
     and claiming moves the generation first; the same generation on both sides
     of the read means every value read was this lifetime's. */
  if (atomic_load(&slot->generation) != generation) {
    return 0;
  }
  for (int counter = 0; counter < HETOIMASIA_CAPTURE_COUNTERS; counter++) {
    counters[counter] = atomic_load(&slot->counters[counter]);
  }
  for (int latch = 0; latch < 2; latch++) {
    latches[latch] = atomic_load(&slot->latches[latch]);
  }
  return atomic_load(&slot->generation) == generation;
}

void hetoimasia_capture_preset_counter(hetoimasia_capture_storage *storage, int which, uint64_t value)
{
  if (which >= 0 && which < HETOIMASIA_CAPTURE_COUNTERS) {
    atomic_store(&slots[storage->slot].counters[which], value);
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
  uint32_t queue_label_count,
  const char *const *queue_label_names,
  uint32_t cmd_buf_label_count,
  const char *const *cmd_buf_label_names,
  int null_data)
{
  hetoimasia_capture_label queue_labels[queue_label_count > 0 ? queue_label_count : 1];
  hetoimasia_capture_label cmd_buf_labels[cmd_buf_label_count > 0 ? cmd_buf_label_count : 1];
  for (uint32_t index = 0; queue_label_names != NULL && index < queue_label_count; index++) {
    queue_labels[index] = (hetoimasia_capture_label) {.label_name = queue_label_names[index]};
  }
  for (uint32_t index = 0; cmd_buf_label_names != NULL && index < cmd_buf_label_count; index++) {
    cmd_buf_labels[index] = (hetoimasia_capture_label) {.label_name = cmd_buf_label_names[index]};
  }
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
    .queue_label_count = queue_label_count,
    .queue_labels = queue_label_names == NULL ? NULL : queue_labels,
    .cmd_buf_label_count = cmd_buf_label_count,
    .cmd_buf_labels = cmd_buf_label_names == NULL ? NULL : cmd_buf_labels,
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
  return hetoimasia_capture_offer(user_data, severity, 0x2, NULL, 0, message, 0, NULL, NULL, NULL, 0, NULL, 0, NULL, 0);
}

uint32_t hetoimasia_capture_offer_announced(
  void *user_data, int *arrived, int *gate, uint32_t severity, const char *message)
{
  hetoimasia_capture_callback_data data = {
    .s_type = 0,
    .next = NULL,
    .flags = 0,
    .message_id_name = NULL,
    .message_id_number = 0,
    .message = message,
    .queue_label_count = 0,
    .queue_labels = NULL,
    .cmd_buf_label_count = 0,
    .cmd_buf_labels = NULL,
    .object_count = 0,
    .objects = NULL,
  };
  return capture(severity, 0x2, &data, user_data, arrived, gate);
}

void hetoimasia_capture_flag_set(int *flag)
{
  __atomic_store_n(flag, 1, __ATOMIC_SEQ_CST);
}

int hetoimasia_capture_flag_get(int *flag)
{
  return __atomic_load_n(flag, __ATOMIC_SEQ_CST);
}
