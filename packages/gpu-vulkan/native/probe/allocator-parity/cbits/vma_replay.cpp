// The allocator parity probe's VMA side: a whole trace replayed into one VMA
// virtual block inside C++, so no timed operation crosses into Haskell.
//
// VMA itself is the copy the Hackage `VulkanMemoryAllocator` package compiles
// into its library (see README.md for the pinned version). That package does
// not install `vk_mem_alloc.h`, so the few virtual-block declarations this file
// calls are restated below, exactly as VMA 3.3.0 declares them. They are not
// trusted on their own: `hetoimasia_vma_check_*` let the probe marshal each
// struct through the binding's own generated layout and read it back here, and
// the probe refuses to run when any field disagrees.

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <new>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

#include <vulkan/vulkan_core.h>

extern "C" {

// ---------------------------------------------------------------------------
// VMA 3.3.0's virtual-block API, restated (vk_mem_alloc.h, "Virtual allocator")

typedef struct VmaVirtualBlock_T* VmaVirtualBlock;
VK_DEFINE_NON_DISPATCHABLE_HANDLE(VmaVirtualAllocation)
typedef VkFlags VmaVirtualBlockCreateFlags;
typedef VkFlags VmaVirtualAllocationCreateFlags;

typedef struct VmaVirtualBlockCreateInfo {
  VkDeviceSize size;
  VmaVirtualBlockCreateFlags flags;
  const VkAllocationCallbacks* pAllocationCallbacks;
} VmaVirtualBlockCreateInfo;

typedef struct VmaVirtualAllocationCreateInfo {
  VkDeviceSize size;
  VkDeviceSize alignment;
  VmaVirtualAllocationCreateFlags flags;
  void* pUserData;
} VmaVirtualAllocationCreateInfo;

typedef struct VmaStatistics {
  uint32_t blockCount;
  uint32_t allocationCount;
  VkDeviceSize blockBytes;
  VkDeviceSize allocationBytes;
} VmaStatistics;

typedef struct VmaDetailedStatistics {
  VmaStatistics statistics;
  uint32_t unusedRangeCount;
  VkDeviceSize allocationSizeMin;
  VkDeviceSize allocationSizeMax;
  VkDeviceSize unusedRangeSizeMin;
  VkDeviceSize unusedRangeSizeMax;
} VmaDetailedStatistics;

VkResult vmaCreateVirtualBlock(const VmaVirtualBlockCreateInfo* pCreateInfo, VmaVirtualBlock* pVirtualBlock);
void vmaDestroyVirtualBlock(VmaVirtualBlock virtualBlock);
VkResult vmaVirtualAllocate(VmaVirtualBlock virtualBlock, const VmaVirtualAllocationCreateInfo* pCreateInfo,
                            VmaVirtualAllocation* pAllocation, VkDeviceSize* pOffset);
void vmaVirtualFree(VmaVirtualBlock virtualBlock, VmaVirtualAllocation allocation);
void vmaCalculateVirtualBlockStatistics(VmaVirtualBlock virtualBlock, VmaDetailedStatistics* pStats);

// ---------------------------------------------------------------------------
// The clock both sides time with

// Nanoseconds from the raw monotonic clock. The Haskell replay calls this same
// function around each of its operations, so the two sides read one clock at
// the same cost.
uint64_t hetoimasia_probe_now(void) {
#if defined(__APPLE__)
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC_RAW, &now);
  return static_cast<uint64_t>(now.tv_sec) * 1000000000u + static_cast<uint64_t>(now.tv_nsec);
#endif
}

// The mean nanoseconds between two back-to-back clock reads, over `pairs`
// pairs: what one empty timed interval costs on this side.
double hetoimasia_probe_clock_pair(uint64_t pairs) {
  uint64_t total = 0;
  for (uint64_t i = 0; i < pairs; ++i) {
    uint64_t start = hetoimasia_probe_now();
    uint64_t end = hetoimasia_probe_now();
    total += end - start;
  }
  return pairs == 0 ? 0.0 : static_cast<double>(total) / static_cast<double>(pairs);
}

