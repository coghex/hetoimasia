-- | THE ONE PUBLICATION DECISION of the backed terrain owner (TRA-22, requirement 3).
--
-- Every new committed root of every arena becomes authoritative here and nowhere else: a
-- removal with its connection obligation, a discovery batch, a reclamation step and a
-- creator's growth all pass 'decide'. It is ONE transaction that rechecks what the
-- publication assumes and, when every check holds, writes the forced new state, retires
-- the transaction's slot and its credits and delivers the request's result, all at once.
-- Whatever wins first wins entirely: a cancellation, a lease release, a close or the
-- parent session's end that commits before it leaves the old root, content, knowledge and
-- frontier authoritative; a decision that commits first makes every later cancellation
-- answer that the request was already settled.
--
-- == What is prepared BEFORE the decision, outside it
--
-- 'prepareDecision' builds the whole new state as values and forces them: the next 'Store'
-- (the pure 'publish' of the eligible transaction), the next authority and its checked
-- revision increments (requirement 6: content advances exactly when terrain changed,
-- knowledge exactly when knowledge changed, the store on every commit; none wraps), the
-- removal's answer and the cell's rebuilt resident segment, and a growth's answer. Any of
-- that which fails is refused there, as a defect, before anything is decided.
--
-- == What the decision does, in order
--
-- Reads and comparisons only (table (C) of the pull request lists each with where its
-- value was prepared):
--
-- 1. The service is running and the parent session admits.
-- 2. The arena is live, with the store identity the transaction was planned for.
-- 3. The arena's committed version is the plan's base, and its active transaction is
--    this one.
-- 4. For a request: it is still in the table, and its staging is still current.
-- 5. For a request: the host's 'endpointEligible'.
-- 6. For a removal: its content precondition still holds (@stale_view@).
-- 7. For a removal: the cell's region is still resident with the generation the rebuild
--    was computed over.
--
-- Then the writes, none of which can fail on a state the checks admitted: the accounting
-- model's events (a refusal there is an accounting DEFECT: the transaction is abandoned
-- with 'throwSTM', nothing is written, and the owner ends supervised), the new store and
-- resident detail, the request's result, the release of the transaction's edit-bank
-- credits, the slot, and LAST the host's 'endpointSettle' (a callback that throws
-- abandons all of it). Nothing fallible, allocating beyond what the transaction holds,
-- native or Lua runs inside.
--
-- == What runs after
--
-- Nothing the publication depends on: the slot, the credits, the readmission of the
-- requests the commit superseded and the wake of every waiter are all inside the one
-- transaction, so there is no step after the commit that an asynchronous exception
-- could separate from it. Only diagnostics (a probe point, a log record) follow.
module Hetoimasia.Terrain.Runtime.Internal.Publish
  ( Decision (..)
  , DecisionFor (..)
  , Verdict (..)
  , prepareDecision
  , prepareGrowthDecision
  , checkedIncrements
  , decide
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception)
import Control.Monad (forM_, unless, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Coordinate (TileCoord, decomposeTile)
import Hetoimasia.Terrain.Palette (Palette)
import qualified Hetoimasia.Terrain.Residency as R
import Hetoimasia.Terrain.Residency (ArenaId, RequestId, Revision (..))
import Hetoimasia.Terrain.Resident (Resident)
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (PreparedGrowth, commitBackingGrowthSTM)
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Grant)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (StoreIdentity)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( ActiveView (..)
  , Published (..)
  , Store
  , TxnId
  , activeView
  , commitGrowth
  , publish
  , storeConfig
  , storeHeader
  , storeIdentity
  , storeVersion
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Effects (..), Plan, plEffects, plIdentity, pidBaseVersion)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes)

-- | Everything a publication writes, prepared and forced before the decision.
data Decision = Decision
  { decArena ∷ !ArenaId
  , decIdentity ∷ !StoreIdentity
  , decBase ∷ !Word64
  , -- | The transaction the publication ends ('Nothing' for a growth, which publishes no
    -- roots: its decision commits the cap with nothing active in the store).
    decTxn ∷ !(Maybe TxnId)
  , decNext ∷ !Store
  , -- | The authority once published.
    decAuthority ∷ !D.Authority
  , decFor ∷ !DecisionFor
  }

-- | What the publication is for, with what it delivers.
data DecisionFor
  = -- | A removal with its obligation: the request, the cell and its precondition, the
    -- answer, the region's generation the rebuild was computed over, and the rebuild
    -- (palette, resident detail, the bytes the rebuilt segment grew).
    ForRemoval !RequestId !TileCoord !(Maybe Precondition) !RemoveAnswer !Word64 !Palette !Resident !Word64
  | -- | A discovery batch or a reclamation step: no request, no settlement.
    ForBatch
  | -- | A creator's growth: the backend's prepared extra range is committed with the
    -- store's cap and the request's answer.
    ForGrowth !RequestId !PreparedGrowth !GrowAnswer

