/* The native suite's image provenance, and nothing else.
 *
 * "The loader this run loaded is the qualified one" is an observation, not an assumption: two independently
 * found libraries can export the same symbol name, but only one image can define the address a call
 * actually reaches. This asks the dynamic linker which image defines an address. The suite creates no
 * window and calls no GLFW function of its own; the production host does that, through its own session.
 */
#ifndef HETOIMASIA_LUA_ENGINE_GRAPHICS_NATIVE_H
#define HETOIMASIA_LUA_ENGINE_GRAPHICS_NATIVE_H

#include <stddef.h>

/* The image that defines `address`, and the symbol it is known by there. Writes at most `capacity` bytes
 * including the terminator and returns 1 when the address was attributed, 0 when it was not. */
int hetoimasia_lege_image_of(const void *address, char *image, size_t image_capacity,
                             char *symbol, size_t symbol_capacity);

#endif /* HETOIMASIA_LUA_ENGINE_GRAPHICS_NATIVE_H */
