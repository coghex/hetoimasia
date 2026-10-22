-- | The manifest and entry boot checkpoint: the CPU composition of the strict
-- manifest parser with the generic content inventory, run before any authored
-- Lua.
--
-- __Contract.__ A launcher opens the content root once, scans it into an
-- 'Inventory' ("Hetoimasia.Content.Inventory"), and then asks this module to
-- prove, from that inventory alone, that the folder can boot:
--
-- 1. @hetoimasia.json@ names an inventoried regular file within the manifest
--    limit (64 KiB under the fixed profile), judged from the inventory before a
--    byte is read, and exactly that spelling: a missing file, a directory, and a
--    root that holds only @Hetoimasia.json@ all fail, and no other spelling and
--    no parent folder is searched.
-- 2. Its bytes are read by a verified read, the only way bytes leave an
--    inventoried file, and are compared once more with the inventoried length
--    and digest. The manifest is then parsed from /those pinned bytes/, never
--    from a preliminary read, and no reserialized JSON is ever compared. A
--    manifest parsed from revision A, with revision B pinned by the scan, is
--    refused by 'checkManifestPinned' whether or not the two documents are valid
--    or equivalent.
-- 3. Every entry text the manifest declares, including a common @entry@ that
--    every selected role overrides, is a valid literal root-relative reference
--    under the content identity policy and names an inventoried regular file.
--
-- It evaluates, parses and compiles no Lua, starts no VM, worker, window or
-- launcher command, and claims nothing about the behavior of an entry. On
-- success it returns the manifest, the content key of every declared entry and
-- the key each selected role will load, which the later launcher consumes under
-- the root owner it already holds. Nothing here opens, closes or caches a
-- handle: the reader is a narrow service the caller passes in, normally the
-- inventory's own verified read over its open root.
--
-- __Ownership.__ A 'Checkpoint' is immutable data. The inventory and the root
-- belong to the caller, who keeps the root open for the session.
module Hetoimasia.LuaEngine.Boot
  ( -- * Configuration
    ContentConfiguration (..)
  , contentConfiguration
  , ConfigurationRefusal (..)

    -- * The checkpoint
  , VerifiedReader
  , bootCheckpoint
  , bootCheckpointFrom
  , checkManifestPinned
  , manifestFileName
  , Checkpoint (..)
  , ResolvedEntry (..)

    -- * Refusals
  , BootRefusal (..)
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Content (ContentLimits, ContentRoot, contentLimits)
import Hetoimasia.Content.Identity (ContentKey, IdentityLimits, ReferenceRefusal, parseReference, parseReferenceText)
import Hetoimasia.Content.Inventory
  ( Inventory
  , InventoryLimits
  , InventorySpec (..)
  , InventoryLimitsRefusal
  , Presence (..)
  , ReadFailure
  , bytesMatch
  , inspectEntry
  , inventoryIdentityLimits
  , inventoryLimits
  , inventoryLimitsOf
  , inventoryRootKey
  , readVerified
  )
import Hetoimasia.LuaEngine.Manifest
  ( DeclaredEntry (..)
  , EntrySlot
  , GameplayRole (..)
  , Manifest (..)
  , ManifestError
  , PresentationRole (..)
  , Role (..)
  , RoleSelection (..)
  , declaredEntries
  , parseManifestWith
  )
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (..)
  , Profile
  , bytesLimit
  , countLimit
  )

-- | The two limit values the content layer is configured with, derived from
-- one profile. The content package holds no default of its own: the fixed M1
-- profile, or a validated smaller one, is the only source.
data ContentConfiguration = ContentConfiguration
  { configContentLimits ∷ !ContentLimits
  -- ^ For opening the root: the path depth is the profile's segment limit and
  -- the read chunk is its streaming buffer.
  , configInventoryLimits ∷ !InventoryLimits
  -- ^ For the scan and for parsing references.
  }
  deriving (Eq, Show)

-- | Why a profile cannot configure the content layer.
data ConfigurationRefusal
  = -- | A profile value does not fit a machine integer.
    LimitDoesNotFit !Word64
  | -- | The content layer refused the numbers.
    InventoryLimitsRefused !InventoryLimitsRefusal
  | -- | The path depth or buffer is not positive.
    ContentLimitsRefused !Int !Int
  deriving (Eq, Show)

