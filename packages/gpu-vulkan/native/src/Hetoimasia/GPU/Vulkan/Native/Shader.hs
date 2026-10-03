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
--
-- = Shader interfaces (GRS-16)
--
-- A shader that reads anything from the host — a push-constant block, vertex
-- inputs, descriptor bindings — is compiled by a checked splice, given its
-- 'ShaderInterface' ("Hetoimasia.GPU.Vulkan.Native.Shader.Interface"):
--
-- > import Shared.Interfaces (quadVertex) -- another module: a splice runs it
-- >
-- > quad ∷ CheckedShader
-- > quad = $(checkedVertexShader quadVertex [glsl|
-- >   #version 450
-- >   layout(location = 0) in vec2 position;
-- >   void main() { gl_Position = vec4(position, 0.0, 1.0); }
-- > |])
--
-- After compiling, a checked splice reads the SPIR-V's interface with the pure
-- reader "Hetoimasia.GPU.Vulkan.Native.Shader.Reflect" and compares it with
-- the description in both directions: something declared but absent from the
-- shader, something present but undeclared, and a stage, push-constant member
-- offset or size, vertex input location or format, or descriptor set,
-- binding, kind or count that disagrees each fail the build, naming the
-- module, the splice's position, the stage and every mismatch. A shader that
-- passes is a 'CheckedShader', its SPIR-V beside its description, from which a
-- pipeline takes its push-constant ranges and vertex input
-- ("Hetoimasia.GPU.Vulkan.Native.Recording.createCheckedPipeline").
--
-- The unchecked vertex and fragment splices — 'vertexShader', 'fragmentShader',
-- their file forms, and 'compileShaderQ' and 'compileShaderFileQ' for those
-- stages — compile only interface-free shaders: one that declares a
-- push-constant block, a vertex input or a descriptor binding fails the build,
-- naming what it found. Built-ins, a vertex shader's outputs and a fragment
-- shader's inputs and outputs are no interface of the host's, so the triangle's
-- shaders and every other interface-free shader compile as before. Compute
-- shaders are compiled as they always were. No native tool reads the
-- SPIR-V.
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

    -- * Checked shaders (GRS-16)
  , checkedVertexShader
  , checkedFragmentShader
  , checkedVertexShaderFile
  , checkedFragmentShaderFile
  , CheckedShader (..)
  , CheckedShaders (..)

    -- * The configuration a splice compiles under
  , TargetEnvironment
  , vulkan13
  , targetEnvironmentName
  , ShaderStage (..)
  , fingerprintPath
  ) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.List (intercalate)
