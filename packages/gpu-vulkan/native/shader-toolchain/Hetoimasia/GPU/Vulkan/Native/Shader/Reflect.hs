-- | A pure reader of a compiled shader's external interface (GRS-16, D-19):
-- what its SPIR-V says it reads from the host, recovered from the module's
-- words with no native tool.
--
-- The reader follows the module's one entry point and the global variables
-- its interface lists — which, from SPIR-V 1.4 on, is every global it uses —
-- through their storage classes, types and decorations:
--
-- * the push-constant block: a variable of the @PushConstant@ storage class,
--   a @Block@ struct whose members' offsets come from their @Offset@
--   decorations and whose sizes are computed from their types — scalars,
--   vectors, matrices under their @MatrixStride@ and @RowMajor@ or @ColMajor@
--   decorations, and arrays of those under their @ArrayStride@;
-- * a vertex shader's inputs: each @Input@ variable that is not a built-in,
--   with its @Location@ and its scalar or vector type;
-- * descriptor bindings: each @UniformConstant@, @Uniform@ or
--   @StorageBuffer@ variable with a @DescriptorSet@ and a @Binding@, its kind,
--   and its count — one, a fixed array's length, or a runtime-sized array.
--
-- A fragment shader's inputs and outputs and a vertex shader's outputs are
-- varyings, which the pipeline's own validation checks, and built-ins are the
-- device's: neither is part of what the host declares, and the reader reports
-- neither. A module it cannot read, or an interface construct it does not
-- support — a nested push-constant struct, a matrix or array vertex input, a
-- texel buffer, an input attachment — is an error naming it, never an empty or
-- a matching interface; so is an interface naming an id the module defines no
-- variable for, and a push-constant member whose extent is beyond what 32
-- bits can hold, computed without bound and never wrapped.
--
-- The module's words are read in the byte order the compiler wrote them,
-- which the magic number says.
module Hetoimasia.GPU.Vulkan.Native.Shader.Reflect
  ( Reflection (..)
  , ReflectedStage (..)
  , ScalarKind (..)
  , ReflectedType (..)
  , ReflectedKind (..)
  , ReflectedCount (..)
  , ReflectedDescriptor (..)
  , reflect
  , renderReflectedType
  ) where

