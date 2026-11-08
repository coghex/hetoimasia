-- | The normalized retained records of the discovery model, and the provider
-- through which an operation reads them.
--
-- Everything the model retains is one of four plain-data records under an
-- ordered key, plus a small always-resident 'Header'. There is no closure,
-- pointer identity or auxiliary heap index in them, so the same records
-- reconstruct the same knowledge and the same unfinished work.
--
-- @
-- 'KeyRun' column lo       -> 'RecRun' hi        a removed run @[lo, hi)@ of one column
-- 'KeyLink' node           -> 'RecRoot' root     a union-find root: size and knowledge
--                          -> 'RecChild' parent  a member pointing toward its root
-- 'KeyTodo' sequence       -> 'RecTodo' todo     one removal's unfinished connections
-- @
--
-- A node with no 'KeyLink' record is an implicit singleton root: a source
-- component is known exactly when the compiled source calls it exterior, a
-- removed run is unknown. Absent therefore means /confirmed/ unknown, which is a
-- different fact from a record the provider has not supplied ('Unavailable').
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Discovery.Records
  ( Node (..)
  , RecordKey (..)
  , Record (..)
  , Root (..)
  , Todo (..)
  , edgeCount
  , Authority (..)
  , Header (..)
  , pendingObligations
  , Fetch (..)
  , Provider (..)
  , keyBytes
  , recordBytes
  , entryBytes
  , nodeKeyBytes
  , entryOverheadBytes
  ) where

import Data.Int (Int64)
import Data.Word (Word64, Word8)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Internal.Cell (Column)
import Hetoimasia.Terrain.Internal.Connectivity.Index (ComponentKey)
import Hetoimasia.Terrain.Residency (ArenaId, Revision)

-- | A member of the connectivity forest: a source component of the compiled
-- source, or a removed run named by the lowest level it had when the node was
-- made. A run whose lower end later moves keeps its old node as a member of the
-- same class, so aliases stay valid when removals extend or merge runs.
data Node
  = SrcNode !ComponentKey
  | RunNode !Column !Int64
  deriving stock (Eq, Ord, Show)

-- | The ordered key of a retained record. Runs of one column are adjacent and
-- sorted by their lower end, so the run at or below a level is one floor lookup.
data RecordKey
  = KeyRun !Column !Int64
  | KeyLink !Node
  | KeyTodo !Word64
  deriving stock (Eq, Ord, Show)

-- | A union-find root: the members it holds and whether the class is known.
data Root = Root
  { rootSize ∷ !Word64
  , rootKnown ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | One removal's unfinished connections: its cell and how many of the
-- 'edgeCount' connections have been inspected. Zero is unseen, a number between
-- is pending, and a finished obligation is deleted (expanded).
data Todo = Todo
  { todoTile ∷ !TileCoord
  , todoDone ∷ !Word8
  }
  deriving stock (Eq, Show)

-- | The connections a removal introduces: its own old void and its six faces.
edgeCount ∷ Word8
edgeCount = 7

-- | A retained record.
data Record
  = RecRun !Int64
  | RecRoot !Root
  | RecChild !Node
  | RecTodo !Todo
  deriving stock (Eq, Show)

-- | The authority every candidate is bound to: the arena incarnation and the
-- three revisions the later owner advances (content for terrain changes,
-- knowledge for knowledge changes, store for frontier and maintenance).
data Authority = Authority
  { authArena ∷ !ArenaId
  , authContent ∷ !Revision
  , authKnowledge ∷ !Revision
  , authStore ∷ !Revision
  }
  deriving stock (Eq, Show)

-- | The always-resident control state: the authority, the oldest unfinished
-- obligation, the next sequence to allocate and the accounted retained bytes.
-- Obligations are finished strictly in sequence, so every sequence in
-- @[head, tail)@ holds exactly one 'RecTodo'.
data Header = Header
  { hAuthority ∷ !Authority
  , hHead ∷ !Word64
  , hTail ∷ !Word64
  , hBytes ∷ !Int
  }
  deriving stock (Eq, Show)

-- | The unfinished obligations.
pendingObligations ∷ Header → Word64
pendingObligations h = hTail h - hHead h

-- | The answer to a record request: the record, a confirmed absence, or a
-- record the provider has not supplied. A missing record is never read as
-- absent, as air, as unknown fog or as proof that no connection exists.
data Fetch a
  = Found !a
  | Absent
  | Unavailable !RecordKey
  deriving stock (Eq, Show)

-- | The bounded window through which an operation reads retained records.
-- 'fetchFloorRun' answers the removed run of a column with the greatest lower
-- end at or below a level (a floor lookup).
data Provider = Provider
  { fetchRecord ∷ RecordKey → Fetch Record
  , fetchFloorRun ∷ Column → Int64 → Fetch (Int64, Int64)
  }

-- | The accounted bytes of a node key: a source component key holds a tile and
-- three optional parameters, a run a column and a level.
nodeKeyBytes ∷ Node → Int
nodeKeyBytes (SrcNode _) = 96
nodeKeyBytes (RunNode _ _) = 40

-- | The container overhead of one retained entry.
entryOverheadBytes ∷ Int
entryOverheadBytes = 48

-- | The accounted bytes of a key.
keyBytes ∷ RecordKey → Int
keyBytes (KeyRun _ _) = 32
keyBytes (KeyLink node) = 8 + nodeKeyBytes node
keyBytes (KeyTodo _) = 16

-- | The accounted bytes of a record's value.
recordBytes ∷ Record → Int
recordBytes (RecRun _) = 8
recordBytes (RecRoot _) = 16
recordBytes (RecChild node) = 8 + nodeKeyBytes node
recordBytes (RecTodo _) = 40

-- | The accounted bytes of one entry: key, value and container overhead. At most
-- 'Hetoimasia.Terrain.Internal.Discovery.Limits.maxRecordBytes'.
entryBytes ∷ RecordKey → Record → Int
entryBytes key record = keyBytes key + recordBytes record + entryOverheadBytes