import Language.Haskell.TH (Exp, Loc (..), Q, location, reportWarning, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import System.Directory (getCurrentDirectory)
import Vulkan.Utils.ShaderQQ.GLSL.Glslang (glsl)

import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (CheckedShader (..), CheckedShaders (..), ShaderInterface, compareInterface, foundInterface, renderMismatch)
import Hetoimasia.GPU.Vulkan.Native.Shader.Reflect (reflect)
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
-- of its own for an include to be found relative to. A vertex or fragment
-- shader must be interface-free.
compileShaderQ ∷ TargetEnvironment → ShaderStage → [FilePath] → String → Q Exp
compileShaderQ target stage includes = unchecked target stage includes . InlineSource

-- | Compile a file relative to the package root to a strict @ByteString@ of
-- SPIR-V. Its includes are resolved relative to the file. A vertex or fragment
-- shader must be interface-free.
compileShaderFileQ ∷ TargetEnvironment → ShaderStage → FilePath → Q Exp
compileShaderFileQ target stage = unchecked target stage [] . SourceFile

-- | A vertex shader from source text, for 'vulkan13', checked against its
-- description: a 'CheckedShader'.
checkedVertexShader ∷ ShaderInterface → String → Q Exp
checkedVertexShader interface = checked vulkan13 Vertex interface . InlineSource

-- | A fragment shader from source text, for 'vulkan13', checked against its
-- description: a 'CheckedShader'.
checkedFragmentShader ∷ ShaderInterface → String → Q Exp
checkedFragmentShader interface = checked vulkan13 Fragment interface . InlineSource

-- | A vertex shader from a file relative to the package root, for 'vulkan13',
-- checked against its description: a 'CheckedShader'.
checkedVertexShaderFile ∷ ShaderInterface → FilePath → Q Exp
checkedVertexShaderFile interface = checked vulkan13 Vertex interface . SourceFile

-- | A fragment shader from a file relative to the package root, for
-- 'vulkan13', checked against its description: a 'CheckedShader'.
checkedFragmentShaderFile ∷ ShaderInterface → FilePath → Q Exp
checkedFragmentShaderFile interface = checked vulkan13 Fragment interface . SourceFile

-- | Compile, and for a vertex or fragment shader refuse any interface.
unchecked ∷ TargetEnvironment → ShaderStage → [FilePath] → ShaderSource → Q Exp
unchecked target stage includes source = do
  (site, spirv) ← compiledAt target stage includes source
  case stage of
    Compute → pure ()
    _ → case reflect spirv of
      Left reason → fail (unreadable site stage reason)
      Right found → case foundInterface found of
        [] → pure ()
        declared →
          fail
            ( intercalate
                "\n"
                ( (described site stage <> " declares an interface, which only a checked splice may compile:")
                    : map ("    " <>) declared
                    <> ["  compile it with " <> checkedName stage <> " and its interface description instead"]
                )
            )
  lift spirv

-- | Compile, read the interface, and compare it with the description: the
-- 'CheckedShader' if they agree, and a build failure naming every mismatch if
-- they do not.
checked ∷ TargetEnvironment → ShaderStage → ShaderInterface → ShaderSource → Q Exp
checked target stage interface source = do
  (site, spirv) ← compiledAt target stage [] source
  case reflect spirv of
    Left reason → fail (unreadable site stage reason)
    Right found → case compareInterface interface found of
      [] → [|CheckedShader $(lift spirv) $(lift interface)|]
      mismatches →
        fail
          ( intercalate
              "\n"
              ((described site stage <> " does not match its interface description:") : map (("    " <>) . renderMismatch) mismatches)
          )

-- | Compile under the fingerprinted toolchain, register the rebuild inputs,
-- and report the compiler's warnings, answering the splice's site and the
-- SPIR-V.
compiledAt ∷ TargetEnvironment → ShaderStage → [FilePath] → ShaderSource → Q (ShaderSite, ByteString)
compiledAt target stage includes source = do
  here ← location
  toolchain ← either (fail . renderToolchainFailure) pure =<< runIO (loadToolchain fingerprintPath)
  addDependentFile fingerprintPath
  root ← runIO getCurrentDirectory
  let site =
        ShaderSite
          { siteModule = loc_module here
          , siteFile = loc_filename here
          , siteLine = fst (loc_start here)
          , siteColumn = snd (loc_start here)
          }
      request =
        CompileRequest
          { requestSite = site
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
  pure (site, compiledSpirv compiled)

-- | The shader a failure is about: its stage, where it was spliced, and the
-- module.
described ∷ ShaderSite → ShaderStage → String
described site stage =
  "the "
    <> stageName stage
    <> " shader spliced at "
    <> siteFile site
    <> ":"
    <> show (siteLine site)
    <> ":"
    <> show (siteColumn site)
    <> " in module "
    <> siteModule site

unreadable ∷ ShaderSite → ShaderStage → String → String
unreadable site stage reason = described site stage <> " could not be read for its interface: " <> reason

stageName ∷ ShaderStage → String
stageName = \case
  Vertex → "vertex"
  Fragment → "fragment"
  Compute → "compute"

checkedName ∷ ShaderStage → String
checkedName = \case
  Vertex → "checkedVertexShader or checkedVertexShaderFile"
  Fragment → "checkedFragmentShader or checkedFragmentShaderFile"
  Compute → "a compute splice"
