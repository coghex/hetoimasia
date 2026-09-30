-- | A committed trace, parsed and checked before anything is timed.
--
-- The format is line-oriented text (README.md states it in full): @#@ comments,
-- a @trace@, @capacity@ and @seed@ header, then one operation per line —
-- @a ID SIZE ALIGNMENT@, @f ID@ or @c LABEL@. Parsing and checking happen here,
-- once, so neither replay spends a timed interval on them.
module Parity.Trace
  ( Trace (..)
  , OpKind (..)
  , readTrace
  , opKind
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.IntSet as IntSet
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Model.Placement (ResourceTiling (OptimalResource), validateFit)
import Numeric (showHex)

-- | A parsed trace. Operations are stored column-wise; an operation's
-- identity is its allocation's for @a@ and @f@, and the checkpoint's ordinal
-- for @c@.
data Trace = Trace
  { traceName ∷ !String
  , traceCapacity ∷ !Word64
  , traceSeed ∷ !Word64
  , traceDigest ∷ !String
    -- ^ The SHA-256 of the file's bytes.
  , traceKinds ∷ !(Unboxed.Vector Word32)
  , traceIds ∷ !(Unboxed.Vector Word32)
  , traceSizes ∷ !(Unboxed.Vector Word64)
  , traceAlignments ∷ !(Unboxed.Vector Word64)
  , traceIdentities ∷ !Int
    -- ^ How many allocation identities the trace issues.
  , traceCheckpoints ∷ ![String]
  , traceNotes ∷ ![String]
    -- ^ The file's comment lines after the format line: its derivation and
    -- the assumptions it was generated under.
  }

-- | What an operation does.
data OpKind = Allocate | Free | Checkpoint
  deriving (Eq, Show)

opKind ∷ Word32 → OpKind
opKind 0 = Allocate
opKind 1 = Free
opKind _ = Checkpoint
{-# INLINE opKind #-}

data Row = Row !Word32 !Word32 !Word64 !Word64

-- | Parse and check a trace file. Identities must be issued densely from zero,
-- each freed at most once and only after it was allocated, and every request
-- must be one placement accepts, so a replay never meets a malformed step.
readTrace ∷ FilePath → IO Trace
readTrace path = do
  bytes ← ByteString.readFile path
  let digest = concatMap hex (ByteString.unpack (SHA256.hash bytes))
      hex byte = let s = showHex byte "" in if length s == 1 then '0' : s else s
      numbered = zip [1 ∷ Int ..] (map Char8.unpack (Char8.lines bytes))
      content = filter (not . isComment) numbered
      isComment (_, line) = null (words line) || take 1 line == "#"
      notes = drop 1 [dropWhile (== ' ') (drop 1 line) | (_, line) ← numbered, take 1 line == "#"]
  case content of
    (_, nameLine) : (_, capacityLine) : (_, seedLine) : body → do
      name ← header "trace" nameLine
      capacity ← read <$> header "capacity" capacityLine
      seed ← read <$> header "seed" seedLine
      (rows, identities, labels) ← either (fail . ((path <> ": ") <>)) pure (parseBody body)
      let column ∷ Unboxed.Unbox a ⇒ (Row → a) → Unboxed.Vector a
          column f = Unboxed.fromList (map f rows)
      pure
        Trace
          { traceName = name
          , traceCapacity = capacity
          , traceSeed = seed
          , traceDigest = digest
          , traceKinds = column (\(Row k _ _ _) → k)
          , traceIds = column (\(Row _ i _ _) → i)
          , traceSizes = column (\(Row _ _ s _) → s)
          , traceAlignments = column (\(Row _ _ _ a) → a)
          , traceIdentities = identities
          , traceCheckpoints = labels
          , traceNotes = notes
          }
    _ → fail (path <> ": a trace needs a trace, capacity and seed header")
  where
    header key line = case words line of
      [key', value] | key' == key → pure value
      _ → fail (path <> ": expected '" <> key <> " VALUE', found " <> show line)

parseBody ∷ [(Int, String)] → Either String ([Row], Int, [String])
parseBody body = finish <$> foldl' step (Right ([], 0, IntSet.empty, [])) body
  where
    finish (rows, next, _, labels) = (reverse rows, next, reverse labels)
    step (Left problem) _ = Left problem
    step (Right (rows, next, live, labels)) (lineNumber, line) =
      case words line of
        ["a", identity, size, alignment]
          | read identity /= next → bad "allocation identities must be issued densely from zero"
          | Left rejection ← validateFit (read size) (read alignment) OptimalResource → bad (show rejection)
          | otherwise →
              Right (Row 0 (fromIntegral next) (read size) (read alignment) : rows, next + 1, IntSet.insert next live, labels)
        ["f", identity]
          | not (IntSet.member (read identity) live) → bad "freed an identity that is not live"
          | otherwise → Right (Row 1 (read identity) 0 0 : rows, next, IntSet.delete (read identity) live, labels)
        ["c", label] → Right (Row 2 (fromIntegral (length labels)) 0 0 : rows, next, live, label : labels)
        _ → bad ("unrecognised line " <> show line)
      where
        bad problem = Left ("line " <> show lineNumber <> ": " <> problem)
