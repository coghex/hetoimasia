-- | The world part of a target's scene (TRA-9): a terrain view's revision, as the 2D renderer's own values.
--
-- = What it is
--
-- A target's published scene is either an M1 scene (the copied, checked content a script published) or a world
-- scene that a terrain view published under its exclusive claim of the target. 'SceneWorld' is the second: one
-- depth-enabled world view of the 2D renderer whose quads live in retained chunks, with the clear colour, the
-- metrics the view was planned for, and everything the revision holds: the chunks it lists and the complete
-- identities of the textures its records name. It holds no terrain value, no Lua object and no callback; this
-- library does not depend on the terrain packages, which build it.
--
-- 'WorldTag' names the view incarnation and that view's revision of the plan the world was made from, so the
-- frame that drew it can say which plan it drew ("Hetoimasia.LuaEngine.Graphics.Scene.Receipts").
--
-- = Owned state
--
-- None: the value is immutable, made by the publishing view and forced before publication ('rnf'), and owned by
-- the host from acceptance. What it holds is protected as every scene's references are: by the host's release
-- barrier until adoption and by the scene ledger's adoption records afterwards
-- ("Hetoimasia.LuaEngine.Graphics.Scene.Ledger").
module Hetoimasia.LuaEngine.Graphics.Scene.World
  ( SceneWorld (..)
  , WorldTag (..)
  , worldSnapshot
  ) where

import Control.DeepSeq (NFData (rnf))
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour
  , FrameTable (..)
  , Pass (..)
  , Snapshot (..)
  , Target (WindowTarget)
  , View (..)
  , layerChunks
  , layerInstances
  )

-- | Which view incarnation published the world, and which of that view's plan revisions it is.
data WorldTag = WorldTag
  { tagView ∷ !Word64
  , tagRevision ∷ !Word64
  }
  deriving (Eq, Ord, Show)

-- | A terrain view's revision: one depth-enabled world view over retained chunks.
data SceneWorld = SceneWorld
  { worldTag ∷ !WorldTag
  , worldClear ∷ !ClearColour
  , worldView ∷ !View
    -- ^ Its camera and viewport as planned, the material's push block, and one depth-enabled world layer listing
    -- the chunks.
  , worldMetrics ∷ !TargetMetrics
    -- ^ The target metrics the view was planned for. A frame of other metrics draws the same view.
  , worldChunks ∷ !(Set ChunkRef)
    -- ^ Every chunk the view lists, once.
  , worldTextures ∷ !(Set Word64)
    -- ^ The complete identity of every texture the chunks' records name, once.
  }
  deriving (Eq, Show)

instance NFData SceneWorld where
  rnf world =
    forceView (worldView world)
      `seq` Set.foldr seq () (worldChunks world)
      `seq` rnf (worldTextures world)

-- Every field of the renderer's values is strict, so forcing each list's spine and each element is full normal
-- form.
forceView ∷ View → ()
forceView view =
  spine (viewClips view)
    `seq` Map.foldr (\material rest → forceMaterial material `seq` rest) () (viewMaterials view)
    `seq` foldr (\table rest → spine (frameTableFrames table) `seq` rest) () (viewFrameTables view)
    `seq` foldr (\layer rest → forceLayer layer `seq` rest) () (viewLayers view)
  where
    forceMaterial material = foldr (\record rest → spine (recordHandles record) `seq` spine (recordWords record) `seq` rest) () (materialRecords material) `seq` ByteString.length (materialPushBlock material) `seq` ()
    forceLayer layer = spine (layerChunks layer) `seq` spine (layerInstances layer)

spine ∷ [a] → ()
spine = foldr seq ()

-- | The renderer's snapshot of a world for a window, or for an offscreen target recorded as its window: one window
-- pass, cleared, drawing the one view.
worldSnapshot ∷ SceneWorld → Snapshot
worldSnapshot world = Snapshot [Pass WindowTarget (worldClear world) [worldView world]]
