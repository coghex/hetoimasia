#version 450

// A push-constant member whose extent, 1073741825 floats four bytes apart,
// is beyond what 32 bits can hold: the reader must refuse it rather than wrap.

layout(push_constant) uniform Pushed {
    float data[1073741825];
} pushed;

layout(location = 0) out vec4 colour;

void main() {
    colour = vec4(pushed.data[0]);
}
