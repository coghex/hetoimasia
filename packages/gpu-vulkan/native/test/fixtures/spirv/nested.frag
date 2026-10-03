#version 450

// A push-constant block with a nested struct, which the reader does not
// support and must refuse rather than misread.

struct Inner { vec4 value; };

layout(push_constant) uniform Pushed {
    Inner inner;
} pushed;

layout(location = 0) out vec4 colour;

void main() {
    colour = pushed.inner.value;
}
