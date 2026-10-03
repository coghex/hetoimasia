-- | The reader's whitelist (GRS-16), one rule at a time: each row mutates a
-- committed, valid fixture so that exactly one rule of the supported subset
-- is broken, and the reader must refuse it, naming that rule — never read
-- the module as empty or as matching. The unmutated fixtures are read
-- successfully, so a refusal here is the mutation's.
--
-- The rows work on instruction words: each fixture is split into its header
-- and its instructions, a mutation rewrites, inserts or moves instructions,
-- and the module is reassembled with every word count kept true.
module Test.Shader.Malformed (spec) where

import Control.Monad (unless)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString qualified as ByteString
import Data.List (isInfixOf, partition)
import Data.Word (Word32)
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Shader.Reflect (reflect)

spec ∷ Spec
spec = describe "The reader's whitelist" $ do
  it "reads every fixture the rows mutate, unmutated" $
    mapM_ (\fixture → load fixture >>= \parts → either (expectationFailure . ((fixture <> ": ") <>)) (const (pure ())) (reflect (assemble parts))) [descriptors, interface]
  mapM_ row rows
  describe "an exact operand count for every opcode it supports" $
    mapM_ operandRow operandRows
  where
    row (rule, fixture, mutation, expected) = it rule $ do
      (header, instructions) ← load fixture
      reflect (assemble (header, mutation instructions)) `shouldSatisfy` failedWith expected
    operandRow (opcode, fixture, extra) = do
      it ("refuses an " <> name opcode <> " with one operand too many") $ do
        (header, instructions) ← load fixture
        reflect (assemble (header, onOpcode opcode (\words' → withWords (words' <> replicate extra 0)) instructions))
          `shouldSatisfy` failedWith "operands, where the reader requires"
      -- A sampler's one operand is its result id: without it, it declares
      -- nothing, which the undeclared-reference row already covers.
      unless (opcode == 26) $ it ("refuses an " <> name opcode <> " with one operand too few") $ do
        (header, instructions) ← load fixture
        reflect (assemble (header, onOpcode opcode (\words' → withWords (take (length words' - 1) words')) instructions))
          `shouldSatisfy` failedWith "operands, where the reader requires"
    failedWith fragment = either (fragment `isInfixOf`) (const False)

-- | A rule, the fixture it mutates, the mutation, and what the refusal must
-- say.
type Row = (String, FilePath, [[Word32]] → [[Word32]], String)

rows ∷ [Row]
rows =
  [ -- References
    ( "refuses an id named where a type is required that the module does not declare"
    , descriptors
    , onOpcode 30 (setOperand 1 unknown)
    , "which the module does not declare as a type or constant"
    )
  , ( "refuses a forward reference, a type named before it is declared"
    , descriptors
    , \instructions → let (vectors, rest) = partition ((== 23) . opcodeOfWords) instructions in rest <> vectors
    , "which is not declared before the instruction"
    )
  , ( "refuses a cycle, a struct naming itself as a member"
    , descriptors
    , map (\words' → if opcodeOfWords words' == 30 then setOperand 1 (resultOfType words') words' else words')
    , "which is not declared before the instruction"
    )
  , ( "refuses an id declared more than once"
    , descriptors
    , \instructions → instructions <> [instruction 22 [firstType 22 instructions, 64]]
    , "more than once"
    )
  , -- Kinds
    ( "refuses a variable whose type is not a pointer"
    , descriptors
    , \instructions → onOpcode 59 (setOperand 0 (firstType 22 instructions)) instructions
    , "as its pointer type, an OpTypeFloat, where the reader requires an OpTypePointer"
    )
  , ( "refuses a constant where a type is required"
    , descriptors
    , \instructions → onOpcode 30 (setOperand 1 (firstConstant instructions)) instructions
    , "an OpConstant, where the reader requires"
    )
  , ( "refuses a type where an array length's constant is required"
    , descriptors
    , \instructions → onOpcode 28 (setOperand 2 (firstType 21 instructions)) instructions
    , "as an array length, an OpTypeInt, where the reader requires an OpConstant"
    )
  , ( "refuses a type opcode outside the subset, an OpTypeFunction as a struct member"
    , descriptors
    , \instructions → onOpcode 30 (setOperand 1 (firstType 33 instructions)) instructions
    , "an OpTypeFunction, where the reader requires"
    )
  , -- Scalars
    ( "refuses an integer of a width outside 8, 16, 32 and 64"
    , descriptors
    , onOpcode 21 (setOperand 1 12)
    , "an OpTypeInt of width 12"
    )
  , ( "refuses an integer of a signedness other than 0 or 1"
    , descriptors
    , onOpcode 21 (setOperand 2 2)
    , "an OpTypeInt of signedness 2"
    )
  , ( "refuses a float of a width outside 16, 32 and 64"
    , descriptors
    , onOpcode 22 (setOperand 1 24)
    , "an OpTypeFloat of width 24"
    )
  , -- Vectors and matrices
    ( "refuses a vector of more than 4 components"
    , descriptors
    , onOpcode 23 (setOperand 2 5)
    , "an OpTypeVector of 5 components, where the reader requires 2, 3 or 4"
    )
  , ( "refuses a vector of fewer than 2 components"
    , descriptors
    , onOpcode 23 (setOperand 2 1)
    , "an OpTypeVector of 1 components, where the reader requires 2, 3 or 4"
    )
  , ( "refuses a vector whose component is not a scalar"
    , descriptors
    , \instructions → onOpcode 23 (setOperand 1 (firstType 19 instructions)) instructions
    , "as a vector's component, an OpTypeVoid, where the reader requires a scalar"
    )
  , ( "refuses a matrix of more than 4 columns"
    , interface
    , onOpcode 24 (setOperand 2 5)
    , "an OpTypeMatrix of 5 columns, where the reader requires 2, 3 or 4"
    )
  , ( "refuses a matrix whose column is not a vector"
    , interface
    , \instructions → onOpcode 24 (setOperand 1 (firstType 22 instructions)) instructions
    , "as a matrix's column, an OpTypeFloat, where the reader requires a float vector"
    )
  , ( "refuses a matrix whose column is an integer vector"
    , interface
    , \instructions → [instruction 21 [fresh, 32, 1], instruction 23 [fresh + 1, fresh, 4]] <> onOpcode 24 (setOperand 1 (fresh + 1)) instructions
    , "whose column is a vector of OpTypeInt, where the reader requires a float vector"
    )
  , -- Images and samplers
    ( "refuses an image whose sampled type is not a scalar"
    , descriptors
    , \instructions → onOpcode 25 (setOperand 1 (firstType 19 instructions)) instructions
    , "as an image's sampled type, an OpTypeVoid, where the reader requires"
    )
  , ( "refuses an image whose sampled type is a 16-bit float"
    , descriptors
    , \instructions → instruction 22 [fresh, 16] : onOpcode 25 (setOperand 1 fresh) instructions
    , "an OpTypeFloat of width 16, where the reader requires a 32-bit float or a 32- or 64-bit integer"
    )
  , ( "refuses an image of an unknown dimension"
    , descriptors
    , onOpcode 25 (setOperand 2 7)
    , "an OpTypeImage of dimension 7, where the reader requires at most 6"
    )
  , ( "refuses an image of an unknown depth"
    , descriptors
    , onOpcode 25 (setOperand 3 3)
    , "an OpTypeImage of depth 3, where the reader requires at most 2"
    )
  , ( "refuses an image whose arrayed operand is neither 0 nor 1"
    , descriptors
    , onOpcode 25 (setOperand 4 2)
    , "an OpTypeImage of arrayed 2, where the reader requires at most 1"
    )
  , ( "refuses an image whose multisampled operand is neither 0 nor 1"
    , descriptors
    , onOpcode 25 (setOperand 5 2)
    , "an OpTypeImage of multisampled 2, where the reader requires at most 1"
    )
  , ( "refuses an image whose sampled operand is beyond 2"
    , descriptors
    , onOpcode 25 (setOperand 6 3)
    , "an OpTypeImage of sampled 3, where the reader requires at most 2"
    )
  , ( "refuses an image of an unknown format"
    , descriptors
    , onOpcode 25 (setOperand 7 42)
    , "an OpTypeImage of format 42, where the reader requires at most 41"
    )
  , ( "refuses an image of an unknown access qualifier"
    , descriptors
    , onOpcode 25 (\words' → withWords (words' <> [3]))
    , "an OpTypeImage of access qualifier 3, where the reader requires at most 2"
    )
  , ( "refuses a sampled image whose image is not an image"
    , descriptors
    , \instructions → instruction 26 [fresh] : onOpcode 27 (setOperand 1 fresh) instructions
    , "as a sampled image's image, an OpTypeSampler, where the reader requires an OpTypeImage"
    )
  , -- Arrays
    ( "refuses an array whose element is void"
    , descriptors
    , \instructions → onOpcode 28 (setOperand 1 (firstType 19 instructions)) instructions
    , "as an array element, an OpTypeVoid, where the reader requires"
    )
  , ( "refuses an array whose element is a runtime-sized array"
    , descriptors
    , \instructions → [instruction 22 [fresh, 32], instruction 29 [fresh + 1, fresh]] <> onOpcode 28 (setOperand 1 (fresh + 1)) instructions
    , "as an array element, an OpTypeRuntimeArray, where the reader requires"
    )
  , ( "refuses a runtime-sized array whose element is void"
    , descriptors
    , \instructions → onOpcode 29 (setOperand 1 (firstType 19 instructions)) instructions
    , "as a runtime array's element, an OpTypeVoid, where the reader requires"
    )
  , ( "refuses an array length of 0"
    , descriptors
    , onOpcode 43 (setOperand 2 0)
    , "an OpConstant of 0, where the reader requires a positive length"
    )
  , ( "refuses a negative array length"
    , descriptors
    , onOpcode 43 (setOperand 2 0xFFFFFFFC) . onOpcode 21 (setOperand 2 1)
    , "an OpConstant of -4, where the reader requires a positive length"
    )
  , ( "refuses an array length whose type the module does not declare"
    , descriptors
    , onOpcode 43 (setOperand 0 unknown)
    , "as an array length's type, which the module does not declare as a type or constant"
    )
  , ( "refuses an array length whose type is a float"
    , descriptors
    , \instructions → instruction 22 [fresh, 32] : onOpcode 43 (setOperand 0 fresh) instructions
    , "an OpConstant whose type (id " <> show fresh <> ") is not a 32-bit integer"
    )
  , ( "refuses an array length whose type is a 64-bit integer"
    , descriptors
    , \instructions → instruction 21 [fresh, 64, 0] : onOpcode 43 (\words' → withWords (setOperand 0 fresh words' <> [0])) instructions
    , "an OpConstant whose type (id " <> show fresh <> ") is not a 32-bit integer"
    )
  , ( "refuses an array length's constant with an operand too many"
    , descriptors
    , onOpcode 43 (\words' → withWords (words' <> [0]))
    , "an OpConstant with 4 operands, where the reader requires 3"
    )
  , -- Structs
    ( "refuses a struct member that is opaque"
    , descriptors
    , \instructions → onOpcode 30 (setOperand 1 (firstType 25 instructions)) instructions
    , "as struct member 0, an OpTypeImage, where the reader requires"
    )
  , ( "refuses a struct member that is void"
    , descriptors
    , \instructions → onOpcode 30 (setOperand 1 (firstType 19 instructions)) instructions
    , "as struct member 0, an OpTypeVoid, where the reader requires"
    )
  , ( "refuses a runtime-sized array that is not its struct's last member"
    , descriptors
    , \instructions → onOpcode 30 (\words' → withWords (words' <> [firstType 22 instructions])) instructions
    , "as struct member 0, an OpTypeRuntimeArray, where the reader requires a sized type, or a runtime-sized array as the last member"
    )
  , -- Pointers and storage classes
    ( "refuses a pointer of a storage class outside the subset"
    , descriptors
    , onPointers 12 (setOperand 1 5)
    , "an OpTypePointer of storage class 5"
    )
  , ( "refuses a variable of a storage class outside the subset"
    , descriptors
    , map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 12 then setOperand 2 5 words' else words')
    , "has storage class 5, which the reader does not support"
    )
  , ( "refuses a variable whose pointer's storage class is not its own"
    , descriptors
    , onPointers 12 (setOperand 1 2)
    , ", but its pointer type (id"
    )
  , ( "refuses a pointer whose pointee is void"
    , descriptors
    , \instructions → onPointers 12 (setOperand 2 (firstType 19 instructions)) instructions
    , "as a pointer's pointee, an OpTypeVoid, where the reader requires"
    )
  , ( "refuses a pointer whose pointee is a pointer"
    , descriptors
    , \instructions → [instruction 22 [fresh, 32], instruction 32 [fresh + 1, 12, fresh]] <> onPointers 12 (setOperand 2 (fresh + 1)) instructions
    , "as a pointer's pointee, an OpTypePointer, where the reader requires"
    )
  , ( "refuses a boolean an Input variable reaches"
    , descriptors
    , \instructions → instruction 20 [fresh] : onPointers 1 (pointing (firstType 21 instructions) fresh) instructions
    , "an OpTypeBool, which the Input storage class cannot hold"
    )
  , ( "refuses an opaque type an Input variable reaches"
    , descriptors
    , \instructions → instruction 26 [fresh] : onPointers 1 (pointing (firstType 21 instructions) fresh) instructions
    , "an OpTypeSampler, which the Input storage class cannot hold"
    )
  , ( "refuses a boolean a buffer reaches"
    , descriptors
    , \instructions → instruction 20 [fresh] : onOpcode 30 (setOperand 1 fresh) instructions
    , "an OpTypeBool, which the"
    )
  ]

