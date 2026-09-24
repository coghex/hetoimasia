{-# LANGUAGE TemplateHaskell #-}

-- | GLSL compiled while the Haskell build runs, embedded as SPIR-V.
--
-- This is VK-9's adapter over the binding's own workflow (D-11, P-9). Source
-- is written with 'glsl', @vulkan-utils@' interpolating quasiquoter, which
-- inserts a @#line@ directive pointing at the Haskell file and substitutes
-- @$name@ or @${name}@ with the 'show' of a Haskell value, so shared constants
-- and layout declarations are written once. A splice then compiles it:
--
-- > import Hetoimasia.GPU.Vulkan.Native.Shader (fragmentShader, glsl)
-- > import Shared.Layout (colourLocation) -- another module: a splice runs it
-- >
-- > shadeRed ∷ ByteString
-- > shadeRed = $(fragmentShader [glsl|
-- >   #version 450
-- >   layout(location = ${colourLocation}) out vec4 colour;
-- >   void main() { colour = vec4(1, 0, 0, 1); }
-- > |])
--
-- or compiles a file relative to the package root, whose @#include@s are
-- resolved relative to the file:
--
-- > shadeBlue = $(fragmentShaderFile "shaders/blue.frag")
--
-- Unlike the binding's own @vert@ and @frag@ quoters, which run whatever
-- @glslangValidator@ is on @PATH@ for no stated target and register nothing,
-- every splice here:
--
-- * compiles for an explicit target environment, 'vulkan13', and refuses to
--   compile for any target the toolchain fingerprint was not generated for;
-- * runs only the private-prefix wrapper the fingerprint names, after
--   checking the fingerprint against the wrapper, the compiler and the native
--   manifest as they are now — see
--   "Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain";
-- * registers its rebuild inputs with 'addDependentFile': the fingerprint, the
--   source file when there is one, and every include the compiler resolved,
--   transitively. A package that splices shaders lists those files as source
--   files too — this package's @**/*.fingerprint@ and shader globs — because
--   Cabal otherwise never asks GHC to look;
-- * fails the build, naming the module, the splice's position, the stage and
--   the compiler's own message, when the shader does not compile.
--
-- Compiling needs no display, device, loader session or consent. An
-- interpolated value must be defined in another module, as for any splice.
module Hetoimasia.GPU.Vulkan.Native.Shader
  ( -- * Writing shader source
    glsl

    -- * Compiling it during the build
  , vertexShader
  , fragmentShader
  , computeShader
  , vertexShaderFile
  , fragmentShaderFile
  , computeShaderFile
  , compileShaderQ
  , compileShaderFileQ

    -- * The configuration a splice compiles under
  , TargetEnvironment
  , vulkan13
  , targetEnvironmentName
  , ShaderStage (..)
  , fingerprintPath
  ) where

import Control.Monad (unless)
import Data.List (intercalate)
import Language.Haskell.TH (Exp, Loc (..), Q, location, reportWarning, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import System.Directory (getCurrentDirectory)
import Vulkan.Utils.ShaderQQ.GLSL.Glslang (glsl)

import Hetoimasia.GPU.Vulkan.Native.Shader.Toolchain
  ( CompileRequest (..)
  , CompiledShader (..)
  , ShaderSite (..)
  , ShaderSource (..)
  , ShaderStage (..)
  , TargetEnvironment
  , compileShader
  , fingerprintPath
  , loadToolchain
  , renderShaderFailure
  , renderToolchainFailure
  , targetEnvironmentName
  , vulkan13
  )

-- | A vertex shader from source text, for 'vulkan13'.
vertexShader ∷ String → Q Exp
vertexShader = compileShaderQ vulkan13 Vertex []

-- | A fragment shader from source text, for 'vulkan13'.
fragmentShader ∷ String → Q Exp
fragmentShader = compileShaderQ vulkan13 Fragment []

-- | A compute shader from source text, for 'vulkan13'.
computeShader ∷ String → Q Exp
computeShader = compileShaderQ vulkan13 Compute []

-- | A vertex shader from a file relative to the package root, for 'vulkan13'.
vertexShaderFile ∷ FilePath → Q Exp
vertexShaderFile = compileShaderFileQ vulkan13 Vertex

-- | A fragment shader from a file relative to the package root, for 'vulkan13'.
fragmentShaderFile ∷ FilePath → Q Exp
fragmentShaderFile = compileShaderFileQ vulkan13 Fragment

-- | A compute shader from a file relative to the package root, for 'vulkan13'.
computeShaderFile ∷ FilePath → Q Exp
computeShaderFile = compileShaderFileQ vulkan13 Compute

-- | Compile source text to a strict @ByteString@ of SPIR-V. The include
-- directories are relative to the package root; source text has no directory
-- of its own for an include to be found relative to.
compileShaderQ ∷ TargetEnvironment → ShaderStage → [FilePath] → String → Q Exp
compileShaderQ target stage includes = splice target stage includes . InlineSource

-- | Compile a file relative to the package root to a strict @ByteString@ of
-- SPIR-V. Its includes are resolved relative to the file.
compileShaderFileQ ∷ TargetEnvironment → ShaderStage → FilePath → Q Exp
compileShaderFileQ target stage = splice target stage [] . SourceFile

splice ∷ TargetEnvironment → ShaderStage → [FilePath] → ShaderSource → Q Exp
splice target stage includes source = do
  here ← location
  toolchain ← either (fail . renderToolchainFailure) pure =<< runIO (loadToolchain fingerprintPath)
  addDependentFile fingerprintPath
  root ← runIO getCurrentDirectory
  let request =
        CompileRequest
          { requestSite =
              ShaderSite
                { siteModule = loc_module here
                , siteFile = loc_filename here
                , siteLine = fst (loc_start here)
                , siteColumn = snd (loc_start here)
                }
          , requestTarget = target
          , requestStage = stage
          , requestIncludes = includes
          , requestSource = source
          }
  compiled ← either (fail . renderShaderFailure) pure =<< runIO (compileShader toolchain root request)
  mapM_ addDependentFile (compiledInputs compiled)
  -- A compiler warning is a build warning, so -Werror makes it an error.
  unless (null (compiledWarnings compiled)) $
    reportWarning (intercalate "\n" ("glslang warned about this shader:" : map ("    " <>) (compiledWarnings compiled)))
  lift (compiledSpirv compiled)
