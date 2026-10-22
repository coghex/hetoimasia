-- | The resolved configuration a valid manifest yields.
--
-- __Ownership.__ These are immutable values produced by
-- "Hetoimasia.LuaEngine.Manifest"; the module holds only data. A 'Manifest'
-- claims nothing about the filesystem: its entry texts are exactly what the
-- document decoded to, and whether they are valid root-relative paths, name
-- inventoried regular files, or match any hash is the content layer's to check
-- before Lua runs. The parser neither normalises nor validates a path, so there
-- is no second path implementation to disagree with that layer.
module Hetoimasia.LuaEngine.Manifest.Types
  ( -- * The manifest
    Manifest (..)
  , ContentId
  , contentIdText
  , unsafeContentId

    -- * Roles
  , RoleSelection (..)
  , GameplayRole (..)
  , PresentationRole (..)
  , EntryOrigin (..)
  , selectedRoles

    -- * Declared entries
  , EntrySlot (..)
  , DeclaredEntry (..)
  , declaredEntries
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Hetoimasia.Foundation.Time (Duration)
import Hetoimasia.LuaEngine.Manifest.Error (Role (..))

-- | A valid manifest.
data Manifest = Manifest
  { manifestBytes ∷ !ByteString
    -- ^ The exact bytes that were parsed, not a reserialization. Anchored
    -- inventory and fingerprint work later checks these bytes. The value shares
    -- the caller's buffer.
  , manifestId ∷ !ContentId
  , manifestCommonEntry ∷ !(Maybe Text)
    -- ^ The common @entry@ as written, kept even when every role overrides it.
  , manifestRoles ∷ !RoleSelection
  }
  deriving (Eq, Show)

-- | The stable content identifier: 1 to 64 ASCII characters matching
-- @[a-z][a-z0-9_-]*@, exactly as written.
newtype ContentId = ContentId Text
  deriving (Eq, Ord, Show)

-- | The identifier's text.
contentIdText ∷ ContentId → Text
contentIdText (ContentId text) = text

-- | Wrap text already validated by the schema; not exported by the facade.
unsafeContentId ∷ Text → ContentId
unsafeContentId = ContentId

-- | Where a role's entry text came from.
data EntryOrigin
  = ExplicitEntry
    -- ^ The role's own @entry@.
  | CommonEntry
    -- ^ The common @entry@, either because the role declares none or because
    -- @vms@ is absent. A text shared by both roles is one authored input that
    -- each VM will still load independently.
  deriving (Eq, Show)

-- | The gameplay role. Its tick is part of the role because gameplay is the
-- only role that has one: the type cannot hold a tick without gameplay, or
-- gameplay without one.
data GameplayRole = GameplayRole
  { gameplayEntry ∷ !Text
    -- ^ The selected entry text.
  , gameplayEntryOrigin ∷ !EntryOrigin
  , gameplayTick ∷ !Duration
    -- ^ The logical tick period: positive, whole nanoseconds, exactly as the
    -- decimal text named it. There is no default.
  }
  deriving (Eq, Show)

-- | The presentation role, driven by the elapsed clock. Its cadence belongs to
-- its Lua behavior, not to the manifest.
data PresentationRole = PresentationRole
  { presentationEntry ∷ !Text
  , presentationEntryOrigin ∷ !EntryOrigin
  }
  deriving (Eq, Show)

-- | The declared role set: one or both of the two fixed roles. Array order in
-- the document is not startup or dependency order and is not recorded.
data RoleSelection
  = GameplayOnly !GameplayRole
  | PresentationOnly !PresentationRole
  | BothRoles !GameplayRole !PresentationRole
  deriving (Eq, Show)

-- | The roles present, in the fixed order gameplay then presentation.
selectedRoles ∷ RoleSelection → [Role]
selectedRoles selection = case selection of
  GameplayOnly _ → [Gameplay]
  PresentationOnly _ → [Presentation]
  BothRoles _ _ → [Gameplay, Presentation]

-- | Which declaration an entry text was written in.
data EntrySlot
  = CommonSlot
  | RoleSlot !Role
  deriving (Eq, Ord, Show)

-- | An entry text exactly as declared.
data DeclaredEntry = DeclaredEntry
  { declaredSlot ∷ !EntrySlot
  , declaredPath ∷ !Text
  }
  deriving (Eq, Show)

-- | Every entry text the document declared, including a common entry that every
-- role overrides: the common entry first, then each role's explicit entry,
-- gameplay before presentation. The later inventory check must cover all of
-- them, not only the selected ones.
declaredEntries ∷ Manifest → [DeclaredEntry]
declaredEntries manifest =
  [DeclaredEntry CommonSlot path | Just path ← [manifestCommonEntry manifest]]
    ++ [DeclaredEntry (RoleSlot Gameplay) (gameplayEntry role) | Just role ← [gameplay], gameplayEntryOrigin role == ExplicitEntry]
    ++ [DeclaredEntry (RoleSlot Presentation) (presentationEntry role) | Just role ← [presentation], presentationEntryOrigin role == ExplicitEntry]
  where
    (gameplay, presentation) = case manifestRoles manifest of
      GameplayOnly role → (Just role, Nothing)
      PresentationOnly role → (Nothing, Just role)
      BothRoles g p → (Just g, Just p)