import Control.Monad (forM, unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Word (Word32)

-- | What a shader's SPIR-V says it reads from the host.
data Reflection = Reflection
  { reflectionStage ∷ !ReflectedStage
  , reflectionPushMembers ∷ !(Maybe [(Word32, Word32)])
    -- ^ The push-constant block's members, in declaration order, as offset
    -- and size in bytes; 'Nothing' when the shader declares no block.
  , reflectionInputs ∷ ![(Word32, ReflectedType)]
    -- ^ A vertex shader's inputs, by location, in ascending order. Empty for
    -- any other stage.
  , reflectionDescriptors ∷ ![ReflectedDescriptor]
    -- ^ In ascending order of set and binding.
  }
  deriving (Eq, Show)

-- | The entry point's execution model.
data ReflectedStage = ReflectedVertex | ReflectedFragment | ReflectedOther !Word32
  deriving (Eq, Show)

data ScalarKind
  = FloatScalar !Word32
  | SignedScalar !Word32
  | UnsignedScalar !Word32
    -- ^ Each with its width in bits.
  deriving (Eq, Show)

-- | The type of a vertex input.
data ReflectedType
  = ScalarType !ScalarKind
  | VectorType !ScalarKind !Word32
  deriving (Eq, Show)

-- | What kind of descriptor a binding is.
data ReflectedKind
  = ReflectedCombinedImageSampler
  | ReflectedSampledImage
  | ReflectedStorageImage
  | ReflectedSampler
  | ReflectedUniformBuffer
  | ReflectedStorageBuffer
  deriving (Eq, Show)

-- | How many descriptors a binding is.
data ReflectedCount = ReflectedFixed !Word32 | ReflectedRuntime
  deriving (Eq, Show)

data ReflectedDescriptor = ReflectedDescriptor
  { reflectedSet ∷ !Word32
  , reflectedBinding ∷ !Word32
  , reflectedKind ∷ !ReflectedKind
  , reflectedCount ∷ !ReflectedCount
  }
  deriving (Eq, Show)

-- | A type as a failure names it.
renderReflectedType ∷ ReflectedType → String
renderReflectedType = \case
  ScalarType kind → scalar kind
  VectorType kind count → scalar kind <> " vector of " <> show count
  where
    scalar = \case
      FloatScalar width → show width <> "-bit float"
      SignedScalar width → show width <> "-bit signed integer"
      UnsignedScalar width → show width <> "-bit unsigned integer"

-- ---------------------------------------------------------------------------
-- The module

-- | One instruction: its opcode and its operand words.
data Instruction = Instruction !Word32 ![Word32]

-- | What the reader keeps of the module's declarations.
data Module = Module
  { moduleTypes ∷ !(Map.Map Word32 Instruction)
    -- ^ Every type and constant, by result id.
  , moduleVariables ∷ !(Map.Map Word32 (Word32, Word32))
    -- ^ Every global variable, by id: its pointer type and storage class.
  , moduleDecorations ∷ !(Map.Map Word32 [(Word32, [Word32])])
  , moduleMemberDecorations ∷ !(Map.Map (Word32, Word32) [(Word32, [Word32])])
  , moduleEntries ∷ ![(Word32, [Word32])]
    -- ^ Each entry point's execution model and interface ids.
  }

-- | Read a module's interface, or say why it cannot be read.
reflect ∷ ByteString → Either String Reflection
reflect bytes = do
  words' ← moduleWords bytes
  instructions ← decode words'
  let parsed = foldl collect (Module Map.empty Map.empty Map.empty Map.empty []) instructions
  (model, interface) ← case moduleEntries parsed of
    [entry] → Right entry
    [] → Left "the module has no entry point"
    entries → Left ("the module has " <> show (length entries) <> " entry points, not one")
  let stage = case model of
        0 → ReflectedVertex
        4 → ReflectedFragment
        other → ReflectedOther other
  globals ← forM interface $ \variable → case Map.lookup variable (moduleVariables parsed) of
    Just held → Right (variable, held)
    Nothing → Left ("the entry point's interface names id " <> show variable <> ", which the module defines no variable for")
  push ← pushBlock parsed [(variable, pointer) | (variable, (pointer, storage)) ← globals, storage == storagePushConstant]
  inputs ←
    if stage == ReflectedVertex
      then fmap (sortOn fst . concat) . forM [(variable, pointer) | (variable, (pointer, storage)) ← globals, storage == storageInput] $ \(variable, pointer) →
        vertexInput parsed variable pointer
      else Right []
  descriptors ←
    fmap (sortOn (\found → (reflectedSet found, reflectedBinding found)) . concat) . forM [(variable, held) | (variable, held@(_, storage)) ← globals, storage `elem` [storageUniformConstant, storageUniform, storageStorageBuffer]] $ \(variable, (pointer, storage)) →
      descriptor parsed variable pointer storage
  pure (Reflection stage push inputs descriptors)

moduleWords ∷ ByteString → Either String [Word32]
moduleWords bytes
  | ByteString.length bytes `mod` 4 /= 0 = Left "the module is not a whole number of words"
  | ByteString.length bytes < 20 = Left "the module is shorter than its header"
  | otherwise =
      let little = map wordLittle (chunks bytes)
       in case little of
            magic : _
              | magic == spirvMagic → Right little
              | byteSwap magic == spirvMagic → Right (map byteSwap little)
            _ → Left "the module does not begin with SPIR-V's magic number"
  where
    chunks rest
      | ByteString.null rest = []
      | otherwise = let (word, after) = ByteString.splitAt 4 rest in word : chunks after
    wordLittle word = foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack word)
    byteSwap word =
      ((word .&. 0xFF) `shiftL` 24) .|. ((word .&. 0xFF00) `shiftL` 8) .|. ((word `shiftR` 8) .&. 0xFF00) .|. (word `shiftR` 24)

