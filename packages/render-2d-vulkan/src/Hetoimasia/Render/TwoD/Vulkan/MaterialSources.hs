{-# LANGUAGE DeriveLift #-}

-- | What an application material's declaration comes to (R2D-11): the layout of
-- its push block, the GLSL its two variants are compiled from, and the interface
-- descriptions they are checked against. All of it is pure and is run by the
-- splice in "Hetoimasia.Render.TwoD.Vulkan.Material", from a module of its own
-- because a splice can run only what another module has compiled.
--
-- = The material function
--
-- An application writes one GLSL function of a fixed signature:
--
-- > vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record)
--
-- It receives the instance's sampled texel (premultiplied, in linear light, as
-- the instance's sampler gives it), the interpolated texture coordinates, the
-- instance's parameter word, and the record that word indexes. It returns the
-- material's colour, premultiplied, in linear light. The engine wraps whatever
-- it returns: the tint, the brightness, and the blend output or the cutout
-- variant's discard (render-2d D-26), so a material cannot omit them.
--
-- Declared around the function, and usable in it:
--
-- * @MaterialRecord@, a struct of @uvec2 handles[H]@ and @uint words[W]@, with
--   @H@ and @W@ the layout's counts, or one when a count is zero (an array
--   cannot be empty; that element is never read and is zero). A handle is a full
--   handle, a lookup index and a generation.
-- * @vec4 sampleTexture(uvec2 handle, vec2 uv)@, which samples a full handle
--   through the texture table's lookup with its generation check, so an index
--   that was released and reused samples the transparent placeholder, with the
--   instance's own sampler choice. Call it unconditionally: its implicit
--   derivatives are defined only in uniform control flow.
-- * @pushed.name@ for each member of the declared push block.
--
-- A cutout-capable material promises that its output alpha is binary wherever its
-- primary texture's is.
--
-- = Records in the storage region
--
-- A record is @2 × handles + words@ 32-bit words: each handle's lookup index then
-- its generation, then the words, with no padding, and record @k@ of a table
-- begins @k@ records after the table's base. The base, in words, is the engine's
-- @recordBase@ push member, which the recorder sets for each run; the shader
-- reads the table as @uint words[]@ of set 2's storage buffer.
--
-- = The push block
--
-- A material's push block starts at 'applicationPushOffset' and holds its
-- declared members in std430 layout (a scalar is aligned to four bytes, a
-- @vec2@ to eight, a @vec4@ to sixteen), each declared with its offset so the
-- host's packing and the shader's agree. The block's size is the end of the last
-- member rounded up to four bytes, and may be at most 'applicationPushLimit'.
-- The shader declares the rest of the 128 bytes as reserved words, in the vertex
-- and the fragment stage alike, which is what lets one pipeline layout serve
-- every material, and what the checked interface compares against the compiled
-- SPIR-V.
--
-- __Dependencies.__ @base@, @template-haskell@ for 'Lift', the native backend's
-- interface descriptions and render-2d's record layout, and this package's
-- layout and shader-source modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Vulkan.MaterialSources
  ( -- * The declaration
    MaterialDeclaration (..)
  , PushField (..)
  , PushType (..)
  , PushOffset (..)
  , pushTypeSize

    -- * Checking and laying it out
  , Laid (..)
  , layOut
  , declarationProblems
  , maxRecordHandles
  , maxRecordWords

    -- * What it compiles from
  , materialVertexSource
  , materialFragmentSource
  , materialVertexInterface
  , materialFragmentInterface
  ) where

import Data.Char (isAlphaNum, isAscii, isLetter)
import Data.List (isInfixOf, isPrefixOf, nub)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
import Hetoimasia.Render.TwoD.Material (RecordLayout (..))
import Hetoimasia.Render.TwoD.Vulkan.Layout
  ( applicationPushLimit
  , applicationPushOffset
  , instanceVertexInput
  , pushMembers
  , reservedPushMember
  )
import Hetoimasia.Render.TwoD.Vulkan.ShaderSources
  ( enginePushMembers
  , fragmentCommon
  , fragmentHead
  , pushBlockSource
  , reservedDeclaration
  , vertexSource
  )
import Language.Haskell.TH.Syntax (Lift)

-- | The type of a member of an application's push block.
data PushType = PushFloat | PushUint | PushInt | PushVec2 | PushVec4
  deriving (Eq, Ord, Show, Enum, Bounded, Lift)

-- | A member of an application's push block, by the name the shader reads it
-- under (@pushed.name@).
data PushField = PushField
  { pushFieldName ∷ String
  , pushFieldType ∷ PushType
  }
  deriving (Eq, Show, Lift)

