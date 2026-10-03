#version 450
#extension GL_EXT_nonuniform_qualifier : require

// The checked fragment shader of the shader suite (GRS-16), compiled from this
// file by `checkedFragmentShaderFile` against `checkedFragmentInterface`: a
// push-constant tint, a combined image sampler, a fixed pair of images, a
// sampler, and a runtime-sized table of images.

layout(push_constant) uniform Pushed { vec4 tint; } pushed;

layout(set = 0, binding = 0) uniform sampler2D combined;
layout(set = 0, binding = 1) uniform texture2D pair[2];
layout(set = 0, binding = 2) uniform sampler plain;
layout(set = 1, binding = 0) uniform texture2D table[];

layout(location = 0) in vec4 shade;
layout(location = 0) out vec4 colour;

void main() {
    vec2 at = shade.xy;
    colour = pushed.tint
        * texture(combined, at)
        * texture(sampler2D(pair[1], plain), at)
        * texture(sampler2D(table[nonuniformEXT(uint(shade.z))], plain), at);
}
