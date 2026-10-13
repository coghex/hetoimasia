-- | The 64-byte instance encoding.
--
-- 'encodeLayer' writes a validated layer's instances, in submission order, into
-- one strict buffer of exactly 64 bytes per instance, little-endian:
--
-- > offset  size  field
-- >      0    24  the transform as six f32, column-major: [a, b, c, d, tx, ty]
-- >     24    16  the UV rectangle as four f32: (u0, v0, u1, v1)
-- >     40     4  the texture handle's lookup index (u32)
-- >     44     4  the texture handle's generation (u32)
-- >     48     4  the depth key (u32)
-- >     52     4  the tint, one byte each for R, G, B, A
-- >     56     4  the flags word (u32)
-- >     60     4  the material parameter word (u32)
--
-- The material an instance names ('Hetoimasia.Render.TwoD.Snapshot.instanceMaterial')
-- is a value the planner reads and is not encoded: the layout above is the whole
-- of it, and the parameter word is the only material datum an instance carries.
--
-- A transform's coefficients are @x' = a * x + c * y + tx@ and
-- @y' = b * x + d * y + ty@; see "Hetoimasia.Math.Affine2".
--
-- __The flags word.__ Bits 0–1 hold the sampler choice: 0 default, 1 nearest,
-- 2 linear, and 3 is never produced. Bit 2 is the translucent override and bit
-- 3 the additive flag. Bits 4–15 are reserved and always zero. Bits 16–31 hold
-- the clip index, an unsigned 16-bit number with 0 meaning none, so a shader
-- reads it as @flags >> 16@. A validated layer's clip index is 0 or selects an
-- entry of its view's clip table ("Hetoimasia.Render.TwoD.Clip"), and is
-- written unchanged: encoding neither renumbers nor resolves it, so the
-- table's entry order is the one the shader indexes. 'flagsWord' packs any
-- instance, so the layout is fixed and tested independently of validation.
--
-- __std430.__ The 64-byte stride is std430-compatible only when a shader
-- declares the UV rectangle as two @vec2@s, or reads the instance as vertex
-- attributes. Declared as a @vec4@, the UV rectangle would align to 16 bytes
-- and move to offset 32, breaking the stride.
--
-- __Drawing order.__ 'encodeLayerInDrawingOrder' writes the same chunks
-- permuted by a planned layer's drawing order, so a draw run's instances are
-- one contiguous range of the buffer: the @k@-th chunk it writes is byte for
-- byte the chunk 'encodeLayer' writes at the position
-- 'Hetoimasia.Render.TwoD.DrawPlan.drawingOrder' lists @k@-th. A recorder that
-- uploads it draws a run as its @runStart@ and @runCount@ over the buffer, with
-- no further reordering.
--
-- __Chunks__ (R2D-10). A layer that lists retained chunks encodes, in drawing
-- order, the ring's entries: its dynamic cutouts and the merged ordered
-- instances of its chunks and its own, each entry read from the dynamic list or
-- from the chunk listing the plan says. 'encodeChunkCutouts' encodes a chunk's
-- cutout instances, once, in the order the chunk's device buffer holds them: a
-- run of that chunk draws as its @runStart@ and @runCount@ over this buffer.
--
-- __Material records__ (R2D-11). 'encodeRecords' writes a material's records as
-- the recorder puts them in the batch's storage region: little-endian 32-bit
-- words, record after record with no padding, each record a full handle for each
-- of the layout's handles (its lookup index, then its generation) and then its
-- words. A record is @2 × handles + words@ words, so record @k@ starts at word
-- @k × (2 × handles + words)@ of its table, which is how the shader indexes it
-- with the instance's parameter word.
--
-- __Cost.__ Encoding is pure, total and linear in the number of instances. It
-- allocates the one result buffer of the exact final size and no buffer per
-- instance, and encoding the same layer always gives the same bytes. No
-- instance has a NaN or infinity here, because validation refused it.
-- 'encodeLayerInDrawingOrder' also holds the layer's instances in one array of
-- that many elements while it writes.
--
-- __Dependencies.__ @base@, @array@ for the drawing-order encoder's instance
-- array, @bytestring@, @hetoimasia-math@ for the transform's coefficients,
-- @hetoimasia-render-api@'s backend-facing module for the handle's two numbers,
-- and this package's draw plan, snapshot and validation modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Encoding
  ( encodeLayer
  , encodeLayerInDrawingOrder
  , encodeChunkCutouts
  , encodeRecords
  , instanceStride
  , flagsWord
  ) where