-- | How a decision ended. Only 'Committed' wrote anything.
data Verdict
  = -- | Published: the new roots, revisions and result are authoritative together.
    Committed !D.Authority
  | -- | A cancellation, a release, a close, the arena's end or the service's closing won:
    -- nothing was written; the holder drains and ends.
    LostToEnd
  | -- | The host is not (or no longer) eligible: nothing was written; the holder aborts
    -- without a write and waits again, holding no slot.
    NotEligible
  | -- | The request's staging no longer holds (the content moved): nothing was written;
    -- the holder aborts and the request is staged again.
    StagingMoved
  deriving stock (Eq, Show)

-- | A defect found inside the decision: the accounting model refused an event the checks
-- admitted. It abandons the whole transaction (nothing written) and ends the owner.
newtype DecisionDefect = DecisionDefect Text
  deriving stock (Show)

instance Exception DecisionDefect

-- | The revision rule (requirement 6), checked BEFORE the decision against the authority
-- the plan was made on: content advances by exactly one when the plan changes terrain and
-- not otherwise, knowledge likewise, the store by exactly one on every commit, the arena
-- never changes, and nothing wraps (an increment past the last value is refused here; #661
-- refuses it at staging first).
checkedIncrements ∷ D.Authority → Effects → Either Text D.Authority
checkedIncrements base effects = do
  let next = effAuthority effects
      step what before after changed
        | after == before && not changed = Right ()
        | changed && before /= maxBound && after == before + 1 = Right ()
        | otherwise = Left (Text.pack (what <> " revision " <> show before <> " -> " <> show after <> " for a plan that " <> (if changed then "changes" else "does not change") <> " it"))
      rev (Revision n) = n
  when (D.authArena next /= D.authArena base) (Left "a plan names another incarnation")
  step "content" (rev (D.authContent base)) (rev (D.authContent next)) (effTerrain effects)
  step "knowledge" (rev (D.authKnowledge base)) (rev (D.authKnowledge next)) (effKnowledge effects)
  step "store" (rev (D.authStore base)) (rev (D.authStore next)) True
  Right next

-- | Build the decision's writes from an eligible transaction, outside any transaction, and
-- check them. The caller forces the result before it decides.
prepareDecision ∷ ArenaId → Store → TxnId → Plan → DecisionFor → Either Text Decision
prepareDecision aid store tid plan for = do
  (published, next) ← either (Left . Text.pack . ("the store refused to publish an eligible transaction: " <>) . show) Right (publish tid store)
  _ ← checkedIncrements (D.hAuthority (storeHeader store)) (pubEffects published)
  unless (D.hAuthority (storeHeader next) == effAuthority (pubEffects published)) (Left "the published header is not the plan's authority")
  Right
    Decision
      { decArena = aid
      , decIdentity = storeIdentity store
      , decBase = pidBaseVersion (plIdentity plan)
      , decTxn = Just tid
      , decNext = next
      , decAuthority = effAuthority (plEffects plan)
      , decFor = for
      }

-- | Build a growth's decision: the store with its larger allowance committed ('commitGrowth',
-- which clears only a capacity pause), and its answer.
prepareGrowthDecision ∷ ArenaId → Store → RequestId → PreparedGrowth → Either Text Decision
prepareGrowthDecision aid store rid prepared = do
  next ← either (Left . Text.pack . ("the store refused to commit an obtained growth: " <>) . show) Right (commitGrowth store)
  Right
    Decision
      { decArena = aid
      , decIdentity = storeIdentity store
      , decBase = storeVersion store
      , decTxn = Nothing
      , decNext = next
      , decAuthority = D.hAuthority (storeHeader store)
      , decFor = ForGrowth rid prepared (GrowAnswer aid (cfgAllowanceBytes (storeConfig next)) True)
      }

