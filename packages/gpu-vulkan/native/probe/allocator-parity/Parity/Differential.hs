{-# LANGUAGE BangPatterns #-}

-- | A self-check that the mutable prototype makes the reference's decisions.
--
-- Seeded random scripts drive the pure reference 'Block' and a
-- 'MutableBlock' in lockstep: small blocks, granularities up to 1,024, both
-- tilings, alignments up to 128, and releases of random live placements. After
-- every step the two must agree on where a request went or that it was
-- refused, and on every field of the block's usage. Every released handle is
-- then released again and must be refused, and an invalid request must be
-- rejected with the reference's answer. The traces never exercise granularity,
-- so this is where the prototype's page rule is checked.
module Parity.Differential
  ( differentialCheck
  ) where

import Control.Monad.ST (stToIO)
import Data.Bits (shiftL, shiftR, xor)
import Data.Word (Word64)
import Hetoimasia.GPU.Model.Placement
  ( Fitted (..)
  , ResourceTiling (..)
  , bestFit
  , blockUsage
  , openFixedBlock
  , placeInBlock
  , releaseInBlock
  , validateFit
  )
import Prototype.MutableBestFit

-- | Run @scripts@ seeded scripts of @steps@ steps each; answer every
-- disagreement found, at most one per script.
differentialCheck ∷ Int → Int → IO [String]
differentialCheck scripts steps = concat <$> mapM runScript [1 .. scripts]
  where
    runScript script = do
      let generator0 = splitMix (fromIntegral script * 7919)
          (capacityDraw, generator1) = next generator0
          (granularityDraw, generator2) = next generator1
          capacity = 64 + fromIntegral (capacityDraw `mod` 8129) ∷ Integer
          granularity = [1, 2, 16, 64, 256, 1024] !! fromIntegral (granularityDraw `mod` 6)
      opened ← stToIO (newMutableBlock capacity granularity)
      case (openFixedBlock bestFit capacity granularity, opened) of
        (Right reference, Right mutable) → do
          invalid ← stToIO (placeMutable mutable 0 1 LinearResource)
          let invalidAgrees = case (invalid, validateFit 0 1 LinearResource) of
                (MutableInvalid a, Left b) → a == b
                _ → False
          if not invalidAgrees
            then pure [label script "an invalid request was not rejected as the reference rejects it"]
            else go script capacity reference mutable [] (0 ∷ Int) generator2
        _ → pure [label script "the two blocks were not both opened"]
    go script capacity reference mutable live !step generator
      | step == steps = pure []
      | otherwise = do
          let (choice, generator1) = next generator
          if choice `mod` 5 < 3 || null live
            then do
              let (sizeDraw, generator2) = next generator1
                  (alignmentDraw, generator3) = next generator2
                  (tilingDraw, generator4) = next generator3
                  largest = max 1 (fromIntegral capacity `div` 3)
                  size = if sizeDraw `mod` 4 == 0 then 1 + sizeDraw `mod` 48 else 1 + sizeDraw `mod` largest
                  alignment = 1 `shiftL` fromIntegral (alignmentDraw `mod` 8)
                  tiling = if even tilingDraw then LinearResource else OptimalResource
              answer ← stToIO (placeMutable mutable size alignment tiling)
              let expected = case validateFit size alignment tiling of
                    Right fit → placeInBlock fit reference
                    Left _ → Refused
              case (expected, answer) of
                (Refused, MutableRefused) → compareUsage script step capacity reference mutable live generator4
                (Fitted offset reference', MutablePlaced allocation)
                  | allocationOffset allocation == offset →
                      compareUsage script step capacity reference' mutable ((offset, allocation) : live) generator4
                _ →
                  pure [label script ("step " <> show step <> ": the reference and the prototype placed a request differently")]
            else do
              let (pick, generator2) = next generator1
                  index = fromIntegral (pick `mod` fromIntegral (length live))
                  (offset, allocation) = live !! index
                  others = take index live <> drop (index + 1) live
              released ← stToIO (releaseMutable mutable allocation)
              again ← stToIO (releaseMutable mutable allocation)
              case releaseInBlock offset reference of
                Just reference'
                  | released && not again → compareUsage script step capacity reference' mutable others generator2
                  | again → pure [label script ("step " <> show step <> ": a released handle was released again")]
                _ → pure [label script ("step " <> show step <> ": the two refused to release the same placement differently")]
    compareUsage script step capacity reference mutable live generator = do
      usage ← stToIO (mutableUsage mutable)
      if usage == blockUsage reference
        then go script capacity reference mutable live (step + 1) generator
        else
          pure
            [ label script ("step " <> show step <> ": usage differs: reference " <> show (blockUsage reference) <> ", prototype " <> show usage)
            ]
    label script problem = "differential script " <> show script <> ": " <> problem

-- A splitmix64 generator, as the trace generator uses.
newtype SplitMix = SplitMix Word64

splitMix ∷ Word64 → SplitMix
splitMix = SplitMix

next ∷ SplitMix → (Word64, SplitMix)
next (SplitMix state) =
  let state' = state + 0x9E3779B97F4A7C15
      z1 = (state' `xor` (state' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
   in (z2 `xor` (z2 `shiftR` 31), SplitMix state')