-- | Where a member sits: its name and type, and its byte offset from the start
-- of the application's block, which is where a host packs it and where it is
-- pushed ('applicationPushOffset' further into the pipeline layout's range).
data PushOffset = PushOffset
  { pushOffsetName ∷ String
  , pushOffsetType ∷ PushType
  , pushOffsetBytes ∷ Word32
  }
  deriving (Eq, Show, Lift)

-- | What an application declares about a material.
data MaterialDeclaration = MaterialDeclaration
  { declaredCutoutCapable ∷ Bool
  -- ^ Whether its output alpha is binary wherever its primary texture's is, so
  -- that it routes to the cutout path and gets a cutout variant.
  , declaredRecord ∷ RecordLayout
  -- ^ The layout of its records.
  , declaredPush ∷ [PushField]
  -- ^ Its push block's members, in order.
  , declaredSource ∷ String
  -- ^ The GLSL that defines @material@ (and any function it uses).
  }

-- | The size and alignment of a push type in std430.
pushTypeSize ∷ PushType → (Word32, Word32)
pushTypeSize = \case
  PushFloat → (4, 4)
  PushUint → (4, 4)
  PushInt → (4, 4)
  PushVec2 → (8, 8)
  PushVec4 → (16, 16)

glslType ∷ PushType → String
glslType = \case
  PushFloat → "float"
  PushUint → "uint"
  PushInt → "int"
  PushVec2 → "vec2"
  PushVec4 → "vec4"

-- | The most handles a record may hold.
maxRecordHandles ∷ Word32
maxRecordHandles = 16

-- | The most words a record may hold.
maxRecordWords ∷ Word32
maxRecordWords = 64

-- | A declaration's push block laid out.
data Laid = Laid
  { laidOffsets ∷ [PushOffset]
  , laidBytes ∷ Word32
  -- ^ The block's size: the end of its last member, in a multiple of four bytes.
  }

-- | The members in std430 layout from the start of the application's block.
layOut ∷ [PushField] → Laid
layOut = go 0 []
  where
    go end placed [] = Laid (reverse placed) end
    go end placed (PushField name kind : rest) =
      let (size, alignment) = pushTypeSize kind
          offset = alignment * ((end + alignment - 1) `div` alignment)
       in go (offset + size) (PushOffset name kind offset : placed) rest

-- | Everything wrong with a declaration, each as a sentence that names it; empty
-- when it is acceptable. A material with a problem fails to compile.
declarationProblems ∷ MaterialDeclaration → [String]
declarationProblems declaration =
  [ "the push block would be " <> show (laidBytes laid) <> " bytes, beyond the limit of " <> show applicationPushLimit <> " bytes (the block's " <> show (applicationPushOffset + applicationPushLimit) <> " less the engine's first " <> show applicationPushOffset <> ")"
  | laidBytes laid > applicationPushLimit
  ]
    <> [ "the record holds " <> show handles <> " handles, beyond the limit of " <> show maxRecordHandles
       | handles > maxRecordHandles
       ]
    <> [ "the record holds " <> show wordCount <> " words, beyond the limit of " <> show maxRecordWords
       | wordCount > maxRecordWords
       ]
    <> [ "the push member name " <> show name <> " is not a GLSL identifier the shader may declare"
       | PushField name _ ← fields
       , not (identifier name)
       ]
    <> [ "the push member name " <> show name <> " is one the engine's own block declares"
       | PushField name _ ← fields
       , name `elem` engineNames
       ]
    <> [ "the push member name " <> show name <> " is declared more than once"
       | name ← nub [name | PushField name _ ← fields, length [() | PushField other _ ← fields, other == name] > 1]
       ]
    <> [ "the source declares no function named material"
       | not ("material" `isInfixOf` declaredSource declaration)
       ]
  where
    fields = declaredPush declaration
    laid = layOut fields
    RecordLayout handles wordCount = declaredRecord declaration
    identifier = \case
      first : rest →
        (isAscii first && (isLetter first || first == '_'))
          && all (\character → isAscii character && (isAlphaNum character || character == '_')) rest
          && not ("gl_" `isPrefixOf` (first : rest))
          && not ("__" `isInfixOf` (first : rest))
      [] → False
    -- Every member the engine's block declares, read from the declaration the
    -- shaders are written from, and the reserved words the block ends with, which
    -- a material may not name whether or not its own members leave room for them.
    engineNames = map snd enginePushMembers <> ["reserved"]

-- | The application's members of the push block as the shaders declare them,
-- each with its offset, then the reserved words that make the block span the
-- whole range.
appMembers ∷ Laid → String
appMembers laid =
  concat
    [ "    layout(offset = " <> show (applicationPushOffset + offset) <> ") " <> glslType kind <> " " <> name <> ";\n"
    | PushOffset name kind offset ← laidOffsets laid
    ]
    <> reservedDeclaration (laidBytes laid)

-- | The vertex stage of a material: the engine's, declaring the material's push
-- block (which it does not read) because a pipeline's two stages declare the same
-- block, and the storage region, from which it reads an animated instance's frame.
materialVertexSource ∷ Laid → String
materialVertexSource = vertexSource . appMembers

-- | The fragment stage of one variant of a material: the table's bindings, the
-- storage region, the push block, what both
-- variants share, the record and its loader, the application's function, the
-- instance's material at its fragment, and the variant's tail.
materialFragmentSource ∷ MaterialDeclaration → Laid → String → String
materialFragmentSource declaration laid tailSource =
  fragmentHead
    <> pushBlockSource (appMembers laid)
    <> fragmentCommon
    <> recordSupport (declaredRecord declaration)
    <> "\n"
    <> declaredSource declaration
    <> "\n"
    <> sampleApplicationMaterial
    <> tailSource

-- | The record struct and the function that loads a record of the layout.
recordSupport ∷ RecordLayout → String
recordSupport (RecordLayout handles wordCount) =
  unlines
    ( [ ""
      , "// A record of the material's layout: its handles, then its words. An array"
      , "// the layout leaves empty has one element, never read, which is zero."
      , "struct MaterialRecord {"
      , "    uvec2 handles[" <> show (max 1 handleCount) <> "];"
      , "    uint words[" <> show (max 1 wordTotal) <> "];"
      , "};"
      , ""
      , "MaterialRecord loadRecord(uint index) {"
      , "    MaterialRecord record;"
      ]
        <> ["    record.handles[" <> show k <> "] = uvec2(0u, 0u);" | k ← [0 .. max 1 handleCount - 1]]
        <> ["    record.words[" <> show k <> "] = 0u;" | k ← [0 .. max 1 wordTotal - 1]]
        <> loads
        <> ["    return record;", "}"]
    )
  where
    -- Signed counts, so that a layout with no handle or no word counts down from
    -- nothing rather than wrapping a Word32 to billions of assignments.
    handleCount = fromIntegral handles ∷ Int
    wordTotal = fromIntegral wordCount ∷ Int
    stride = 2 * handleCount + wordTotal
    loads
      | stride == 0 = []
      | otherwise =
          ["    uint base = pushed.recordBase + index * " <> show stride <> "u;"]
            <> [ "    record.handles[" <> show k <> "] = uvec2(region.words[base + " <> show (2 * k) <> "u], region.words[base + " <> show (2 * k + 1) <> "u]);"
               | k ← [0 .. handleCount - 1]
               ]
            <> ["    record.words[" <> show k <> "] = region.words[base + " <> show (2 * handleCount + k) <> "u];" | k ← [0 .. wordTotal - 1]]

-- | The instance's material at its fragment: its function applied to the sampled
-- texel, the coordinates, the parameter word and the record the word indexes.
sampleApplicationMaterial ∷ String
sampleApplicationMaterial =
  unlines
    [ "// The instance's material at this fragment."
    , "vec4 sampleMaterial() {"
    , "    vec4 texel = sampleTexture(handle, at);"
    , "    return material(texel, at, attributes.y, loadRecord(attributes.y));"
    , "}"
    , ""
    ]

-- | The push-constant members a material's two stages declare, as the
-- interface descriptions state them: the engine's, the application's, and the
-- rest reserved.
declaredPushMembers ∷ Laid → [PushMember]
declaredPushMembers laid =
  pushMembers
    <> [PushMember (applicationPushOffset + offset) (fst (pushTypeSize kind)) | PushOffset _ kind offset ← laidOffsets laid]
    <> [reservedPushMember (laidBytes laid) | laidBytes laid < applicationPushLimit]

-- | The vertex stage's description: the instance attributes, the push block and
-- the storage region, which it reads the view's frame tables from (R2D-18).
materialVertexInterface ∷ Laid → ShaderInterface
materialVertexInterface laid =
  (interfaceFor VertexInterface)
    { interfacePushConstants = declaredPushMembers laid
    , interfaceVertexInput = instanceVertexInput
    , interfaceDescriptors = storageTableDescriptors
    }

-- | The fragment stage's description: the push block, the texture table and the
-- storage region.
materialFragmentInterface ∷ Laid → ShaderInterface
materialFragmentInterface laid =
  (interfaceFor FragmentInterface)
    { interfacePushConstants = declaredPushMembers laid
    , interfaceDescriptors = textureTableDescriptors <> storageTableDescriptors
    }
