#version 450

// Boolean built-ins, which are the device's rather than the host's: the
// reader must read this shader as interface-free, not refuse its booleans.

layout(location = 0) out vec4 colour;

void main() {
    colour = (gl_FrontFacing && !gl_HelperInvocation) ? vec4(1.0) : vec4(0.0);
}
