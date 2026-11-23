{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's policy: every protected text found by the scan must lie in a stanza
-- @tools/validation/owner-tx-issuers.fields@ lists, and every listed stanza must hold one.
module Policy
  ( Allowlist (..)
  , Entry (..)
  , readAllowlist
  , check
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as Map
import Distribution.Fields (Field (..), FieldLine (..), Name (..), readFields)
import Distribution.Utils.Generic (fromUTF8BS)
import Scan

-- | One listed stanza: a repository-relative file and the stanza's header.
data Entry = Entry
  { entryFile ∷ FilePath
  , entryStanza ∷ String
  }
  deriving (Eq, Ord, Show)

newtype Allowlist = Allowlist {allowedStanzas ∷ [Entry]}

-- | Read the allowlist with Cabal's own field parser: only @entry@ sections, each with exactly one nonempty @file@,
-- @stanza@ and @reason@ and nothing else; an entry listed twice, by file and stanza, makes it unreadable.
--
-- > entry
-- >   file: packages/foundation/hetoimasia-foundation.cabal
-- >   stanza: library owner-tx-issuer
-- >   reason: the issuer bridge's definition
readAllowlist ∷ ByteString.ByteString → Either String Allowlist
readAllowlist bytes = do
  fields ← either (\failure → Left ("Cabal's field parser refused it: " <> show failure)) Right (readFields bytes)
  entries ← forM fields $ \case
    Section (Name _ section) [] inner | fromUTF8BS section == "entry" → do
      let values key = [unwords [fromUTF8BS line | FieldLine _ line ← contents] | Field (Name _ name) contents ← inner, fromUTF8BS name == key]
          others = [fromUTF8BS name | Field (Name _ name) _ ← inner, fromUTF8BS name `notElem` ["file", "stanza", "reason"]] <> ["a section" | Section {} ← inner]
      case (values "file", values "stanza", values "reason", others) of
        ([file], [stanza], [reason], [])
          | any (`elem` " \t\"'") file || any (`elem` "\"'") stanza || stanza /= unwords (words stanza) →
              Left ("unsupported: a file with a space or a quote, or a stanza with a quote or a space that is not one separator between tokens: " <> show (file, stanza))
          | not (null file) && not (null stanza) && not (null (words reason)) →
              Right (Entry file stanza)
        _ → Left ("an entry needs exactly one nonempty file, stanza and reason, and nothing else: " <> show (values "file", values "stanza", others))
    Section (Name _ name) _ _ → Left ("the section " <> fromUTF8BS name <> " is not an entry section with no arguments")
    Field (Name _ name) _ → Left ("the field " <> fromUTF8BS name <> " is outside an entry section")
  case [entry | (entry, count) ← Map.toList (Map.fromListWith (+) [(e, 1 ∷ Int) | e ← entries]), count > 1] of
    [] → Right (Allowlist entries)
    repeated → Left ("an entry listed more than once: " <> intercalate "; " [entryFile e <> " (" <> entryStanza e <> ")" | e ← repeated])

-- | Every problem: a file that cannot be read, a protected text outside a listed stanza, an entry naming more than one
-- stanza, and a stale entry.
check ∷ Allowlist → [(FilePath, Either String Scanned)] → [String]
check allowlist files =
  unreadable <> outside <> ambiguous <> stale
  where
    entries = allowedStanzas allowlist
    scanned = Map.fromList [(path, result) | (path, Right result) ← files]
    unreadable = [path <> ": " <> why | (path, Left why) ← files]
    listed path stanza = Entry path (stanzaHeader stanza) `elem` entries
    outside =
      concat
        [ [ path <> ":" <> show (matchLine match) <> ": " <> matchText match <> " at the top level, outside any listed stanza"
          | match ← scannedTopLevel result
          ]
            <> [ path <> ":" <> show (matchLine match) <> ": " <> matchText match <> " in the stanza " <> stanzaHeader stanza <> ", which the allowlist does not list"
               | stanza ← scannedStanzas result
               , not (listed path stanza)
               , match ← stanzaMatches stanza
               ]
        | (path, result) ← Map.toList scanned
        ]
    stanzasOf entry = maybe [] (\result → [stanza | stanza ← scannedStanzas result, stanzaHeader stanza == entryStanza entry]) (Map.lookup (entryFile entry) scanned)
    ambiguous =
      [ entryFile entry <> ": the allowlist entry for " <> entryStanza entry <> " names " <> show (length found) <> " stanzas (lines " <> intercalate ", " (map (show . stanzaLine) found) <> ")"
      | entry ← entries
      , let found = stanzasOf entry
      , length found > 1
      ]
    stale =
      nub
        [ entryFile entry <> ": the allowlist entry for " <> entryStanza entry <> " is stale: " <> why
        | entry ← entries
        , Just why ← [staleness entry]
        ]
    staleness entry
      | entryFile entry `notElem` map fst files = Just "no scanned file has that path"
      | Map.notMember (entryFile entry) scanned = Nothing
      | null (stanzasOf entry) = Just "the file has no stanza with that header"
      | all (null . stanzaMatches) (stanzasOf entry) = Just "the stanza mentions no protected text"
      | otherwise = Nothing
