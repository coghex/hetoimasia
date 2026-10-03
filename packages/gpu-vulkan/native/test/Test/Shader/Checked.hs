{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Checked shaders that match their descriptions (GRS-16), in both forms: the
-- vertex shader from inline source, the fragment shader from a file. That
-- this module compiles is itself the proof that matching shaders compile.
module Test.Shader.Checked (matchingVertex, matchingFragment) where

import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShader, checkedFragmentShaderFile, checkedVertexShader, glsl)
import Test.Shader.Interfaces (checkedFragmentInterface, checkedVertexInterface)

matchingVertex ∷ CheckedShader
matchingVertex =
  $( checkedVertexShader
       checkedVertexInterface
       [glsl|
    #version 450

    layout(push_constant) uniform Pushed { vec4 tint; } pushed;

    layout(location = 0) in vec2 position;
    layout(location = 1) in vec4 colour;

    layout(location = 0) out vec4 shade;

    void main() {
        shade = colour * pushed.tint;
        gl_Position = vec4(position, 0.0, 1.0);
    }
  |]
   )

matchingFragment ∷ CheckedShader
matchingFragment = $(checkedFragmentShaderFile checkedFragmentInterface "test/shaders/checked.frag")