-- | Every opcode on the whitelist with a fixed operand count, the fixture
-- that reaches one, and how many operands make one too many: an image's
-- optional access qualifier takes a ninth, so a tenth is the excess.
operandRows ∷ [(Word32, FilePath, Int)]
operandRows =
  [ (21, descriptors, 1)
  , (22, descriptors, 1)
  , (23, descriptors, 1)
  , (24, interface, 1)
  , (25, descriptors, 2)
  , (26, descriptors, 1)
  , (27, descriptors, 1)
  , (28, descriptors, 1)
  , (29, descriptors, 1)
  , (32, descriptors, 1)
  ]

name ∷ Word32 → String
name = \case
  21 → "OpTypeInt"
  22 → "OpTypeFloat"
  23 → "OpTypeVector"
  24 → "OpTypeMatrix"
  25 → "OpTypeImage"
  26 → "OpTypeSampler"
  27 → "OpTypeSampledImage"
  28 → "OpTypeArray"
  29 → "OpTypeRuntimeArray"
  32 → "OpTypePointer"
  other → "instruction of opcode " <> show other

descriptors, interface ∷ FilePath
descriptors = "test/fixtures/spirv/descriptors.frag.spv"
interface = "test/fixtures/spirv/interface.vert.spv"

-- | Ids no fixture uses: one never declared, and the first of those the rows
-- declare.
unknown, fresh ∷ Word32
unknown = 0xFFFFF
fresh = 0xFFFF0

