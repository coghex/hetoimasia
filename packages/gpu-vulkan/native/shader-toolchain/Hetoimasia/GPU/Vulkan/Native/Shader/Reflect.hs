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
-- neither.
--
-- Before anything is read, every type and constant an interface variable
-- reaches is checked against one explicit whitelist, the subset the reader
-- supports ('validateInterface'): its opcode is one its position allows — a
-- type where a type is required, of the kinds that position may hold, and an
-- 'OpConstant' where an array length is required — its operand count is exact,
-- its literals are in range, every id it names resolves to an instruction of
-- the required kind declared before it, so a cycle or a forward reference
-- cannot pass, and no id is declared twice. A module it cannot read, an
-- interface construct it does not support — a nested push-constant struct, a
-- matrix or array vertex input, a texel buffer, an input attachment, a vertex
-- input that starts past its location's first component — or one that fails
-- that whitelist is an error naming it, never an empty or a matching
-- interface; so is an interface naming an id the module defines no variable
-- for, a descriptor variable lacking its DescriptorSet or Binding, and a
-- push-constant member whose extent is beyond what 32 bits can hold, computed
-- without bound and never wrapped.
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

import Control.Monad (foldM, foldM_, forM, unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Set as Set
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
  , moduleVariableOperands ∷ !(Map.Map Word32 [Word32])
    -- ^ Every global variable's complete operands, by id, so its whole
    -- declaration is validated before any of it is read.
  , moduleDecorations ∷ !(Map.Map Word32 [(Word32, [Word32])])
  , moduleMemberDecorations ∷ !(Map.Map (Word32, Word32) [(Word32, [Word32])])
  , moduleEntries ∷ ![[Word32]]
    -- ^ Each entry point's complete operands.
  , modulePositions ∷ !(Map.Map Word32 Int)
    -- ^ Where in the module each type, constant and global variable is
    -- declared, by result id.
  , moduleDuplicates ∷ ![Word32]
    -- ^ Every such result id declared more than once.
  }

-- | Read a module's interface, or say why it cannot be read.
reflect ∷ ByteString → Either String Reflection
reflect bytes = do
  words' ← moduleWords bytes
  instructions ← decode words'
  let parsed = foldl collect (Module Map.empty Map.empty Map.empty Map.empty Map.empty [] Map.empty []) (zip [0 ..] instructions)
      bound = case drop 3 words' of
        value : _ → value
        [] → 0
  -- Every id the reader records is below the header's bound.
  case [declared | declared ← Map.keys (modulePositions parsed), declared >= bound] of
    beyond : _ → Left ("the module declares id " <> show beyond <> ", beyond its header's bound of " <> show bound)
    [] → pure ()
  (model, interface) ← case moduleEntries parsed of
    [entry] → entryPoint entry
    [] → Left "the module has no entry point"
    entries → Left ("the module has " <> show (length entries) <> " entry points, not one")
  let stage = case model of
        0 → ReflectedVertex
        4 → ReflectedFragment
        other → ReflectedOther other
  globals ← forM interface $ \variable → case Map.lookup variable (moduleVariables parsed) of
    Just held → Right (variable, held)
    Nothing → Left ("the entry point's interface names id " <> show variable <> ", which the module defines no variable for")
  -- Every decoration the reader reads, every interface variable's
  -- declaration, and every type and constant one reaches, is on the
  -- whitelist before anything is read from it; so are the explicit layout
  -- decorations a buffer or push-constant block requires.
  validateDecorations parsed
  validateInterface parsed globals
  validateLayout parsed globals
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

collect ∷ Module → (Int, Instruction) → Module
collect parsed (position, instruction@(Instruction opcode operands)) = case (opcode, operands) of
  (15, _) → parsed {moduleEntries = moduleEntries parsed <> [operands]}
  (71, target : decorated : values) → parsed {moduleDecorations = Map.insertWith (flip (<>)) target [(decorated, values)] (moduleDecorations parsed)}
  (72, target : member : decorated : values) →
    parsed {moduleMemberDecorations = Map.insertWith (flip (<>)) (target, member) [(decorated, values)] (moduleMemberDecorations parsed)}
  (59, pointer : result : storage : _) →
    declared result (parsed {moduleVariables = Map.insert result (pointer, storage) (moduleVariables parsed), moduleVariableOperands = Map.insert result operands (moduleVariableOperands parsed)})
  _
    | opcode `elem` typeOpcodes, result : _ ← operands → declared result (parsed {moduleTypes = Map.insert result instruction (moduleTypes parsed)})
    | opcode `elem` constantOpcodes, _ : result : _ ← operands → declared result (parsed {moduleTypes = Map.insert result instruction (moduleTypes parsed)})
    | otherwise → parsed
  where
    declared result held
      | Map.member result (modulePositions held) = held {moduleDuplicates = moduleDuplicates held <> [result]}
      | otherwise = held {modulePositions = Map.insert result position (modulePositions held)}

