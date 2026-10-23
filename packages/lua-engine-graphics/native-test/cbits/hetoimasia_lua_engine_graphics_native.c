#define _GNU_SOURCE
#include "hetoimasia_lua_engine_graphics_native.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int hetoimasia_lege_image_of(const void *address, char *image, size_t image_capacity,
                             char *symbol, size_t symbol_capacity)
{
  Dl_info info;
  if (image_capacity > 0) {
    image[0] = '\0';
  }
  if (symbol_capacity > 0) {
    symbol[0] = '\0';
  }
  if (address == NULL) {
    return 0;
  }
  memset(&info, 0, sizeof info);
  if (dladdr(address, &info) == 0) {
    return 0;
  }
  if (info.dli_fname != NULL && image_capacity > 0) {
    snprintf(image, image_capacity, "%s", info.dli_fname);
  }
  if (info.dli_sname != NULL && symbol_capacity > 0) {
    snprintf(symbol, symbol_capacity, "%s", info.dli_sname);
  }
  return 1;
}