-- | THE decision. One transaction; see the module header for what it checks and writes.
-- The owner calls it masked, with the decision forced.
decide ∷ Service → Maybe Grant → Decision → STM Verdict
decide svc credit dec = do
  open ← sessionOpen (serviceAdmission svc)
  st ← readSt svc
  let aid = decArena dec
  case Map.lookup aid (stateArenas st) of
    _ | statePhase st /= Running || not open → pure LostToEnd
    Nothing → pure LostToEnd
    Just arena
      | storeIdentity (arenaStore arena) /= decIdentity dec → pure LostToEnd
      | storeVersion (arenaStore arena) /= decBase dec || fmap avId (activeView (arenaStore arena)) /= decTxn dec →
          throwSTM (DecisionDefect "the committed store is not the base of the transaction the owner holds")
      | otherwise → case decFor dec of
          ForBatch → do
            commitStore arena []
            slotDone True
            markFreed svc
            pure (Committed (decAuthority dec))
          ForRemoval rid tile precondition answer generation palette resident growth → case Map.lookup rid (stateRequests st) of
            Nothing → pure LostToEnd
            Just req
              | not (stagedCurrent req arena) → pure StagingMoved
              | otherwise → do
                  eligible ← endpointEligible (reqEndpoint req)
                  if not eligible
                    then pure NotEligible
                    else
                      if staleView precondition aid arena
                        then do
                          -- the precondition no longer holds: the removal settles stale_view with nothing
                          -- changed; the transaction is the holder's to abort (it publishes nothing)
                          terminateWith False svc rid (Failed StaleView)
                          pure LostToEnd
                        else do
                          let (region, _) = decomposeTile tile
                          unless (regionGeneration st aid region == Just generation) $
                            throwSTM (DecisionDefect "the cell's region changed between the rebuild and the decision")
                          modelEvent (R.RemovalCommitted rid (D.authContent (decAuthority dec)) 0 growth)
                          -- the commit is backed already: the region's detail is a cache again at once, with no
                          -- transfer and no duplicate (requirement 6: offload needs no new authoritative write)
                          modelEvent (R.BeginHandoff aid region 0)
                          modelEvent (R.HandoffConfirmed aid region)
                          commitStore arena [(rid, palette, resident)]
                          modifySt svc (\s → s {stateRequests = Map.insert rid req {reqPhase = Done, reqModel = False} (stateRequests s)})
                          readmitSuperseded aid rid
                          slotDone False
                          markFreed svc
                          endpointSettle (reqEndpoint req) (Succeeded (ARemoved answer))
                          pure (Committed (decAuthority dec))
          ForGrowth rid prepared answer → case Map.lookup rid (stateRequests st) of
            Nothing → pure LostToEnd
            Just req → do
              eligible ← endpointEligible (reqEndpoint req)
              if not eligible
                then pure NotEligible
                else do
                  commitBackingGrowthSTM (serviceStorage svc) (arenaBacking arena) prepared >>= \case
                    Left failure → throwSTM (DecisionDefect (Text.pack ("the backend refused the cap of a prepared growth: " <> show failure)))
                    Right () → pure ()
                  commitStore arena []
                  releaseReq svc rid req
                  slotDone False
                  markFreed svc
                  endpointSettle (reqEndpoint req) (Succeeded (AGrown answer))
                  pure (Committed (decAuthority dec))
  where
    modelEvent event =
      applyEvent svc event >>= \case
        Left refusal → throwSTM (DecisionDefect (Text.pack ("the accounting model refused " <> show event <> ": " <> show refusal)))
        Right _ → pure ()
    -- the new store, and for a removal the rebuilt detail, in one write
    commitStore arena rebuilt =
      modifySt svc $ \s →
        s
          { stateArenas =
              Map.insert
                (decArena dec)
                ( case rebuilt of
                    [(_, palette, resident)] → arena {arenaStore = decNext dec, arenaPalette = palette, arenaResident = resident, arenaGeneration = bumpGeneration (arenaGeneration arena)}
                    _ → arena {arenaStore = decNext dec}
                )
                (stateArenas s)
          }
    -- the slot ends with the publication, and its credits return in the same transaction
    slotDone internal = do
      forM_ credit $ \g → modifyTVar' (serviceEditBank svc) (releaseCredit g)
      modifySt svc $ \s →
        s
          { stateSlot = Nothing
          , stateExplicitRun = if internal then 0 else stateExplicitRun s + 1
          }
    staleView precondition aid arena = case precondition of
      Just (Precondition pa pr) → pa /= aid || pr /= arenaRevision arena
      Nothing → False
    stagedCurrent req arena = case reqPhase req of
      StagedPhase sg → stagedRevision sg == arenaRevision arena
      Waiting → False
      Done → False
    -- every other pending removal of the arena, and every read that lost its staging to the
    -- commit, is admitted again at the new revision (as the baseline commit did)
    readmitSuperseded aid rid = do
      after ← readSt svc
      let others =
            [ r
            | (r, q) ← sortOn (reqSeq . snd) (Map.toList (stateRequests after))
            , r /= rid
            , reqArena q == Just aid
            , case reqPhase q of Done → False; _ → True
            , case reqCmd q of CRemove {} → True; CCell {} → True; CColumn {} → True; CSurface {} → True; CKnowledge {} → True; _ → False
            ]
      forM_ others (readmitSTM svc)
    regionGeneration st aid region =
      case [R.regionGeneration r | r ← R.modelRegions (stateModel st), R.regionArena r == aid, R.regionCoord r == region] of
        g : _ → Just g
        [] → Nothing