// The compiler this file was built with, for the retained record.
const char* hetoimasia_probe_compiler(void) {
#if defined(__clang__)
  return "clang " __clang_version__;
#elif defined(__GNUC__)
  return "gcc " __VERSION__;
#else
  return "unknown";
#endif
}

// ---------------------------------------------------------------------------
// Layout checks against the binding

// Nonzero when the binding's marshalling of a VmaVirtualBlockCreateInfo with
// the given size and flags reads back through this file's declaration.
int hetoimasia_vma_check_block_info(const VmaVirtualBlockCreateInfo* info, uint64_t size, uint32_t flags,
                                    uint64_t declared_size) {
  return declared_size == sizeof(VmaVirtualBlockCreateInfo) && info->size == size && info->flags == flags &&
         info->pAllocationCallbacks == nullptr;
}

// The same for a VmaVirtualAllocationCreateInfo.
int hetoimasia_vma_check_allocation_info(const VmaVirtualAllocationCreateInfo* info, uint64_t size,
                                         uint64_t alignment, uint32_t flags, void* user_data,
                                         uint64_t declared_size) {
  return declared_size == sizeof(VmaVirtualAllocationCreateInfo) && info->size == size &&
         info->alignment == alignment && info->flags == flags && info->pUserData == user_data;
}

// Fill a VmaDetailedStatistics, through this file's declaration, with values
// derived from a seed, for the binding to read back. Returns its size.
uint64_t hetoimasia_vma_fill_statistics(VmaDetailedStatistics* statistics, uint64_t seed) {
  statistics->statistics.blockCount = static_cast<uint32_t>(seed + 1);
  statistics->statistics.allocationCount = static_cast<uint32_t>(seed + 2);
  statistics->statistics.blockBytes = seed + 3;
  statistics->statistics.allocationBytes = seed + 4;
  statistics->unusedRangeCount = static_cast<uint32_t>(seed + 5);
  statistics->allocationSizeMin = seed + 6;
  statistics->allocationSizeMax = seed + 7;
  statistics->unusedRangeSizeMin = seed + 8;
  statistics->unusedRangeSizeMax = seed + 9;
  return sizeof(VmaDetailedStatistics);
}

// ---------------------------------------------------------------------------
// The replay

// One trace operation, laid out as the probe's Haskell side writes it.
struct hetoimasia_trace_op {
  uint32_t kind;  // 0 allocate, 1 free, 2 checkpoint
  uint32_t id;    // the allocation's identity; the checkpoint's ordinal
  uint64_t size;
  uint64_t alignment;
};

// Heap accounting for the counting pass. VMA 3.3.0 builds a virtual block's
// metadata with null allocation callbacks (vk_mem_alloc.h, VmaVirtualBlock_T's
// constructor), so callbacks would see only the block object itself, never the
// allocations its operations make. The C library's own statistics see every
// one: the bytes and blocks in use, read after each operation of an untimed
// pass. No Haskell code runs inside the replay, so the figures are VMA's.
struct hetoimasia_heap_reading {
  uint64_t bytes;
  uint64_t blocks;
};

static hetoimasia_heap_reading hetoimasia_heap_now(void) {
#if defined(__APPLE__)
  malloc_statistics_t statistics;
  malloc_zone_statistics(nullptr, &statistics);
  return {static_cast<uint64_t>(statistics.size_in_use), static_cast<uint64_t>(statistics.blocks_in_use)};
#else
  struct mallinfo2 statistics = mallinfo2();
  return {static_cast<uint64_t>(statistics.uordblks), 0};
#endif
}

// The replay's modes.
enum {
  REPLAY_EVIDENCE = 0,       // untimed: outcomes, offsets, samples, checkpoints
  REPLAY_PER_OPERATION = 1,  // one clock pair around each operation
  REPLAY_INTERVALS = 2,      // one clock pair around each interval of operations
  REPLAY_HEAP_COUNT = 3      // untimed, reading the heap after every operation
};

