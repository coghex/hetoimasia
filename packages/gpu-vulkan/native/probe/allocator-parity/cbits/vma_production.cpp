// GRS-18's C side (#361, D-39): the C driver that makes the engine's VMA
// calls on a real device, the device-memory callbacks D-40's accounting reads,
// the validation messenger, and the check of which call safety the Haskell
// binding was built with.
//
// VMA itself is the copy the Hackage `VulkanMemoryAllocator` package compiles
// into its library, exactly as `vma_replay.cpp` uses it: this driver calls the
// same compiled VMA 3.3.0 the binding calls, with the same build settings. That
// package does not install `vk_mem_alloc.h`, so the declarations this file
// calls are restated below exactly as VMA 3.3.0 declares them, and
// `hetoimasia_vma_production_check_*` let the probe hold each restated struct
// to the binding's own generated layout before anything runs.
//
// Nothing here creates the allocator: the probe creates it through the binding,
// identically for both drivers, and hands this file its handle.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>

#include <vulkan/vulkan_core.h>

extern "C" {

// The clock both drivers read; defined in vma_replay.cpp.
uint64_t hetoimasia_probe_now(void);

// ---------------------------------------------------------------------------
// VMA 3.3.0's allocation API, restated (vk_mem_alloc.h)

VK_DEFINE_HANDLE(VmaAllocator)
VK_DEFINE_HANDLE(VmaPool)
VK_DEFINE_HANDLE(VmaAllocation)
typedef VkFlags VmaAllocationCreateFlags;

typedef enum VmaMemoryUsage {
  VMA_MEMORY_USAGE_UNKNOWN = 0,
  VMA_MEMORY_USAGE_MAX_ENUM = 0x7FFFFFFF
} VmaMemoryUsage;

enum {
  VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT = 0x00000002,
};

typedef struct VmaAllocationCreateInfo {
  VmaAllocationCreateFlags flags;
  VmaMemoryUsage usage;
  VkMemoryPropertyFlags requiredFlags;
  VkMemoryPropertyFlags preferredFlags;
  uint32_t memoryTypeBits;
  VmaPool pool;
  void* pUserData;
  float priority;
} VmaAllocationCreateInfo;

typedef struct VmaAllocationInfo {
  uint32_t memoryType;
  VkDeviceMemory deviceMemory;
  VkDeviceSize offset;
  VkDeviceSize size;
  void* pMappedData;
  void* pUserData;
  const char* pName;
} VmaAllocationInfo;

typedef struct VmaProductionStatistics {
  uint32_t blockCount;
  uint32_t allocationCount;
  VkDeviceSize blockBytes;
  VkDeviceSize allocationBytes;
} VmaProductionStatistics;

typedef struct VmaBudget {
  VmaProductionStatistics statistics;
  VkDeviceSize usage;
  VkDeviceSize budget;
} VmaBudget;

VkResult vmaCreateBuffer(VmaAllocator allocator, const VkBufferCreateInfo* pBufferCreateInfo,
                         const VmaAllocationCreateInfo* pAllocationCreateInfo, VkBuffer* pBuffer,
                         VmaAllocation* pAllocation, VmaAllocationInfo* pAllocationInfo);
void vmaDestroyBuffer(VmaAllocator allocator, VkBuffer buffer, VmaAllocation allocation);
VkResult vmaCreateImage(VmaAllocator allocator, const VkImageCreateInfo* pImageCreateInfo,
                        const VmaAllocationCreateInfo* pAllocationCreateInfo, VkImage* pImage,
                        VmaAllocation* pAllocation, VmaAllocationInfo* pAllocationInfo);
void vmaDestroyImage(VmaAllocator allocator, VkImage image, VmaAllocation allocation);
VkResult vmaMapMemory(VmaAllocator allocator, VmaAllocation allocation, void** ppData);
void vmaUnmapMemory(VmaAllocator allocator, VmaAllocation allocation);
VkResult vmaFlushAllocation(VmaAllocator allocator, VmaAllocation allocation, VkDeviceSize offset,
                            VkDeviceSize size);
VkResult vmaInvalidateAllocation(VmaAllocator allocator, VmaAllocation allocation, VkDeviceSize offset,
                                 VkDeviceSize size);
void vmaGetHeapBudgets(VmaAllocator allocator, VmaBudget* pBudgets);

// ---------------------------------------------------------------------------
// Layout checks against the binding

// Nonzero when the binding's marshalling of a VmaAllocationCreateInfo with
// these fields reads back through this file's declaration.
int hetoimasia_vma_production_check_create_info(const VmaAllocationCreateInfo* info, uint32_t flags,
                                                int32_t usage, uint32_t required, uint32_t preferred,
                                                uint32_t type_bits, uint64_t pool, void* user_data,
                                                float priority, uint64_t declared_size) {
  return declared_size == sizeof(VmaAllocationCreateInfo) && info->flags == flags &&
         static_cast<int32_t>(info->usage) == usage && info->requiredFlags == required &&
         info->preferredFlags == preferred && info->memoryTypeBits == type_bits &&
         reinterpret_cast<uint64_t>(info->pool) == pool && info->pUserData == user_data &&
         info->priority == priority;
}

// Fill a VmaAllocationInfo through this file's declaration, from a seed, for
// the binding to read back. The name stays null: the binding would read it as
// a string. Returns the struct's size.
uint64_t hetoimasia_vma_production_fill_allocation_info(VmaAllocationInfo* info, uint64_t seed) {
  info->memoryType = static_cast<uint32_t>(seed + 1);
  info->deviceMemory = reinterpret_cast<VkDeviceMemory>(seed + 2);
  info->offset = seed + 3;
  info->size = seed + 4;
  info->pMappedData = reinterpret_cast<void*>(seed + 5);
  info->pUserData = reinterpret_cast<void*>(seed + 6);
  info->pName = nullptr;
  return sizeof(VmaAllocationInfo);
}

// The same for a VmaBudget.
uint64_t hetoimasia_vma_production_fill_budget(VmaBudget* budget, uint64_t seed) {
  budget->statistics.blockCount = static_cast<uint32_t>(seed + 1);
  budget->statistics.allocationCount = static_cast<uint32_t>(seed + 2);
  budget->statistics.blockBytes = seed + 3;
  budget->statistics.allocationBytes = seed + 4;
  budget->usage = seed + 5;
  budget->budget = seed + 6;
  return sizeof(VmaBudget);
}

// ---------------------------------------------------------------------------
// Device-memory callbacks: D-40's block events

// What VMA's device-memory callbacks have seen, for one allocator. The C
// callbacks below and the probe's Haskell callbacks make exactly the same
// updates to this one layout, so the two destinations do identical work.
//
// `cursor` is the index of the operation the driver is executing, written by
// the driver before each operation, so a logged event names its operation.
// The log is written only when `log` is non-null: three words per event, the
// memory type with bit 32 set for a free, the size, and the cursor.
struct hetoimasia_block_counters {
  uint64_t opened_count;
  uint64_t opened_bytes;
  uint64_t freed_count;
  uint64_t freed_bytes;
  uint64_t held_bytes;
  uint64_t peak_held_bytes;
  uint64_t log_capacity;
  uint64_t log_count;
  uint64_t* log;
  uint64_t cursor;
};

uint64_t hetoimasia_block_counters_size(void) { return sizeof(hetoimasia_block_counters); }

static void hetoimasia_log_event(hetoimasia_block_counters* counters, uint64_t word, uint64_t size) {
  if (counters->log != nullptr && counters->log_count < counters->log_capacity) {
    uint64_t* entry = counters->log + 3 * counters->log_count;
    entry[0] = word;
    entry[1] = size;
    entry[2] = counters->cursor;
  }
  counters->log_count += 1;
}

void hetoimasia_vma_on_allocate(VmaAllocator, uint32_t memory_type, VkDeviceMemory, VkDeviceSize size,
                                void* user_data) {
  hetoimasia_block_counters* counters = static_cast<hetoimasia_block_counters*>(user_data);
  counters->opened_count += 1;
  counters->opened_bytes += size;
  counters->held_bytes += size;
  if (counters->held_bytes > counters->peak_held_bytes) {
    counters->peak_held_bytes = counters->held_bytes;
  }
  hetoimasia_log_event(counters, memory_type, size);
}

void hetoimasia_vma_on_free(VmaAllocator, uint32_t memory_type, VkDeviceMemory, VkDeviceSize size,
                            void* user_data) {
  hetoimasia_block_counters* counters = static_cast<hetoimasia_block_counters*>(user_data);
  counters->freed_count += 1;
  counters->freed_bytes += size;
  counters->held_bytes -= size;
  hetoimasia_log_event(counters, static_cast<uint64_t>(memory_type) | (1ull << 32), size);
}

// The device memory VMA reports it holds, over every heap: what the callbacks'
// `held_bytes` must equal. Reads VMA's statistics and calls back into nothing.
uint64_t hetoimasia_vma_held_bytes(VmaAllocator allocator, uint32_t heap_count) {
  VmaBudget budgets[VK_MAX_MEMORY_HEAPS];
  std::memset(budgets, 0, sizeof budgets);
  vmaGetHeapBudgets(allocator, budgets);
  uint64_t held = 0;
  for (uint32_t heap = 0; heap < heap_count && heap < VK_MAX_MEMORY_HEAPS; ++heap) {
    held += budgets[heap].statistics.blockBytes;
  }
  return held;
}

// ---------------------------------------------------------------------------
// Which call safety the binding was built with

// A device-memory callback that waits for a Haskell thread. A safe foreign
// call releases the calling capability, so another Haskell thread can run and
// release this wait while the call is still inside VMA; an unsafe call holds
// the capability, so on one capability nothing can, and the wait times out.
static std::atomic<int> hetoimasia_detect_entered{0};
static std::atomic<int> hetoimasia_detect_released{0};
static std::atomic<int> hetoimasia_detect_outcome{-1};

void hetoimasia_detect_reset(void) {
  hetoimasia_detect_entered.store(0);
  hetoimasia_detect_released.store(0);
  hetoimasia_detect_outcome.store(-1);
}

int hetoimasia_detect_entered_now(void) { return hetoimasia_detect_entered.load(); }

void hetoimasia_detect_release(void) { hetoimasia_detect_released.store(1); }

// 1 when a Haskell thread released the wait, 0 when it timed out, -1 when the
// callback never ran.
int hetoimasia_detect_result(void) { return hetoimasia_detect_outcome.load(); }

void hetoimasia_detect_on_allocate(VmaAllocator, uint32_t, VkDeviceMemory, VkDeviceSize, void*) {
  if (hetoimasia_detect_outcome.load() != -1) {
    return;
  }
  hetoimasia_detect_entered.store(1);
  const uint64_t deadline = hetoimasia_probe_now() + 2000000000ull;
  while (hetoimasia_detect_released.load() == 0 && hetoimasia_probe_now() < deadline) {
  }
  hetoimasia_detect_outcome.store(hetoimasia_detect_released.load());
}

// ---------------------------------------------------------------------------
// The validation messenger: C only, so no unsafe call can reach Haskell
// through validation

static std::mutex hetoimasia_messages_lock;
static uint64_t hetoimasia_message_counts[3] = {0, 0, 0};  // errors, warnings, other
static char hetoimasia_message_text[16][768];
static uint64_t hetoimasia_messages_kept = 0;

VkBool32 VKAPI_CALL hetoimasia_probe_messenger(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
                                               VkDebugUtilsMessageTypeFlagsEXT,
                                               const VkDebugUtilsMessengerCallbackDataEXT* data, void*) {
  std::lock_guard<std::mutex> guard(hetoimasia_messages_lock);
  int which = (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)     ? 0
              : (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) ? 1
                                                                            : 2;
  hetoimasia_message_counts[which] += 1;
  if (hetoimasia_messages_kept < 16) {
    std::snprintf(hetoimasia_message_text[hetoimasia_messages_kept], sizeof hetoimasia_message_text[0],
                  "%s: %s", which == 0 ? "error" : which == 1 ? "warning" : "other",
                  data != nullptr && data->pMessage != nullptr ? data->pMessage : "(no message)");
    hetoimasia_messages_kept += 1;
  }
  return VK_FALSE;
}

uint64_t hetoimasia_probe_message_count(uint32_t which) {
  std::lock_guard<std::mutex> guard(hetoimasia_messages_lock);
  return which < 3 ? hetoimasia_message_counts[which] : 0;
}

uint64_t hetoimasia_probe_messages_kept(void) {
  std::lock_guard<std::mutex> guard(hetoimasia_messages_lock);
  return hetoimasia_messages_kept;
}

const char* hetoimasia_probe_message_text(uint64_t index) {
  return index < 16 ? hetoimasia_message_text[index] : "";
}

// ---------------------------------------------------------------------------
// The engine-owned shim, Q-19's second candidate

// One C entry per call the engine makes, taking only scalars and one output
// record, so a Haskell caller marshals no struct: the shim builds the Vulkan
// and VMA create infos on its own stack, exactly as the C driver does, and
// calls the same compiled VMA. The probe imports each entry twice, unsafe and
// safe, so both call safeties are measured from one build.
struct hetoimasia_shim_result {
  uint64_t handle;  // VkBuffer or VkImage
  uint64_t allocation;
  uint32_t memory_type;
  uint32_t reserved;
  uint64_t offset;
  uint64_t size;
};

uint64_t hetoimasia_shim_result_size(void) { return sizeof(hetoimasia_shim_result); }

static void hetoimasia_shim_request(VmaAllocationCreateInfo* request, uint32_t vma_flags, uint32_t required,
                                    uint32_t preferred, uint32_t type_bits) {
  std::memset(request, 0, sizeof *request);
  request->flags = vma_flags;
  request->usage = VMA_MEMORY_USAGE_UNKNOWN;
  request->requiredFlags = required;
  request->preferredFlags = preferred;
  request->memoryTypeBits = type_bits;
}

static void hetoimasia_shim_store(hetoimasia_shim_result* out, uint64_t handle, VmaAllocation allocation,
                                  const VmaAllocationInfo& info) {
  out->handle = handle;
  out->allocation = reinterpret_cast<uint64_t>(allocation);
  out->memory_type = info.memoryType;
  out->offset = info.offset;
  out->size = info.size;
}

int32_t hetoimasia_shim_create_buffer(VmaAllocator allocator, uint64_t size, uint32_t usage, uint32_t vma_flags,
                                      uint32_t required, uint32_t preferred, uint32_t type_bits,
                                      hetoimasia_shim_result* out) {
  VkBufferCreateInfo buffer_info;
  std::memset(&buffer_info, 0, sizeof buffer_info);
  buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  buffer_info.size = size;
  buffer_info.usage = usage;
  buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  VmaAllocationCreateInfo request;
  hetoimasia_shim_request(&request, vma_flags, required, preferred, type_bits);
  VkBuffer buffer = VK_NULL_HANDLE;
  VmaAllocation allocation = VK_NULL_HANDLE;
  VmaAllocationInfo info;
  VkResult result = vmaCreateBuffer(allocator, &buffer_info, &request, &buffer, &allocation, &info);
  if (result == VK_SUCCESS) {
    hetoimasia_shim_store(out, reinterpret_cast<uint64_t>(buffer), allocation, info);
  }
  return result;
}

int32_t hetoimasia_shim_create_image(VmaAllocator allocator, uint32_t width, uint32_t height, uint32_t format,
                                     uint32_t usage, uint32_t vma_flags, uint32_t required, uint32_t preferred,
                                     uint32_t type_bits, hetoimasia_shim_result* out) {
  VkImageCreateInfo image_info;
  std::memset(&image_info, 0, sizeof image_info);
  image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  image_info.imageType = VK_IMAGE_TYPE_2D;
  image_info.format = static_cast<VkFormat>(format);
  image_info.extent = {width, height, 1};
  image_info.mipLevels = 1;
  image_info.arrayLayers = 1;
  image_info.samples = VK_SAMPLE_COUNT_1_BIT;
  image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
  image_info.usage = usage;
  image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  VmaAllocationCreateInfo request;
  hetoimasia_shim_request(&request, vma_flags, required, preferred, type_bits);
  VkImage image = VK_NULL_HANDLE;
  VmaAllocation allocation = VK_NULL_HANDLE;
  VmaAllocationInfo info;
  VkResult result = vmaCreateImage(allocator, &image_info, &request, &image, &allocation, &info);
  if (result == VK_SUCCESS) {
    hetoimasia_shim_store(out, reinterpret_cast<uint64_t>(image), allocation, info);
  }
  return result;
}

void hetoimasia_shim_destroy_buffer(VmaAllocator allocator, uint64_t buffer, uint64_t allocation) {
  vmaDestroyBuffer(allocator, reinterpret_cast<VkBuffer>(buffer), reinterpret_cast<VmaAllocation>(allocation));
}

void hetoimasia_shim_destroy_image(VmaAllocator allocator, uint64_t image, uint64_t allocation) {
  vmaDestroyImage(allocator, reinterpret_cast<VkImage>(image), reinterpret_cast<VmaAllocation>(allocation));
}

// The mapped pointer, or null when the mapping failed.
void* hetoimasia_shim_map(VmaAllocator allocator, uint64_t allocation) {
  void* mapped = nullptr;
  return vmaMapMemory(allocator, reinterpret_cast<VmaAllocation>(allocation), &mapped) == VK_SUCCESS ? mapped
                                                                                                       : nullptr;
}

void hetoimasia_shim_unmap(VmaAllocator allocator, uint64_t allocation) {
  vmaUnmapMemory(allocator, reinterpret_cast<VmaAllocation>(allocation));
}

int32_t hetoimasia_shim_flush(VmaAllocator allocator, uint64_t allocation) {
  return vmaFlushAllocation(allocator, reinterpret_cast<VmaAllocation>(allocation), 0, VK_WHOLE_SIZE);
}

int32_t hetoimasia_shim_invalidate(VmaAllocator allocator, uint64_t allocation) {
  return vmaInvalidateAllocation(allocator, reinterpret_cast<VmaAllocation>(allocation), 0, VK_WHOLE_SIZE);
}

// ---------------------------------------------------------------------------
// The C driver

// A resource class: one deterministic Vulkan descriptor and allocation
// policy, as the probe's Haskell side builds it for both drivers.
struct hetoimasia_resource_class {
  uint32_t is_image;          // 0 a buffer, 1 a 2D image
  uint32_t usage;             // VkBufferUsageFlags or VkImageUsageFlags
  uint32_t format;            // the image's VkFormat
  uint32_t memory_type;       // the one memory type the engine chose
  uint32_t allocation_flags;  // VmaAllocationCreateFlags every request carries
  uint32_t required_flags;    // VkMemoryPropertyFlags
  uint32_t preferred_flags;
  uint32_t reserved;
};

// One operation of a script, as the probe's Haskell side encodes it.
struct hetoimasia_resource_op {
  uint32_t kind;
  uint32_t id;           // the resource's identity; the checkpoint's ordinal
  uint32_t class_index;  // for a creation
  uint32_t width;        // for an image
  uint32_t height;
  uint32_t reserved;
  uint64_t size;  // a buffer's size; an image's requested bytes
};

enum {
  OP_CREATE_D40 = 0,    // D-40: NEVER_ALLOCATE first, then an allocating call
  OP_DESTROY = 1,       // free the resource and its allocation
  OP_CHECKPOINT = 2,    // record the byte quantities (evidence only)
  OP_CREATE_PLAIN = 3,  // one allocating call
  OP_MAP = 4,
  OP_UNMAP = 5,
  OP_FLUSH = 6,  // the whole allocation
  OP_INVALIDATE = 7
};

enum {
  MODE_EVIDENCE = 0,       // untimed: outcomes, placements, byte quantities
  MODE_PER_OPERATION = 1,  // one clock pair around each operation
  MODE_WHOLE = 2           // one clock pair around the whole script
};

// Per-operation evidence words.
enum {
  EVIDENCE_OUTCOME = 0,  // bit 0 created, 1 placed by NEVER_ALLOCATE, 2 by the
                         // allocating call, 3 D-40's bound broken, 4 the
                         // NEVER_ALLOCATE attempt opened memory
  EVIDENCE_TYPE = 1,
  EVIDENCE_OFFSET = 2,
  EVIDENCE_SIZE = 3,
  EVIDENCE_OPENED = 4,  // bytes the operation's calls opened
  EVIDENCE_REQUIRED_SIZE = 5,
  EVIDENCE_REQUIRED_ALIGNMENT = 6,
  EVIDENCE_REQUIRED_TYPE_BITS = 7,
  EVIDENCE_WORDS = 8
};

// Per-checkpoint words.
enum {
  CHECKPOINT_LIVE_REQUESTED = 0,
  CHECKPOINT_LIVE_ALLOCATED = 1,
  CHECKPOINT_HELD = 2,
  CHECKPOINT_HELD_BY_VMA = 3,
  CHECKPOINT_LIVE_RESOURCES = 4,
  CHECKPOINT_OPENED = 5,
  CHECKPOINT_WORDS = 6
};

// Summary words, written by every mode.
enum {
  SUMMARY_CHECKSUM = 0,
  SUMMARY_CREATES = 1,
  SUMMARY_DESTROYS = 2,
  SUMMARY_HITS = 3,
  SUMMARY_MISSES = 4,
  SUMMARY_OTHER = 5,
  SUMMARY_TIMED = 6,
  SUMMARY_BOUND_BROKEN = 7,
  SUMMARY_PEAK_REQUESTED = 8,
  SUMMARY_PEAK_ALLOCATED = 9,
  SUMMARY_HELD_MISMATCHES = 10,
  SUMMARY_FAILURES = 11,
  SUMMARY_LEFT_LIVE = 12,
  SUMMARY_RETAINED = 13,
  SUMMARY_WORDS = 16
};

static const uint64_t FNV_PRIME = 1099511628211ull;
static const uint64_t FNV_OFFSET = 1469598103934665603ull;

struct hetoimasia_live {
  uint64_t handle;  // VkBuffer or VkImage
  VmaAllocation allocation;
  uint64_t requested;
  uint64_t allocated;
  uint32_t is_image;
  uint32_t live;
};

// Replay a script through VMA from C with the engine's descriptors and
// policies. `elapsed[i]` accumulates operation i's nanoseconds per operation;
// `elapsed_allocating[i]` the allocating call's alone, for a creation
// NEVER_ALLOCATE could not place. `preferred_block_sizes` is indexed by memory
// type and is D-40's bound. `evidence` (EVIDENCE_WORDS per operation) and
// `checkpoints` (CHECKPOINT_WORDS per checkpoint) are written in the evidence
// mode only. Whatever the script leaves live is freed untimed at the end.
//
// Returns 0, or 1 when the handle table could not be allocated.
int hetoimasia_vma_replay_script(VmaAllocator allocator, VkDevice device, uint32_t heap_count,
                                 const hetoimasia_resource_class* classes, const hetoimasia_resource_op* ops,
                                 uint64_t count, uint64_t identities, const uint64_t* preferred_block_sizes,
                                 hetoimasia_block_counters* counters, uint32_t mode, uint64_t* elapsed,
                                 uint64_t* elapsed_allocating, uint64_t* evidence, uint64_t* checkpoints,
                                 uint64_t* summary) {
  hetoimasia_live* live = new (std::nothrow) hetoimasia_live[identities > 0 ? identities : 1]();
  if (live == nullptr) {
    return 1;
  }
  uint64_t checksum = FNV_OFFSET;
  uint64_t creates = 0, destroys = 0, hits = 0, misses = 0, other = 0, timed = 0, bound_broken = 0;
  uint64_t live_requested = 0, live_allocated = 0, live_resources = 0;
  uint64_t peak_requested = 0, peak_allocated = 0, held_mismatches = 0, failures = 0;
  const bool per_operation = mode == MODE_PER_OPERATION;
  const bool evidence_mode = mode == MODE_EVIDENCE;
  const uint64_t whole_start = mode == MODE_WHOLE ? hetoimasia_probe_now() : 0;

  for (uint64_t i = 0; i < count; ++i) {
    const hetoimasia_resource_op& op = ops[i];
    counters->cursor = i;
    if (op.kind == OP_CREATE_D40 || op.kind == OP_CREATE_PLAIN) {
      const hetoimasia_resource_class& resource_class = classes[op.class_index];
      VkBufferCreateInfo buffer_info;
      VkImageCreateInfo image_info;
      std::memset(&buffer_info, 0, sizeof buffer_info);
      std::memset(&image_info, 0, sizeof image_info);
      if (resource_class.is_image) {
        image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = VK_IMAGE_TYPE_2D;
        image_info.format = static_cast<VkFormat>(resource_class.format);
        image_info.extent = {op.width, op.height, 1};
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = resource_class.usage;
        image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      } else {
        buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.size = op.size;
        buffer_info.usage = resource_class.usage;
        buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      }
      VmaAllocationCreateInfo request;
      std::memset(&request, 0, sizeof request);
      request.usage = VMA_MEMORY_USAGE_UNKNOWN;
      request.requiredFlags = resource_class.required_flags;
      request.preferredFlags = resource_class.preferred_flags;
      request.memoryTypeBits = 1u << resource_class.memory_type;
      const bool d40 = op.kind == OP_CREATE_D40;
      uint64_t handle = 0;
      VmaAllocation allocation = VK_NULL_HANDLE;
      VmaAllocationInfo info;
      std::memset(&info, 0, sizeof info);
      const uint64_t opened_before = counters->opened_bytes;
      uint64_t opened_by_attempt = 0;
      bool hit = false;
      bool allocated = false;
      uint64_t allocating_time = 0;
      const uint64_t start = per_operation ? hetoimasia_probe_now() : 0;
      VkResult result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
      if (d40) {
        request.flags = resource_class.allocation_flags | VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT;
        if (resource_class.is_image) {
          VkImage image = VK_NULL_HANDLE;
          result = vmaCreateImage(allocator, &image_info, &request, &image, &allocation, &info);
          handle = reinterpret_cast<uint64_t>(image);
        } else {
          VkBuffer buffer = VK_NULL_HANDLE;
          result = vmaCreateBuffer(allocator, &buffer_info, &request, &buffer, &allocation, &info);
          handle = reinterpret_cast<uint64_t>(buffer);
        }
        hit = result == VK_SUCCESS;
        // NEVER_ALLOCATE must open nothing, placed or not.
        opened_by_attempt = counters->opened_bytes - opened_before;
      }
      if (!hit) {
        const uint64_t allocating_start = per_operation ? hetoimasia_probe_now() : 0;
        request.flags = resource_class.allocation_flags;
        if (resource_class.is_image) {
          VkImage image = VK_NULL_HANDLE;
          result = vmaCreateImage(allocator, &image_info, &request, &image, &allocation, &info);
          handle = reinterpret_cast<uint64_t>(image);
        } else {
          VkBuffer buffer = VK_NULL_HANDLE;
          result = vmaCreateBuffer(allocator, &buffer_info, &request, &buffer, &allocation, &info);
          handle = reinterpret_cast<uint64_t>(buffer);
        }
        allocated = result == VK_SUCCESS;
        if (per_operation) {
          allocating_time = hetoimasia_probe_now() - allocating_start;
        }
      }
      if (per_operation) {
        const uint64_t end = hetoimasia_probe_now();
        elapsed[i] += end - start;
        elapsed_allocating[i] += allocating_time;
        timed += end - start;
      }
      // D-40's reconciliation: what the allocating call opened, against the
      // bound reserved before it.
      const uint64_t opened = counters->opened_bytes - opened_before;
      const uint64_t opened_by_allocating = opened - opened_by_attempt;
      bool broken = false;
      if (result == VK_SUCCESS) {
        const uint64_t preferred = preferred_block_sizes[info.memoryType];
        const uint64_t bound = info.size > preferred ? info.size : preferred;
        broken = opened_by_allocating > bound || opened_by_attempt != 0;
      }
      bound_broken += broken ? 1 : 0;
      creates += 1;
      if (result != VK_SUCCESS) {
        failures += 1;
        live[op.id].live = 0;
      } else {
        hits += hit ? 1 : 0;
        misses += (d40 && allocated) ? 1 : 0;
        checksum = checksum * FNV_PRIME + (i + 1);
        checksum = checksum * FNV_PRIME + (static_cast<uint64_t>(info.memoryType) + 1);
        checksum = checksum * FNV_PRIME + info.offset;
        checksum = checksum * FNV_PRIME + info.size;
        live[op.id] = {handle, allocation, op.size, info.size, resource_class.is_image, 1};
        live_requested += op.size;
        live_allocated += info.size;
        live_resources += 1;
        peak_requested = live_requested > peak_requested ? live_requested : peak_requested;
        peak_allocated = live_allocated > peak_allocated ? live_allocated : peak_allocated;
      }
      if (evidence_mode) {
        uint64_t* row = evidence + EVIDENCE_WORDS * i;
        row[EVIDENCE_OUTCOME] = (result == VK_SUCCESS ? 1u : 0u) | (hit ? 2u : 0u) | (allocated ? 4u : 0u) |
                                (broken ? 8u : 0u) | (opened_by_attempt != 0 ? 16u : 0u);
        row[EVIDENCE_TYPE] = result == VK_SUCCESS ? info.memoryType : 0;
        row[EVIDENCE_OFFSET] = result == VK_SUCCESS ? info.offset : 0;
        row[EVIDENCE_SIZE] = result == VK_SUCCESS ? info.size : 0;
        row[EVIDENCE_OPENED] = opened;
        VkMemoryRequirements requirements;
        std::memset(&requirements, 0, sizeof requirements);
        if (result == VK_SUCCESS) {
          if (resource_class.is_image) {
            vkGetImageMemoryRequirements(device, reinterpret_cast<VkImage>(handle), &requirements);
          } else {
            vkGetBufferMemoryRequirements(device, reinterpret_cast<VkBuffer>(handle), &requirements);
          }
        }
        row[EVIDENCE_REQUIRED_SIZE] = requirements.size;
        row[EVIDENCE_REQUIRED_ALIGNMENT] = requirements.alignment;
        row[EVIDENCE_REQUIRED_TYPE_BITS] = requirements.memoryTypeBits;
      }
    } else if (op.kind == OP_DESTROY) {
      hetoimasia_live& resource = live[op.id];
      if (resource.live) {
        const uint64_t start = per_operation ? hetoimasia_probe_now() : 0;
        if (resource.is_image) {
          vmaDestroyImage(allocator, reinterpret_cast<VkImage>(resource.handle), resource.allocation);
        } else {
          vmaDestroyBuffer(allocator, reinterpret_cast<VkBuffer>(resource.handle), resource.allocation);
        }
        if (per_operation) {
          const uint64_t end = hetoimasia_probe_now();
          elapsed[i] += end - start;
          timed += end - start;
        }
        destroys += 1;
        live_requested -= resource.requested;
        live_allocated -= resource.allocated;
        live_resources -= 1;
        resource.live = 0;
      }
    } else if (op.kind >= OP_MAP && op.kind <= OP_INVALIDATE) {
      hetoimasia_live& resource = live[op.id];
      if (resource.live) {
        const uint64_t start = per_operation ? hetoimasia_probe_now() : 0;
        VkResult result = VK_SUCCESS;
        void* mapped = nullptr;
        switch (op.kind) {
          case OP_MAP:
            result = vmaMapMemory(allocator, resource.allocation, &mapped);
            break;
          case OP_UNMAP:
            vmaUnmapMemory(allocator, resource.allocation);
            break;
          case OP_FLUSH:
            result = vmaFlushAllocation(allocator, resource.allocation, 0, VK_WHOLE_SIZE);
            break;
          default:
            result = vmaInvalidateAllocation(allocator, resource.allocation, 0, VK_WHOLE_SIZE);
            break;
        }
        if (per_operation) {
          const uint64_t end = hetoimasia_probe_now();
          elapsed[i] += end - start;
          timed += end - start;
        }
        failures += result == VK_SUCCESS ? 0 : 1;
        other += 1;
        checksum = checksum * FNV_PRIME + (op.kind == OP_MAP && mapped != nullptr ? 1 : 0);
      }
    } else if (evidence_mode) {
      uint64_t* row = checkpoints + CHECKPOINT_WORDS * op.id;
      row[CHECKPOINT_LIVE_REQUESTED] = live_requested;
      row[CHECKPOINT_LIVE_ALLOCATED] = live_allocated;
      row[CHECKPOINT_HELD] = counters->held_bytes;
      row[CHECKPOINT_HELD_BY_VMA] = hetoimasia_vma_held_bytes(allocator, heap_count);
      row[CHECKPOINT_LIVE_RESOURCES] = live_resources;
      row[CHECKPOINT_OPENED] = counters->opened_count;
      held_mismatches += row[CHECKPOINT_HELD] != row[CHECKPOINT_HELD_BY_VMA] ? 1 : 0;
    }
  }
  if (mode == MODE_WHOLE) {
    timed = hetoimasia_probe_now() - whole_start;
  }

  // Whatever the script left live is freed untimed, so the allocator is
  // destroyed empty; what VMA still holds afterwards is what it retains.
  uint64_t left_live = 0;
  counters->cursor = count;
  for (uint64_t id = 0; id < identities; ++id) {
    hetoimasia_live& resource = live[id];
    if (resource.live) {
      if (resource.is_image) {
        vmaDestroyImage(allocator, reinterpret_cast<VkImage>(resource.handle), resource.allocation);
      } else {
        vmaDestroyBuffer(allocator, reinterpret_cast<VkBuffer>(resource.handle), resource.allocation);
      }
      resource.live = 0;
      left_live += 1;
    }
  }
  if (evidence_mode) {
    held_mismatches += counters->held_bytes != hetoimasia_vma_held_bytes(allocator, heap_count) ? 1 : 0;
  }
  delete[] live;

  summary[SUMMARY_CHECKSUM] = checksum;
  summary[SUMMARY_CREATES] = creates;
  summary[SUMMARY_DESTROYS] = destroys;
  summary[SUMMARY_HITS] = hits;
  summary[SUMMARY_MISSES] = misses;
  summary[SUMMARY_OTHER] = other;
  summary[SUMMARY_TIMED] = timed;
  summary[SUMMARY_BOUND_BROKEN] = bound_broken;
  summary[SUMMARY_PEAK_REQUESTED] = peak_requested;
  summary[SUMMARY_PEAK_ALLOCATED] = peak_allocated;
  summary[SUMMARY_HELD_MISMATCHES] = held_mismatches;
  summary[SUMMARY_FAILURES] = failures;
  summary[SUMMARY_LEFT_LIVE] = left_live;
  summary[SUMMARY_RETAINED] = counters->held_bytes;
  return 0;
}

}  // extern "C"
