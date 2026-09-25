-- | The consent gate every native example passes before its body runs.
--
-- Consent is read once, at the start of the process ("Test.GPU.Vulkan.Native.Consent").
-- An example that would enter the shared session or start a child asks the
-- gate first, so without consent no body forks, waits, dispatches or launches:
-- it fails with 'NativeSessionRefused' before any of that, and the run counts
-- the refusal. The shared fixture's owner asks again before it initializes
-- anything, so an operation that reached it some other way is still refused
-- before a native step.
module Test.GPU.Vulkan.Native.Gate
  ( Gate
  , newGate
  , gateConsent
  , admit
  , refusals
  , NativeSessionRefused (..)
  ) where

import Control.Exception (Exception (..), throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Text as Text

import Test.GPU.Vulkan.Native.Consent (Consent, Refusal, refusalMessage)

data Gate = Gate
  { gateConsent ∷ !(Either Refusal Consent)
  , gateRefusals ∷ !(IORef Int)
  }

newGate ∷ Either Refusal Consent → IO Gate
newGate consent = Gate consent <$> newIORef 0

-- | An example, or the owner, asked for a native session this run was not
-- authorized to enter.
newtype NativeSessionRefused = NativeSessionRefused Refusal
  deriving (Show)

instance Exception NativeSessionRefused where
  displayException (NativeSessionRefused refusal) = Text.unpack (refusalMessage refusal)

-- | The run's consent, or a refusal counted and thrown.
admit ∷ Gate → IO Consent
admit gate = case gateConsent gate of
  Right consent → pure consent
  Left refusal → do
    atomicModifyIORef' (gateRefusals gate) (\count → (count + 1, ()))
    throwIO (NativeSessionRefused refusal)

-- | How many times the gate refused.
refusals ∷ Gate → IO Int
refusals = readIORef . gateRefusals
