{-# LANGUAGE TemplateHaskell #-}

-- | A fragment shader reading boolean built-ins, gl_FrontFacing and
-- gl_HelperInvocation, through an unchecked splice: built-ins are the
-- device's, so the shader declares no interface, and that this module
-- compiles is itself the proof the splice accepts it.
module Test.Shader.BuiltIns (builtInFragment) where

import Data.ByteString (ByteString)

import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShaderFile)

builtInFragment ∷ ByteString
builtInFragment = $(fragmentShaderFile "test/fixtures/spirv/builtins.frag")
