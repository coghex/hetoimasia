{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

-- | The scene a window holds in the Lua-first engine (LFE-20), and the ledger of what the adopted revisions
-- of those scenes hold.
--
-- = The scene
--
-- 'GraphicsScene' is the host's per-window scene type for the M1 profile: the copied, checked
-- 'SceneContent' a script published and the distinct texture identities it names. It is pure, strict and
-- immutable. It holds no Lua object, and it is the whole of what the owner is handed: the viewport is
-- never in it, because the window's metrics are the renderer's, read for each frame
-- ("Hetoimasia.LuaEngine.Graphics.Scene.Render"). A window's initial scene is 'initialGraphicsScene':
-- opaque black, empty, naming nothing.
--
-- = The ledger
--
-- The host's scene ledger (@Scenes.hs@ of the window integration) adopts a revision of a window under
-- each attachment that takes it, and releases each adoption on its own, once it is superseded or its
-- target has ended and every use of it is over. It tells the renderer through the two hooks of a
-- 'SceneLifecycle', on the owner's thread, which 'ledgerLifecycle' implements. The hooks carry the
-- window and the revision, not the attachment, so this ledger keeps a /count/ for each window and
-- revision: the texture identities of the adopted scene are held while the count is above zero, and the
-- last release drops them. A map that inserted and deleted by window and revision would let the first
-- release of a revision adopted twice drop the protection of the second.
--
-- = Owned state, threads and lifetime
--
-- +--------------+--------+-----------------------+------------------------+------------------------------+
-- | State        | Owner  | Writers               | Readers                | Lifetime and disposal        |
-- +==============+========+=======================+========================+==============================+
-- | The records  | the    | the two hooks, on the | any thread, in STM     | made before the host is built |
-- | (one for each| ledger | owner's thread        | (the texture backend's | and never reset; a record    |
-- | window and   |        |                       | release, the tests)    | goes with its last release   |
-- | revision)    |        |                       |                        |                              |
-- +--------------+--------+-----------------------+------------------------+------------------------------+
--
-- The ledger exists before the host does, so the lifecycle the host is configured with is the real one
-- from its first step: there is no slot to be empty, and no adoption or release can fall on a fallback
-- that ignores it. A hook is one STM transaction over pure data; it neither waits nor raises. A release
-- the ledger has no adoption for (or an adoption of a revision under a different scene) is a defect of
-- the host's pairing, not something a hook may raise: it is counted and its first description kept, and
-- 'ledgerReading' shows it. The records are bounded by the host's own retention (six unreleased
-- revisions for each target, two windows in the M1 profile) and each holds the distinct textures its scene names,
-- which the scene's own sprite limit ('SceneSprites') bounds: a scene has at most that many sprites, so it names at
-- most that many textures. The ledger itself is a map and a set, not a fixed table.
module Hetoimasia.LuaEngine.Graphics.Scene.Ledger
  ( -- * The scene
    GraphicsScene (GraphicsSceneWith, GraphicsScene, graphicsContent, graphicsReferences, graphicsWorld)
  , graphicsScene
  , worldGraphicsScene
  , sceneHolds
  , initialGraphicsScene

    -- * The ledger
  , SceneLedger
  , newSceneLedger
  , ledgerLifecycle
  , ledgerAdopted
  , ledgerReleased
  , ledgerHeld
  , ledgerHolds
  , ledgerChunkHeld

    -- * Interests
  , ledgerRetainInterest
  , ledgerDropInterest
  , ledgerInterests

    -- * The adopted world
  , ledgerNewestAdopted

    -- * Reading
  , LedgerReading (..)
  , ledgerReading
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.GPU.Vulkan.GLFW (SceneLifecycle (..), SceneTargetKey)
import Hetoimasia.LuaEngine.Scene
  ( PreparedScene (preparedContent)
  , SceneContent (sceneSprites)
  , SceneSprite (spriteTexture)
  , TextureUse (useView)
  , initialContent
  , textureUses
  )
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag)
import Hetoimasia.LuaEngine.Texture (TextureView (viewIdentity))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Numeric.Natural (Natural)

