#version 450

// A vertex shader with every kind of host interface the reader reports for
// the vertex stage: a push-constant block of a matrix, a vector and an array,
// three vertex inputs, a built-in it reads and a varying it writes, neither of
// which the reader reports.

layout(push_constant) uniform Pushed {
    mat4 transform;
    vec4 tint;
    float scale[3];
} pushed;

layout(location = 0) in vec2 position;
layout(location = 1) in uint index;
layout(location = 2) in vec4 colour;

layout(location = 0) out vec4 shade;

void main() {
    shade = colour * pushed.tint * pushed.scale[index % 3u] * float(gl_VertexIndex);
    gl_Position = pushed.transform * vec4(position, 0.0, 1.0);
}
