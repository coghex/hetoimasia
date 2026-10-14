-- | The texture registry's pure state: for each lookup index the registry has
-- registered a texture at, the generation it registered last, that handle's
-- cutout mark and whether its release is marked (R2D-8, GUIDE-5).
--
-- = The release policy
--
-- A handle is reported released by these rules, and by no others:
--
-- * __An index never registered here__ is not reported released.
-- * __A stale handle__ — a handle at a registered index whose generation is not
--   the one registered last — is reported released, whether or not its release
--   was ever marked. "Before" is the order of registration at the index, never
--   a numeric comparison of generations, so it holds across the table's
--   wraparound from the largest generation to 1.
-- * __The current handle__ — the generation registered last — is reported
--   released while its release is marked. The marker persists through the
--   table release, until a later generation is registered at the index. An
--   unmarked current handle is not reported released, including after an
--   unmarked direct table release.
-- * __A reissued handle__ — registration of a handle whose index and generation
--   equal the current one, as after the table's generation wraps — is the new
--   live handle: its marker is clear until it is marked again.
--
-- Because the policy needs only the last generation registered at an index,
-- the state is one fixed-size entry per index registered at: its size is the
-- number of indices, independent of how many textures were registered and
-- released ('retainedEntries'). It replaces a set of every handle ever
-- released, which grew with each release.
--
-- = State
--
-- A 'Ledger' is an immutable value; the registry ("Hetoimasia.Render.TwoD.Vulkan.Textures")
-- holds it in a @TVar@ and replaces it in a transaction. An index's entry is
-- created by its first registration and lives for the life of the registry; a
-- later registration at the index overwrites it in place.
module Hetoimasia.Render.TwoD.Vulkan.Textures.Ledger
  ( Ledger
  , emptyLedger
  , registerHandle
  , forgetMark
  , markHandleReleased
  , handleReleased
  , markOf
  , markedCutouts
  , retainedEntries
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend

-- | The registry's state, one 'Entry' per registered index.
newtype Ledger = Ledger (Map Word32 Entry)

-- | What the registry holds for an index: the generation registered last, that
-- handle's mark (gone once its table release ran) and whether its release is
-- marked.
data Entry = Entry
  { entryGeneration ∷ !Word32
  , entryMark ∷ !(Maybe Bool)
  , entryReleased ∷ !Bool
  }

emptyLedger ∷ Ledger
emptyLedger = Ledger Map.empty

-- | Register a handle with its mark: it becomes its index's current handle,
-- unmarked as released, and whatever the index held before is stale.
registerHandle ∷ Api.TextureHandle → Bool → Ledger → Ledger
registerHandle handle mark (Ledger entries) =
  Ledger (Map.insert (ApiBackend.handleIndex handle) (Entry (ApiBackend.handleGeneration handle) (Just mark) False) entries)

-- | The table release of a handle: its mark is forgotten when it is the
-- index's current handle. A stale handle changes nothing, and the release
-- marker is kept either way.
forgetMark ∷ Api.TextureHandle → Ledger → Ledger
forgetMark handle (Ledger entries) = Ledger (Map.adjust forget (ApiBackend.handleIndex handle) entries)
  where
    forget entry
      | entryGeneration entry == ApiBackend.handleGeneration handle = entry {entryMark = Nothing}
      | otherwise = entry

-- | Mark a handle's release. 'Nothing' for a handle that is not its index's
-- current handle with its mark held, or whose release is already marked.
markHandleReleased ∷ Api.TextureHandle → Ledger → Maybe Ledger
markHandleReleased handle (Ledger entries) = case Map.lookup (ApiBackend.handleIndex handle) entries of
  Just entry
    | entryGeneration entry == ApiBackend.handleGeneration handle
    , Just _ ← entryMark entry
    , not (entryReleased entry) →
        Just (Ledger (Map.insert (ApiBackend.handleIndex handle) entry {entryReleased = True} entries))
  _ → Nothing

-- | Whether the policy reports the handle released.
handleReleased ∷ Ledger → Api.TextureHandle → Bool
handleReleased (Ledger entries) handle = case Map.lookup (ApiBackend.handleIndex handle) entries of
  Nothing → False
  Just entry
    | entryGeneration entry /= ApiBackend.handleGeneration handle → True
    | otherwise → entryReleased entry

-- | The mark held for a handle: 'Nothing' for a stale handle, one whose table
-- release ran, or an index never registered.
markOf ∷ Ledger → Api.TextureHandle → Maybe Bool
markOf (Ledger entries) handle = case Map.lookup (ApiBackend.handleIndex handle) entries of
  Just entry | entryGeneration entry == ApiBackend.handleGeneration handle → entryMark entry
  _ → Nothing

-- | The handles that hold a set mark.
markedCutouts ∷ Ledger → [Api.TextureHandle]
markedCutouts (Ledger entries) =
  [ ApiBackend.textureHandle index (entryGeneration entry)
  | (index, entry) ← Map.toAscList entries
  , Just True ← [entryMark entry]
  ]

-- | How many entries the ledger retains, which is all of its state: one per
-- registered index.
retainedEntries ∷ Ledger → Int
retainedEntries (Ledger entries) = Map.size entries
