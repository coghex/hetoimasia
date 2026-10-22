-- | The checked mapping from logical names to the exact native components an
-- enumeration observed.
--
-- State, ownership and lifetime. A 'NativeMapping' is an immutable persistent
-- tree built in one pure call, 'buildMapping', by the caller, who owns it and
-- its lifetime. Nothing is shared between mappings, nothing is cached, and no
-- registry exists. A build either returns a complete mapping or a refusal: an
-- entry that fails leaves nothing behind, because the partially built tree is
-- local to the call and dropped with it.
--
-- Each directory level keeps two indexes over its children. One is keyed by the
-- NFC name and is the only index a lookup uses, so lookup is exact: no case
-- folding and no fallback to a native spelling. The other is keyed by the
-- canonical caseless key and exists only to refuse an ambiguous sibling set.
module Hetoimasia.Content.Internal.Identity.Mapping
  ( ObservedKind (..)
  , ObservedEntry (..)
  , NativeMapping
  , MappedEntry
  , InventoryRefusal (..)
  , InventoryReason (..)
  , EntryProblem (..)
  , Collision (..)
  , CollisionKind (..)
  , CollidingEntry (..)
  , buildMapping
  , mappingRoot
  , mappingSize
  , lookupPath
  , mappingEntries
  , mappedPath
  , mappedNative
  , mappedKind
  , mappedSupplied
  ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Content.Internal.Identity.Reference (CheckedSegment (..), checkSegment, sumCapped)
import Hetoimasia.Content.Internal.Identity.Types
import Hetoimasia.Content.Internal.Types (NativeName (NativeName))

-- | What the enumeration saw an entry to be, for the identity policy: a
-- directory, or anything that is not one. An entry of any other native kind
-- (a link, a device) is the enumerator's to refuse, not this policy's.
data ObservedKind = ObservedFile | ObservedDirectory
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One observed entry: its path below the root as exact native components,
-- never joined, split, trimmed or re-encoded, and its kind.
data ObservedEntry = ObservedEntry
  { observedPath ∷ ![ByteString]
  , observedKind ∷ !ObservedKind
  }
  deriving (Eq, Show)

-- | Why an inventory was refused. No mapping is produced.
data InventoryRefusal = InventoryRefusal
  { inventoryRoot ∷ !RootKey
  , inventoryReason ∷ !InventoryReason
  }
  deriving (Eq, Show)

data InventoryReason
  = -- | An entry whose spelling or size the policy refuses: bad inventory, not
    -- an entry to omit.
    InvalidEntry !Excerpt !EntryProblem
  | -- | The same exact native path supplied twice.
    DuplicateEntry !Excerpt
  | -- | An ancestor supplied as a non-directory, then the entry below it.
    BelowNonDirectory !Excerpt !Excerpt
  | -- | An entry supplied as a non-directory that other supplied paths pass
    -- through.
    NonDirectoryHasChildren !Excerpt
  | SiblingCollision !Collision
  | -- | More entries than the caller's allowance, which is stated.
    TooManyEntries !Int
  deriving (Eq, Show)

-- | What is wrong with one entry.
data EntryProblem
  = EmptyEntryPath
  | -- | Components, then the limit; counted only up to one past the limit. The
    -- excerpt of such an entry shows only those leading components.
    EntryTooDeep !Int !Int
  | -- | Native bytes of the path (separators included), then the limit. The
    -- sum stops growing once it is past the limit, so it is the whole path's
    -- length only when the path is not far over.
    EntryTooLong !Int !Int
  | -- | The component number and what is wrong with it.
    BadComponent !Int !SegmentProblem
  | -- | NFC bytes of the path, then the limit; summed as 'EntryTooLong' is.
    EntryNormalizedTooLong !Int !Int
  deriving (Eq, Show)

-- | Two distinct siblings that the policy cannot tell apart.
data Collision = Collision
  { collisionParent ∷ !Excerpt
  -- ^ The NFC path of their directory; empty at the root.
  , collisionBy ∷ !CollisionKind
  , collisionExisting ∷ !CollidingEntry
  , collisionIncoming ∷ !CollidingEntry
  }
  deriving (Eq, Show)

data CollisionKind
  = -- | The same NFC name from different native spellings.
    SameNormalization
  | -- | Different NFC names with one canonical caseless key.
    SameCaseless
  deriving (Eq, Show)

data CollidingEntry = CollidingEntry
  { collidingName ∷ !NativeName
  , collidingKind ∷ !ObservedKind
  }
  deriving (Eq, Show)

-- | One directory level: children by NFC name (the lookup index) and the
-- caseless key of each to the child that owns it (the ambiguity index).
data Level = Level
  { byNfc ∷ !(Map ByteString Node)
  , byCaseless ∷ !(Map ByteString CollidingEntry)
  }

data Node = Node
  { nodeNative ∷ !NativeName
  , nodeKind ∷ !ObservedKind
  , nodeSupplied ∷ !Bool
  , nodeChildren ∷ !Level
  }

emptyLevel ∷ Level
emptyLevel = Level Map.empty Map.empty

-- | The checked mapping of one root.
data NativeMapping = NativeMapping
  { mappingRootKey ∷ !RootKey
  , mappingCount ∷ !Int
  , mappingTree ∷ !Level
  }

-- | The root the mapping was built for.
mappingRoot ∷ NativeMapping → RootKey
mappingRoot = mappingRootKey

-- | How many entries were supplied; the directories implied by their paths are
-- not counted.
mappingSize ∷ NativeMapping → Int
mappingSize = mappingCount

-- | An entry found in a mapping.
data MappedEntry = MappedEntry
  { entryPath ∷ !LogicalPath
  , entryNative ∷ !(NonEmpty NativeName)
  , entryKind ∷ !ObservedKind
  , entrySupplied ∷ !Bool
  }
  deriving (Eq, Show)

-- | The entry's logical (NFC) path.
mappedPath ∷ MappedEntry → LogicalPath
mappedPath = entryPath

-- | The exact native components to open, lossless and in order.
mappedNative ∷ MappedEntry → NonEmpty NativeName
mappedNative = entryNative

mappedKind ∷ MappedEntry → ObservedKind
mappedKind = entryKind

-- | Whether the entry was supplied, or is only a directory a supplied path
-- passes through.
mappedSupplied ∷ MappedEntry → Bool
mappedSupplied = entrySupplied

-- | One validated component of an entry.
data Component = Component
  { componentNative ∷ !NativeName
  , componentNfc ∷ !ByteString
  , componentCaseless ∷ ByteString
  }

-- | Build the checked mapping of an observed inventory.
--
-- Every ancestor component of every supplied path takes part in the sibling
-- check whether or not it was supplied as an entry of its own, so
-- @Hero/a@ and @hero/b@ collide at the root with no directory entry supplied.
-- Directories therefore need not be supplied; supplying one marks it supplied.
-- The same exact native path twice, a path below a non-directory, and a
-- component the grammar refuses are refused rather than repaired or
-- deduplicated.
--
-- The entries are consumed one at a time and the consumption stops at the first
-- refusal and at one entry past the allowance, so an unbounded enumeration is
-- never materialized.
buildMapping ∷ IdentityLimits → RootKey → [ObservedEntry] → Either InventoryRefusal NativeMapping
buildMapping limits root = go 0 emptyLevel
  where
    refusal = InventoryRefusal root
    go count tree [] = Right (NativeMapping root count tree)
    go count tree (entry : rest)
      | count >= limitEntries limits = Left (refusal (TooManyEntries (limitEntries limits)))
      | otherwise = do
          components ← first (refusal . InvalidEntry (excerptOfPath (take (segmentAllowance limits) (observedPath entry)))) (validateEntry limits entry)
          tree' ← first refusal (insertEntry entry components tree)
          go (count + 1) tree' rest

-- | Check an entry's size and every component, from the bytes as supplied.
validateEntry ∷ IdentityLimits → ObservedEntry → Either EntryProblem [Component]
validateEntry limits entry
  | null components = Left EmptyEntryPath
  | depth > limitSegments limits = Left (EntryTooDeep depth (limitSegments limits))
  | rawBytes > limitPathBytes limits = Left (EntryTooLong rawBytes (limitPathBytes limits))
  | otherwise = do
      checked ← traverse component (zip [0 ..] components)
      let normalizedBytes = addSaturating (sumCapped (limitPathBytes limits) (map (BS.length . componentNfc) checked)) (depth - 1)
      if normalizedBytes > limitPathBytes limits
        then Left (EntryNormalizedTooLong normalizedBytes (limitPathBytes limits))
        else Right checked
  where
    components = take (segmentAllowance limits) (observedPath entry)
    depth = length components
    rawBytes = addSaturating (sumCapped (limitPathBytes limits) (map BS.length components)) (depth - 1)
    component (index, bytes) = case checkSegment limits bytes of
      Left problem → Left (BadComponent index problem)
      Right checked →
        Right
          Component
            { componentNative = NativeName (BS.copy bytes)
            , componentNfc = checkedNfc checked
            , componentCaseless = checkedCaseless checked
            }

-- | Insert an entry, creating the directories its path implies.
insertEntry ∷ ObservedEntry → [Component] → Level → Either InventoryReason Level
insertEntry entry = descend []
  where
    whole = observedPath entry
    wholeExcerpt = excerptOfPath whole
    descend ∷ [ByteString] → [Component] → Level → Either InventoryReason Level
    descend _ [] level = Right level
    descend done (component : rest) level =
      case Map.lookup name (byNfc level) of
        Just node
          | nodeNative node /= componentNative component →
              Left (collide SameNormalization (CollidingEntry (nodeNative node) (nodeKind node)))
          | isLast && nodeSupplied node → Left (DuplicateEntry wholeExcerpt)
          | isLast && kind /= nodeKind node → Left (NonDirectoryHasChildren wholeExcerpt)
          | isLast → Right (replace node {nodeSupplied = True})
          | nodeKind node /= ObservedDirectory →
              Left (BelowNonDirectory (excerptOfPath (take (length done + 1) whole)) wholeExcerpt)
          | otherwise → do
              children ← descend (name : done) rest (nodeChildren node)
              Right (replace node {nodeChildren = children})
        Nothing → case Map.lookup (componentCaseless component) (byCaseless level) of
          Just existing → Left (collide SameCaseless existing)
          Nothing → do
            children ← descend (name : done) rest emptyLevel
            let node = Node (componentNative component) kind isLast children
            Right
              level
                { byNfc = Map.insert name node (byNfc level)
                , byCaseless = Map.insert (componentCaseless component) (CollidingEntry (componentNative component) kind) (byCaseless level)
                }
      where
        name = componentNfc component
        isLast = null rest
        kind = if isLast then observedKind entry else ObservedDirectory
        replace node = level {byNfc = Map.insert name node (byNfc level)}
        collide by existing =
          SiblingCollision
            Collision
              { collisionParent = excerptOfPath (reverse done)
              , collisionBy = by
              , collisionExisting = existing
              , collisionIncoming = CollidingEntry (componentNative component) kind
              }

-- | Exact lookup of a logical path. A path that differs only in case, or that
-- the inventory does not hold, is not found; there is no other fallback.
lookupPath ∷ NativeMapping → LogicalPath → Maybe MappedEntry
lookupPath mapping path = walk [] (NonEmpty.toList (pathSegments path)) (mappingTree mapping)
  where
    walk _ [] _ = Nothing
    walk before (segment : rest) level = do
      node ← Map.lookup segment (byNfc level)
      case rest of
        [] →
          Just
            MappedEntry
              { entryPath = path
              , entryNative = NonEmpty.prependList before (nodeNative node :| [])
              , entryKind = nodeKind node
              , entrySupplied = nodeSupplied node
              }
        _ → walk (before <> [nodeNative node]) rest (nodeChildren node)

-- | Every entry the mapping can address, supplied or implied, depth first, the
-- children of each directory in the byte order of their NFC names.
mappingEntries ∷ NativeMapping → [MappedEntry]
mappingEntries mapping = walk [] [] (mappingTree mapping)
  where
    walk ∷ [ByteString] → [NativeName] → Level → [MappedEntry]
    walk logical natives level =
      concat
        [ here : walk logicalHere nativesHere (nodeChildren node)
        | (segment, node) ← Map.toAscList (byNfc level)
        , let logicalHere = logical <> [segment]
              nativesHere = natives <> [nodeNative node]
              here =
                MappedEntry
                  { entryPath =
                      LogicalPath
                        (BS.intercalate "/" logicalHere)
                        (NonEmpty.prependList logical (segment :| []))
                  , entryNative = NonEmpty.prependList natives (nodeNative node :| [])
                  , entryKind = nodeKind node
                  , entrySupplied = nodeSupplied node
                  }
        ]
