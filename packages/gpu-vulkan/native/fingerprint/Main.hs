-- | @hetoimasia-shader-fingerprint@: validate the shader toolchain and write
-- its fingerprint, before the build that splices shaders.
--
-- This has to run before Cabal and GHC decide whether a shader-splicing module
-- is up to date, including on a warm build where no splice would otherwise run:
-- a splice cannot notice that the compiler changed if nothing makes it run. It
-- observes the private-prefix wrapper and the native manifest, refuses unless
-- they agree, and writes the fingerprint only if it differs from the one on
-- disk, so an unchanged toolchain rebuilds nothing.
--
-- > hetoimasia-shader-fingerprint --output packages/gpu-vulkan/native/shaders/toolchain.fingerprint
--
-- The wrapper defaults to @HETOIMASIA_GLSLANG@ and the manifest to the one
-- beside @HETOIMASIA_VULKAN_PREFIX@, both of which
-- @tools/native/native.py prepare@ exports; @--glslang@ and
-- @--native-manifest@ name them explicitly. Nothing is found on @PATH@.
--
-- Exit status: 0 when the fingerprint is current, 1 when the toolchain is
-- refused, 2 for a usage error.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

import Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain
  ( Fingerprint (..)
  , FingerprintInputs (..)
  , generateFingerprint
  , renderToolchainFailure
  , writeFingerprint
  )

data Options = Options
  { optionOutput ∷ Maybe FilePath
  , optionInputs ∷ FingerprintInputs
  }

main ∷ IO ()
main = do
  arguments ← getArgs
  case parse arguments (Options Nothing (FingerprintInputs Nothing Nothing)) of
    Left problem → do
      hPutStrLn stderr ("hetoimasia-shader-fingerprint: " <> problem)
      hPutStrLn stderr "usage: hetoimasia-shader-fingerprint --output FILE [--glslang WRAPPER] [--native-manifest MANIFEST]"
      exitWith (ExitFailure 2)
    Right Options {optionOutput = Nothing} → do
      hPutStrLn stderr "hetoimasia-shader-fingerprint: --output is required"
      exitWith (ExitFailure 2)
    Right Options {optionOutput = Just output, optionInputs = inputs} →
      generateFingerprint inputs >>= \case
        Left failure → do
          hPutStrLn stderr ("hetoimasia-shader-fingerprint: " <> renderToolchainFailure failure)
          exitWith (ExitFailure 1)
        Right fingerprint → do
          wrote ← writeFingerprint output fingerprint
          putStrLn
            ( "shader fingerprint: "
                <> output
                <> (if wrote then " written" else " unchanged")
                <> " (glslang "
                <> fingerprintVersion fingerprint
                <> " "
                <> take 12 (fingerprintCompilerSha256 fingerprint)
                <> " behind "
                <> fingerprintWrapper fingerprint
                <> ", target "
                <> fingerprintTarget fingerprint
                <> ", flags "
                <> unwords (fingerprintFlags fingerprint)
                <> ", native manifest "
                <> take 12 (fingerprintManifestSha256 fingerprint)
                <> ")"
            )

parse ∷ [String] → Options → Either String Options
parse arguments options = case arguments of
  [] → Right options
  "--output" : path : rest → parse rest options {optionOutput = Just path}
  "--glslang" : path : rest → parse rest options {optionInputs = (optionInputs options) {inputWrapper = Just path}}
  "--native-manifest" : path : rest →
    parse rest options {optionInputs = (optionInputs options) {inputManifest = Just path}}
  argument : _ → Left ("unexpected argument " <> argument)
