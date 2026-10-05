-- | An asset's identity and provenance, and the decoder interface every codec
-- package implements.
--
-- A decoder is a pure function: it is given the asset it is decoding and that
-- asset's bytes, and returns the decoded value or a refusal naming the asset
-- and the reason. Reading the bytes — from a file, an archive, the network, or
-- memory — stays with the caller, which also supplies the identity and the
-- provenance. Nothing here owns state, starts a thread or performs IO.
module Hetoimasia.Asset
  ( -- * Identity and provenance
    AssetId (..)
  , Provenance (..)
  , Asset (..)

    -- * Decoding
  , Decoder (..)
  , AssetRefusal (..)
  )
where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.Text (Text)

-- | The caller's name for an asset: whatever key its catalogue, its content
-- or its game uses. This package attaches no meaning to it beyond equality.
newtype AssetId = AssetId Text
  deriving (Eq, Ord, Show)

instance NFData AssetId where
  rnf (AssetId name) = rnf name

-- | Where an asset's bytes came from, as the caller read them.
data Provenance
  = -- | Read from this file.
    FromFile !FilePath
  | -- | Supplied from memory: embedded in a program, generated, or received.
    -- The text says from where.
    FromMemory !Text
  deriving (Eq, Ord, Show)

instance NFData Provenance where
  rnf = \case
    FromFile path → rnf path
    FromMemory origin → rnf origin

-- | The asset a decoder is decoding, as its caller identifies it. Every
-- refusal names it.
data Asset = Asset
  { assetId ∷ !AssetId
  , assetProvenance ∷ !Provenance
  }
  deriving (Eq, Ord, Show)

instance NFData Asset where
  rnf (Asset name provenance) = rnf name `seq` rnf provenance

-- | Why a decoder refused an asset's bytes. No partial value accompanies a
-- refusal.
data AssetRefusal = AssetRefusal
  { refusedAsset ∷ !Asset
  , refusalReason ∷ !Text
  }
  deriving (Eq, Show)

instance NFData AssetRefusal where
  rnf (AssetRefusal asset reason) = rnf asset `seq` rnf reason

-- | A codec: a pure function from an asset and its bytes to the decoded
-- value, or to a refusal naming that asset. The same asset and bytes always
-- give the same result, and no exception escapes a decoder.
newtype Decoder a = Decoder
  { runDecoder ∷ Asset → ByteString → Either AssetRefusal a
  }
