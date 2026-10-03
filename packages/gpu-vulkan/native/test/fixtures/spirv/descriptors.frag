#version 450
#extension GL_EXT_nonuniform_qualifier : require

// A fragment shader with every descriptor kind the reader reports, a fixed
// array and a runtime-sized one, and a varying input it does not report.

layout(set = 0, binding = 0) uniform sampler2D combined;
layout(set = 0, binding = 1) uniform texture2D images[4];
layout(set = 0, binding = 2) uniform sampler plain;
layout(set = 0, binding = 3, rgba8) uniform readonly image2D stored;
layout(set = 1, binding = 0) uniform Uniforms { vec4 tint; } uniforms;
layout(set = 1, binding = 1) readonly buffer Storage { vec4 values[]; } storage;
layout(set = 2, binding = 0) uniform texture2D table[];

layout(location = 0) in vec2 coordinate;
layout(location = 1) flat in uint slot;
layout(location = 0) out vec4 colour;

void main() {
    colour = texture(combined, coordinate)
        + texture(sampler2D(images[slot % 4u], plain), coordinate)
        + imageLoad(stored, ivec2(0))
        + uniforms.tint
        + storage.values[slot]
        + texture(sampler2D(table[nonuniformEXT(slot)], plain), coordinate);
}
