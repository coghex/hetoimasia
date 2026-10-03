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

import Hetoimasia.GPU.Vulkan.Native.Shader.Reflect (Reflection (..), reflect)

spec ∷ Spec
spec = describe "The reader's whitelist" $ do
  it "reads every fixture the rows mutate, unmutated" $
    mapM_ (\fixture → load fixture >>= \parts → either (expectationFailure . ((fixture <> ": ") <>)) (const (pure ())) (reflect (assemble parts))) [descriptors, interface, layout]
  mapM_ row rows
  describe "an exact operand count for every opcode it supports" $
    mapM_ operandRow operandRows
  it "refuses an id beyond the header's bound" $ do
    (header, instructions) ← load descriptors
    reflect (assemble (setOperand 2 5 header, instructions)) `shouldSatisfy` failedWith "beyond its header's bound of 5"
  it "reads a legal relaxed block layout: a float at offset 0 and then a vec3 at offset 4, aligned only to its scalar" $ do
    (header, instructions) ← load layout
    -- The push-constant block's struct: the one whose member 1 is at 12.
    let pushed = case [operand 0 words' | words' ← instructions, decorates 72 35 words', operand 1 words' == 1, operand 3 words' == 12] of
          found : _ → found
          [] → unknown
        offset member value words'
          | decorates 72 35 words' && operand 0 words' == pushed && operand 1 words' == member = setOperand 3 value words'
          | otherwise = words'
        -- The vec3, member 0, moved to 4, and the float, member 1, to 0: the
        -- vector straddles no 16-byte boundary, so the relaxed block layout
        -- takes it, though std430's base alignment would put it at 16.
        relaxed = map (offset 0 4 . offset 1 0) instructions
    fmap reflectionPushMembers (reflect (assemble (header, instructions))) `shouldBe` Right (Just [(0, 12), (12, 4), (16, 16), (32, 8)])
    fmap reflectionPushMembers (reflect (assemble (header, relaxed))) `shouldBe` Right (Just [(4, 12), (0, 4), (16, 16), (32, 8)])

  it "reads an Output variable whose initializer is a null constant of its own type, exactly as without one" $ do
    (header, instructions) ← load interface
    let outputs = [words' | words' ← instructions, opcodeOfWords words' == 59, operand 2 words' == 3]
        nulls = [(operand 1 words', fresh + index, pointeeOf (operand 0 words') instructions) | (index, words') ← zip [0 ..] outputs]
        initialize words' = case [constant | (variable, constant, _) ← nulls, opcodeOfWords words' == 59, variable == operand 1 words'] of
          constant : _ → withWords (words' <> [constant])
          [] → words'
        mutated = foldr (\(_, constant, pointee') → insertAfterDeclaration pointee' [instruction 46 [pointee', constant]]) (map initialize instructions) nulls
    reflect (assemble (withRoom header, mutated)) `shouldBe` reflect (assemble (header, instructions))
  where
    row (rule, fixture, mutation, expected) = it rule $ do
      (header, instructions) ← load fixture
      reflect (assemble (withRoom header, mutation instructions)) `shouldSatisfy` failedWith expected
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
  , -- Decorations the reader reads: literal counts, duplicates, targets
    ( "refuses a Location decoration with an extra literal"
    , descriptors
    , onDecoration 71 30 (\words' → withWords (words' <> [0]))
    , "Location decoration carries 2 literals, where the reader requires 1"
    )
  , ( "refuses a Binding decoration with no literal"
    , descriptors
    , onDecoration 71 33 (\words' → withWords (take (length words' - 1) words'))
    , "Binding decoration carries 0 literals, where the reader requires 1"
    )
  , ( "refuses an Offset decoration with no literal, rather than reading it as 0"
    , interface
    , onDecoration 72 35 (\words' → withWords (take (length words' - 1) words'))
    , "Offset decoration carries 0 literals, where the reader requires 1"
    )
  , ( "refuses an Offset decoration with an extra literal"
    , interface
    , onDecoration 72 35 (\words' → withWords (words' <> [0]))
    , "Offset decoration carries 2 literals, where the reader requires 1"
    )
  , ( "refuses a Block decoration carrying a literal"
    , descriptors
    , onDecoration 71 2 (\words' → withWords (words' <> [0]))
    , "Block decoration carries 1 literals, where the reader requires 0"
    )
  , ( "refuses a decoration of a kind it reads given twice"
    , descriptors
    , \instructions → instructions <> [words' | words' ← instructions, decorates 71 30 words']
    , "is decorated with Location more than once"
    )
  , ( "refuses an ArrayStride of 0"
    , interface
    , onDecoration 71 6 (setOperand 2 0)
    , "ArrayStride is 0, where the reader requires a positive stride"
    )
  , ( "refuses a MatrixStride of 0"
    , interface
    , onDecoration 72 7 (setOperand 3 0)
    , "MatrixStride is 0, where the reader requires a positive stride"
    )
  , ( "refuses a member both RowMajor and ColMajor"
    , interface
    , \instructions → instructions <> [setOperand 2 4 words' | words' ← instructions, decorates 72 5 words']
    , "is decorated both RowMajor and ColMajor"
    )
  , ( "refuses a member decoration naming a member its struct does not have"
    , interface
    , onDecoration 72 35 (setOperand 1 9)
    , "member 9 of id"
    )
  , ( "refuses a member decoration whose target is not a struct"
    , interface
    , \instructions → onDecoration 72 35 (setOperand 0 (firstType 22 instructions)) instructions
    , "which is not a struct the module declares"
    )
  , ( "refuses a decoration of a kind it reads whose target the module does not declare"
    , descriptors
    , onDecoration 71 33 (setOperand 0 unknown)
    , "but declares no type, constant or variable of that id"
    )
  , ( "refuses a variable decorated both BuiltIn and Location, rather than excluding it as a built-in"
    , interface
    , \instructions → instructions <> [instruction 71 [operand 0 words', 11, 0] | words' ← instructions, decorates 71 30 words', operand 2 words' == 2]
    , "is decorated both BuiltIn and Location, which a built-in does not take"
    )
  , ( "refuses a built-in variable decorated with a Component"
    , interface
    , \instructions → instructions <> [instruction 71 [operand 0 words', 31, 0] | words' ← instructions, decorates 71 11 words']
    , "is decorated both BuiltIn and Component, which a built-in does not take"
    )
  , -- The explicit layout a buffer or push-constant block requires
    ( "refuses a buffer member with no Offset"
    , descriptors
    , filter (not . decorates 72 35)
    , "has no Offset"
    )
  , ( "refuses a push-constant member with no Offset"
    , interface
    , filter (not . decorates 72 35)
    , "has no Offset"
    )
  , ( "refuses a buffer's runtime-sized array with no ArrayStride"
    , descriptors
    , filter (not . decorates 71 6)
    , "which has no ArrayStride"
    )
  , ( "refuses a push-constant array with no ArrayStride"
    , interface
    , filter (not . decorates 71 6)
    , "which has no ArrayStride"
    )
  , ( "refuses a push-constant matrix with no MatrixStride"
    , interface
    , filter (not . decorates 72 7)
    , "is a matrix with no MatrixStride"
    )
  , ( "refuses a push-constant matrix neither RowMajor nor ColMajor"
    , interface
    , filter (not . decorates 72 5)
    , "is a matrix that is neither RowMajor nor ColMajor"
    )
  , -- Layout values, matched to the device profile: std140 for a uniform
    -- block, std430 for a storage buffer or push-constant block, each with
    -- Vulkan's relaxed block layout
    ( "refuses a MatrixStride that is not a multiple of its matrix's alignment"
    , interface
    , onDecoration 72 7 (setOperand 3 1)
    , "has a MatrixStride of 1, which is not a multiple of its matrix's alignment 16 under std430"
    )
  , ( "refuses an ArrayStride that is not a multiple of its array's alignment"
    , interface
    , onDecoration 71 6 (setOperand 2 1)
    , "whose ArrayStride of 1 is not a multiple of its alignment 4 under std430"
    )
  , ( "refuses a member offset that is not a multiple of its alignment"
    , interface
    , map (\words' → if decorates 72 35 words' && operand 3 words' == 64 then setOperand 3 66 words' else words')
    , "at offset 66 is not a multiple of its alignment 4 under std430"
    )
  , ( "refuses a vector that improperly straddles a 16-byte boundary"
    , interface
    , map (\words' → if decorates 72 35 words' && operand 3 words' == 64 then setOperand 3 68 words' else words')
    , "a vector of 16 bytes at offset 68, improperly straddles a 16-byte boundary under std430"
    )
  , ( "refuses a member that overlaps the one before it"
    , layout
    , map (\words' → if decorates 72 35 words' && operand 3 words' == 12 then setOperand 3 8 words' else words')
    , "overlaps member 0, which ends at byte 12"
    )
  , ( "refuses a member placed between the end of a struct and the next multiple of its alignment"
    , layout
    , map (\words' → if decorates 72 35 words' && operand 3 words' == 48 then setOperand 3 40 words' else words')
    , "lies between the end of member 1, at byte 36, and the next multiple of its alignment 16"
    )
  , ( "refuses a uniform block's float array of stride 4, which std140 aligns to 16, though std430 takes it"
    , layout
    , map (\words' → if decorates 71 6 words' && operand 2 words' == 16 then setOperand 2 4 words' else words')
    , "whose ArrayStride of 4 is not a multiple of its alignment 16 under std140"
    )
  , ( "refuses a uniform block's array at an offset std140 does not align, though std430 would"
    , layout
    , map (\words' → if decorates 72 35 words' && operand 3 words' == 128 then setOperand 3 132 words' else words')
    , "at offset 132 is not a multiple of its alignment 16 under std140"
    )
  , ( "refuses an ArrayStride smaller than its element"
    , layout
    , map (\words' → if decorates 71 6 words' && operand 2 words' == 32 then setOperand 2 16 words' else words')
    , "is smaller than its element's 20 bytes"
    )
  , -- Interface variables' declarations
    ( "refuses an OpVariable with extra operands"
    , interface
    , onOpcode 59 (\words' → withWords (words' <> [0, 0]))
    , "is an OpVariable with 5 operands, where the reader requires 3 or 4"
    )
  , ( "refuses an initializer on an Input variable"
    , interface
    , \instructions → map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 1 then withWords (words' <> [firstConstant instructions]) else words') instructions
    , "has an initializer, which the Input storage class does not take"
    )
  , ( "refuses an initializer the module does not declare"
    , interface
    , map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 3 then withWords (words' <> [unknown]) else words')
    , "as its initializer, which the module does not declare as a type or constant"
    )
  , ( "refuses an initializer of another type than its variable's"
    , interface
    , \instructions →
        let float = firstType 22 instructions
         in insertAfterDeclaration float [instruction 43 [float, fresh, 0]] $
              map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 3 then withWords (words' <> [fresh]) else words') instructions
    , "is not the type it must have"
    )
  , ( "refuses a composite initializer of fewer constituents than its type has"
    , interface
    , \instructions →
        let vector = firstVector 4 instructions
            float = firstType 22 instructions
         in insertBeforeFirst 59 [instruction 43 [float, fresh, 0], instruction 44 [vector, fresh + 1, fresh, fresh, fresh]] $
              map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 3 && pointeeOf (operand 0 words') instructions == vector then withWords (words' <> [fresh + 1]) else words') instructions
    , "of 3 constituents, where its type has 4"
    )
  , ( "refuses an initializer whose constant names its type before the type is declared"
    , interface
    , \instructions →
        let vector = firstVector 4 instructions
            declaresVector words' = opcodeOfWords words' == 23 && operand 0 words' == vector
            (earlier, rest) = break declaresVector instructions
         in map (\words' → if opcodeOfWords words' == 59 && operand 2 words' == 3 && pointeeOf (operand 0 words') instructions == vector then withWords (words' <> [fresh]) else words') $
              earlier <> [instruction 46 [vector, fresh]] <> rest
    , "which is not declared before the instruction (id " <> show fresh <> ") that refers to it"
    )
  , -- The entry point
    ( "refuses an entry point listing an interface id twice"
    , descriptors
    , onOpcode 15 (\words' → withWords (words' <> [lastWord words']))
    , "more than once"
    )
  , ( "refuses an entry point whose name is not terminated within it"
    , descriptors
    , onOpcode 15 (\words' → withWords (take 4 words'))
    , "the entry point's name is not terminated within its instruction"
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

descriptors, interface, layout ∷ FilePath
descriptors = "test/fixtures/spirv/descriptors.frag.spv"
interface = "test/fixtures/spirv/interface.vert.spv"
layout = "test/fixtures/spirv/layout.frag.spv"

-- | Ids no fixture uses: one never declared, and the first of those the rows
-- declare.
unknown, fresh ∷ Word32
unknown = 0xFFFFF
fresh = 0xFFFF0

-- ---------------------------------------------------------------------------
-- Instruction words

-- | A header whose id bound leaves room for the ids rows declare, so that
-- only the rule a row breaks is broken.
withRoom ∷ [Word32] → [Word32]
withRoom header = setOperand 2 (max (operand 2 header) (fresh + 16)) header

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

-- | Whether this is an OpDecorate (71) or an OpMemberDecorate (72) of this
-- decoration kind.
decorates ∷ Word32 → Word32 → [Word32] → Bool
decorates opcode kind words' = opcodeOfWords words' == opcode && operand (if opcode == 71 then 1 else 2) words' == kind

onDecoration ∷ Word32 → Word32 → ([Word32] → [Word32]) → [[Word32]] → [[Word32]]
onDecoration opcode kind change = map (\words' → if decorates opcode kind words' then change words' else words')

-- | These instructions inserted just before the first of this opcode.
insertBeforeFirst ∷ Word32 → [[Word32]] → [[Word32]] → [[Word32]]
insertBeforeFirst opcode inserted instructions =
  let (earlier, rest) = break ((== opcode) . opcodeOfWords) instructions in earlier <> inserted <> rest

-- | These instructions inserted just after the type declaring this id, so
-- they may name it.
insertAfterDeclaration ∷ Word32 → [[Word32]] → [[Word32]] → [[Word32]]
insertAfterDeclaration typeId inserted instructions =
  let (earlier, rest) = break (\words' → opcodeOfWords words' `elem` [19 .. 38] && operand 0 words' == typeId) instructions
   in case rest of
        declaration : later → earlier <> [declaration] <> inserted <> later
        [] → earlier <> inserted

-- | The type a pointer of this id points to.
pointeeOf ∷ Word32 → [[Word32]] → Word32
pointeeOf pointer instructions = case [operand 2 words' | words' ← instructions, opcodeOfWords words' == 32, operand 0 words' == pointer] of
  found : _ → found
  [] → unknown

-- | The first vector type of this many components.
firstVector ∷ Word32 → [[Word32]] → Word32
firstVector components instructions = case [operand 0 words' | words' ← instructions, opcodeOfWords words' == 23, operand 2 words' == components] of
  found : _ → found
  [] → unknown

lastWord ∷ [Word32] → Word32
lastWord = \case
  [] → 0
  words' → last words'

firstConstant ∷ [[Word32]] → Word32
firstConstant instructions = case [operand 1 words' | words' ← instructions, opcodeOfWords words' == 43] of
  found : _ → found
  [] → unknown
