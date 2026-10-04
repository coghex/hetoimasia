-- | The bindless texture table's pure bookkeeping (GRS-7; resource services
-- design D-1, D-11, D-22, D-23, D-27, D-31 and D-35): stable handles, the
-- slots they resolve to, and the lookup versions batches freeze them in.
--
-- Nothing here makes a native call or reads a clock. The native table
-- ("Hetoimasia.GPU.Vulkan.Native.TextureTable") owns the descriptor sets, the
-- version ring's memory and the images, and asks this module what to write
-- and when; whether a version is still held by a batch comes from the GPU
-- model's own holds, passed in as a predicate, so these rules run unchanged
-- against the headless examples.
--
-- = Handles
--
-- A 'TextureHandle' is a lookup index and a generation, never persisted.
-- 'registerTexture' reserves a free index and a free slot for one texture;
-- until its upload completes ('completeTexture') the handle resolves to slot
-- 0, the placeholder, and afterwards to its own slot, in versions published
-- after that. 'releaseTexture' ends it: the index may be issued again under
-- the next generation at once, and the slot retires. A stale handle —
-- released, or of an older generation at its index — is refused wherever it
-- is used. Slot 0 is never issued, and counts against the table's size.
--
-- = Versions
--
-- A version maps every lookup index to a slot and the generation valid
-- there, as a whole-table copy in one entry of a ring of a configured size.
-- A new version is published only when a mapping has changed since the
-- current one ('bindVersion'); batches bound in between share it. A batch
-- keeps the version it first bound for the rest of its life, and a ring
-- entry is overwritten only when no batch holds it and it is not the current
-- version. When a new version is owed and every other entry is held, binding
-- is backpressure; when nothing changed, the current version stays bindable
-- however many entries are held.
--
-- = Slots
--
-- A released texture's slot is reused, and its descriptor rewritten, only
-- once no live version maps it ('reclaimSlots'). A version is live while a
-- batch holds it, and the current version also while no mapping has changed
-- since it was published — the only time a batch can still bind it. A
-- release always changes a mapping, so the slot of a texture no batch ever
-- bound is free at once. A slot a texture is registered into was free, so no live
-- version maps it: the descriptor written into it when its upload completes
-- can be sampled by no recorded or pending batch.
--
-- = Swaps
--
-- 'swapTexture' asks a live handle to show a replacement texture (GRS-9): it
-- reserves a free slot for the replacement and changes no mapping, so the
-- handle keeps resolving to what it shows now — its own texture, or slot 0
-- while that is still pending — until 'completeSwap'. Completion is a mapping
-- change like any other: the next version published resolves the handle to
-- the replacement's slot, and the old texture's slot retires exactly as a
-- released texture's does. A handle holds at most one pending swap: a second
-- supersedes the first, whose slot — never published, never written — is
-- free at once, its replacement answered for the caller to release.
-- 'cancelSwap' undoes a pending swap whose replacement failed, and
-- 'releaseTexture' ends a pending swap with its handle, freeing its slot the
-- same way. A completion for a handle released since is refused as stale,
-- whatever generation now holds its index.
module Hetoimasia.GPU.Model.TextureTable
  ( -- * Configuration
    TableConfig
  , tableCapacity
  , tableInitialSlots
  , tableVersionCount
  , defaultVersionCount
  , TableConfigRefused (..)
  , validateTableConfig

    -- * Handles
  , TextureHandle (..)
  , LookupEntry (..)
  , invalidEntry
  , resolveHandle

    -- * The table
  , TextureTable
  , newTextureTable
  , TableRefusal (..)
  , registerTexture
  , completeTexture
  , releaseTexture
  , unregisterTexture
  , swapTexture
  , completeSwap
  , cancelSwap
  , growTable
  , grownSlots
  , bindVersion
  , VersionBinding (..)
  , reclaimSlots

    -- * Observation
  , HandleStanding (..)
  , handleStanding
  , pendingTextures
  , pendingSwaps
  , pendingSwap
  , currentMapping
  , currentVersion
  , versionMapping
  , versionTextures
  , liveVersions
  , freeSlots
  , allocatedSlots
  , writtenSlots
  , retiringSlots
  , mappedSlots
  ) where

