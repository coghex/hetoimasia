#version 450

// A matrix vertex input, which the reader does not support and must refuse.

layout(location = 0) in mat2 basis;

void main() {
    gl_Position = vec4(basis[0], basis[1]);
}
