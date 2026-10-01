// The production VMA shim (GRS-11, #333): the engine-owned C entries the
// native backend's allocator calls, in the shape #361 (GRS-18) qualified.
//
// - One entry per engine call, taking only scalars and writing its results into
//   one caller-owned record, so the Haskell side marshals no struct and imports
//   every entry `unsafe`.
// - D-40's device-memory callbacks count in C, into the allocator's own state.
//   Nothing reachable from these entries enters Haskell, which is what lets
//   them be unsafe calls.
// - Every entry runs on the graphics owner's thread alone: the allocator is
//   created with VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT and nothing
//   here locks.
//
// VMA itself is the copy the pinned Hackage `VulkanMemoryAllocator` package
// compiles into its library, with the build flags `cabal.project.vulkan`
// constrains. This file includes the same `vk_mem_alloc.h`, vendored from that
// package's distribution under `vendor/vma/`, for its declarations only, under
// exactly the configuration that package's `src/lib.cpp` compiles it with, so
// every structure here has the layout the compiled VMA reads. See
// docs/toolchain.md, "VMA".

#define VMA_STATIC_VULKAN_FUNCTIONS 0
#define VMA_DEDICATED_ALLOCATION 1
#define VMA_BIND_MEMORY2 1
#define VMA_MEMORY_BUDGET 1
#define VMA_BUFFER_DEVICE_ADDRESS 1
#define VMA_MEMORY_PRIORITY 1
#define VMA_EXTERNAL_MEMORY 1

#include <cstdint>
#include <cstdlib>
#include <cstring>

#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#endif

#include <vk_mem_alloc.h>

#ifdef __clang__
#pragma clang diagnostic pop
#endif

