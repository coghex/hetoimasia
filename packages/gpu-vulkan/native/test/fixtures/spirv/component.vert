#version 450

// A vertex input in the second component of its location, which the reader
// does not support and must refuse rather than report as the location's
// first component.

layout(location = 0, component = 1) in float height;

void main() {
    gl_Position = vec4(0.0, height, 0.0, 1.0);
}