-- | Configure the content layer from a profile: 10,000 entries including the
-- root, 32 segments, 1,024 path bytes and 255 per segment, 64 MiB per file,
-- 1 GiB per root and a 64 KiB buffer under the fixed M1 profile.
contentConfiguration ∷ Profile → Either ConfigurationRefusal ContentConfiguration
contentConfiguration profile = do
  entries ← narrow (let Count n = countLimit profile InventoryEntries in n)
  segments ← narrow (let Count n = countLimit profile PathSegments in n)
  pathBytes ← bytesOf PathBytes
  segmentBytes ← bytesOf PathSegmentBytes
  fileBytes ← bytesOf HashFileBytes
  rootBytes ← bytesOf HashRootBytes
  bufferBytes ← bytesOf HashBufferBytes
  inventory ←
    either (Left . InventoryLimitsRefused) Right . inventoryLimits $
      InventorySpec
        { specEntries = entries
        , specSegments = segments
        , specPathBytes = pathBytes
        , specSegmentBytes = segmentBytes
        , specFileBytes = fileBytes
        , specRootBytes = rootBytes
        , specBufferBytes = bufferBytes
        }
  content ← maybe (Left (ContentLimitsRefused segments bufferBytes)) Right (contentLimits segments bufferBytes)
  pure ContentConfiguration {configContentLimits = content, configInventoryLimits = inventory}
  where
    bytesOf limit = let Bytes n = bytesLimit profile limit in narrow n
    narrow n
      | n > fromIntegral (maxBound ∷ Int) = Left (LimitDoesNotFit n)
      | otherwise = Right (fromIntegral n)

-- | The one file name the launcher reads, exactly this spelling.
manifestFileName ∷ ByteString
manifestFileName = Char8.pack "hetoimasia.json"

-- | The narrow service a checkpoint reads the manifest through: a verified read
-- of a key within a byte ceiling. The inventory's own is
-- @'readVerified' inventory root@.
type VerifiedReader = ContentKey → Int → IO (Either ReadFailure ByteString)

-- | A declared entry that passed: where it was written, its text exactly as
-- declared, its content key and its inventoried length.
data ResolvedEntry = ResolvedEntry
  { resolvedSlot ∷ !EntrySlot
  , resolvedText ∷ !Text
  , resolvedKey ∷ !ContentKey
  , resolvedLength ∷ !Word64
  }
  deriving (Eq, Show)

-- | What a successful checkpoint hands the launcher.
data Checkpoint = Checkpoint
  { checkpointManifest ∷ !Manifest
  -- ^ Parsed from the pinned, verified bytes.
  , checkpointManifestKey ∷ !ContentKey
  , checkpointEntries ∷ ![ResolvedEntry]
  -- ^ Every declared entry in 'declaredEntries' order, a common entry that
  -- every role overrides included.
  , checkpointRoleEntries ∷ ![(Role, ContentKey)]
  -- ^ The key each selected role loads, gameplay before presentation. Nothing
  -- has been evaluated, parsed as Lua or compiled.
  }
  deriving (Eq, Show)

-- | Why a folder cannot boot. Each carries bounded evidence; none is a cleanup
-- failure, a cancellation or an engine defect, which propagate as exceptions.
data BootRefusal
  = -- | The manifest's name is not a valid reference under the limits in force.
    ManifestNameRefused !ReferenceRefusal
  | -- | No @hetoimasia.json@ in the inventory: absent, or only a spelling that
    -- differs in case.
    ManifestAbsent
  | -- | An inventoried directory has the manifest's name.
    ManifestNotAFile
  | -- | The inventoried length exceeds the manifest limit: the length and the
    -- limit. Decided before any read.
    ManifestOverLimit !Word64 !Int
  | -- | The verified read refused: the content changed since the scan, or could
    -- not be read.
    ManifestReadRefused !ReadFailure
  | -- | The bytes in hand are not the bytes the scan pinned.
    ManifestNotPinned
  | -- | The pinned bytes are not a valid manifest.
    ManifestRefused !ManifestError
  | -- | A declared entry text is not a valid literal reference.
    EntryReferenceRefused !EntrySlot !ReferenceRefusal
  | -- | A declared entry names nothing in the inventory.
    EntryAbsent !EntrySlot !ContentKey
  | -- | A declared entry names an inventoried directory.
    EntryNotAFile !EntrySlot !ContentKey
  deriving (Eq, Show)