import Control.Applicative ((<|>))
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Word (Word32)

-- ---------------------------------------------------------------------------
-- Configuration

-- | The table's validated configuration (D-11): the cap its sampled-image
-- array is declared at, the slots allocated now (growth arrives in GRS-14),
-- slot 0 among them, and how many lookup versions its ring holds.
data TableConfig = TableConfig
  { tableCapacity ∷ !Word32
  , tableInitialSlots ∷ !Word32
  , tableVersionCount ∷ !Word32
  }
  deriving (Eq, Show)

-- | The ring's size when an application states none.
defaultVersionCount ∷ Integer
defaultVersionCount = 8

-- | Why a table configuration was refused. Nothing is clamped.
data TableConfigRefused
  = TableCapacityInvalid !Integer
    -- ^ A cap that is not a positive count a 32-bit descriptor count holds.
  | TableInitialInvalid !Integer
    -- ^ An initial size below two — slot 0 and one texture — or one a 32-bit
    -- count cannot hold.
  | TableInitialAboveCapacity !Integer !Integer
    -- ^ The initial size, and the cap it exceeds.
  | TableVersionsInvalid !Integer
    -- ^ A version count that is not a positive count a 32-bit offset index
    -- holds.
  deriving (Eq, Show)

-- | Validate a table's cap, initial size and version count once, before
-- anything uses them. Zero, negative and unrepresentable values are refused,
-- never clamped; the initial size counts slot 0, so it must be at least two.
-- The device's own limits are checked where the device is known.
validateTableConfig ∷ Integer → Integer → Integer → Either TableConfigRefused TableConfig
validateTableConfig capacity initial versions
  | capacity < 1 || capacity > most = Left (TableCapacityInvalid capacity)
  | initial < 2 || initial > most = Left (TableInitialInvalid initial)
  | initial > capacity = Left (TableInitialAboveCapacity initial capacity)
  | versions < 1 || versions > most = Left (TableVersionsInvalid versions)
  | otherwise = Right (TableConfig (fromInteger capacity) (fromInteger initial) (fromInteger versions))
  where
    most = toInteger (maxBound ∷ Word32)

-- ---------------------------------------------------------------------------
-- Handles

-- | A texture's stable handle: a lookup index and a generation, which is
-- never zero. Instance data carries it; the shader resolves it through the
-- version its batch bound.
data TextureHandle = TextureHandle
  { handleIndex ∷ !Word32
  , handleGeneration ∷ !Word32
  }
  deriving (Eq, Ord, Show)

-- | What a version maps one lookup index to: a slot and the generation valid
-- at that index. A handle resolves to the entry's slot only when its
-- generation matches and is not zero; anything else resolves to slot 0.
data LookupEntry = LookupEntry
  { entrySlot ∷ !Word32
  , entryGeneration ∷ !Word32
  }
  deriving (Eq, Ord, Show)

-- | The entry of an index no live handle holds: generation zero, which no
-- handle has, so every handle resolves through it to slot 0.
invalidEntry ∷ LookupEntry
invalidEntry = LookupEntry 0 0

-- | What the shader resolves a handle to through one version of a table of
-- this many lookup entries: the entry's slot when the index is in bounds and
-- the entry's generation is the handle's, which is never zero; slot 0, the
-- placeholder, otherwise. A stale or foreign handle never reaches another
-- texture's slot, and never an unwritten one.
resolveHandle ∷ Word32 → Map Word32 LookupEntry → TextureHandle → Word32
resolveHandle entries mapping handle
  | handleIndex handle >= entries = 0
  | otherwise = case Map.lookup (handleIndex handle) mapping of
      Just entry
        | entryGeneration entry /= 0 && entryGeneration entry == handleGeneration handle → entrySlot entry
      _ → 0

-- ---------------------------------------------------------------------------
-- The table

