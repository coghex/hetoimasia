{-# LANGUAGE TemplateHaskell #-}

-- | The fragment half of VK-9's verification pair: a file whose include
-- includes another, so the splice has a transitive include to register.
module Test.Shader.Fragment (verificationFragment) where

import Data.ByteString (ByteString)

import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShaderFile)

-- | Reads the tag through two levels of include.
verificationFragment ∷ ByteString
verificationFragment = $(fragmentShaderFile "test/shaders/verification.frag")