-- | The manifest's key within the inventory's root.
manifestKey ∷ Inventory → Either BootRefusal ContentKey
manifestKey inventory =
  either (Left . ManifestNameRefused) Right (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory) manifestFileName)

-- | Whether a parsed manifest is the one the scan pinned: its exact bytes must
-- have the inventoried length and digest of @hetoimasia.json@. Nothing is
-- reserialized or compared as JSON, so two documents that parse alike but
-- differ in a byte are different here.
checkManifestPinned ∷ Inventory → Manifest → Either BootRefusal ()
checkManifestPinned inventory manifest = do
  key ← manifestKey inventory
  case inspectEntry inventory key of
    Absent → Left ManifestAbsent
    PresentDirectory → Left ManifestNotAFile
    PresentFile _
      | bytesMatch inventory key (manifestBytes manifest) → Right ()
      | otherwise → Left ManifestNotPinned

-- | Run the checkpoint through a verified reader.
bootCheckpoint ∷ Profile → Inventory → VerifiedReader → IO (Either BootRefusal Checkpoint)
bootCheckpoint profile inventory reader =
  case manifestKey inventory of
    Left refusal → pure (Left refusal)
    Right key → case inspectEntry inventory key of
      Absent → pure (Left ManifestAbsent)
      PresentDirectory → pure (Left ManifestNotAFile)
      PresentFile size
        | size > fromIntegral ceiling' → pure (Left (ManifestOverLimit size ceiling'))
        | otherwise →
            reader key ceiling' >>= \case
              Left refusal → pure (Left (ManifestReadRefused refusal))
              Right bytes
                | not (bytesMatch inventory key bytes) → pure (Left ManifestNotPinned)
                | otherwise →
                    pure $ case parseManifestWith profile bytes of
                      Left refusal → Left (ManifestRefused refusal)
                      Right manifest → resolveEntries inventory key manifest
  where
    Bytes limit = bytesLimit profile ManifestBytes
    ceiling' = fromIntegral (min limit (fromIntegral (maxBound ∷ Int))) ∷ Int

-- | Run the checkpoint through the inventory's own verified read over its root.
bootCheckpointFrom ∷ Profile → ContentRoot → Inventory → IO (Either BootRefusal Checkpoint)
bootCheckpointFrom profile root inventory = bootCheckpoint profile inventory (readVerified inventory root)

-- | Validate every declared entry and choose each selected role's.
resolveEntries ∷ Inventory → ContentKey → Manifest → Either BootRefusal Checkpoint
resolveEntries inventory key manifest = do
  resolved ← traverse resolve (declaredEntries manifest)
  let byText = Map.fromList [(resolvedText entry, resolvedKey entry) | entry ← resolved]
  pure
    Checkpoint
      { checkpointManifest = manifest
      , checkpointManifestKey = key
      , checkpointEntries = resolved
      , checkpointRoleEntries = roleEntries byText (manifestRoles manifest)
      }
  where
    limits ∷ IdentityLimits
    limits = inventoryIdentityLimits (inventoryLimitsOf inventory)
    resolve (DeclaredEntry slot text) = do
      entryKey ← either (Left . EntryReferenceRefused slot) Right (parseReferenceText limits (inventoryRootKey inventory) text)
      case inspectEntry inventory entryKey of
        Absent → Left (EntryAbsent slot entryKey)
        PresentDirectory → Left (EntryNotAFile slot entryKey)
        PresentFile size → Right (ResolvedEntry slot text entryKey size)

-- | The key of each selected role's entry. Every selected text is a declared
-- one, so each is among the resolved entries.
roleEntries ∷ Map Text ContentKey → RoleSelection → [(Role, ContentKey)]
roleEntries byText = \case
  GameplayOnly gameplay → gameplayEntryOf gameplay
  PresentationOnly presentation → presentationEntryOf presentation
  BothRoles gameplay presentation → gameplayEntryOf gameplay <> presentationEntryOf presentation
  where
    gameplayEntryOf role = [(Gameplay, k) | Just k ← [Map.lookup (gameplayEntry role) byText]]
    presentationEntryOf role = [(Presentation, k) | Just k ← [Map.lookup (presentationEntry role) byText]]
