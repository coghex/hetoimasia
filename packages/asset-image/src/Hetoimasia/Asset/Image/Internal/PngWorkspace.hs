-- | The payload account the bounded decoder charges its buffers to, and the
-- scopes that keep that account honest.
--
-- The decoder never owns a bank. It is handed a 'PayloadAccount': two
-- operations on a bank that someone else owns (the texture pipeline of
-- LFE-16), one to ask for bytes before a buffer of that size is allocated and
-- one to give them back. This module holds only the decoder's side of that
-- contract: every reservation is paired with its release in a scope with the
-- failure table below, and a reservation the account refuses is a content
-- refusal of class @ExceededLimit LimitWorkspaceBytes@.
--
-- == The failure table
--
-- It is the table of "Hetoimasia.Foundation.Resource" restated for this
-- package, which depends on no foundation: the body's failure propagates with
-- its own type; a release that fails after a successful body fails the scope
-- and the body's result is discarded; if both fail the body's failure
-- propagates and the release's is retained beside it as a
-- 'PayloadCleanupFailure'. A refused reservation runs no release.
--
-- The reservation runs under 'mask', so a blocking account stays cancellable
-- unless the caller imposed an uninterruptible mask, with no unmasked gap
-- between a granted reservation and the protection of its release. The body
-- runs with the caller's masking state restored. A release runs under
-- 'uninterruptibleMask_': an account's release must have a controlled
-- blocking duration.
module Hetoimasia.Asset.Image.Internal.PngWorkspace
  ( PayloadStage (..)
  , PayloadAccount (..)
  , PayloadCleanupFailure (..)
  , Refusal (..)
  , withCharge
  , stageName
  )
where

import Control.Exception
  ( Exception (displayException, fromException, toException)
  , SomeAsyncException
  , SomeException (SomeException)
  , asyncExceptionFromException
  , asyncExceptionToException
  , mask
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (unless)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (cast)
import Hetoimasia.Asset.Image.PngPreflight (LimitKind (LimitWorkspaceBytes), PngRefusalClass (ExceededLimit))

-- | What a reservation is for. The stage is for the account's records and a
-- refusal's reason; the decoder's behaviour never depends on it.
data PayloadStage
  = -- | The single RGBA8 output level, kept after the decode returns.
    StageOutput
  | -- | Fixed decoder scratch: the inflater, the shared premultiplication
    -- table, the palette table and the all-zero row above each pass.
    StageScratch
  | -- | The inflated, filtered scanlines, unfiltered where they lie.
    StageWorking
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The decoder's view of its pipeline's byte bank.
--
-- @reservePayload stage n@ asks for @n > 0@ bytes and answers whether they
-- were granted: 'True' if the bank now counts them as live, 'False' (and
-- nothing counted) if they do not fit. It is called before the buffer is
-- allocated, and a buffer is allocated only after a 'True'. @releasePayload
-- stage n@ returns exactly the bytes a granted reservation took, once the
-- decoder holds no reference to the buffer. Neither is called with a size
-- other than a granted or requested one, and a release is called exactly once
-- per grant, even when the decode fails, is refused later or is cancelled.
--
-- An exception from either is a host fault, never a content refusal.
data PayloadAccount = PayloadAccount
  { reservePayload ∷ PayloadStage → Int → IO Bool
  , releasePayload ∷ PayloadStage → Int → IO ()
  }

-- | A content failure, raised inside the decoder and turned into the decode's
-- refusal at its boundary. It is not exported from the package.
data Refusal = Refusal !PngRefusalClass !Text
  deriving (Show)

instance Exception Refusal

-- | A scope's body failed and its release failed too: the body's failure and
-- the release failures retained beside it, innermost first. If the body's
-- failure was asynchronous the whole is asynchronous, so a cancellation is
-- never mistaken for anything else by a handler that tells them apart.
data PayloadCleanupFailure = PayloadCleanupFailure
  { cleanupPrimary ∷ !SomeException
  , cleanupFailures ∷ ![SomeException]
  }
  deriving (Show)

instance Exception PayloadCleanupFailure where
  toException failure
    | isAsynchronous (cleanupPrimary failure) = asyncExceptionToException failure
    | otherwise = SomeException failure
  fromException wrapped = case asyncExceptionFromException wrapped of
    Just failure → Just failure
    Nothing → case wrapped of SomeException inner → cast inner
  displayException failure =
    "payload cleanup failed after "
      <> displayException (cleanupPrimary failure)
      <> concatMap (\cleanup → "; and " <> displayException cleanup) (cleanupFailures failure)

isAsynchronous ∷ SomeException → Bool
isAsynchronous = isJust . (fromException ∷ SomeException → Maybe SomeAsyncException)

-- | The words a reason uses for a stage.
stageName ∷ PayloadStage → Text
stageName = \case
  StageOutput → "RGBA8 output"
  StageScratch → "decoder scratch"
  StageWorking → "inflated scanline"

-- | Reserve @bytes@ for a stage, run the body, and release them when it
-- returns, fails or is cancelled. With @keep@ the reservation is the
-- caller's when the body returns normally (the output), and is released only
-- when it fails.
withCharge ∷ Bool → PayloadAccount → PayloadStage → Int → IO a → IO a
withCharge keep account stage bytes body = mask $ \restore → do
  granted ← reservePayload account stage bytes
  unless granted $
    throwIO
      ( Refusal
          (ExceededLimit LimitWorkspaceBytes)
          ("the " <> stageName stage <> " buffer of " <> Text.pack (show bytes) <> " bytes does not fit the pipeline's workspace")
      )
  outcome ← try (restore body)
  case outcome of
    Right result
      | keep → pure result
      | otherwise →
          try (uninterruptibleMask_ (releasePayload account stage bytes)) >>= \case
            Right () → pure result
            Left (cleanup ∷ SomeException) → throwIO cleanup
    Left (primary ∷ SomeException) →
      try (uninterruptibleMask_ (releasePayload account stage bytes)) >>= \case
        Right () → throwIO primary
        Left (cleanup ∷ SomeException) → throwIO (retain primary cleanup)
  where
    -- Nested scopes append to the evidence and keep the first primary.
    retain primary cleanup = case fromException primary of
      Just earlier → earlier {cleanupFailures = cleanupFailures earlier <> [cleanup]}
      Nothing → PayloadCleanupFailure primary [cleanup]
