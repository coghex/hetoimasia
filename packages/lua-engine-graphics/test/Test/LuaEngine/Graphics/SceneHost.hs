-- | A stand-in for the window integration's scene ledger (@Scenes.hs@), for the lifecycle suite.
--
-- /Injected evidence, and it says so./ The suite cannot reach the real ledger through public interfaces: the
-- integration's controller is private, and the only public composition is a whole host over a loader. This model
-- applies the rules that module documents, so the M1 adapter's own bookkeeping is judged under them; the real
-- ledger's behaviour is proved by the integration's own suite and, composed with the adapter, by the native scene
-- retention subgroup. It proves ordering and ownership, never a frame.
--
-- The rules it applies:
--
-- * a window has one latest published scene, and publication is a latest-value replacement that rises one revision
--   and never waits; a window with no publication is at revision 0;
-- * a target /adopts/ the latest revision when it is newer than the last it adopted (or it adopted nothing), and
--   only while it holds fewer than six unreleased revisions; adopting runs the lifecycle's adopted hook with the
--   exact scene taken, and a revision published and replaced before a step takes it is never adopted;
-- * the same revision can be adopted again under a new attachment, each adoption released on its own;
-- * an adoption is released once it is superseded (a newer revision adopted for the target, or the target ended)
--   and every use recorded with it is over, in adoption order for each window, and never otherwise;
-- * a release request captures a barrier: for every window the host holds, the latest published revision, leaving
--   out windows with no publication (the declared initial scene holds nothing). It is met when each such window's
--   live target has adopted that revision, or the window is gone. A published window with no live target holds it.
--
-- Nothing sleeps; each step is a call the example makes.
module Test.LuaEngine.Graphics.SceneHost
  ( Model
  , newModel
  , modelLedger
  , modelWindow
  , modelTarget
  , modelCapture
  , setUsable
  , closeHost
  , Step (..)
  , adoptNow
  , adoptFor
  , beginUse
  , endUse
  , endTarget
  , removeWindow
  , releasePass
  , dissolve
  , publishedRevision
  , latestScene
  , adoptedRecords
  , retentionLimit
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Control.Monad (forM_)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger
  ( GraphicsScene
  , SceneLedger
  , ledgerAdopted
  , ledgerReleased
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (HostAnswer (..))
import Numeric.Natural (Natural)

-- | One adoption that has not been released.
data Rec = Rec
  { recRevision ∷ !Natural
  , recAttachment ∷ !Int
  , recUses ∷ !Int
  , recEnded ∷ !Bool
    -- ^ Its target ended.
  }

data Win = Win
  { winPublished ∷ !Natural
  , winLatest ∷ !(Maybe GraphicsScene)
  , winTarget ∷ !(Maybe Int)
    -- ^ The live target's attachment, if it has one.
  , winWatermark ∷ !Natural
    -- ^ The highest revision the live target has adopted and been notified of.
  , winLastAdopted ∷ !(Map Int Natural)
  , winRecs ∷ ![Rec]
    -- ^ Oldest adoption first.
  , winUsable ∷ !Bool
  }

data Model = Model
  { mWindows ∷ !(TVar (Map Int Win))
  , mClosed ∷ !(TVar Bool)
  , mLedger ∷ !(SceneLedger Int)
  }

-- | The host's retention limit for the M1 profile: two frame slots, so 2 * (2 + 1).
retentionLimit ∷ Int
retentionLimit = 6

-- | A model over this ledger (the one the fake owner's port reads).
newModel ∷ SceneLedger Int → IO Model
newModel ledger = Model <$> newTVarIO Map.empty <*> newTVarIO False <*> pure ledger

modelLedger ∷ Model → SceneLedger Int
modelLedger = mLedger

-- | The host holds a window with this number, at revision 0 with no target.
modelWindow ∷ Model → Int → IO ()
modelWindow model window = atomically (modifyTVar' (mWindows model) (Map.insert window (Win 0 Nothing Nothing 0 Map.empty [] True)))

-- | The window's capability, as the window provider's port yields it: publish, and whether the incarnation is
-- usable.
modelTarget ∷ Model → Int → (Prepared GraphicsScene → IO HostAnswer, STM Bool)
modelTarget model window = (publishing, usable)
  where
    publishing scene = atomically $ do
      closed ← readTVar (mClosed model)
      windows ← readTVar (mWindows model)
      case Map.lookup window windows of
        _ | closed → pure HostAnsweredClosed
        Nothing → pure HostAnsweredUnknown
        Just found → do
          writeTVar (mWindows model) (Map.insert window found {winPublished = winPublished found + 1, winLatest = Just (preparedValue scene)} windows)
          pure HostAccepted
    usable = maybe False winUsable . Map.lookup window <$> readTVar (mWindows model)

-- | Whether the window's incarnation is the admitted one: the example makes it not so.
setUsable ∷ Model → Int → Bool → IO ()
setUsable model window usable = atomically (modifyTVar' (mWindows model) (Map.adjust (\found → found {winUsable = usable}) window))

-- | The host's publications end with its exit.
closeHost ∷ Model → IO ()
closeHost model = atomically (writeTVar (mClosed model) True)

-- | What a release request captures at its admission, in the host's terms.
modelCapture ∷ Model → STM (STM Bool)
modelCapture model = do
  windows ← readTVar (mWindows model)
  -- Windows with no publication stay out of the barrier: the declared initial scene holds nothing.
  let named = [(window, winPublished found) | (window, found) ← Map.toList windows, winPublished found > 0]
  pure $ do
    now ← readTVar (mWindows model)
    pure (all (met now) named)
  where
    met now (window, revision) = case Map.lookup window now of
      Nothing → True
      Just found → winTarget found /= Nothing && winWatermark found >= revision

-- | What a step did.
data Step = Adopted !Natural | Deferred | NothingNew | NoTarget
  deriving (Eq, Show)

-- | The window's target (attachment 1) takes the latest scene, if it should.
adoptNow ∷ Model → Int → IO Step
adoptNow model window = adoptFor model window 1

-- | The window's target under this attachment takes the latest scene, if it should: newer than the last that
-- attachment adopted, and below the retention limit. A target is attached the first time it adopts.
adoptFor ∷ Model → Int → Int → IO Step
adoptFor model window attachment = do
  taken ← atomically $ do
    windows ← readTVar (mWindows model)
    case Map.lookup window windows of
      Nothing → pure NoTarget'
      Just found → do
        let revision = winPublished found
            scene = maybe (error "no scene") id (winLatest found)
            last' = Map.lookup attachment (winLastAdopted found)
            fresh = case last' of
              Nothing → True
              Just seen → revision > seen
            unreleased = length [() | rec ← winRecs found, recAttachment rec == attachment]
        case () of
          _
            | revision == 0 → pure NoTarget'
            | not fresh → pure Nothing'
            | unreleased >= retentionLimit → pure Full'
            | otherwise → do
                let rec = Rec revision attachment 0 False
                    adopted =
                      found
                        { winTarget = Just attachment
                        , winLastAdopted = Map.insert attachment revision (winLastAdopted found)
                        , winRecs = winRecs found <> [rec]
                        }
                writeTVar (mWindows model) (Map.insert window adopted windows)
                pure (Took' revision scene)
  case taken of
    NoTarget' → pure NoTarget
    Nothing' → pure NothingNew
    Full' → pure Deferred
    Took' revision scene → do
      -- The hook runs, then the watermark rises: a barrier reads the watermark.
      ledgerAdopted (mLedger model) window revision scene
      atomically (modifyTVar' (mWindows model) (Map.adjust (\found → found {winWatermark = max revision (winWatermark found)}) window))
      pure (Adopted revision)

data Taken = NoTarget' | Nothing' | Full' | Took' !Natural !GraphicsScene

-- | A frame recorded with this adopted revision begins: the revision cannot be released until it ends.
beginUse ∷ Model → Int → Natural → Int → IO ()
beginUse model window revision attachment = atomically (modifyTVar' (mWindows model) (Map.adjust (changeRec revision attachment (\rec → rec {recUses = recUses rec + 1})) window))

-- | That frame's use is over: its completion was observed.
endUse ∷ Model → Int → Natural → Int → IO ()
endUse model window revision attachment = atomically (modifyTVar' (mWindows model) (Map.adjust (changeRec revision attachment (\rec → rec {recUses = max 0 (recUses rec - 1)})) window))

changeRec ∷ Natural → Int → (Rec → Rec) → Win → Win
changeRec revision attachment change found =
  found {winRecs = [if recRevision rec == revision && recAttachment rec == attachment then change rec else rec | rec ← winRecs found]}

-- | The target under this attachment ends: its adoptions are superseded, and it no longer counts for a barrier.
endTarget ∷ Model → Int → Int → IO ()
endTarget model window attachment =
  atomically . modifyTVar' (mWindows model) . Map.adjust end $ window
  where
    end found =
      found
        { winRecs = [if recAttachment rec == attachment then rec {recEnded = True} else rec | rec ← winRecs found]
        , winTarget = if winTarget found == Just attachment then Nothing else winTarget found
        }

-- | Every window is gone, every use is over and every adoption released: the end of an example, however it ended.
dissolve ∷ Model → IO ()
dissolve model = do
  windows ← readTVarIO (mWindows model)
  forM_ (Map.keys windows) $ \window → do
    atomically . modifyTVar' (mWindows model) . Map.adjust (\found → found {winRecs = [rec {recUses = 0} | rec ← winRecs found]}) $ window
    removeWindow model window

-- | The window is gone: its target ends and the host no longer holds it.
removeWindow ∷ Model → Int → IO ()
removeWindow model window = do
  atomically $ modifyTVar' (mWindows model) $ Map.adjust (\found → found {winRecs = [rec {recEnded = True} | rec ← winRecs found], winTarget = Nothing}) window
  _ ← releasePass model
  atomically (modifyTVar' (mWindows model) (Map.delete window))

-- | Release what may be: an adoption that is superseded (a newer adoption of the same attachment exists, or its
-- target ended) with no use outstanding, in adoption order for each window, stopping a window at the first that may
-- not. Answers the (window, revision) pairs released, in order.
releasePass ∷ Model → IO [(Int, Natural)]
releasePass model = do
  windows ← readTVarIO (mWindows model)
  released ← fmap concat . traverse (releaseWindow model) $ Map.keys windows
  pure released

releaseWindow ∷ Model → Int → IO [(Int, Natural)]
releaseWindow model window = go []
  where
    go done = do
      next ← atomically $ do
        windows ← readTVar (mWindows model)
        case Map.lookup window windows of
          Nothing → pure Nothing
          Just found -> case winRecs found of
            rec : rest
              | superseded found rec && recUses rec == 0 → do
                  writeTVar (mWindows model) (Map.insert window found {winRecs = rest} windows)
                  pure (Just rec)
            _ → pure Nothing
      case next of
        Nothing → pure (reverse done)
        Just rec → do
          ledgerReleased (mLedger model) window (recRevision rec)
          go ((window, recRevision rec) : done)
    superseded found rec =
      recEnded rec || any (\other → recAttachment other == recAttachment rec && recRevision other > recRevision rec) (winRecs found)

-- | The window's latest published revision.
publishedRevision ∷ Model → Int → IO Natural
publishedRevision model window = maybe 0 winPublished . Map.lookup window <$> readTVarIO (mWindows model)

-- | The window's latest published scene.
latestScene ∷ Model → Int → IO (Maybe GraphicsScene)
latestScene model window = (>>= winLatest) . Map.lookup window <$> readTVarIO (mWindows model)

-- | The window's unreleased adoptions: revision, attachment and outstanding uses, oldest first.
adoptedRecords ∷ Model → Int → IO [(Natural, Int, Int)]
adoptedRecords model window = maybe [] (map (\rec → (recRevision rec, recAttachment rec, recUses rec)) . winRecs) . Map.lookup window <$> readTVarIO (mWindows model)

