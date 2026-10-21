-- | The canonical encoding of the sample's authoritative state, and its SHA-256 digest (#500 requirements 1
-- and 2; D-23, D-45).
--
-- = What it is for
--
-- D-23's qualification compares the authoritative state of repeated executions at logical boundaries. The
-- comparison is of these digests: one pure function turns what the driver has committed (or published to end the
-- session) into bytes, and the digest is SHA-256 of them. It claims what D-23 claims: the same build and platform.
-- Nothing here is a value across platforms or versions, and no digest of a whole run is committed anywhere; the
-- only pinned digests are those of two hand-built states in the examples.
--
-- = The format (version 1)
--
-- Every integer is fixed-width and big-endian, every sequence is length-prefixed and in a fixed order, and
-- nothing is rendered by @show@, floating point or the iteration order of a map or a set:
--
-- @
-- format        "HLDS" (4 bytes), version u16 = 1
-- tick          u64   the committed tick (unchanged by a failure or a stop)
-- random        u64   the random stream's state
-- entities      u32 count, then for each, by index:  x i64, y i64, version u64
-- status        u8 kind: 0 running, 1 paused, 2 failed, 3 stopped
--               failed only: u64 the failing tick, u8 the failing phase's kind (below)
-- applied       u32 count, then each place:           tick u64, order u32
-- stale         u32 count, then each, in place order: tick u64, order u32, reason u8 (0 session, 1 version),
--                                                     entity u32, version u64, dx i64, dy i64
--               u32 the number of stale rejections that did not fit the list
-- invalidated   u32 count, then each place; u32 the number not listed
-- discarded     u32 count, then each place; u32 the number not listed
-- @
--
-- A failing phase's kind is one byte: 1 initializing, 2 active, 3 paused, 4 stopping, 5 completed, 6 stopped,
-- 7 failed, 8 a task (which has no phase), and 0 for a phase this version has no tag for.
--
-- = What it covers, and what it leaves out
--
-- It covers the world (the entities in index order, each with its position and version), the committed tick, the
-- random stream's state, the dispositions in place order and the session's status kind, with the failing tick and
-- the failing phase's kind for a failure. It leaves out everything that is run-local identity or text a script
-- chose: the session's identity, the gameplay behavior's instance identity, the owner's identity, the failure's
-- message, its stage and its kind (script-controlled text), the number of later failures, the stale intention's own
-- session and the tick of the view it acted on (informational), tracebacks and timestamps, and the snapshot's
-- revision, which is a property of the publication and not of the state. Two snapshots that differ in nothing the
-- format covers have the same digest, whichever run published them.
module Hetoimasia.Sample.LuaDomains.Canonical
  ( -- * Digests
    Digest
  , digestBytes
  , digestHex
  , parseDigest
  , digestLength
    -- * The encoding
  , formatTag
  , formatVersion
  , encodeSnapshot
  , digestSnapshot
  , digestOf
    -- * Comparing traces
  , firstDivergence
  ) where

import Control.DeepSeq (NFData (rnf))
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder (Builder, byteString, int64BE, toLazyByteString, word16BE, word32BE, word64BE, word8)
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (digitToInt, isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word16, Word8)
import Hetoimasia.Sample.LuaDomains.Intention
  ( Dispositions (..)
  , Intention (..)
  , Placement (..)
  , Stale (..)
  , StaleReason (..)
  )
import Hetoimasia.Sample.LuaDomains.Snapshot
  ( FailureEvidence (..)
  , GameSnapshot (..)
  , SessionFailure (..)
  , SessionStatus (..)
  )
import Hetoimasia.Sample.LuaDomains.World (Entity (..), World (..))

-- | A SHA-256 digest: exactly 'digestLength' bytes.
newtype Digest = Digest ByteString
  deriving (Eq, Ord)

instance Show Digest where
  show digest = "Digest " <> Text.unpack (digestHex digest)

instance NFData Digest where
  rnf (Digest bytes) = rnf bytes

-- | The length of a digest, in bytes.
digestLength ∷ Int
digestLength = 32

-- | The digest's bytes.
digestBytes ∷ Digest → ByteString
digestBytes (Digest bytes) = bytes

