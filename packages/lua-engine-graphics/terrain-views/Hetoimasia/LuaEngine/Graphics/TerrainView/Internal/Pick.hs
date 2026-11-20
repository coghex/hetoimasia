-- | A pick's consistency reference, with its constructors. A hidden module of the terrain-views library: only the
-- adapter's picker makes a reference, and callers outside the library read one through the public accessors in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Types", which name no constructor and no field, so a reference can be
-- neither made nor altered (a record update needs a field) outside it.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Internal.Pick
  ( PickIdentity (..)
  , PickRef (..)
  , pickTarget
  , pickViewId
  , pickRevision
  , pickTag
  , pickArena
  , pickContent
  , pickKnowledge
  , pickResidency
  , pickRefCell
  , pickRefPart
  , pickRefIdentity
  ) where

import Data.Word (Word64)
import Hetoimasia.LuaEngine.Graphics.Scene.World (WorldTag)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Render2D.Cells (PartKind)
import Hetoimasia.Terrain.Residency (ArenaId, Revision)

-- | Everything a pick's consistency is: the target and view incarnations, the adopted revision and its plan tag, the
-- arena incarnation and its content and knowledge revisions, and the adopted plan's residency identity.
data PickIdentity k = PickIdentity
  { identityTarget ∷ !k
  , identityViewId ∷ !Word64
  , identityRevision ∷ !Word64
  , identityTag ∷ !WorldTag
  , identityArena ∷ !ArenaId
  , identityContent ∷ !Revision
  , identityKnowledge ∷ !Revision
  , identityResidency ∷ !Word64
    -- ^ The adopted plan's residency identity, checked against the arena's generation in the removal's arbitration.
  }
  deriving (Eq, Show)

-- | A hit's consistency reference: the exact logical cell and part, and the identity it was picked under.
data PickRef k = PickRef
  { refCell ∷ !TileCoord
  , refPart ∷ !PartKind
  , refIdentity ∷ !(PickIdentity k)
  }
  deriving (Eq, Show)

-- The accessors are plain functions, not fields: exporting them lets a caller read an identity, never update one.
pickTarget ∷ PickIdentity k → k
pickTarget = identityTarget

pickViewId ∷ PickIdentity k → Word64
pickViewId = identityViewId

pickRevision ∷ PickIdentity k → Word64
pickRevision = identityRevision

pickTag ∷ PickIdentity k → WorldTag
pickTag = identityTag

pickArena ∷ PickIdentity k → ArenaId
pickArena = identityArena

pickContent ∷ PickIdentity k → Revision
pickContent = identityContent

pickKnowledge ∷ PickIdentity k → Revision
pickKnowledge = identityKnowledge

pickResidency ∷ PickIdentity k → Word64
pickResidency = identityResidency

pickRefCell ∷ PickRef k → TileCoord
pickRefCell = refCell

pickRefPart ∷ PickRef k → PartKind
pickRefPart = refPart

pickRefIdentity ∷ PickRef k → PickIdentity k
pickRefIdentity = refIdentity