-- | The one entry point's execution model and interface ids, from its
-- complete operands: a model, a function, a name that ends within the
-- instruction — its last word holding a terminating zero and only zeros
-- after it — and then interface ids, none listed twice.
entryPoint ∷ [Word32] → Either String (Word32, [Word32])
entryPoint = \case
  model : _ : rest@(_ : _) → case break terminated rest of
    (_, final : interface)
      | not (padded final) → Left "the entry point's name is not padded with zeros after its terminator"
      | otherwise → case [repeated | (index, repeated) ← zip [0 ∷ Int ..] interface, repeated `elem` take index interface] of
          repeated : _ → Left ("the entry point's interface lists id " <> show repeated <> " more than once")
          [] → Right (model, interface)
    (_, []) → Left "the entry point's name is not terminated within its instruction"
  operands → Left ("the entry point has " <> show (length operands) <> " operands, where the reader requires a model, a function and a name")
  where
    bytesOf word = [(word `shiftR` shift) .&. 0xFF | shift ← [0, 8, 16, 24]]
    terminated word = 0 `elem` bytesOf word
    padded word = all (== 0) (dropWhile (/= 0) (bytesOf word))

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
          case decoration parsed variable decorationComponent of
            Just component
              | component /= 0 →
                  Left ("the vertex input at location " <> show location <> " starts at component " <> show component <> ", which the reader does not support")
            _ → pure ()
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
    (Nothing, Nothing) → Left ("the descriptor variable (id " <> show variable <> ") has neither a DescriptorSet nor a Binding")
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
    named = "the descriptor variable (id " <> show variable <> ")"
    -- A buffer's element must be a defined struct decorated as its storage
    -- class requires: a Block for a storage buffer and a uniform buffer, or a
    -- BufferBlock for a storage buffer in the Uniform class.
    kindOf element
      | storage == storageStorageBuffer = do
          bufferStruct element
          if hasDecoration parsed element decorationBlock
            then Right ReflectedStorageBuffer
            else Left (named <> " is a storage buffer whose struct is not a Block")
      | storage == storageUniform = do
          bufferStruct element
          if hasDecoration parsed element decorationBufferBlock
            then Right ReflectedStorageBuffer
            else
              if hasDecoration parsed element decorationBlock
                then Right ReflectedUniformBuffer
                else Left (named <> " is a uniform buffer whose struct is not a Block")
      | otherwise = case typeOf parsed element of
          Just (Instruction 27 [_, image]) → case imageKind image of
            Right ReflectedSampledImage → Right ReflectedCombinedImageSampler
            Right _ → Left (named <> " is a combined image sampler over an image that is not sampled")
            Left reason → Left (named <> " is a combined image sampler over " <> reason)
          Just (Instruction 26 _) → Right ReflectedSampler
          Just (Instruction 25 _) → either (Left . ((named <> " is ") <>)) Right (imageKind element)
          Just (Instruction opcode _) → Left (named <> " is of a type of opcode " <> show opcode <> ", which the reader does not support")
          Nothing → Left (named <> " names a type the module does not declare")
    bufferStruct element = case typeOf parsed element of
      Just (Instruction 30 _) → Right ()
      Just _ → Left (named <> " is a buffer whose element is not a struct")
      Nothing → Left (named <> " is a buffer whose struct the module does not declare")
    -- A defined image of a supported dimension, sampled or storage.
    imageKind image = case typeOf parsed image of
      Just (Instruction 25 (_ : _ : dimension : _ : _ : _ : sampled : _))
        | dimension == dimensionBuffer → Left "a texel buffer, which the reader does not support"
        | dimension == dimensionSubpassData → Left "an input attachment, which the reader does not support"
        | dimension > dimensionRect → Left ("an image of dimension " <> show dimension <> ", which the reader does not support")
        | sampled == 1 → Right ReflectedSampledImage
        | sampled == 2 → Right ReflectedStorageImage
        | otherwise → Left "an image whose use is unknown until run time, which the reader does not support"
      Just _ → Left "a type that is not an image"
      Nothing → Left "an image type the module does not declare"

