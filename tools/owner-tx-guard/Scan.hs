{-# LANGUAGE LambdaCase, MultiWayIf, NoOverloadedStrings #-}

-- | The textual scan of the issuer guard (the design's "Approved amendment · Textual issuer guard").
--
-- Every repository file at any depth whose basename ends in @.cabal@ or starts with @cabal.project@ is read, whether or
-- not a project lists or imports it. Cabal-syntax's 'readFields' only splits each file into fields and sections: a
-- stanza is one outermost section, its header and everything nested in it; a top-level field belongs to no stanza.
-- Field names, values (continuation lines joined with one space) and section headers are searched, full-line comments
-- aside, for the protected texts, ASCII case-insensitively (only @A@ to @Z@ fold), each end at the text's edge or next
-- to a character outside @[A-Za-z0-9_]@, each match located on its own line. Every branch is searched as written:
-- nothing is evaluated. A file Cabal's lexer cannot read, or reads with an ambiguous layout (tabs, inconsistent
-- indentation, braces, a non-breaking space), is unreadable; a quoted section argument, a non-ASCII field name or section
-- header, and a symbolic link met in the walk (never followed) are unsupported. Field values and comments may hold
-- non-ASCII text, and a non-ASCII character is a boundary. The guard catches accidental use of the bridge in this
-- repository; deliberate evasion is issuer review's.
module Scan
  ( Stanza (..)
  , Match (..)
  , Scanned (..)
  , protectedTexts
  , scannedFiles
  , generatedDirectories
  , scanFile
  , headerOf
  , matchesIn
  ) where

import qualified Data.ByteString as ByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, ord)
import Data.List (isPrefixOf, isSuffixOf, sort, tails)
import Distribution.Fields (Field (..), FieldLine (..), Name (..), SectionArg (..), readFields')
import Distribution.Fields.LexerMonad (LexWarning (..), LexWarningType (..))
import Distribution.Parsec.Position (Position (..))
import Distribution.Utils.Generic (fromUTF8BS)
import System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
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

-- | Every file to scan, repository-relative and sorted: at any depth, except under version-control metadata (@.git@,
-- at any depth) and the generated directories the validation catalog names at the repository's root. The skip set is
-- fixed here; no scanned file or allowlist entry extends it. A symbolic link below the root is reported wherever the
-- walk lists it, before any skip by name and whatever it points to, and never followed; the root is used as given.
scannedFiles ∷ FilePath → IO ([FilePath], [String])
scannedFiles root = (\(files, problems) → (sort files, sort problems)) <$> go ""
  where
    skipped relative entry = entry == ".git" || (null relative && entry `elem` generatedDirectories)
    go relative = do
      entries ← listDirectory (root </> relative)
      results ←
        mapM
          ( \entry → do
              let path = if null relative then entry else relative </> entry
              link ← pathIsSymbolicLink (root </> path)
              directory ← if link then pure False else doesDirectoryExist (root </> path)
              if
                | link → pure ([], [path <> ": unsupported: a symbolic link, which the guard never follows"])
                | skipped relative entry → pure ([], [])
                | directory → go path
                | ".cabal" `isSuffixOf` entry || "cabal.project" `isPrefixOf` entry → pure ([path], [])
                | otherwise → pure ([], [])
          )
          entries
      pure (concatMap fst results, concatMap snd results)

-- | The generated directories the validation catalog names (@generated_paths@), which hold build output and nested
-- worktrees rather than repository files.
generatedDirectories ∷ [FilePath]
generatedDirectories = ["dist-newstyle", "dist-dev", "dist-vulkan", "dist-vulkan-proof", ".worktrees", "captures", "receipts"]

-- | Split one file into stanzas and top-level fields and find every protected text, or say why it cannot be read or is
-- unsupported: a quoted section argument, or a non-ASCII field name or section header, anywhere is unsupported.
scanFile ∷ ByteString.ByteString → Either String Scanned
scanFile bytes = case readFields' bytes of
  Left failure → Left ("unreadable: Cabal's lexer cannot split it: " <> show failure)
  Right (fields, warnings) → case [warning | warning@(LexWarning kind _) ← warnings, kind /= LexWarningBOM] of
    LexWarning kind (Position line column) : _ → Left ("unreadable: an ambiguous stanza boundary (" <> show kind <> ") at line " <> show line <> ", column " <> show column)
    [] → case (concatMap quoted fields, concatMap nonAscii fields) of
      (line : _, _) → Left ("unsupported: a quoted section argument at line " <> show line)
      (_, line : _) → Left ("unsupported: a non-ASCII field name or section header at line " <> show line)
      ([], []) →
        Right
          Scanned
            { scannedStanzas = [Stanza (headerOf name arguments) (lineOf name) (matchesOf field) | field@(Section name arguments _) ← fields]
            , scannedTopLevel = concat [matchesOf field | field@(Field _ _) ← fields]
            }
  where
    lineOf (Name (Position line _) _) = line
    quoted = \case
      Field _ _ → []
      Section _ arguments inner → [line | SecArgStr (Position line _) _ ← arguments] <> concatMap quoted inner
    -- field values and comments may hold non-ASCII text; names and headers may not
    nonAscii = \case
      Field name@(Name (Position line _) _) _ → [line | any (> '\DEL') (headerOf name [])]
      Section name@(Name (Position line _) _) arguments inner → [line | any (> '\DEL') (headerOf name arguments)] <> concatMap nonAscii inner

-- | A section's header: its name and arguments as Cabal's lexer splits them, single spaces between.
headerOf ∷ Name Position → [SectionArg Position] → String
headerOf (Name _ name) arguments = unwords (fromUTF8BS name : map argument arguments)
  where
    argument = \case
      SecArgName _ text → fromUTF8BS text
      SecArgStr _ text → fromUTF8BS text
      SecArgOther _ text → fromUTF8BS text

-- Every protected text in a field or section, everything nested included, each on its own line.
matchesOf ∷ Field Position → [Match]
matchesOf = \case
  Field (Name (Position line _) name) contents → found line (fromUTF8BS name) <> concat [found valueLine (fromUTF8BS text) | FieldLine (Position valueLine _) text ← contents]
  Section name@(Name (Position line _) _) arguments inner → found line (headerOf name arguments) <> concatMap matchesOf inner
  where
    found line text = [Match line protected | protected ← matchesIn text]

-- | The protected texts in this text, once per occurrence.
matchesIn ∷ String → [String]
matchesIn text =
  [ protected
  | protected ← protectedTexts
  , (before, rest) ← zip (Nothing : map Just text) (tails text)
  , map asciiLower protected `isPrefixOf` map asciiLower rest
  , boundary before
  , boundary (case drop (length protected) rest of [] → Nothing; next : _ → Just next)
  ]
  where
    asciiLower c = if isAsciiUpper c then toEnum (ord c + 32) else c
    boundary = \case
      Nothing → True
      Just c → not (isAsciiLower c || isAsciiUpper c || isDigit c || c == '_')