decode ∷ [Word32] → Either String [Instruction]
decode words' = go (drop 5 words')
  where
    go [] = Right []
    go (first : rest) =
      let count = fromIntegral (first `shiftR` 16)
          opcode = first .&. 0xFFFF
       in if count == 0
            then Left "the module has an instruction of no words"
            else
              if length (take (count - 1) rest) < count - 1
                then Left "the module ends inside an instruction"
                else (Instruction opcode (take (count - 1) rest) :) <$> go (drop (count - 1) rest)

collect ∷ Module → Instruction → Module
collect parsed instruction@(Instruction opcode operands) = case (opcode, operands) of
  (15, model : _ : rest) → parsed {moduleEntries = moduleEntries parsed <> [(model, drop (stringWords rest) rest)]}
  (71, target : decorated : values) → parsed {moduleDecorations = Map.insertWith (flip (<>)) target [(decorated, values)] (moduleDecorations parsed)}
  (72, target : member : decorated : values) →
    parsed {moduleMemberDecorations = Map.insertWith (flip (<>)) (target, member) [(decorated, values)] (moduleMemberDecorations parsed)}
  (59, pointer : result : storage : _) → parsed {moduleVariables = Map.insert result (pointer, storage) (moduleVariables parsed)}
  _
    | opcode `elem` typeOpcodes, result : _ ← operands → parsed {moduleTypes = Map.insert result instruction (moduleTypes parsed)}
    | opcode `elem` constantOpcodes, _ : result : _ ← operands → parsed {moduleTypes = Map.insert result instruction (moduleTypes parsed)}
    | otherwise → parsed
  where
    -- A literal string occupies the words up to and including the one whose
    -- last byte is a terminating zero.
    stringWords rest = 1 + length (takeWhile (not . terminated) rest)
    terminated word = any (\shift → (word `shiftR` shift) .&. 0xFF == 0) [0, 8, 16, 24]

-- ---------------------------------------------------------------------------
-- Push constants

pushBlock ∷ Module → [(Word32, Word32)] → Either String (Maybe [(Word32, Word32)])
pushBlock parsed = \case
  [] → Right Nothing
  [(_, pointer)] → do
    struct ← pointee parsed pointer
    case typeOf parsed struct of
      Just (Instruction 30 (_ : members)) → do
        unless (hasDecoration parsed struct decorationBlock) (Left "the push-constant variable's struct is not a Block")
        Just <$> forM (zip [0 ..] members) (\(index, member) → do
          offset ← maybe (Left ("push-constant member " <> show index <> " has no Offset")) Right (memberDecoration parsed struct index decorationOffset)
          size ← memberSize parsed struct index member
          -- Computed without bound, and refused rather than narrowed when its
          -- end is beyond what 32 bits, and so any push-constant range, hold.
          when (toInteger offset + size > toInteger (maxBound ∷ Word32)) $
            Left ("push-constant member " <> show index <> " reaches byte " <> show (toInteger offset + size) <> ", beyond what 32 bits can hold")
          pure (offset, fromInteger size))
      _ → Left "the push-constant variable is not a struct"
  variables → Left ("the shader has " <> show (length variables) <> " push-constant variables, not one")

