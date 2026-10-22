-- | What the bounded-decode examples share: the complete entry (preflight
-- under limits, then decode into a bank), a reader for its outcome, and the
-- bytes allocated while an action runs.
module Test.Asset.Image.DecodeSupport
  ( decodeAsset
  , Outcome (..)
  , decodeIn
  , decodeFresh
  , decodeFixtureBounded
  , acceptedImage
  , refusedAs
  , allocatedDuring
  , m1Bank
  , levelOf
  , chargeFor
  , fullyEvaluated
  )
where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import qualified Data.Text as Text
import GHC.Conc (getAllocationCounter, setAllocationCounter)
import GHC.Exts.Heap (Box, GenClosure (..), asBox, getBoxedClosureData)
import Hetoimasia.Asset (Asset)
import Data.Maybe (fromMaybe)
import Hetoimasia.Asset.Image (DecodedImage (decodedLevels))
import Hetoimasia.Asset.Image.PngDecode (PayloadAccount, PayloadStage, decodeBounded, decodeReservations, m1WorkspaceBytes)
import Hetoimasia.Asset.Image.PngPreflight (PngLimits, PngPreflight, PngRefusal (..), PngRefusalClass, m1PngLimits, preflightPng)
import Test.Asset.Image.PayloadLedger (Ledger, chargeCaller, ledgerAccount, newLedger)
import Test.Asset.Image.PreflightSupport (asset)
import Test.Asset.Image.Support (fixtureBytes)
import Test.Hspec (Expectation, expectationFailure, shouldBe, shouldSatisfy)

-- | The asset every example decodes as.
decodeAsset ∷ Asset
decodeAsset = asset

-- | What the complete entry gave, with the preflight when it got that far and
-- the bank it ran in.
data Outcome = Outcome
  { outcomeResult ∷ Either PngRefusal DecodedImage
  , outcomePreflight ∷ Maybe PngPreflight
  , outcomeLedger ∷ Ledger
  , outcomeSourceBytes ∷ Int
  }

-- | A bank of the M1 size.
m1Bank ∷ IO Ledger
m1Bank = newLedger m1WorkspaceBytes

-- | Preflight under limits, then decode into the bank, as a texture pipeline
-- would: the caller charges the encoded input first and keeps that charge.
decodeIn ∷ Ledger → (PayloadAccount → PayloadAccount) → PngLimits → ByteString → IO Outcome
decodeIn ledger wrap limits bytes = do
  charged ← chargeCaller ledger (ByteString.length bytes)
  charged `shouldBe` True
  case preflightPng limits decodeAsset bytes of
    Left refusal → pure (Outcome (Left refusal) Nothing ledger (ByteString.length bytes))
    Right preflighted → do
      result ← decodeBounded (wrap (ledgerAccount ledger)) preflighted
      pure (Outcome result (Just preflighted) ledger (ByteString.length bytes))

-- | The same in a fresh M1 bank under the M1 limits.
decodeFresh ∷ ByteString → IO Outcome
decodeFresh bytes = do
  ledger ← m1Bank
  decodeIn ledger id m1PngLimits bytes

decodeFixtureBounded ∷ FilePath → IO Outcome
decodeFixtureBounded name = fixtureBytes name >>= decodeFresh

-- | The decoded image, or a failed example.
acceptedImage ∷ Outcome → IO DecodedImage
acceptedImage outcome = case outcomeResult outcome of
  Right image → pure image
  Left refusal → do
    expectationFailure ("expected an image, refused as " <> show (pngRefusalClass refusal) <> ": " <> Text.unpack (pngRefusalReason refusal))
    fail "refused"

-- | The outcome is a refusal of this class, naming the asset, with a bounded
-- fixed-text reason.
refusedAs ∷ Outcome → PngRefusalClass → Expectation
refusedAs outcome expected = case outcomeResult outcome of
  Left refusal → do
    pngRefusedAsset refusal `shouldBe` decodeAsset
    pngRefusalClass refusal `shouldBe` expected
    Text.length (pngRefusalReason refusal) `shouldSatisfy` (\n → n > 0 && n < 300)
  Right image → expectationFailure ("expected a refusal of class " <> show expected <> ", decoded " <> show (force image `seq` ()))

-- | The bytes the current thread allocated while the action ran and its
-- result was evaluated by the action itself.
allocatedDuring ∷ IO a → IO (a, Int64)
allocatedDuring action = do
  setAllocationCounter 0
  result ← action
  after ← getAllocationCounter
  _ ← evaluate after
  pure (result, negate after)

-- | The one level of a decoded image.
levelOf ∷ DecodedImage → IO ByteString
levelOf image = case decodedLevels image of
  [level] → pure level
  levels → expectationFailure ("expected one level, found " <> show (length levels)) >> fail "levels"

-- | What the decoder charges for a stage of this preflight.
chargeFor ∷ PayloadStage → PngPreflight → Int
chargeFor stage preflighted = fromInteger (fromMaybe 0 (lookup stage (decodeReservations preflighted)))

-- | Whether a value is constructors all the way down: no thunk, indirection
-- to a thunk or blackhole is reachable from it. A byte array is a leaf.
fullyEvaluated ∷ a → IO Bool
fullyEvaluated = go . asBox
  where
    go ∷ Box → IO Bool
    go box =
      getBoxedClosureData box >>= \case
        IndClosure {indirectee = next} → go next
        BlackholeClosure {indirectee = next} → go next
        ConstrClosure {ptrArgs = fields} → and <$> mapM go fields
        ArrWordsClosure {} → pure True
        _ → pure False