import Data.Array (Array, listArray, (!))
import qualified Data.Array.Unboxed as Unboxed
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder (Builder, floatLE, toLazyByteString, word32LE, word8)
import Data.ByteString.Builder.Extra (toLazyByteStringWith, untrimmedStrategy)
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32)
import Hetoimasia.Math.Affine2 (toColumnMajor)
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex)
import Hetoimasia.Render.TwoD.Chunk (Chunk, chunkCutoutPositions, chunkInstanceAt)
import Hetoimasia.Render.TwoD.Material (MaterialRecord (..), RecordLayout (..))
import Hetoimasia.Render.TwoD.DrawPlan (PlannedLayer (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( Instance (..)
  , Sampler (..)
  , Tint (..)
  , UvRect (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayerChunks, validLayerContents)

-- | The size of one encoded instance in bytes: 64.
instanceStride ∷ Int
instanceStride = 64

-- | A validated layer's instances in submission order: exactly 'instanceStride'
-- bytes each, in one strict buffer. A layer without instances encodes to the
-- empty buffer.
encodeLayer ∷ ValidLayer → ByteString
encodeLayer layer
  | size == 0 = ByteString.empty
  | otherwise =
      Lazy.toStrict (toLazyByteStringWith (untrimmedStrategy size size) mempty (foldMap encodeInstance instances))
  where
    instances = layerInstances (validLayerContents layer)
    size = instanceStride * length instances

-- | A planned layer's ring entries in drawing order: exactly 'instanceStride'
-- bytes each, in one strict buffer. Each entry is read from the layer's dynamic
-- instances by submission index, or from the chunk the plan names by build
-- position; for a layer that lists no chunk, the @k@-th chunk is the chunk
-- 'encodeLayer' writes for the @k@-th submission index of
-- 'Hetoimasia.Render.TwoD.DrawPlan.drawingOrder'. A layer whose plan holds no
-- order (an empty layer, or one in a zero-size viewport) encodes to the empty
-- buffer. 'Nothing' when the order names an instance the layer does not hold,
-- which planning that layer never does: the plan belongs to another layer.
encodeLayerInDrawingOrder ∷ PlannedLayer → ValidLayer → Maybe ByteString
encodeLayerInDrawingOrder planned layer = do
  resolved ← traverse resolve entries
  let size = instanceStride * length resolved
  if size == 0
    then Just ByteString.empty
    else Just (Lazy.toStrict (toLazyByteStringWith (untrimmedStrategy size size) mempty (foldMap encodeInstance resolved)))
  where
    instances = layerInstances (validLayerContents layer)
    count = length instances
    held ∷ Array Int Instance
    held = listArray (0, count - 1) instances
    chunks = map snd (validLayerChunks layer)
    chunkCount = length chunks
    chunkArray ∷ Array Int Chunk
    chunkArray = listArray (0, chunkCount - 1) chunks
    entries = zip (Unboxed.elems (plannedOrigin planned)) (Unboxed.elems (plannedOrder planned))
    resolve (origin, index)
      | origin < 0 = if index >= 0 && index < count then Just (held ! index) else Nothing
      | origin < chunkCount = chunkInstanceAt (chunkArray ! origin) index
      | otherwise = Nothing

-- | A chunk's cutout-path instances in the order its device buffer holds them
-- (by material, then build order): exactly 'instanceStride' bytes each, in one
-- strict buffer, empty when the chunk has none.
encodeChunkCutouts ∷ Chunk → ByteString
encodeChunkCutouts built
  | size == 0 = ByteString.empty
  | otherwise = Lazy.toStrict (toLazyByteStringWith (untrimmedStrategy size size) mempty (foldMap encodeInstance cutouts))
  where
    cutouts = [candidate | position ← chunkCutoutPositions built, Just candidate ← [chunkInstanceAt built position]]
    size = instanceStride * length cutouts

encodeInstance ∷ Instance → Builder
encodeInstance candidate =
  foldMap floatLE (toColumnMajor (instanceTransform candidate))
    <> foldMap floatLE [u0, v0, u1, v1]
    <> word32LE (handleIndex (instanceTexture candidate))
    <> word32LE (handleGeneration (instanceTexture candidate))
    <> word32LE (instanceDepthKey candidate)
    <> word8 r
    <> word8 g
    <> word8 b
    <> word8 a
    <> word32LE (flagsWord candidate)
    <> word32LE (instanceParameter candidate)
  where
    UvRect u0 v0 u1 v1 = instanceUv candidate
    Tint r g b a = instanceTint candidate

-- | The flags word of an instance: sampler choice in bits 0–1, translucent in
-- bit 2, additive in bit 3, bits 4–15 zero and the clip index in bits 16–31.
flagsWord ∷ Instance → Word32
flagsWord candidate =
  samplerCode (instanceSampler candidate)
    .|. flag 2 (instanceTranslucent candidate)
    .|. flag 3 (instanceAdditive candidate)
    .|. (fromIntegral (instanceClip candidate) `shiftL` 16)
  where
    flag position set = if set then 1 `shiftL` position else 0

-- | A sampler choice's code. The code 3 is never produced.
samplerCode ∷ Sampler → Word32
samplerCode SamplerDefault = 0
samplerCode SamplerNearest = 1
samplerCode SamplerLinear = 2

-- | A material's records, in the order given, as the batch's storage region
-- holds them (see "Material records" above): 'recordLayoutBytes' bytes each. A
-- validated view's and chunk's records have exactly the handles and words the
-- layout declares; the function is total, so one that has fewer is padded with
-- zero words and one that has more is cut off at the layout, and a record never
-- moves another.
encodeRecords ∷ RecordLayout → [MaterialRecord] → ByteString
encodeRecords (RecordLayout handles wordCount) records
  | null records = ByteString.empty
  | otherwise = Lazy.toStrict (toLazyByteString (foldMap encodeRecord records))
  where
    encodeRecord (MaterialRecord held values) =
      foldMap handleWords (fit (fromIntegral handles) Nothing (map Just held))
        <> foldMap word32LE (fit (fromIntegral wordCount) 0 values)
    handleWords = \case
      Just handle → word32LE (handleIndex handle) <> word32LE (handleGeneration handle)
      Nothing → word32LE 0 <> word32LE 0
    fit count filler items = take count (items <> repeat filler)