-- | The bytes a push-constant member occupies, from its offset: a scalar's
-- or vector's own size; a matrix's columns, or rows, apart by its stride and
-- the last one's own size; an array's elements apart by its stride and the
-- last one's own size.
memberSize ∷ Module → Word32 → Int → Word32 → Either String Integer
memberSize parsed struct index member = sized member
  where
    named what = Left ("push-constant member " <> show index <> " is " <> what <> ", which the reader does not support")
    rowMajor = isJust (memberDecoration' decorationRowMajor)
    memberDecoration' wanted = lookup wanted (Map.findWithDefault [] (struct, fromIntegral index) (moduleMemberDecorations parsed))
    sized typeId = case typeOf parsed typeId of
      Just (Instruction 21 [_, width, _]) → Right (toInteger width `div` 8)
      Just (Instruction 22 (_ : width : _)) → Right (toInteger width `div` 8)
      Just (Instruction 23 [_, component, count]) → (* toInteger count) <$> sized component
      Just (Instruction 24 [_, column, columns]) → do
        stride ← case memberDecoration' decorationMatrixStride of
          Just (value : _) → Right value
          _ → Left ("push-constant member " <> show index <> " is a matrix with no MatrixStride")
        case typeOf parsed column of
          Just (Instruction 23 [_, component, rows]) → do
            scalar ← sized component
            pure $
              if rowMajor
                then (toInteger rows - 1) * toInteger stride + toInteger columns * scalar
                else (toInteger columns - 1) * toInteger stride + toInteger rows * scalar
          _ → named "a matrix of an unsupported column type"
      Just (Instruction 28 [_, element, length']) → do
        count ← constantValue parsed length'
        stride ← maybe (Left ("push-constant member " <> show index <> " is an array with no ArrayStride")) Right (decoration parsed typeId decorationArrayStride)
        each ← sized element
        pure (if count == 0 then 0 else (toInteger count - 1) * toInteger stride + each)
      Just (Instruction 30 _) → named "a nested struct"
      Just (Instruction 29 _) → named "a runtime-sized array"
      Just (Instruction opcode _) → named ("a type of opcode " <> show opcode)
      Nothing → Left ("push-constant member " <> show index <> " names a type the module does not declare")

-- ---------------------------------------------------------------------------
-- Vertex inputs

vertexInput ∷ Module → Word32 → Word32 → Either String [(Word32, ReflectedType)]
vertexInput parsed variable pointer
  | hasDecoration parsed variable decorationBuiltIn = Right []
  | otherwise = do
      typeId ← pointee parsed pointer
      case typeOf parsed typeId of
        Just (Instruction 30 (_ : members)) | any (\member → isJust (memberDecoration parsed typeId member decorationBuiltIn)) [0 .. length members - 1] → Right []
        _ → do
          location ← maybe (Left ("a vertex input " <> name <> " has no Location")) Right (decoration parsed variable decorationLocation)
          kind ← inputType typeId
          pure [(location, kind)]
  where
    name = "(id " <> show variable <> ")"
    inputType typeId = case typeOf parsed typeId of
      Just (Instruction 23 [_, component, count]) → (`VectorType` count) <$> scalarKind component
      Just (Instruction _ _) | Right kind ← scalarKind typeId → Right (ScalarType kind)
      _ → Left ("the vertex input " <> name <> " is neither a scalar nor a vector, which the reader does not support")
    scalarKind typeId = case typeOf parsed typeId of
      Just (Instruction 21 [_, width, signedness]) → Right (if signedness == 1 then SignedScalar width else UnsignedScalar width)
      Just (Instruction 22 (_ : width : _)) → Right (FloatScalar width)
      _ → Left "not a scalar"

-- ---------------------------------------------------------------------------
-- Descriptors

descriptor ∷ Module → Word32 → Word32 → Word32 → Either String [ReflectedDescriptor]
descriptor parsed variable pointer storage =
  case (decoration parsed variable decorationDescriptorSet, decoration parsed variable decorationBinding) of
    (Nothing, Nothing) → Right []
    (Just set, Just binding) → do
      typeId ← pointee parsed pointer
      (element, count) ← case typeOf parsed typeId of
        Just (Instruction 28 [_, element, length']) → (\value → (element, ReflectedFixed value)) <$> constantValue parsed length'
        Just (Instruction 29 [_, element]) → Right (element, ReflectedRuntime)
        _ → Right (typeId, ReflectedFixed 1)
      kind ← kindOf element
      pure [ReflectedDescriptor set binding kind count]
    _ → Left ("the descriptor variable (id " <> show variable <> ") has a DescriptorSet or a Binding but not both")
  where
    kindOf element
      | storage == storageStorageBuffer = Right ReflectedStorageBuffer
      | storage == storageUniform =
          if hasDecoration parsed element decorationBufferBlock
            then Right ReflectedStorageBuffer
            else
              if hasDecoration parsed element decorationBlock
                then Right ReflectedUniformBuffer
                else Left ("the uniform variable (id " <> show variable <> ") is not a Block")
      | otherwise = case typeOf parsed element of
          Just (Instruction 27 _) → Right ReflectedCombinedImageSampler
          Just (Instruction 26 _) → Right ReflectedSampler
          Just (Instruction 25 (_ : _ : dimension : _ : _ : _ : sampled : _))
            | dimension == dimensionBuffer → Left ("the descriptor variable (id " <> show variable <> ") is a texel buffer, which the reader does not support")
            | dimension == dimensionSubpassData → Left ("the descriptor variable (id " <> show variable <> ") is an input attachment, which the reader does not support")
            | dimension > dimensionRect → Left ("the descriptor variable (id " <> show variable <> ") is an image of dimension " <> show dimension <> ", which the reader does not support")
            | sampled == 1 → Right ReflectedSampledImage
            | sampled == 2 → Right ReflectedStorageImage
          Just (Instruction opcode _) → Left ("the descriptor variable (id " <> show variable <> ") is of a type of opcode " <> show opcode <> ", which the reader does not support")
          Nothing → Left ("the descriptor variable (id " <> show variable <> ") names a type the module does not declare")

-- ---------------------------------------------------------------------------
-- Shared lookups

typeOf ∷ Module → Word32 → Maybe Instruction
typeOf parsed typeId = Map.lookup typeId (moduleTypes parsed)

pointee ∷ Module → Word32 → Either String Word32
pointee parsed pointer = case typeOf parsed pointer of
  Just (Instruction 32 [_, _, typeId]) → Right typeId
  _ → Left ("a variable's type (id " <> show pointer <> ") is not a pointer")

constantValue ∷ Module → Word32 → Either String Word32
constantValue parsed constant = case typeOf parsed constant of
  Just (Instruction 43 [_, _, value]) → Right value
  _ → Left ("an array's length (id " <> show constant <> ") is not a 32-bit constant")

decoration ∷ Module → Word32 → Word32 → Maybe Word32
decoration parsed target wanted = case lookup wanted (Map.findWithDefault [] target (moduleDecorations parsed)) of
  Just (value : _) → Just value
  _ → Nothing

hasDecoration ∷ Module → Word32 → Word32 → Bool
hasDecoration parsed target wanted = isJust (lookup wanted (Map.findWithDefault [] target (moduleDecorations parsed)))

memberDecoration ∷ Module → Word32 → Int → Word32 → Maybe Word32
memberDecoration parsed struct member wanted = case lookup wanted (Map.findWithDefault [] (struct, fromIntegral member) (moduleMemberDecorations parsed)) of
  Just (value : _) → Just value
  Just [] → Just 0
  Nothing → Nothing

-- ---------------------------------------------------------------------------
-- Numbers

spirvMagic ∷ Word32
spirvMagic = 0x07230203

typeOpcodes, constantOpcodes ∷ [Word32]
typeOpcodes = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32]
constantOpcodes = [43]

storageUniformConstant, storageInput, storageUniform, storagePushConstant, storageStorageBuffer ∷ Word32
storageUniformConstant = 0
storageInput = 1
storageUniform = 2
storagePushConstant = 9
storageStorageBuffer = 12

decorationBlock, decorationBufferBlock, decorationRowMajor, decorationArrayStride, decorationMatrixStride, decorationBuiltIn, decorationLocation, decorationBinding, decorationDescriptorSet, decorationOffset ∷ Word32
decorationBlock = 2
decorationBufferBlock = 3
decorationRowMajor = 4
decorationArrayStride = 6
decorationMatrixStride = 7
decorationBuiltIn = 11
decorationLocation = 30
decorationBinding = 33
decorationDescriptorSet = 34
decorationOffset = 35

dimensionRect, dimensionBuffer, dimensionSubpassData ∷ Word32
dimensionRect = 4
dimensionBuffer = 5
dimensionSubpassData = 6
