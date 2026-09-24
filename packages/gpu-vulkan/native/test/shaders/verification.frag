#version 450
#extension GL_GOOGLE_include_directive : require

// The fragment half of VK-9's verification pair, compiled from this file by
// `fragmentShaderFile`. Its include includes another, so the adapter has a
// transitive include to resolve and register.
#include "include/verification_interface.glsl"

layout(location = 0) out vec4 colour;

void main() {
    colour = verificationColour(tag);
}