-- ---------------------------------------------------------------------------
-- The whitelist

-- | Whether every type and constant the interface variables reach is one the
-- reader supports, structurally:
--
-- * each variable's storage class is one the reader knows, and its type is an
--   'OpTypePointer' of that same storage class declared before it;
-- * each id an instruction names resolves to a type or constant declared
--   before that instruction — so a forward reference, a self-reference and a
--   cycle are all refused — and no such id is declared twice;
-- * each id names an instruction of the kind its position requires: a
--   pointer's pointee, an array's or runtime array's element, a struct's
--   members (a runtime array only as the last), a vector's scalar component,
--   a matrix's float-vector column, an image's sampled type (a 32-bit float or
--   a 32- or 64-bit integer), a sampled image's image, and an array's length,
--   an 'OpConstant' of a 32-bit integer type with a positive value;
-- * each instruction has exactly the operands its opcode takes, with literals
--   in range: an integer of 8, 16, 32 or 64 bits and a signedness of 0 or 1, a
--   float of 16, 32 or 64 bits, a vector of 2, 3 or 4 components, a matrix of
--   2, 3 or 4 columns, an image's dimension, depth, arrayed, multisampled,
--   sampled, format and access operands within their enumerations, and a
--   pointer's storage class one the reader knows;
-- * nothing an Input, Output, Uniform, PushConstant or StorageBuffer variable
--   reaches is a boolean or an opaque image, sampler or sampled image, which
--   those storage classes cannot hold.
--
-- The first instruction that is not is an error naming it, the rule it
-- breaks, and the variable that reaches it.
validateInterface ∷ Module → [(Word32, (Word32, Word32))] → Either String ()
validateInterface parsed globals = do
  case moduleDuplicates parsed of
    duplicate : _ → Left ("the module defines id " <> show duplicate <> " more than once")
    [] → pure ()
  foldM_ variableOk Set.empty globals
  where
    variableOk seen (variable, (pointer, storage)) = do
      let named = "the interface variable (id " <> show variable <> ")"
      held ← case lookup storage storageClasses of
        Just name → Right name
        Nothing → Left (named <> " has storage class " <> show storage <> ", which the reader does not support")
      let position = Map.findWithDefault 0 variable (modulePositions parsed)
          -- A built-in is the device's, not the host's: what it holds is
          -- the built-in's own, a boolean included.
          context
            | storage `elem` hostVisible && not (hasDecoration parsed variable decorationBuiltIn) = Just held
            | otherwise = Nothing
      Instruction opcode operands ← refer named variable position "its pointer type" pointer
      unless (opcode == 32) $ Left (wrongKind named pointer "its pointer type" opcode "an OpTypePointer")
      seen' ← wellFormed named context seen pointer
      pointee' ← case operands of
        [_, declared, pointee']
          | declared /= storage →
              Left (named <> " has storage class " <> show storage <> ", but its pointer type (id " <> show pointer <> ") has storage class " <> show declared)
          | otherwise → Right pointee'
        _ → Left (named <> " has a pointer type (id " <> show pointer <> ") the reader cannot read")
      -- The declaration itself: its result type, its result, its storage
      -- class, and an initializer only where its storage class takes one.
      case Map.findWithDefault [] variable (moduleVariableOperands parsed) of
        [_, _, _] → pure seen'
        [_, _, _, initializer]
          | storage `notElem` initialized →
              Left (named <> " has an initializer, which the " <> held <> " storage class does not take")
          | otherwise → constantOf named variable position "its initializer" initializer pointee' seen'
        found → Left (named <> " is an OpVariable with " <> show (length found) <> " operands, where the reader requires 3 or 4")

    -- Resolve an id named by the instruction declared at this position.
    refer named user position role target = case (Map.lookup target (moduleTypes parsed), Map.lookup target (modulePositions parsed)) of
      (Just instruction, Just declared)
        | declared < position → Right instruction
        | otherwise → Left (named <> " reaches id " <> show target <> " as " <> role <> ", which is not declared before the instruction (id " <> show user <> ") that refers to it")
      _ → Left (named <> " reaches id " <> show target <> " as " <> role <> ", which the module does not declare as a type or constant")

    wrongKind named target role opcode requirement =
      named <> " reaches id " <> show target <> " as " <> role <> ", an " <> opcodeName opcode <> ", where the reader requires " <> requirement

    -- Check one type's own operands, then each type it names; a type already
    -- checked in the same storage-class context is not checked again.
    wellFormed named context seen typeId
      | Set.member (context, typeId) seen = Right seen
      | otherwise = do
          let marked = Set.insert (context, typeId) seen
              position = Map.findWithDefault 0 typeId (modulePositions parsed)
          Instruction opcode operands ← maybe (Left (named <> " reaches id " <> show typeId <> ", which the module does not declare as a type or constant")) Right (Map.lookup typeId (moduleTypes parsed))
          let count ∷ String → Either String a
              count expected = Left (named <> " reaches type id " <> show typeId <> ", an " <> opcodeName opcode <> " with " <> show (length operands) <> " operands, where the reader requires " <> expected)
              literal ∷ String → String → Either String a
              literal what allowed = Left (named <> " reaches type id " <> show typeId <> ", an " <> opcodeName opcode <> " " <> what <> ", where the reader requires " <> allowed)
              -- Resolve a named type, require its kind, refuse what this
              -- storage class cannot hold, then check it in turn.
              child = childIn context
              childIn within role requirement allowed target through = do
                Instruction childOpcode childOperands ← refer named typeId position role target
                unless (childOpcode `elem` allowed) $ Left (wrongKind named target role childOpcode requirement)
                case within of
                  Just name
                    | childOpcode `elem` [20, 25, 26, 27] →
                        Left (named <> " reaches id " <> show target <> " as " <> role <> ", an " <> opcodeName childOpcode <> ", which the " <> name <> " storage class cannot hold")
                  _ → pure ()
                checked ← wellFormed named within through target
                pure (checked, childOpcode, childOperands)
          case opcode of
            _ | opcode `elem` [19, 20, 26] → if length operands == 1 then pure marked else count "1"
            21 → case operands of
              [_, width, signedness]
                | width `notElem` [8, 16, 32, 64] → literal ("of width " <> show width) "8, 16, 32 or 64"
                | signedness `notElem` [0, 1] → literal ("of signedness " <> show signedness) "0 or 1"
                | otherwise → pure marked
              _ → count "3"
            22 → case operands of
              [_, width]
                | width `notElem` [16, 32, 64] → literal ("of width " <> show width) "16, 32 or 64"
                | otherwise → pure marked
              _ → count "2"
            23 → case operands of
              [_, component, components] → do
                (checked, _, _) ← child "a vector's component" "a scalar" [20, 21, 22] component marked
                if components `elem` [2, 3, 4] then pure checked else literal ("of " <> show components <> " components") "2, 3 or 4"
              _ → count "3"
            24 → case operands of
              [_, column, columns] → do
                (checked, _, columnOperands) ← child "a matrix's column" "a float vector" [23] column marked
                case columnOperands of
                  [_, component, _] → case Map.lookup component (moduleTypes parsed) of
                    Just (Instruction 22 _) → pure ()
                    Just (Instruction other _) → literal ("whose column is a vector of " <> opcodeName other) "a float vector"
                    Nothing → pure ()
                  _ → pure ()
                if columns `elem` [2, 3, 4] then pure checked else literal ("of " <> show columns <> " columns") "2, 3 or 4"
              _ → count "3"
            25 → case operands of
              _ : sampledType : dimension : depth : arrayed : multisampled : sampled : format : access
                | length access <= 1 → do
                    (checked, sampledOpcode, sampledOperands) ← child "an image's sampled type" "a 32-bit float or a 32- or 64-bit integer" [21, 22] sampledType marked
                    case (sampledOpcode, sampledOperands) of
                      (21, [_, width, _]) | width `elem` [32, 64] → pure ()
                      (22, [_, 32]) → pure ()
                      _ → Left (named <> " reaches id " <> show sampledType <> " as an image's sampled type, an " <> opcodeName sampledOpcode <> " of width " <> show (widthOf sampledOperands) <> ", where the reader requires a 32-bit float or a 32- or 64-bit integer")
                    let ranges = [("dimension", dimension, 6), ("depth", depth, 2), ("arrayed", arrayed, 1), ("multisampled", multisampled, 1), ("sampled", sampled, 2), ("format", format, 41)] <> [("access qualifier", qualifier, 2) | qualifier ← access]
                    case [(what, value, most) | (what, value, most) ← ranges, value > most] of
                      (what, value, most) : _ → literal ("of " <> what <> " " <> show value) ("at most " <> show most)
                      [] → pure checked
              _ → count "8 or 9"
            27 → case operands of
              [_, image] → (\(checked, _, _) → checked) <$> child "a sampled image's image" "an OpTypeImage" [25] image marked
              _ → count "2"
            28 → case operands of
              [_, element, length'] → do
                (checked, _, _) ← child "an array element" "a sized or opaque type" elementOpcodes element marked
                arrayLength named typeId position length' checked
              _ → count "3"
            29 → case operands of
              [_, element] → (\(checked, _, _) → checked) <$> child "a runtime array's element" "a sized or opaque type" elementOpcodes element marked
              _ → count "2"
            30 → case operands of
              _ : members →
                foldM
                  ( \through (index, member) → do
                      let lastMember = index == length members - 1
                          allowed = if lastMember then 29 : memberOpcodes else memberOpcodes
                          role = "struct member " <> show index
                          -- A built-in member, as of gl_PerVertex, is the
                          -- device's too.
                          within = if isJust (memberDecoration parsed typeId index decorationBuiltIn) then Nothing else context
                      (checked, memberOpcode, _) ← childIn within role "a sized type, or a runtime-sized array as the last member" allowed member through
                      when (memberOpcode == 29 && not lastMember) $ Left (wrongKind named member role memberOpcode "a sized type, or a runtime-sized array as the last member")
                      pure checked
                  )
                  marked
                  (zip [0 ∷ Int ..] members)
              [] → count "at least 1"
            32 → case operands of
              [_, storage, pointee']
                | Nothing ← lookup storage storageClasses → literal ("of storage class " <> show storage) ("one of storage classes " <> show (map fst storageClasses))
                | otherwise → (\(checked, _, _) → checked) <$> child "a pointer's pointee" "a type other than void or a pointer" pointeeOpcodes pointee' marked
              _ → count "3"
            _ → Left (named <> " reaches type id " <> show typeId <> ", an " <> opcodeName opcode <> ", which the reader does not support")
      where
        widthOf = \case
          _ : width : _ → width
          _ → 0

    -- An array's length: an OpConstant, declared before the array, of exactly
    -- its three operands, whose type is a 32-bit integer declared before it
    -- and whose value is positive.
    arrayLength named array position constant seen = do
      Instruction opcode operands ← refer named array position "an array length" constant
      case (opcode, operands) of
        (43, resultType : rest) → do
          let constantPosition = Map.findWithDefault 0 constant (modulePositions parsed)
          Instruction typeOpcode typeOperands ← refer named constant constantPosition "an array length's type" resultType
          checked ← wellFormed named Nothing seen resultType
          signed ← case (typeOpcode, typeOperands) of
            (21, [_, 32, signedness]) → Right (signedness == 1)
            _ → Left (named <> " reaches id " <> show constant <> " as an array length, an OpConstant whose type (id " <> show resultType <> ") is not a 32-bit integer")
          case rest of
            [_, value]
              | value == 0 → Left (named <> " reaches id " <> show constant <> " as an array length, an OpConstant of 0, where the reader requires a positive length")
              | signed && value >= 0x80000000 →
                  Left (named <> " reaches id " <> show constant <> " as an array length, an OpConstant of " <> show (toInteger value - 0x100000000) <> ", where the reader requires a positive length")
              | otherwise → pure checked
            _ → Left (named <> " reaches id " <> show constant <> " as an array length, an OpConstant with " <> show (length operands) <> " operands, where the reader requires 3")
        _ → Left (wrongKind named constant "an array length" opcode "an OpConstant of a 32-bit integer type")

    -- A constant of exactly this type, declared before the instruction that
    -- names it: a boolean, a scalar of as many words as its width, a null, or
    -- a composite of as many constituents as its type has, each in turn a
    -- constant of that constituent's type.
    constantOf named user position role constant expected seen = do
      Instruction opcode operands ← refer named user position role constant
      let constantPosition = Map.findWithDefault 0 constant (modulePositions parsed)
          resultType = case operands of
            found : _ → found
            [] → 0
          mismatch ∷ Either String a
          mismatch = Left (named <> " reaches id " <> show constant <> " as " <> role <> ", an " <> opcodeName opcode <> " whose type (id " <> show resultType <> ") is not the type it must have (id " <> show expected <> ")")
          counted ∷ String → Either String a
          counted required = Left (named <> " reaches id " <> show constant <> " as " <> role <> ", an " <> opcodeName opcode <> " with " <> show (length operands) <> " operands, where the reader requires " <> required)
          expectedType = Map.lookup expected (moduleTypes parsed)
      -- The constant's own type is a reference like any other: declared
      -- before the constant.
      _ ← refer named constant constantPosition ("the type of " <> role) resultType
      when (resultType /= expected) mismatch
      case opcode of
        _
          | opcode `elem` [41, 42, 48, 49] → case expectedType of
              Just (Instruction 20 _) | length operands == 2 → pure seen
              Just (Instruction 20 _) → counted "2"
              _ → mismatch
          | opcode `elem` [43, 50] → case expectedType of
              Just (Instruction typeOpcode (_ : width : _))
                | typeOpcode `elem` [21, 22] →
                    let required = if width > 32 then 4 else 3
                     in if length operands == required then pure seen else counted (show required)
              _ → mismatch
          | opcode == 46 → if length operands == 2 then pure seen else counted "2"
          | opcode `elem` [44, 51] → do
              let constituents = drop 2 operands
              elements ← case expectedType of
                Just (Instruction 23 [_, component, components]) → Right (replicate (fromIntegral components) component)
                Just (Instruction 24 [_, column, columns]) → Right (replicate (fromIntegral columns) column)
                Just (Instruction 28 [_, element, length']) → (\value → replicate (fromIntegral value) element) <$> constantValue parsed length'
                Just (Instruction 30 (_ : members)) → Right members
                _ → mismatch
              unless (length constituents == length elements) $
                Left (named <> " reaches id " <> show constant <> " as " <> role <> ", an " <> opcodeName opcode <> " of " <> show (length constituents) <> " constituents, where its type has " <> show (length elements))
              foldM
                (\through (index, (constituent, element)) → constantOf named constant constantPosition ("constituent " <> show index <> " of " <> role) constituent element through)
                seen
                (zip [0 ∷ Int ..] (zip constituents elements))
          | otherwise → Left (wrongKind named constant role opcode "a constant of a boolean, scalar, null or composite kind")

-- ---------------------------------------------------------------------------
-- Decorations

-- | Every decoration of a kind the reader reads, wherever it is: its target
-- declared, as a struct with that member where it decorates a member; its
-- literals exactly as many as its kind takes — none for Block, BufferBlock,
-- RowMajor and ColMajor, one for ArrayStride, MatrixStride, BuiltIn,
-- Location, Component, Binding, DescriptorSet and Offset; a stride positive;
-- no kind twice on one target or member; and never both RowMajor and
-- ColMajor, nor BuiltIn with Location or Component. Nothing is read from a
-- decoration until all of them pass, so no missing literal can stand for a
-- default.
validateDecorations ∷ Module → Either String ()
validateDecorations parsed = do
  forM_' (Map.toList (moduleDecorations parsed)) $ \(target, found) → do
    let consumed = [(kind, values) | (kind, values) ← found, isJust (lookup kind decorationLiterals)]
        subject = "id " <> show target
    unless (null consumed || Map.member target (modulePositions parsed)) $
      Left ("the module decorates " <> subject <> " with " <> decorationName (fst (head' consumed)) <> ", but declares no type, constant or variable of that id")
    validateKinds subject consumed
  forM_' (Map.toList (moduleMemberDecorations parsed)) $ \((target, member), found) → do
    let consumed = [(kind, values) | (kind, values) ← found, isJust (lookup kind decorationLiterals)]
        subject = "member " <> show member <> " of id " <> show target
    unless (null consumed) $ case Map.lookup target (moduleTypes parsed) of
      Just (Instruction 30 (_ : members))
        | fromIntegral member < length members → pure ()
        | otherwise → Left ("the module decorates " <> subject <> ", a struct of " <> show (length members) <> " members")
      _ → Left ("the module decorates " <> subject <> ", which is not a struct the module declares")
    validateKinds subject consumed
    when (all (`elem` map fst consumed) [decorationRowMajor, decorationColMajor]) $
      Left (subject <> " is decorated both RowMajor and ColMajor")
  where
    forM_' = flip mapM_
    head' = \case
      first : _ → first
      [] → (0, [])
    validateKinds subject consumed =
      forM_' (zip [0 ∷ Int ..] consumed) $ \(index, (kind, values)) → do
        when (kind `elem` map fst (take index consumed)) $
          Left (subject <> " is decorated with " <> decorationName kind <> " more than once")
        let required = maybe 0 id (lookup kind decorationLiterals)
        unless (length values == required) $
          Left (subject <> "'s " <> decorationName kind <> " decoration carries " <> show (length values) <> " literals, where the reader requires " <> show required)
        when (kind `elem` [decorationArrayStride, decorationMatrixStride] && values == [0]) $
          Left (subject <> "'s " <> decorationName kind <> " is 0, where the reader requires a positive stride")
        -- A built-in is located by the device, not by a Location or a
        -- Component: the combination is refused before any built-in is
        -- excluded from what the host declares.
        when (kind `elem` [decorationLocation, decorationComponent] && decorationBuiltIn `elem` map fst consumed) $
          Left (subject <> " is decorated both BuiltIn and " <> decorationName kind <> ", which a built-in does not take")

-- | The explicit layout a Uniform, StorageBuffer or PushConstant block
-- requires, from its struct down — through a descriptor array of blocks,
-- which is not memory and takes no stride: every member of every struct it
-- reaches has an Offset; every array and runtime-sized array it reaches has
-- an ArrayStride; and every member that is a matrix, or an array of them,
-- has a MatrixStride and is RowMajor or ColMajor.
validateLayout ∷ Module → [(Word32, (Word32, Word32))] → Either String ()
validateLayout parsed globals =
  mapM_ block [(variable, pointer) | (variable, (pointer, storage)) ← globals, storage `elem` [storageUniform, storagePushConstant, storageStorageBuffer]]
  where
    block (variable, pointer) = do
      let named = "the interface variable (id " <> show variable <> ")"
      typeId ← pointee parsed pointer
      let struct = case typeOf parsed typeId of
            Just (Instruction opcode (_ : element : _)) | opcode `elem` [28, 29] → element
            _ → typeId
      case typeOf parsed struct of
        Just (Instruction 30 _) → layoutStruct named struct
        _ → pure ()
    layoutStruct named struct = case typeOf parsed struct of
      Just (Instruction 30 (_ : members)) →
        forM_' (zip [0 ..] members) $ \(index, member) → do
          when (isNothing (memberDecoration parsed struct index decorationOffset)) $
            Left (named <> " reaches struct id " <> show struct <> ", whose member " <> show index <> " has no Offset")
          layoutMember named struct index member
      _ → pure ()
    layoutMember named struct index typeId = case typeOf parsed typeId of
      Just (Instruction 24 _) → do
        let decorations = Map.findWithDefault [] (struct, fromIntegral index) (moduleMemberDecorations parsed)
            subject = named <> " reaches struct id " <> show struct <> ", whose member " <> show index <> " is a matrix"
        unless (isJust (lookup decorationMatrixStride decorations)) $ Left (subject <> " with no MatrixStride")
        unless (any (isJust . (`lookup` decorations)) [decorationRowMajor, decorationColMajor]) $ Left (subject <> " that is neither RowMajor nor ColMajor")
      Just (Instruction opcode (_ : element : _))
        | opcode `elem` [28, 29] → do
            unless (hasDecoration parsed typeId decorationArrayStride) $
              Left (named <> " reaches array id " <> show typeId <> ", member " <> show index <> " of struct id " <> show struct <> ", which has no ArrayStride")
            layoutMember named struct index element
      Just (Instruction 30 _) → layoutStruct named typeId
      _ → pure ()
    forM_' = flip mapM_

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
  _ → Nothing

-- ---------------------------------------------------------------------------
-- Numbers

spirvMagic ∷ Word32
spirvMagic = 0x07230203

-- | Every type declaration with a result id, and every constant, so a
-- position requiring one kind can name the other it found. Only some are on
-- the whitelist.
typeOpcodes, constantOpcodes ∷ [Word32]
typeOpcodes = [19 .. 38]
constantOpcodes = [41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52]

-- | What an array's or runtime array's element, a struct's member and a
-- pointer's pointee may be.
elementOpcodes, memberOpcodes, pointeeOpcodes ∷ [Word32]
elementOpcodes = [20, 21, 22, 23, 24, 25, 26, 27, 28, 30]
memberOpcodes = [20, 21, 22, 23, 24, 28, 30]
pointeeOpcodes = [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30]

-- | The storage classes the reader knows, by number, and those whose
-- contents the host or the pipeline's fixed function supplies or receives.
storageClasses ∷ [(Word32, String)]
storageClasses =
  [ (0, "UniformConstant")
  , (1, "Input")
  , (2, "Uniform")
  , (3, "Output")
  , (4, "Workgroup")
  , (6, "Private")
  , (9, "PushConstant")
  , (12, "StorageBuffer")
  ]

hostVisible ∷ [Word32]
hostVisible = [1, 2, 3, 9, 12]

-- | The storage classes whose variables may carry an initializer: Output and
-- Private.
initialized ∷ [Word32]
initialized = [3, 6]

-- | Every decoration kind the reader reads, with how many literals it
-- takes, and its name.
decorationLiterals ∷ [(Word32, Int)]
decorationLiterals = [(2, 0), (3, 0), (4, 0), (5, 0), (6, 1), (7, 1), (11, 1), (30, 1), (31, 1), (33, 1), (34, 1), (35, 1)]

decorationName ∷ Word32 → String
decorationName = \case
  2 → "Block"
  3 → "BufferBlock"
  4 → "RowMajor"
  5 → "ColMajor"
  6 → "ArrayStride"
  7 → "MatrixStride"
  11 → "BuiltIn"
  30 → "Location"
  31 → "Component"
  33 → "Binding"
  34 → "DescriptorSet"
  35 → "Offset"
  other → "decoration " <> show other

opcodeName ∷ Word32 → String
opcodeName opcode = case lookup opcode names of
  Just name → name
  Nothing → "instruction of opcode " <> show opcode
  where
    names =
      zip [19 ..] ["OpTypeVoid", "OpTypeBool", "OpTypeInt", "OpTypeFloat", "OpTypeVector", "OpTypeMatrix", "OpTypeImage", "OpTypeSampler", "OpTypeSampledImage", "OpTypeArray", "OpTypeRuntimeArray", "OpTypeStruct", "OpTypeOpaque", "OpTypePointer", "OpTypeFunction", "OpTypeEvent", "OpTypeDeviceEvent", "OpTypeReserveId", "OpTypeQueue", "OpTypePipe"]
        <> zip [41 ..] ["OpConstantTrue", "OpConstantFalse", "OpConstant", "OpConstantComposite", "OpConstantSampler", "OpConstantNull"]
        <> zip [48 ..] ["OpSpecConstantTrue", "OpSpecConstantFalse", "OpSpecConstant", "OpSpecConstantComposite", "OpSpecConstantOp"]

storageUniformConstant, storageInput, storageUniform, storagePushConstant, storageStorageBuffer ∷ Word32
storageUniformConstant = 0
storageInput = 1
storageUniform = 2
storagePushConstant = 9
storageStorageBuffer = 12

decorationBlock, decorationBufferBlock, decorationRowMajor, decorationColMajor, decorationArrayStride, decorationMatrixStride, decorationBuiltIn, decorationLocation, decorationComponent, decorationBinding, decorationDescriptorSet, decorationOffset ∷ Word32
decorationBlock = 2
decorationBufferBlock = 3
decorationRowMajor = 4
decorationColMajor = 5
decorationArrayStride = 6
decorationMatrixStride = 7
decorationBuiltIn = 11
decorationLocation = 30
decorationComponent = 31
decorationBinding = 33
decorationDescriptorSet = 34
decorationOffset = 35

dimensionRect, dimensionBuffer, dimensionSubpassData ∷ Word32
dimensionRect = 4
dimensionBuffer = 5
dimensionSubpassData = 6