-- | One table's bookkeeping, over whatever the caller keeps for each texture
-- (@a@: the image, for the native table).
data TextureTable a = TextureTable
  { tableConfig ∷ !TableConfig
  , tableIndices ∷ !(Map Word32 IndexState)
    -- ^ Every index ever issued, with its latest generation and the handle
    -- that holds it now, if any.
  , tableFree ∷ !(Set Word32)
    -- ^ Slots no live version maps and no handle holds.
  , tableRetiring ∷ !(Map Word32 a)
    -- ^ Released textures' slots, with what was kept for each, not yet free.
  , tableTextures ∷ !(Map Word32 a)
    -- ^ What was kept for each slot a live handle holds.
  , tableVersions ∷ !(Map Word32 (Map Word32 LookupEntry))
    -- ^ Every ring entry ever written, with the mapping it holds.
  , tableCurrent ∷ !(Maybe Word32)
    -- ^ The ring entry of the current version, once one is published.
  , tableDirty ∷ !Bool
    -- ^ Whether a mapping changed since the current version was published.
  , tableAllocated ∷ !Word32
    -- ^ How many slots the current set holds, slot 0 included: the initial
    -- size, doubled by each growth up to the cap (GRS-14).
  , tableWritten ∷ !(Set Word32)
    -- ^ The slots whose descriptor holds a texture the table still keeps: a
    -- completed texture's, until its slot is freed. What a growth copies.
  }
  deriving (Eq, Show)

data IndexState = IndexState
  { indexGeneration ∷ !Word32
  , indexHolder ∷ !(Maybe Holder)
  , indexSwap ∷ !(Maybe Word32)
    -- ^ The slot reserved for the live handle's pending replacement (GRS-9),
    -- if a swap is pending; no version maps it.
  }
  deriving (Eq, Show)

-- | A live handle's slot, and whether its texture's upload has completed.
data Holder
  = HolderPending !Word32
  | HolderReady !Word32
  deriving (Eq, Show)

holderSlot ∷ Holder → Word32
holderSlot = \case
  HolderPending slot → slot
  HolderReady slot → slot

-- | An empty table: every slot but the placeholder free, no index issued,
-- and no version published yet.
newTextureTable ∷ TableConfig → TextureTable a
newTextureTable config =
  TextureTable
    { tableConfig = config
    , tableIndices = Map.empty
    , tableFree = Set.fromList [1 .. tableInitialSlots config - 1]
    , tableRetiring = Map.empty
    , tableTextures = Map.empty
    , tableVersions = Map.empty
    , tableCurrent = Nothing
    , tableDirty = True
    , tableAllocated = tableInitialSlots config
    , tableWritten = Set.empty
    }

-- | Why an operation on the table changed nothing.
data TableRefusal
  = TableStaleHandle !TextureHandle
    -- ^ Released, of an older generation, or never issued.
  | TableFull
    -- ^ Backpressure: no free slot or index until a released texture's slot
    -- is reclaimed.
  | TableVersionsHeld
    -- ^ Backpressure: a new version is owed, and every ring entry but none
    -- is held or current.
  | TableAlreadyComplete !TextureHandle
    -- ^ The handle's texture already completed.
  | TableHasFreeSlot
    -- ^ A growth was asked for while a slot is free: the table grows only
    -- when registration finds none.
  | TableAtCapacity
    -- ^ Backpressure: the table holds its cap and no slot is free, until a
    -- released texture's slot is reclaimed.
  | TableNoSwap !TextureHandle
    -- ^ The live handle has no pending swap to complete or cancel.
  deriving (Eq, Show)

