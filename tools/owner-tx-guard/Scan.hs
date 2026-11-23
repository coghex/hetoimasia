{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The textual scan of the issuer guard (the design's "Approved amendment · Textual issuer guard").
--
-- Every repository file at any depth whose basename ends in @.cabal@ or starts with @cabal.project@ is read, whether or
-- not a project lists or imports it. Cabal-syntax's 'readFields' only splits each file into fields and sections: a
-- stanza is one outermost section, its header and everything nested in it; a top-level field belongs to no stanza.
-- Field names, values (continuation lines joined with one space) and section headers are searched, full-line comments
-- aside, for the protected texts, ASCII case-insensitively, each end at the text's edge or next to a character outside
-- @[A-Za-z0-9_]@. Every branch is searched as written: nothing is evaluated. A file Cabal's lexer cannot read, or reads
-- with an ambiguous layout (tabs, inconsistent indentation, braces, a non-breaking space), is unreadable.
module Scan
  ( Stanza (..)
  , Match (..)
  , Scanned (..)
  , protectedTexts
  , scannedFiles
  , scanFile
  , headerOf
  , matchesIn
  ) where

import qualified Data.ByteString as ByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.List (isPrefixOf, isSuffixOf, sort, tails)
import Distribution.Fields (Field (..), FieldLine (..), Name (..), SectionArg (..), readFields')
import Distribution.Fields.LexerMonad (LexWarning (..), LexWarningType (..))
import Distribution.Parsec.Position (Position (..))
import Distribution.Utils.Generic (fromUTF8BS)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

-- | The texts that may appear only inside a listed stanza.
protectedTexts ∷ [String]
protectedTexts = ["owner-tx-issuer", "Hetoimasia.Foundation.OwnerTx.Issuer", "Hetoimasia.Foundation.OwnerTx.Representation"]

-- | One outermost section of a file: its header (section name and arguments, single spaces between) and line.
data Stanza = Stanza
  { stanzaHeader ∷ String
  , stanzaLine ∷ Int
  , stanzaMatches ∷ [Match]
  }

-- | One occurrence of a protected text.
data Match = Match
  { matchLine ∷ Int
  , matchText ∷ String
  }
  deriving (Eq, Show)

-- | What a file holds: its stanzas, and the matches outside any stanza.
data Scanned = Scanned
  { scannedStanzas ∷ [Stanza]
  , scannedTopLevel ∷ [Match]
  }

-- | Every file to scan, repository-relative and sorted: at any depth, the version-control directory aside.
scannedFiles ∷ FilePath → IO [FilePath]
scannedFiles root = sort <$> go ""
  where
    go relative = do
      entries ← listDirectory (root </> relative)
      concat
        <$> mapM
          ( \entry → do
              let path = if null relative then entry else relative </> entry
              directory ← doesDirectoryExist (root </> path)
              if directory
                then if entry == ".git" then pure [] else go path
                else pure [path | ".cabal" `isSuffixOf` entry || "cabal.project" `isPrefixOf` entry]
          )
          entries

-- | Split one file into stanzas and top-level fields and find every protected text, or say why it cannot be read.
scanFile ∷ ByteString.ByteString → Either String Scanned
scanFile bytes = case readFields' bytes of
  Left failure → Left ("Cabal's lexer cannot split it: " <> show failure)
  Right (fields, warnings) → case [warning | warning@(LexWarning kind _) ← warnings, kind /= LexWarningBOM] of
    LexWarning kind (Position line column) : _ → Left ("an ambiguous stanza boundary (" <> show kind <> ") at line " <> show line <> ", column " <> show column)
    [] →
      Right
        Scanned
          { scannedStanzas = [Stanza (headerOf name arguments) (lineOf name) (matchesOf field) | field@(Section name arguments _) ← fields]
          , scannedTopLevel = concat [matchesOf field | field@(Field _ _) ← fields]
          }
  where
    lineOf (Name (Position line _) _) = line

-- | A section's header: its name and arguments as Cabal's lexer splits them, single spaces between, a quoted argument
-- in quotes.
headerOf ∷ Name Position → [SectionArg Position] → String
headerOf (Name _ name) arguments = unwords (fromUTF8BS name : map argument arguments)
  where
    argument = \case
      SecArgName _ text → fromUTF8BS text
      SecArgStr _ text → show (fromUTF8BS text)
      SecArgOther _ text → fromUTF8BS text

-- Every protected text in a field or section, everything nested included.
matchesOf ∷ Field Position → [Match]
matchesOf = \case
  Field (Name (Position line _) name) contents →
    found line (fromUTF8BS name)
      <> case contents of
        [] → []
        FieldLine (Position first _) _ : _ → found first (unwords [fromUTF8BS text | FieldLine _ text ← contents])
  Section name@(Name (Position line _) _) arguments inner → found line (headerOf name arguments) <> concatMap matchesOf inner
  where
    found line text = [Match line protected | protected ← matchesIn text]

-- | The protected texts in this text, once per occurrence.
matchesIn ∷ String → [String]
matchesIn text =
  [ protected
  | protected ← protectedTexts
  , (before, rest) ← zip (Nothing : map Just text) (tails text)
  , map toLower protected `isPrefixOf` map toLower rest
  , boundary before
  , boundary (case drop (length protected) rest of [] → Nothing; next : _ → Just next)
  ]
  where
    boundary = \case
      Nothing → True
      Just c → not (isAsciiLower c || isAsciiUpper c || isDigit c || c == '_')