-- ---------------------------------------------------------------------------
-- Instruction words

-- | A fixture's header words and its instructions, each with its leading
-- word count and opcode word, in this host's byte order.
load ∷ FilePath → IO ([Word32], [[Word32]])
load path = do
  words' ← toWords <$> ByteString.readFile path
  pure (take 5 words', split (drop 5 words'))
  where
    split [] = []
    split rest@(first : _) = let count = fromIntegral (first `shiftR` 16) in take count rest : split (drop count rest)

assemble ∷ ([Word32], [[Word32]]) → ByteString.ByteString
assemble (header, instructions) = ByteString.pack (concatMap littleEndian (header <> concat instructions))
  where
    littleEndian value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24 ∷ Int]]

toWords ∷ ByteString.ByteString → [Word32]
toWords bytes
  | ByteString.null bytes = []
  | otherwise =
      let (word, rest) = ByteString.splitAt 4 bytes
       in foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack word) : toWords rest

-- | An instruction of this opcode and these operands.
instruction ∷ Word32 → [Word32] → [Word32]
instruction opcode operands = withWords (opcode : operands)

-- | The same instruction with its word count made true again.
withWords ∷ [Word32] → [Word32]
withWords = \case
  first : rest → ((fromIntegral (length rest + 1) `shiftL` 16) .|. (first .&. 0xFFFF)) : rest
  [] → []