-- | The digest as 64 lowercase hexadecimal digits.
digestHex ∷ Digest → Text
digestHex (Digest bytes) = Text.pack (concatMap hexByte (ByteString.unpack bytes))
  where
    hexByte byte = [hexDigit (byte `div` 16), hexDigit (byte `mod` 16)]
    hexDigit n = "0123456789abcdef" !! fromIntegral n

-- | A digest from 64 hexadecimal digits, in either case; nothing else is one.
parseDigest ∷ String → Maybe Digest
parseDigest text
  | length text == 2 * digestLength && all isHex text = Just (Digest (ByteString.pack (pairs (map (fromIntegral . digitToInt) text))))
  | otherwise = Nothing
  where
    isHex c = isDigit c || (isAsciiLower c && c <= 'f') || (isAsciiUpper c && c <= 'F')
    pairs (a : b : rest) = (a `shiftL` 4 .|. b ∷ Word8) : pairs rest
    pairs _ = []

-- | The four bytes that open every encoding.
formatTag ∷ ByteString
formatTag = "HLDS"

-- | The format's version: a change to anything the encoding covers or its layout is a new version.
formatVersion ∷ Word16
formatVersion = 1

-- | SHA-256 of some bytes.
digestOf ∷ ByteString → Digest
digestOf = Digest . SHA256.hash

-- | The canonical encoding of a published snapshot.
encodeSnapshot ∷ GameSnapshot → ByteString
encodeSnapshot snapshot = Lazy.toStrict (toLazyByteString built)
  where
    world = snapWorld snapshot
    built =
      byteString formatTag
        <> word16BE formatVersion
        <> word64BE (worldTick world)
        <> word64BE (worldRandom world)
        <> counted (toList (worldEntities world)) entity
        <> status (snapStatus snapshot)
        <> dispositions (snapDispositions snapshot)
    entity (Entity x y version) = int64BE x <> int64BE y <> word64BE version

-- | The digest of a published snapshot.
digestSnapshot ∷ GameSnapshot → Digest
digestSnapshot = digestOf . encodeSnapshot

-- | The status kind, and for a failure the failing tick and the failing phase's kind.
status ∷ SessionStatus → Builder
status = \case
  Running → word8 0
  Paused → word8 1
  Failed evidence →
    let primary = evidencePrimary evidence
     in word8 2 <> word64BE (failTick primary) <> word8 (phaseKind (failPhase primary))
  Stopped → word8 3

-- | The tag of a failing phase, from the word the evidence carries.
phaseKind ∷ Text → Word8
phaseKind phase = maybe 0 id (lookup phase [("initializing", 1), ("active", 2), ("paused", 3), ("stopping", 4), ("completed", 5), ("stopped", 6), ("failed", 7), ("task", 8)])

dispositions ∷ Dispositions → Builder
dispositions d =
  counted (dispApplied d) place
    <> counted (dispStale d) staleEntry
    <> omitted (dispStaleOmitted d)
    <> counted (dispInvalidated d) place
    <> omitted (dispInvalidatedOmitted d)
    <> counted (dispDiscarded d) place
    <> omitted (dispDiscardedOmitted d)
  where
    omitted = word32BE . fromIntegral

place ∷ Placement → Builder
place (Placement tick order) = word64BE tick <> word32BE order

staleEntry ∷ Stale → Builder
staleEntry (Stale at intention reason) =
  place at
    <> word8 (case reason of StaleSession → 0; StaleVersion → 1)
    <> word32BE (fromIntegral (intentEntity intention))
    <> word64BE (intentVersion intention)
    <> int64BE (intentDx intention)
    <> int64BE (intentDy intention)

-- | A length-prefixed sequence.
counted ∷ [a] → (a → Builder) → Builder
counted items each = word32BE (fromIntegral (length items)) <> foldMap each items

-- | The first position at which two traces differ, or 'Nothing' if they are the same: one trace that is a prefix of the
-- other differs at the first position the shorter lacks.
firstDivergence ∷ [Digest] → [Digest] → Maybe Int
firstDivergence = go 0
  where
    go _ [] [] = Nothing
    go position (a : as) (b : bs)
      | a == b = go (position + 1) as bs
    go position _ _ = Just (position ∷ Int)