-- | What a window's published revision is: the content, the textures it names, and, for a terrain view's
-- publication, the world it draws instead ("Hetoimasia.LuaEngine.Graphics.Scene.World"). A world scene's content is
-- the initial content and names nothing; its world names its own chunks and textures.
data GraphicsScene = GraphicsSceneWith
  { graphicsContent ∷ !SceneContent
  , graphicsReferences ∷ !(Set Word64)
    -- ^ The distinct texture identities the content names, complete (generation above index), whether
    -- or not a sprite is visible.
  , graphicsWorld ∷ !(Maybe SceneWorld)
  }
  deriving (Eq, Show)

-- | An M1 scene: content and its textures, no world. As a pattern it matches only a scene without a world.
pattern GraphicsScene ∷ SceneContent → Set Word64 → GraphicsScene
pattern GraphicsScene content references = GraphicsSceneWith content references Nothing

{-# COMPLETE GraphicsSceneWith #-}

-- | A terrain view's scene: the initial content, naming nothing, and the world.
worldGraphicsScene ∷ SceneWorld → GraphicsScene
worldGraphicsScene world = GraphicsSceneWith initialContent Set.empty (Just world)

-- | Every texture identity an adoption of the scene holds: the content's and the world's.
sceneHolds ∷ GraphicsScene → Set Word64
sceneHolds scene = graphicsReferences scene <> maybe Set.empty worldTextures (graphicsWorld scene)

instance NFData GraphicsScene where
  rnf scene = foldr seq () (map spriteTexture' (sceneSprites (graphicsContent scene))) `seq` rnf (graphicsReferences scene) `seq` rnf (graphicsWorld scene)
    where
      -- Every field of the content is strict, so forcing the list's spine and each sprite is full normal form.
      spriteTexture' sprite = spriteTexture sprite `seq` sprite

-- | The scene a prepared scene makes: the content, and each distinct texture identity once.
graphicsScene ∷ PreparedScene → GraphicsScene
graphicsScene prepared =
  GraphicsScene
    (preparedContent prepared)
    (Set.fromList [viewIdentity (useView use) | use ← textureUses prepared])

-- | The scene of a window before its first publication: opaque black, empty, naming no texture. It is the
-- scene whose declaration, that it holds nothing a release frees, the host's configuration makes.
initialGraphicsScene ∷ GraphicsScene
initialGraphicsScene = GraphicsScene initialContent Set.empty

-- The ledger -----------------------------------------------------------------------------------------

data Adoption = Adoption
  { adoptionCount ∷ !Natural
  , adoptionHolds ∷ !(Set Word64)
  , adoptionChunks ∷ !(Set ChunkRef)
  , adoptionTag ∷ !(Maybe WorldTag)
  }

sameScene ∷ Adoption → Adoption → Bool
sameScene a b = adoptionHolds a == adoptionHolds b && adoptionChunks a == adoptionChunks b && adoptionTag a == adoptionTag b

data State w = State
  { stRecords ∷ !(Map (w, Natural) Adoption)
  , stInterests ∷ !(Map Word64 Natural)
    -- ^ Explicit protected interests in textures, by complete identity, with their counts.
  , stAdopted ∷ !Natural
    -- ^ Adoptions notified, ever.
  , stReleased ∷ !Natural
    -- ^ Releases notified, ever.
  , stDefects ∷ !Int
  , stFirstDefect ∷ !(Maybe Text)
  }

-- | The ledger of what the adopted revisions hold, keyed by the window's identity. The key is the host's
-- 'SceneTargetKey' in production ('ledgerLifecycle'): a window or an offscreen target, in one key space; it is a
-- parameter so that the lifecycle suite, which cannot
-- mint a window identity, drives the same ledger with any ordered key.
newtype SceneLedger w = SceneLedger (TVar (State w))

-- | A ledger with nothing adopted.
newSceneLedger ∷ IO (SceneLedger w)
newSceneLedger = SceneLedger <$> newTVarIO (State Map.empty Map.empty 0 0 0 Nothing)

-- | The two hooks the host is configured with. Both are one transaction over pure data on the owner's
-- thread: neither waits, calls Lua or raises.
ledgerLifecycle ∷ SceneLedger SceneTargetKey → SceneLifecycle GraphicsScene
ledgerLifecycle ledger =
  SceneLifecycle
    { sceneAdopted = \window revision scene → ledgerAdopted ledger window revision scene
    , sceneReleased = ledgerReleased ledger
    }

-- | The owner adopted this revision of the window, with this scene: hold what it names, once more.
ledgerAdopted ∷ (Ord w, Show w) ⇒ SceneLedger w → w → Natural → GraphicsScene → IO ()
ledgerAdopted (SceneLedger var) window revision scene = atomically (adopt var window revision (adoptionOf scene))

adoptionOf ∷ GraphicsScene → Adoption
adoptionOf scene =
  Adoption
    { adoptionCount = 1
    , adoptionHolds = sceneHolds scene
    , adoptionChunks = maybe Set.empty worldChunks (graphicsWorld scene)
    , adoptionTag = worldTag <$> graphicsWorld scene
    }

-- | One adoption of this revision of the window has been released: hold what it names once less.
ledgerReleased ∷ (Ord w, Show w) ⇒ SceneLedger w → w → Natural → IO ()
ledgerReleased (SceneLedger var) window revision = atomically (release var window revision)

adopt ∷ (Ord w, Show w) ⇒ TVar (State w) → w → Natural → Adoption → STM ()
adopt var window revision holds = do
  st ← readTVar var
  let key = (window, revision)
      counted = st {stAdopted = stAdopted st + 1}
  writeTVar var $ case Map.lookup key (stRecords st) of
    Nothing → counted {stRecords = Map.insert key holds (stRecords st)}
    Just found
      | sameScene found holds → counted {stRecords = Map.insert key found {adoptionCount = adoptionCount found + 1} (stRecords st)}
      | otherwise →
          -- A revision is one scene. Protect the union rather than lose a hold, and say so.
          defect
            ("a revision was adopted again under a different scene: window " <> Text.pack (show window) <> ", revision " <> Text.pack (show revision))
            counted
              { stRecords =
                  Map.insert
                    key
                    found
                      { adoptionCount = adoptionCount found + 1
                      , adoptionHolds = adoptionHolds found <> adoptionHolds holds
                      , adoptionChunks = adoptionChunks found <> adoptionChunks holds
                      }
                    (stRecords st)
              }

release ∷ (Ord w, Show w) ⇒ TVar (State w) → w → Natural → STM ()
release var window revision = do
  st ← readTVar var
  let key = (window, revision)
      counted = st {stReleased = stReleased st + 1}
  writeTVar var $ case Map.lookup key (stRecords st) of
    Nothing ->
      defect
        ("a revision was released that was not adopted: window " <> Text.pack (show window) <> ", revision " <> Text.pack (show revision))
        counted
    Just found
      | adoptionCount found > 1 → counted {stRecords = Map.insert key found {adoptionCount = adoptionCount found - 1} (stRecords st)}
      | otherwise → counted {stRecords = Map.delete key (stRecords st)}

defect ∷ Text → State w → State w
defect what st = st {stDefects = stDefects st + 1, stFirstDefect = Just (fromMaybe what (stFirstDefect st))}

-- | Whether this texture, by its complete identity, is held: by an adopted, unreleased revision, or by an
-- explicit interest ('ledgerRetainInterest'). The texture backend's release is gated on it.
ledgerHeld ∷ SceneLedger w → Word64 → STM Bool
ledgerHeld ledger@(SceneLedger var) identity = do
  adopted ← ledgerHolds ledger identity
  interests ← Map.findWithDefault 0 identity . stInterests <$> readTVar var
  pure (adopted > 0 || interests > 0)

-- | Whether any adopted, unreleased revision lists this retained chunk.
ledgerChunkHeld ∷ SceneLedger w → ChunkRef → STM Bool
ledgerChunkHeld (SceneLedger var) chunk = any (Set.member chunk . adoptionChunks) . Map.elems . stRecords <$> readTVar var

-- Interests ---------------------------------------------------------------------------------------------

-- | Take one explicit protected interest in a texture, by its complete identity: while any interest is held,
-- the texture backend does not release the texture's registration, whatever its lease. This is the continuing
-- authority of a holder that is not an adopted revision (a terrain view, from its attachment to its close); it
-- never clears a release flag and never makes a released handle publishable.
ledgerRetainInterest ∷ SceneLedger w → Word64 → STM ()
ledgerRetainInterest (SceneLedger var) identity = do
  st ← readTVar var
  writeTVar var st {stInterests = Map.insertWith (+) identity 1 (stInterests st)}

-- | Drop one interest taken with 'ledgerRetainInterest'. Dropping one that is not held is a defect of the
-- holder's pairing: counted, never raised, and the count is not driven below zero.
ledgerDropInterest ∷ (Show w) ⇒ SceneLedger w → Word64 → STM ()
ledgerDropInterest (SceneLedger var) identity = do
  st ← readTVar var
  writeTVar var $ case Map.lookup identity (stInterests st) of
    Nothing → defect ("an interest was dropped that was not held: texture " <> Text.pack (show identity)) st
    Just 1 → st {stInterests = Map.delete identity (stInterests st)}
    Just n → st {stInterests = Map.insert identity (n - 1) (stInterests st)}

-- | The interests held now, with their counts.
ledgerInterests ∷ SceneLedger w → STM (Map Word64 Natural)
ledgerInterests (SceneLedger var) = stInterests <$> readTVar var

-- The adopted world -------------------------------------------------------------------------------------

-- | The newest adopted, unreleased revision of a target, and the world tag of its scene (none for an M1 scene):
-- what the target shows now. An older revision a frame still uses stays held but is not what the target shows.
ledgerNewestAdopted ∷ Ord w ⇒ SceneLedger w → w → STM (Maybe (Natural, Maybe WorldTag))
ledgerNewestAdopted (SceneLedger var) target = do
  st ← readTVar var
  pure (foldr newer Nothing [(revision, adoptionTag found) | ((key, revision), found) ← Map.toList (stRecords st), key == target])
  where
    newer candidate = \case
      Just kept | fst kept >= fst candidate → Just kept
      _ → Just candidate

-- | How many adoptions hold this texture: for each window and revision, the count of its adoptions. A count is a
-- 'Natural', as a revision is: nothing here wraps, however many adoptions a long run makes.
ledgerHolds ∷ SceneLedger w → Word64 → STM Natural
ledgerHolds (SceneLedger var) identity =
  sum . map adoptionCount . filter (Set.member identity . adoptionHolds) . Map.elems . stRecords <$> readTVar var

-- | What the ledger holds now.
data LedgerReading w = LedgerReading
  { readingRecords ∷ ![((w, Natural), Natural)]
    -- ^ Each adopted, unreleased window and revision with its adoption count, in key order.
  , readingHeld ∷ !(Set Word64)
    -- ^ Every texture identity any adoption holds.
  , readingChunks ∷ !(Set ChunkRef)
    -- ^ Every retained chunk any adoption lists.
  , readingInterests ∷ !(Map Word64 Natural)
    -- ^ The explicit interests held, with their counts.
  , readingAdopted ∷ !Natural
  , readingReleased ∷ !Natural
  , readingDefects ∷ !Int
    -- ^ Pairing defects the hooks were told of: a release with no adoption, or an adoption under another
    -- scene. Zero in a host that keeps its contract.
  , readingFirstDefect ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

ledgerReading ∷ SceneLedger w → STM (LedgerReading w)
ledgerReading (SceneLedger var) = do
  st ← readTVar var
  pure
    LedgerReading
      { readingRecords = [(key, adoptionCount found) | (key, found) ← Map.toList (stRecords st)]
      , readingHeld = Set.unions (map adoptionHolds (Map.elems (stRecords st)))
      , readingChunks = Set.unions (map adoptionChunks (Map.elems (stRecords st)))
      , readingInterests = stInterests st
      , readingAdopted = stAdopted st
      , readingReleased = stReleased st
      , readingDefects = stDefects st
      , readingFirstDefect = stFirstDefect st
      }