-- | Register one texture: reserve a free index and a free slot, and answer
-- its handle, which resolves to slot 0 until 'completeTexture'. A full table
-- is 'TableFull', having reserved nothing.
registerTexture ∷ a → TextureTable a → Either TableRefusal (TextureTable a, TextureHandle)
registerTexture kept table = case (Set.lookupMin (tableFree table), freeIndex) of
  (Just slot, Just index) →
    let generation = maybe 1 (succ' . indexGeneration) (Map.lookup index (tableIndices table))
        handle = TextureHandle index generation
     in Right
          ( table
              { tableIndices = Map.insert index (IndexState generation (Just (HolderPending slot)) Nothing) (tableIndices table)
              , tableFree = Set.delete slot (tableFree table)
              , tableTextures = Map.insert slot kept (tableTextures table)
              , tableDirty = True
              }
          , handle
          )
  _ → Left TableFull
  where
    -- The lookup array has as many entries as the table has slots.
    -- The lookup array has an entry for every slot the cap allows, so an
    -- index is never what runs out first.
    freeIndex = case [index | index ← [0 .. tableCapacity (tableConfig table) - 1], maybe True (null . indexHolder) (Map.lookup index (tableIndices table))] of
      index : _ → Just index
      [] → Nothing
    -- A generation never wraps to zero, which no handle may have.
    succ' generation = if generation == maxBound then 1 else generation + 1

-- | The handle's texture finished its upload: answer the slot reserved for
-- it, and what was kept for it, so its descriptor can be written there
-- before the next version is published. Nothing live maps that slot. A stale
-- handle, or one already complete, is refused.
completeTexture ∷ TextureHandle → TextureTable a → Either TableRefusal (TextureTable a, (Word32, a))
completeTexture handle table = do
  (index, holder) ← live handle table
  case holder of
    HolderReady _ → Left (TableAlreadyComplete handle)
    HolderPending slot → case Map.lookup slot (tableTextures table) of
      Nothing → Left (TableStaleHandle handle)
      Just kept →
        Right
          ( table
              { tableIndices = Map.adjust (\state → state {indexHolder = Just (HolderReady slot)}) index (tableIndices table)
              , tableDirty = True
              , tableWritten = Set.insert slot (tableWritten table)
              }
          , (slot, kept)
          )

-- | End a handle: its index holds no texture from now on, and may be issued
-- again under the next generation; its slot retires, and is free once no
-- live version maps it ('reclaimSlots'). A stale handle is refused.
--
-- A swap still pending ends with it: its replacement's slot, which no
-- version maps, is free at once, and what was kept for it is the caller's to
-- release ('pendingSwap' names it beforehand). No completion can publish it.
releaseTexture ∷ TextureHandle → TextureTable a → Either TableRefusal (TextureTable a)
releaseTexture handle table = do
  (index, holder) ← live handle table
  let slot = holderSlot holder
      withoutSwap = dropSwap index table
  Right
    withoutSwap
      { tableIndices = Map.adjust (\state → state {indexHolder = Nothing}) index (tableIndices withoutSwap)
      , tableTextures = Map.delete slot (tableTextures withoutSwap)
      , tableRetiring = maybe id (Map.insert slot) (Map.lookup slot (tableTextures withoutSwap)) (tableRetiring withoutSwap)
      , tableDirty = True
      }

-- | Undo a registration whose handle was never handed out: its index holds
-- no texture again, and its slot is free at once, with nothing kept for it,
-- since the caller still owns what it registered. Refused for a stale handle,
-- and for one a version maps — its index at its generation — which a handle
-- never handed out cannot have been bound into. A version naming the slot for
-- an earlier occupant is no obstacle: the slot was free when this handle took
-- it, so no live version maps it.
unregisterTexture ∷ TextureHandle → TextureTable a → Either TableRefusal (TextureTable a)
unregisterTexture handle table = do
  (index, holder) ← live handle table
  let slot = holderSlot holder
      mapsHandle = maybe False ((== handleGeneration handle) . entryGeneration) . Map.lookup index
  if any mapsHandle (tableVersions table)
    then Left (TableStaleHandle handle)
    else
      Right
        table
          { tableIndices = Map.adjust (\state → state {indexHolder = Nothing, indexSwap = Nothing}) index (tableIndices table)
          , tableTextures = Map.delete slot (tableTextures table)
          , tableFree = Set.insert slot (tableFree table)
          , tableWritten = Set.delete slot (tableWritten table)
          , tableDirty = True
          }

-- | Ask a live handle to show a replacement (GRS-9), keeping this for it:
-- reserve a free slot for the replacement, which no version maps until
-- 'completeSwap'. No mapping changes, so the handle keeps resolving to what
-- it shows now. A swap already pending on the handle is superseded first:
-- its slot is free at once, and what was kept for it is answered, for the
-- caller to release; it is never shown. Refused, changing nothing: a stale
-- handle, and 'TableFull' when no slot is free — the caller may grow the
-- table and ask again.
swapTexture ∷ TextureHandle → a → TextureTable a → Either TableRefusal (TextureTable a, Maybe a)
swapTexture handle kept table = do
  (index, _) ← live handle table
  let superseded = Map.lookup index (tableIndices table) >>= indexSwap >>= \slot → Map.lookup slot (tableTextures table)
      cleared = dropSwap index table
  case Set.lookupMin (tableFree cleared) of
    Nothing → Left TableFull
    Just slot →
      Right
        ( cleared
            { tableIndices = Map.adjust (\state → state {indexSwap = Just slot}) index (tableIndices cleared)
            , tableFree = Set.delete slot (tableFree cleared)
            , tableTextures = Map.insert slot kept (tableTextures cleared)
            }
        , superseded
        )

-- | The handle's pending replacement finished its upload: the handle shows
-- it from the next version published on. Answer its slot and what was kept
-- for it, so its descriptor can be written there first — nothing live maps
-- that slot — and what was kept for the texture it replaces, whose slot
-- retires as a released texture's does: free once no live version maps it.
-- Refused: a stale handle, and one with no pending swap ('TableNoSwap').
completeSwap ∷ TextureHandle → TextureTable a → Either TableRefusal (TextureTable a, (Word32, a, Maybe a))
completeSwap handle table = do
  (index, holder) ← live handle table
  slot ← maybe (Left (TableNoSwap handle)) Right (Map.lookup index (tableIndices table) >>= indexSwap)
  kept ← maybe (Left (TableNoSwap handle)) Right (Map.lookup slot (tableTextures table))
  let old = holderSlot holder
      replaced = Map.lookup old (tableTextures table)
  Right
    ( table
        { tableIndices = Map.adjust (\state → state {indexHolder = Just (HolderReady slot), indexSwap = Nothing}) index (tableIndices table)
        , tableTextures = Map.delete old (tableTextures table)
        , tableRetiring = maybe id (Map.insert old) replaced (tableRetiring table)
        , tableWritten = Set.insert slot (tableWritten table)
        , tableDirty = True
        }
    , (slot, kept, replaced)
    )

-- | Undo the handle's pending swap, whose replacement will never complete:
-- its slot is free at once, and what was kept for it is answered, for the
-- caller to release. The handle keeps what it shows; no mapping changes.
-- Refused: a stale handle, and one with no pending swap ('TableNoSwap').
cancelSwap ∷ TextureHandle → TextureTable a → Either TableRefusal (TextureTable a, a)
cancelSwap handle table = do
  (index, _) ← live handle table
  slot ← maybe (Left (TableNoSwap handle)) Right (Map.lookup index (tableIndices table) >>= indexSwap)
  kept ← maybe (Left (TableNoSwap handle)) Right (Map.lookup slot (tableTextures table))
  Right (dropSwap index table, kept)

-- | End the pending swap at this index, if any: its slot, never published
-- and never written, is free at once, with nothing kept for it.
dropSwap ∷ Word32 → TextureTable a → TextureTable a
dropSwap index table = case Map.lookup index (tableIndices table) >>= indexSwap of
  Nothing → table
  Just slot →
    table
      { tableIndices = Map.adjust (\state → state {indexSwap = Nothing}) index (tableIndices table)
      , tableTextures = Map.delete slot (tableTextures table)
      , tableFree = Set.insert slot (tableFree table)
      }

-- | Grow the table (GRS-14): double the slots its current set holds, never
-- past the cap, and add the new slots to the free ones, answering the new
-- count. The caller makes the larger set, copies the written slots into it
-- ('writtenSlots') and makes it current; slots, handles and versions are
-- unchanged. Only a registration that found no free slot grows the table —
-- even while released slots are still retiring — so a free slot is
-- 'TableHasFreeSlot'; and a table at its cap is 'TableAtCapacity', which is
-- backpressure.
growTable ∷ TextureTable a → Either TableRefusal (TextureTable a, Word32)
growTable table
  | not (Set.null (tableFree table)) = Left TableHasFreeSlot
  | allocated >= cap = Left TableAtCapacity
  | otherwise =
      Right
        ( table
            { tableAllocated = grown
            , tableFree = Set.union (tableFree table) (Set.fromList [allocated .. grown - 1])
            }
        , grown
        )
  where
    allocated = tableAllocated table
    cap = tableCapacity (tableConfig table)
    grown = grownSlots allocated cap

-- | The slots a growth from this many reaches under this cap: twice as many,
-- never past the cap. The doubling is computed wider than 32 bits, so a count
-- past 2^31 reaches the cap rather than wrapping.
grownSlots ∷ Word32 → Word32 → Word32
grownSlots allocated cap = fromInteger (min (toInteger cap) (2 * toInteger allocated))

-- | The index and holder of a live handle, or its refusal.
live ∷ TextureHandle → TextureTable a → Either TableRefusal (Word32, Holder)
live handle table = case Map.lookup (handleIndex handle) (tableIndices table) of
  Just (IndexState generation (Just holder) _)
    | generation == handleGeneration handle → Right (handleIndex handle, holder)
  _ → Left (TableStaleHandle handle)

-- | The version a batch binding the table now takes, and what must be
-- written first.
data VersionBinding = VersionBinding
  { bindingVersion ∷ !Word32
    -- ^ The ring entry: its offset into the ring selects it.
  , bindingWrite ∷ !(Maybe (Map Word32 LookupEntry))
    -- ^ The whole mapping to write into that entry before any batch reads
    -- it, when the version is new; 'Nothing' when it is the current one.
  }
  deriving (Eq, Show)

-- | The version a batch binding the table takes now. With nothing changed
-- since the current version was published, it is the current one, whatever
-- the ring holds. Otherwise a new version is published into a ring entry no
-- batch holds — the current one, if nothing holds it — and becomes current;
-- with none free, binding is 'TableVersionsHeld'.
bindVersion ∷ (Word32 → Bool) → TextureTable a → Either TableRefusal (TextureTable a, VersionBinding)
bindVersion held table = case tableCurrent table of
  Just current
    | not (tableDirty table) → Right (table, VersionBinding current Nothing)
  _ → case [entry | entry ← [0 .. tableVersionCount (tableConfig table) - 1], not (held entry)] of
    [] → Left TableVersionsHeld
    candidates →
      -- An entry never written, or one whose version no batch holds and that
      -- is not current, before the current one itself.
      let entry = case filter (\candidate → Just candidate /= tableCurrent table) candidates of
            first : _ → first
            [] → head' candidates
          mapping = currentMapping table
       in Right
            ( table
                { tableVersions = Map.insert entry mapping (tableVersions table)
                , tableCurrent = Just entry
                , tableDirty = False
                }
            , VersionBinding entry (Just mapping)
            )
  where
    head' = \case
      first : _ → first
      [] → 0

-- | Free every retiring slot no live version maps ('liveVersions') and answer
-- each with what was kept for it, which nothing can still sample.
reclaimSlots ∷ (Word32 → Bool) → TextureTable a → (TextureTable a, [(Word32, a)])
reclaimSlots held table =
  ( table
      { tableRetiring = Map.withoutKeys (tableRetiring table) (Set.fromList (map fst freed))
      , tableFree = Set.union (tableFree table) (Set.fromList (map fst freed))
      , tableWritten = Set.difference (tableWritten table) (Set.fromList (map fst freed))
      }
  , freed
  )
  where
    mapped = mappedSlots held table
    freed = [(slot, kept) | (slot, kept) ← Map.toList (tableRetiring table), not (Set.member slot mapped)]

-- ---------------------------------------------------------------------------
-- Observation

-- | Where one handle stands.
data HandleStanding
  = HandlePending !Word32
    -- ^ Live, resolving to slot 0 until its upload completes; its reserved
    -- slot.
  | HandleReady !Word32
    -- ^ Live, resolving to its own slot in versions published since.
  | HandleStale
  deriving (Eq, Show)

handleStanding ∷ TextureHandle → TextureTable a → HandleStanding
handleStanding handle table = case live handle table of
  Right (_, HolderPending slot) → HandlePending slot
  Right (_, HolderReady slot) → HandleReady slot
  Left _ → HandleStale

-- | Every live handle whose texture's upload has not completed, with what
-- was kept for it, in index order.
pendingTextures ∷ TextureTable a → [(TextureHandle, a)]
pendingTextures table =
  [ (TextureHandle index generation, kept)
  | (index, IndexState generation (Just (HolderPending slot)) _) ← Map.toList (tableIndices table)
  , Just kept ← [Map.lookup slot (tableTextures table)]
  ]

-- | Every live handle with a pending swap, with what was kept for its
-- replacement, in index order.
pendingSwaps ∷ TextureTable a → [(TextureHandle, a)]
pendingSwaps table =
  [ (TextureHandle index generation, kept)
  | (index, IndexState generation (Just _) (Just slot)) ← Map.toList (tableIndices table)
  , Just kept ← [Map.lookup slot (tableTextures table)]
  ]

-- | The live handle's pending replacement: its reserved slot, and what was
-- kept for it. 'Nothing' for a stale handle or one with no pending swap.
pendingSwap ∷ TextureHandle → TextureTable a → Maybe (Word32, a)
pendingSwap handle table = case live handle table of
  Left _ → Nothing
  Right (index, _) → do
    slot ← Map.lookup index (tableIndices table) >>= indexSwap
    (,) slot <$> Map.lookup slot (tableTextures table)

-- | The mapping a version published now would hold: every index a live
-- handle holds, to its own slot once complete and to slot 0 until then, with
-- its generation. An index no live handle holds is absent, which reads as
-- 'invalidEntry'.
currentMapping ∷ TextureTable a → Map Word32 LookupEntry
currentMapping table =
  Map.fromList
    [ (index, LookupEntry slot generation)
    | (index, IndexState generation (Just holder) _) ← Map.toList (tableIndices table)
    , let slot = case holder of
            HolderPending _ → 0
            HolderReady ready → ready
    ]

-- | The current version's ring entry, once one is published.
currentVersion ∷ TextureTable a → Maybe Word32
currentVersion = tableCurrent

-- | The mapping a ring entry holds, once written.
versionMapping ∷ Word32 → TextureTable a → Maybe (Map Word32 LookupEntry)
versionMapping entry = Map.lookup entry . tableVersions

-- | What was kept for every texture a version maps — each slot but the
-- placeholder's — which a batch binding that version must keep alive: the
-- slot's texture while a handle holds it, or while it retires.
versionTextures ∷ Word32 → TextureTable a → [a]
versionTextures entry table =
  [ kept
  | slot ← Set.toList (Set.fromList (map entrySlot (maybe [] Map.elems (Map.lookup entry (tableVersions table)))))
  , slot /= 0
  , Just kept ← [Map.lookup slot (tableTextures table) <|> Map.lookup slot (tableRetiring table)]
  ]

-- | The ring entries whose versions are live: every one a batch holds, and
-- the current one while no mapping has changed since it was published — once
-- one has, the next binding publishes a new version, so no batch can take it
-- again.
liveVersions ∷ (Word32 → Bool) → TextureTable a → [Word32]
liveVersions held table =
  [ entry
  | entry ← Map.keys (tableVersions table)
  , held entry || (Just entry == tableCurrent table && not (tableDirty table))
  ]

-- | The slots any live version maps.
mappedSlots ∷ (Word32 → Bool) → TextureTable a → Set Word32
mappedSlots held table =
  Set.fromList
    [ entrySlot entry
    | version ← liveVersions held table
    , entry ← maybe [] Map.elems (Map.lookup version (tableVersions table))
    ]

freeSlots ∷ TextureTable a → Set Word32
freeSlots = tableFree

-- | How many slots the current set holds, slot 0 included.
allocatedSlots ∷ TextureTable a → Word32
allocatedSlots = tableAllocated

-- | The slots whose descriptor holds a texture the table still keeps: those
-- a growth copies into the larger set, beside slot 0's placeholder.
writtenSlots ∷ TextureTable a → Set Word32
writtenSlots = tableWritten

retiringSlots ∷ TextureTable a → [Word32]
retiringSlots = Map.keys . tableRetiring