// Replay a trace into one virtual block of `capacity` bytes, with VMA's
// default algorithm, and `allocation_flags` on every request: 0 for VMA's
// default strategy, or VMA_VIRTUAL_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT.
//
// Every mode executes every operation the same way; they differ only in what
// they record. A free of an allocation VMA refused is skipped, and a
// checkpoint does nothing outside the evidence pass.
//
// - Per operation: `elapsed[i]` accumulates operation i's nanoseconds.
// - Intervals: `bounds` holds `interval_count` pairs [start, end) of operation
//   indices, sorted and disjoint; `elapsed[k]` accumulates interval k's
//   nanoseconds, read with one clock pair. Operations outside every interval
//   still run, untimed.
// - Evidence: `outcomes[i]` and `offsets[i]` per allocation; after every
//   `sample_every` operations the free bytes and largest free range are written
//   to `sample_free` and `sample_largest`, and at each checkpoint to
//   `checkpoint_free` and `checkpoint_largest` by ordinal.
// - Heap count: the heap is read after every operation; `summary[4]` receives
//   the operations after which the heap's block count or bytes in use changed,
//   `summary[5]` the bytes still in use at the end, and `summary[6]` the peak,
//   both above what the empty block held.
//
// Every mode writes `summary[0]`, a checksum of every placed offset plus one;
// `summary[1]`, the allocations placed; `summary[2]`, the operations executed;
// and `summary[3]`, the nanoseconds of every timed interval or operation.
//
// Returns 0, the VkResult vmaCreateVirtualBlock failed with, or 1 when the
// handle table could not be allocated.
int hetoimasia_vma_replay(uint64_t capacity, uint32_t allocation_flags, uint32_t mode,
                          const struct hetoimasia_trace_op* ops, uint64_t count, uint64_t identities,
                          uint64_t* elapsed, const uint64_t* bounds, uint64_t interval_count, uint8_t* outcomes,
                          uint64_t* offsets, uint64_t sample_every, uint64_t* sample_free,
                          uint64_t* sample_largest, uint64_t* checkpoint_free, uint64_t* checkpoint_largest,
                          uint64_t* summary) {
  VmaVirtualBlockCreateInfo block_info;
  std::memset(&block_info, 0, sizeof block_info);
  block_info.size = capacity;
  VmaVirtualBlock block = nullptr;
  VkResult created = vmaCreateVirtualBlock(&block_info, &block);
  if (created != VK_SUCCESS) {
    return static_cast<int>(created);
  }
  // Each identity's live allocation, or null when it is not live here. Built
  // before the loop, so no timed operation allocates it.
  VmaVirtualAllocation* handles = new (std::nothrow) VmaVirtualAllocation[identities]();
  if (handles == nullptr) {
    vmaDestroyVirtualBlock(block);
    return 1;
  }
  // Only what the operations themselves cost is charged: readings are taken
  // relative to the heap once the empty block and the handle table exist.
  const hetoimasia_heap_reading heap_before =
      mode == REPLAY_HEAP_COUNT ? hetoimasia_heap_now() : hetoimasia_heap_reading{0, 0};
  hetoimasia_heap_reading heap_last = heap_before;
  uint64_t heap_changes = 0;
  uint64_t heap_peak = heap_before.bytes;
  uint64_t checksum = 0;
  uint64_t placed_count = 0;
  uint64_t executed = 0;
  uint64_t timed = 0;
  uint64_t interval = 0;
  uint64_t interval_start = 0;

  for (uint64_t i = 0; i < count; ++i) {
    if (mode == REPLAY_INTERVALS && interval < interval_count && i == bounds[2 * interval]) {
      interval_start = hetoimasia_probe_now();
    }
    const hetoimasia_trace_op& op = ops[i];
    if (op.kind == 0) {
      VmaVirtualAllocationCreateInfo request;
      std::memset(&request, 0, sizeof request);
      request.size = op.size;
      request.alignment = op.alignment;
      request.flags = allocation_flags;
      VmaVirtualAllocation allocation = VK_NULL_HANDLE;
      VkDeviceSize offset = 0;
      uint64_t start = mode == REPLAY_PER_OPERATION ? hetoimasia_probe_now() : 0;
      VkResult result = vmaVirtualAllocate(block, &request, &allocation, &offset);
      bool placed = result == VK_SUCCESS;
      checksum += placed ? offset + 1 : 0;
      if (mode == REPLAY_PER_OPERATION) {
        uint64_t end = hetoimasia_probe_now();
        elapsed[i] += end - start;
        timed += end - start;
      }
      executed += 1;
      placed_count += placed ? 1 : 0;
      handles[op.id] = placed ? allocation : VK_NULL_HANDLE;
      if (mode == REPLAY_EVIDENCE) {
        outcomes[i] = placed ? 1 : 0;
        offsets[i] = placed ? offset : 0;
      }
    } else if (op.kind == 1) {
      VmaVirtualAllocation allocation = handles[op.id];
      if (allocation != VK_NULL_HANDLE) {
        uint64_t start = mode == REPLAY_PER_OPERATION ? hetoimasia_probe_now() : 0;
        vmaVirtualFree(block, allocation);
        if (mode == REPLAY_PER_OPERATION) {
          uint64_t end = hetoimasia_probe_now();
          elapsed[i] += end - start;
          timed += end - start;
        }
        executed += 1;
        handles[op.id] = VK_NULL_HANDLE;
      }
    } else if (mode == REPLAY_EVIDENCE) {
      VmaDetailedStatistics statistics;
      vmaCalculateVirtualBlockStatistics(block, &statistics);
      checkpoint_free[op.id] = statistics.statistics.blockBytes - statistics.statistics.allocationBytes;
      checkpoint_largest[op.id] = statistics.unusedRangeSizeMax;
    }
    if (mode == REPLAY_INTERVALS && interval < interval_count && i + 1 == bounds[2 * interval + 1]) {
      uint64_t end = hetoimasia_probe_now();
      elapsed[interval] += end - interval_start;
      timed += end - interval_start;
      interval += 1;
    }
    if (mode == REPLAY_HEAP_COUNT) {
      hetoimasia_heap_reading reading = hetoimasia_heap_now();
      heap_changes += (reading.bytes != heap_last.bytes || reading.blocks != heap_last.blocks) ? 1 : 0;
      heap_peak = reading.bytes > heap_peak ? reading.bytes : heap_peak;
      heap_last = reading;
    }
    if (mode == REPLAY_EVIDENCE && sample_every != 0 && (i + 1) % sample_every == 0) {
      VmaDetailedStatistics statistics;
      vmaCalculateVirtualBlockStatistics(block, &statistics);
      uint64_t sample = (i + 1) / sample_every - 1;
      sample_free[sample] = statistics.statistics.blockBytes - statistics.statistics.allocationBytes;
      sample_largest[sample] = statistics.unusedRangeSizeMax;
    }
  }

  // Whatever the trace left live is freed untimed, so the block is destroyed
  // empty, as VMA requires.
  for (uint64_t id = 0; id < identities; ++id) {
    if (handles[id] != VK_NULL_HANDLE) {
      vmaVirtualFree(block, handles[id]);
    }
  }
  delete[] handles;
  vmaDestroyVirtualBlock(block);

  summary[0] = checksum;
  summary[1] = placed_count;
  summary[2] = executed;
  summary[3] = timed;
  summary[4] = heap_changes;
  summary[5] = heap_last.bytes > heap_before.bytes ? heap_last.bytes - heap_before.bytes : 0;
  summary[6] = heap_peak - heap_before.bytes;
  return 0;
}

}  // extern "C"
