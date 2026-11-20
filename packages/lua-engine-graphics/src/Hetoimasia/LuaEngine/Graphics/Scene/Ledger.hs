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
-- opaque black, empty, naming nothing. A terrain view's revision is a world scene ('worldGraphicsScene'): the
-- initial content, naming nothing, and the world ("Hetoimasia.LuaEngine.Graphics.Scene.World"), which names its
-- own retained chunks and textures.
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
-- release of a revision adopted twice drop the protection of the second. An adoption of a world scene holds its
-- chunks as well as its textures ('ledgerChunkHeld').
--
-- = Interests
--
-- A holder that is not an adopted revision can take an explicit interest in a texture ('ledgerRetainInterest'): a
-- terrain view holds its style's two parents from its attachment to its close, so the texture backend, whose release
-- is gated on 'ledgerHeld', does not release their registrations meanwhile, whatever their leases.
--
-- = The listener
--
-- One transaction a holder installs ('ledgerListen'), run inside every adoption and release: the terrain views of
-- the session ask for the graphics owner's next step with it, so a retirement waiting for a release is looked at
-- again. It must not wait or raise.
--
-- = Owned state, threads and lifetime
--
-- +--------------+--------+-----------------------+------------------------+------------------------------+
-- | State        | Owner  | Writers               | Readers                | Lifetime and disposal        |
-- +==============+========+=======================+========================+==============================+
-- | The records  | the    | the two hooks, on the | any thread, in STM     | made before the host is built |
-- | (one for each| ledger | owner's thread        | (the texture backend's | and never reset; a record    |
-- | window and   |        |                       | release, the views,    | goes with its last release   |
-- | revision)    |        |                       | the tests)             |                              |
-- +--------------+--------+-----------------------+------------------------+------------------------------+
-- | Interests    | the    | a terrain view (STM,  | the texture backend's  | an interest goes with its    |
-- |              | ledger | any thread)           | release                | holder's drop                |
-- +--------------+--------+-----------------------+------------------------+------------------------------+
-- | The listener | the    | the terrain views'    | the two hooks          | replaced by the next holder; |
-- |              | ledger | scope (install, clear)|                        | cleared at its scope's end   |
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
  , initialGraphicsScene
  , worldGraphicsScene
  , sceneHolds

    -- * The ledger
  , SceneLedger
  , newSceneLedger
  , ledgerLifecycle
  , ledgerAdopted
  , ledgerReleased
  , ledgerHeld
  , ledgerHolds
  , ledgerChunkHeld
  , ledgerTagHeld

    -- * Interests
  , ledgerRetainInterest
  , ledgerDropInterest

    -- * The listener
  , ledgerListen

    -- * Reading
  , LedgerReading (..)
  , ledgerReading
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad (join)
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
-- revision, the world it draws instead.
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

-- | A terrain view's revision: the initial content, naming nothing, and the world.
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
  , stAdopted ∷ !Natural
    -- ^ Adoptions notified, ever.
  , stReleased ∷ !Natural
    -- ^ Releases notified, ever.
  , stDefects ∷ !Int
  , stFirstDefect ∷ !(Maybe Text)
  , stInterests ∷ !(Map Word64 Natural)
    -- ^ Explicit interests in textures, by complete identity, with their counts.
  }

-- | The ledger of what the adopted revisions hold, keyed by the window's identity. The key is the host's
-- 'SceneTargetKey' in production ('ledgerLifecycle'): a window or an offscreen target, in one key space; it is a
-- parameter so that the lifecycle suite, which cannot
-- mint a window identity, drives the same ledger with any ordered key.
data SceneLedger w = SceneLedger !(TVar (State w)) !(TVar (STM ()))

-- | A ledger with nothing adopted, no interest and a listener that does nothing.
newSceneLedger ∷ IO (SceneLedger w)
newSceneLedger = SceneLedger <$> newTVarIO (State Map.empty 0 0 0 Nothing Map.empty) <*> newTVarIO (pure ())

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
ledgerAdopted (SceneLedger var listener) window revision scene = atomically $ do
  adopt var window revision (Adoption 1 (sceneHolds scene) (maybe Set.empty worldChunks (graphicsWorld scene)) (worldTag <$> graphicsWorld scene))
  join (readTVar listener)

-- | One adoption of this revision of the window has been released: hold what it names once less.
ledgerReleased ∷ (Ord w, Show w) ⇒ SceneLedger w → w → Natural → IO ()
ledgerReleased (SceneLedger var listener) window revision = atomically $ do
  release var window revision
  join (readTVar listener)

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
            counted {stRecords = Map.insert key (Adoption (adoptionCount found + 1) (adoptionHolds found <> adoptionHolds holds) (adoptionChunks found <> adoptionChunks holds) (adoptionTag found)) (stRecords st)}

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
ledgerHeld ledger@(SceneLedger var _) identity = do
  adopted ← ledgerHolds ledger identity
  interests ← Map.findWithDefault 0 identity . stInterests <$> readTVar var
  pure (adopted > 0 || interests > 0)

-- | Whether any adopted, unreleased revision lists this retained chunk.
ledgerChunkHeld ∷ SceneLedger w → ChunkRef → STM Bool
ledgerChunkHeld (SceneLedger var _) chunk = any (Set.member chunk . adoptionChunks) . Map.elems . stRecords <$> readTVar var

-- | Whether an adopted, unreleased revision of this target is the world with this tag: a revision that can still be
-- drawn, or whose frames are still in flight.
ledgerTagHeld ∷ Eq w ⇒ SceneLedger w → w → WorldTag → STM Bool
ledgerTagHeld (SceneLedger var _) target tag =
  any (\((key, _), adoption) → key == target && adoptionTag adoption == Just tag) . Map.toList . stRecords <$> readTVar var

-- | Take one explicit interest in a texture, by its complete identity: while any interest is held, the texture
-- backend does not release the texture's registration. It never makes a released handle publishable.
ledgerRetainInterest ∷ SceneLedger w → Word64 → STM ()
ledgerRetainInterest (SceneLedger var _) identity = do
  st ← readTVar var
  writeTVar var st {stInterests = Map.insertWith (+) identity 1 (stInterests st)}

-- | Drop one interest taken with 'ledgerRetainInterest'. Dropping one that is not held is a defect of the holder's
-- pairing: counted, never raised, and the count is not driven below zero.
ledgerDropInterest ∷ SceneLedger w → Word64 → STM ()
ledgerDropInterest (SceneLedger var _) identity = do
  st ← readTVar var
  writeTVar var $ case Map.lookup identity (stInterests st) of
    Nothing → defect ("an interest was dropped that was not held: texture " <> Text.pack (show identity)) st
    Just 1 → st {stInterests = Map.delete identity (stInterests st)}
    Just n → st {stInterests = Map.insert identity (n - 1) (stInterests st)}

-- | Install the transaction every adoption and release runs after its own ('pure ()' clears it). It must not wait
-- or raise.
ledgerListen ∷ SceneLedger w → STM () → STM ()
ledgerListen (SceneLedger _ listener) = writeTVar listener

-- | How many adoptions hold this texture: for each window and revision, the count of its adoptions. A count is a
-- 'Natural', as a revision is: nothing here wraps, however many adoptions a long run makes.
ledgerHolds ∷ SceneLedger w → Word64 → STM Natural
ledgerHolds (SceneLedger var _) identity =
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
ledgerReading (SceneLedger var _) = do
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
