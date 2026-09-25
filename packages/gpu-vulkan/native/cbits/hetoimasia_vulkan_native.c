/*
** See the header. The assertions below are the whole reason this file includes
** both the Vulkan header and the diagnostics package's.
*/
#include "hetoimasia_vulkan_native.h"

#include <hetoimasia_vulkan_capture.h>

#include <stddef.h>
#include <stdint.h>

#define SAME_FIELD(mirror, mirror_field, real, real_field)                        \
  _Static_assert(offsetof(mirror, mirror_field) == offsetof(real, real_field),   \
                 #mirror "." #mirror_field " is not at " #real "." #real_field); \
  _Static_assert(sizeof(((mirror *) 0)->mirror_field) == sizeof(((real *) 0)->real_field), \
                 #mirror "." #mirror_field " is not the size of " #real "." #real_field)

SAME_FIELD(hetoimasia_capture_callback_data, s_type, VkDebugUtilsMessengerCallbackDataEXT, sType);
SAME_FIELD(hetoimasia_capture_callback_data, next, VkDebugUtilsMessengerCallbackDataEXT, pNext);
SAME_FIELD(hetoimasia_capture_callback_data, flags, VkDebugUtilsMessengerCallbackDataEXT, flags);
SAME_FIELD(hetoimasia_capture_callback_data, message_id_name, VkDebugUtilsMessengerCallbackDataEXT, pMessageIdName);
SAME_FIELD(hetoimasia_capture_callback_data, message_id_number, VkDebugUtilsMessengerCallbackDataEXT, messageIdNumber);
SAME_FIELD(hetoimasia_capture_callback_data, message, VkDebugUtilsMessengerCallbackDataEXT, pMessage);
SAME_FIELD(hetoimasia_capture_callback_data, queue_label_count, VkDebugUtilsMessengerCallbackDataEXT, queueLabelCount);
SAME_FIELD(hetoimasia_capture_callback_data, queue_labels, VkDebugUtilsMessengerCallbackDataEXT, pQueueLabels);
SAME_FIELD(hetoimasia_capture_callback_data, cmd_buf_label_count, VkDebugUtilsMessengerCallbackDataEXT, cmdBufLabelCount);
SAME_FIELD(hetoimasia_capture_callback_data, cmd_buf_labels, VkDebugUtilsMessengerCallbackDataEXT, pCmdBufLabels);
SAME_FIELD(hetoimasia_capture_callback_data, object_count, VkDebugUtilsMessengerCallbackDataEXT, objectCount);
SAME_FIELD(hetoimasia_capture_callback_data, objects, VkDebugUtilsMessengerCallbackDataEXT, pObjects);
_Static_assert(sizeof(hetoimasia_capture_callback_data) == sizeof(VkDebugUtilsMessengerCallbackDataEXT),
               "the callback data mirror is not the size of VkDebugUtilsMessengerCallbackDataEXT");

SAME_FIELD(hetoimasia_capture_object_name, s_type, VkDebugUtilsObjectNameInfoEXT, sType);
SAME_FIELD(hetoimasia_capture_object_name, next, VkDebugUtilsObjectNameInfoEXT, pNext);
SAME_FIELD(hetoimasia_capture_object_name, object_type, VkDebugUtilsObjectNameInfoEXT, objectType);
SAME_FIELD(hetoimasia_capture_object_name, object_handle, VkDebugUtilsObjectNameInfoEXT, objectHandle);
SAME_FIELD(hetoimasia_capture_object_name, object_name, VkDebugUtilsObjectNameInfoEXT, pObjectName);
/* Elements of an array: the stride has to agree too, not just the fields. */
_Static_assert(sizeof(hetoimasia_capture_object_name) == sizeof(VkDebugUtilsObjectNameInfoEXT),
               "the object name mirror is not the size of VkDebugUtilsObjectNameInfoEXT");

SAME_FIELD(hetoimasia_capture_label, s_type, VkDebugUtilsLabelEXT, sType);
SAME_FIELD(hetoimasia_capture_label, next, VkDebugUtilsLabelEXT, pNext);
SAME_FIELD(hetoimasia_capture_label, label_name, VkDebugUtilsLabelEXT, pLabelName);
SAME_FIELD(hetoimasia_capture_label, color, VkDebugUtilsLabelEXT, color);
/* Both label arrays are read by element, so their stride has to agree too. */
_Static_assert(sizeof(hetoimasia_capture_label) == sizeof(VkDebugUtilsLabelEXT),
               "the label mirror is not the size of VkDebugUtilsLabelEXT");

_Static_assert(HETOIMASIA_CAPTURE_SEVERITY_VERBOSE ==VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT, "verbose bit");
_Static_assert(HETOIMASIA_CAPTURE_SEVERITY_INFO == VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT, "info bit");
_Static_assert(HETOIMASIA_CAPTURE_SEVERITY_WARNING == VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT, "warning bit");
_Static_assert(HETOIMASIA_CAPTURE_SEVERITY_ERROR == VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT, "error bit");
_Static_assert(sizeof(VkBool32) == sizeof(uint32_t), "VkBool32 is not 32 bits");
_Static_assert(sizeof(VkDebugUtilsMessageTypeFlagsEXT) == sizeof(uint32_t), "message types are not 32 bits");

VKAPI_ATTR VkBool32 VKAPI_CALL hetoimasia_vulkan_capture_messenger(
  VkDebugUtilsMessageSeverityFlagBitsEXT severity,
  VkDebugUtilsMessageTypeFlagsEXT types,
  const VkDebugUtilsMessengerCallbackDataEXT *data,
  void *user_data)
{
  return (VkBool32) hetoimasia_capture_callback(
    (uint32_t) severity, (uint32_t) types, (const hetoimasia_capture_callback_data *) data, user_data);
}
