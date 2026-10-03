#version 450

// An input attachment, which the reader does not support and must refuse
// rather than classify as a storage image.

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput previous;

layout(location = 0) out vec4 colour;

void main() {
    colour = subpassLoad(previous);
}