extern "C" {

// What the device-memory callbacks saw during one call: every block or
// dedicated allocation VMA opened, and every one it freed.
struct hetoimasia_vma_events {
  uint64_t opened_count;
  uint64_t opened_bytes;
  uint64_t freed_count;
  uint64_t freed_bytes;
};

// One allocator and the events its callbacks are counting into. It is
// allocated here, so the callbacks' user data outlives every call, and freed
// by `hetoimasia_vma_destroy`.
struct hetoimasia_vma_allocator {
  VmaAllocator allocator;
  hetoimasia_vma_events events;
};

// The record every entry writes its results into: the buffer and allocation a
// creation made, where the allocation lies, the mapped address a map answered,
// and the events of the call.
struct hetoimasia_vma_result {
  uint64_t buffer;
  uint64_t allocation;
  uint64_t device_memory;
  uint64_t offset;
  uint64_t size;
  uint64_t mapped;
  uint32_t memory_type;
  uint32_t reserved;
  hetoimasia_vma_events events;
};

uint64_t hetoimasia_vma_result_size(void) { return sizeof(hetoimasia_vma_result); }

static void hetoimasia_vma_on_allocate(VmaAllocator, uint32_t, VkDeviceMemory, VkDeviceSize size, void* user_data) {
  hetoimasia_vma_events* events = static_cast<hetoimasia_vma_events*>(user_data);
  events->opened_count += 1;
  events->opened_bytes += size;
}

static void hetoimasia_vma_on_free(VmaAllocator, uint32_t, VkDeviceMemory, VkDeviceSize size, void* user_data) {
  hetoimasia_vma_events* events = static_cast<hetoimasia_vma_events*>(user_data);
  events->freed_count += 1;
  events->freed_bytes += size;
}

// Start counting one call's events, and hand them to the result after it.
static void hetoimasia_vma_begin(hetoimasia_vma_allocator* state) {
  std::memset(&state->events, 0, sizeof state->events);
}

static void hetoimasia_vma_end(hetoimasia_vma_allocator* state, hetoimasia_vma_result* out) {
  out->events = state->events;
}

// Create one allocator for the device, with the Vulkan entry points of the
// backend's own dispatch, an explicit large-heap block size, and the counting
// callbacks. Answers VK_SUCCESS with the state in `out`, or the failure having
// made nothing.
int32_t hetoimasia_vma_create(void* instance, void* physical_device, void* device, void* get_instance_proc_addr,
                              void* get_device_proc_addr, uint32_t api_version,
                              uint64_t preferred_large_heap_block_size, hetoimasia_vma_allocator** out) {
  hetoimasia_vma_allocator* state =
      static_cast<hetoimasia_vma_allocator*>(std::calloc(1, sizeof(hetoimasia_vma_allocator)));
  if (state == nullptr) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  VmaVulkanFunctions functions;
  std::memset(&functions, 0, sizeof functions);
  functions.vkGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(get_instance_proc_addr);
  functions.vkGetDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(get_device_proc_addr);
  VmaDeviceMemoryCallbacks callbacks;
  callbacks.pfnAllocate = hetoimasia_vma_on_allocate;
  callbacks.pfnFree = hetoimasia_vma_on_free;
  callbacks.pUserData = &state->events;
  VmaAllocatorCreateInfo info;
  std::memset(&info, 0, sizeof info);
  info.flags = VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT;
  info.physicalDevice = static_cast<VkPhysicalDevice>(physical_device);
  info.device = static_cast<VkDevice>(device);
  info.preferredLargeHeapBlockSize = preferred_large_heap_block_size;
  info.pDeviceMemoryCallbacks = &callbacks;
  info.pVulkanFunctions = &functions;
  info.instance = static_cast<VkInstance>(instance);
  info.vulkanApiVersion = api_version;
  VkResult result = vmaCreateAllocator(&info, &state->allocator);
  if (result != VK_SUCCESS) {
    std::free(state);
    return result;
  }
  *out = state;
  return VK_SUCCESS;
}

// Destroy the allocator, which frees whatever device memory VMA still holds —
// its retained empty blocks — and the state. Every allocation must already be
// freed; the caller refuses otherwise.
void hetoimasia_vma_destroy(hetoimasia_vma_allocator* state, hetoimasia_vma_result* out) {
  hetoimasia_vma_begin(state);
  vmaDestroyAllocator(state->allocator);
  hetoimasia_vma_end(state, out);
  std::free(state);
}

// Create a buffer and its allocation in exactly one memory type, bound, as one
// VMA call. With `never_allocate` nonzero the allocation may only be placed in
// device memory VMA already holds. VMA honours the driver's preferred or
// required dedicated allocation within that type. On failure VMA has destroyed
// whatever it made, though the call's events still say what it opened and
// freed on the way.
int32_t hetoimasia_vma_create_buffer(hetoimasia_vma_allocator* state, uint64_t size, uint32_t usage,
                                     uint32_t memory_type, uint32_t never_allocate, hetoimasia_vma_result* out) {
  VkBufferCreateInfo buffer_info;
  std::memset(&buffer_info, 0, sizeof buffer_info);
  buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  buffer_info.size = size;
  buffer_info.usage = usage;
  buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  VmaAllocationCreateInfo request;
  std::memset(&request, 0, sizeof request);
  request.flags = never_allocate != 0 ? VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT : 0;
  request.usage = VMA_MEMORY_USAGE_UNKNOWN;
  request.memoryTypeBits = 1u << memory_type;
  VkBuffer buffer = VK_NULL_HANDLE;
  VmaAllocation allocation = VK_NULL_HANDLE;
  VmaAllocationInfo info;
  hetoimasia_vma_begin(state);
  VkResult result = vmaCreateBuffer(state->allocator, &buffer_info, &request, &buffer, &allocation, &info);
  hetoimasia_vma_end(state, out);
  if (result == VK_SUCCESS) {
    out->buffer = reinterpret_cast<uint64_t>(buffer);
    out->allocation = reinterpret_cast<uint64_t>(allocation);
    out->device_memory = reinterpret_cast<uint64_t>(info.deviceMemory);
    out->offset = info.offset;
    out->size = info.size;
    out->memory_type = info.memoryType;
  }
  return result;
}

// Destroy the buffer, then free its allocation.
void hetoimasia_vma_destroy_buffer(hetoimasia_vma_allocator* state, uint64_t buffer, uint64_t allocation,
                                   hetoimasia_vma_result* out) {
  hetoimasia_vma_begin(state);
  vmaDestroyBuffer(state->allocator, reinterpret_cast<VkBuffer>(buffer), reinterpret_cast<VmaAllocation>(allocation));
  hetoimasia_vma_end(state, out);
}

// Map the allocation for as long as it lives; the address is in `out`.
int32_t hetoimasia_vma_map(hetoimasia_vma_allocator* state, uint64_t allocation, hetoimasia_vma_result* out) {
  void* mapped = nullptr;
  VkResult result = vmaMapMemory(state->allocator, reinterpret_cast<VmaAllocation>(allocation), &mapped);
  out->mapped = reinterpret_cast<uint64_t>(mapped);
  return result;
}

void hetoimasia_vma_unmap(hetoimasia_vma_allocator* state, uint64_t allocation) {
  vmaUnmapMemory(state->allocator, reinterpret_cast<VmaAllocation>(allocation));
}

// Flush or invalidate a range of the allocation, relative to its start: VMA
// translates it into its device memory and aligns it to the atom.
int32_t hetoimasia_vma_flush(hetoimasia_vma_allocator* state, uint64_t allocation, uint64_t offset, uint64_t size) {
  return vmaFlushAllocation(state->allocator, reinterpret_cast<VmaAllocation>(allocation), offset, size);
}

int32_t hetoimasia_vma_invalidate(hetoimasia_vma_allocator* state, uint64_t allocation, uint64_t offset,
                                  uint64_t size) {
  return vmaInvalidateAllocation(state->allocator, reinterpret_cast<VmaAllocation>(allocation), offset, size);
}

// Name the allocation inside VMA; VMA copies the string.
void hetoimasia_vma_set_name(hetoimasia_vma_allocator* state, uint64_t allocation, const char* name) {
  vmaSetAllocationName(state->allocator, reinterpret_cast<VmaAllocation>(allocation), name);
}

}  // extern "C"
