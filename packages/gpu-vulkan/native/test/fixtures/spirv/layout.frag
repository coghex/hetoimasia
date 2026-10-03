#version 450

// Explicit layouts under both profiles the reader checks: a push-constant
// block under std430 — a vec3, a float, a mat2 and a float array of stride
// 4 — and a uniform block under std140 — a float, structs, a vec2 after a
// struct's padding, and a float array of stride 16 — beside a storage
// buffer of structs under std430. Every offset and stride is the pinned
// compiler's own.

struct Pair {
    vec4 a;
    float b;
};

layout(push_constant) uniform Pushed {
    vec3 v;
    float f;
    mat2 m;
    float g[2];
} pushed;

layout(set = 0, binding = 0) uniform Uniforms {
    float x;
    Pair p;
    vec2 y;
    Pair q[2];
    float h[2];
} uniforms;

layout(set = 0, binding = 1) readonly buffer Storage {
    Pair r[];
} storage;

layout(location = 0) out vec4 colour;

void main() {
    colour = vec4(pushed.v, pushed.f) + vec4(pushed.m[0], pushed.m[1]) * pushed.g[1]
        + uniforms.p.a * uniforms.x + vec4(uniforms.y, uniforms.h[1], uniforms.q[1].b)
        + storage.r[0].a;
}