opcodeOfWords ∷ [Word32] → Word32
opcodeOfWords = \case
  first : _ → first .&. 0xFFFF
  [] → 0

-- | Operand n, counting from 0 after the opcode word.
operand ∷ Int → [Word32] → Word32
operand index words' = case drop (index + 1) words' of
  value : _ → value
  [] → 0

setOperand ∷ Int → Word32 → [Word32] → [Word32]
setOperand index value words' = take (index + 1) words' <> [value] <> drop (index + 2) words'

resultOfType ∷ [Word32] → Word32
resultOfType = operand 0

onOpcode ∷ Word32 → ([Word32] → [Word32]) → [[Word32]] → [[Word32]]
onOpcode opcode change = map (\words' → if opcodeOfWords words' == opcode then change words' else words')

-- | Change every pointer of this storage class.
onPointers ∷ Word32 → ([Word32] → [Word32]) → [[Word32]] → [[Word32]]
onPointers storage change = map (\words' → if opcodeOfWords words' == 32 && operand 1 words' == storage then change words' else words')

-- | A pointer to this type redirected to that one; any other unchanged.
pointing ∷ Word32 → Word32 → [Word32] → [Word32]
pointing from to words' = if operand 2 words' == from then setOperand 2 to words' else words'

firstType ∷ Word32 → [[Word32]] → Word32
firstType opcode instructions = case [resultOfType words' | words' ← instructions, opcodeOfWords words' == opcode] of
  found : _ → found
  [] → unknown

firstConstant ∷ [[Word32]] → Word32
firstConstant instructions = case [operand 1 words' | words' ← instructions, opcodeOfWords words' == 43] of
  found : _ → found
  [] → unknown
