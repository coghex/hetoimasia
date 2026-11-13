-- | The owner's transaction runner ("Hetoimasia.Terrain.Runtime.Backed.Txn") through the
-- PRODUCTION storage backend, on real files.
--
-- Nothing here replaces the transaction with an in-memory imitation: the plan is made by the
-- production planner through the production protocol driver, its pages are read from and
-- written to the arena's real reserved file by the backend's two workers, and what the file
-- holds afterwards is read back page by page and compared with an independent reference of the
-- expected records (#661's own plain retained model, applied to the same candidates).
--
-- The waits are one blocking STM wait on the job the runner names ('Blocked'), as the owner
-- composes them with its other sources: no example polls, and none sleeps. A fault is injected
-- at the backend's native seam, so a failure is a real worker meeting a real error, not a
-- doctored outcome.
module Test.TerrainRuntime.Backed.Txn (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask_)
import Control.Monad (foldM, forM, forM_)
import qualified Data.Map.Strict as Map
import Data.Int (Int64)
import Data.Maybe (isJust)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..), Retained, allowanceOf, applyCandidate, envLimits, newRetained, retainedHeader, retainedProvider, retainedRecords, stageRemoval)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Backed.Gather
import Hetoimasia.Terrain.Runtime.Backed.Txn
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service (ReadMode (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..), WorkClass (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..), Store, acquireReader, publish, storeConfig, storeRoots, storeVersion)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (plPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (removalPlanner)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (maxReaders, rHw)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
  ( Act (..)
  , Env (..)
  , addGate
  , addRule
  , awaitReached
  , countEvents
  , openAllGates
  , openBacking
  , openGate
  , readPages
  , withEnv
  )
import Test.TerrainRuntime.Store.Harness (H (..), checkH, columnAt, compareRecords, ident0, newH, smallSpec, tileAt)
import Test.TerrainRuntime.Store.Reference (diskWrite, emptyDisk)
import Test.TerrainRuntime.Store.Scenes (envFor, limitsWith, sealedStack)

-- | The environment of a scene, as #661's discovery model is configured for it.
sceneEnv ∷ D.Env
sceneEnv = envFor (limitsWith 64) sealedStack

-- | Settle a run: take every step that needs no waiting, wait (one blocking transaction) for the
-- job the runner names, and go on. Called masked, as the owner calls it.
settle ∷ Io → Store → Run → IO (Store, Run, Progress)
settle io store run = do
  (store', run', progress) ← mask_ (advance io OwnerRunning store run)
  case progress of
    More → settle io store' run'
    Blocked wait → atomically wait >> settle io store' run'
    ReadyToPublish {} → pure (store', run', progress)
    Finished _ → pure (store', run', progress)

-- | What an owner opens: a backing over the arena's reserved file, for a store of the 64 MiB
-- allowance, and the runner's view of both.
withArena ∷ (Env → Io → Store → IO a) → IO a
withArena body = withEnv $ \env → do
  let h = newH smallSpec ident0
  backing ← openBacking env ident0 (hCfg h)
  body env (Io (envSvc env) backing ExplicitWork) (hStore h)

-- | Remove one cell through the runner, and publish when it is ready (the owner's arbitration,
-- here unconditional).
removeAndPublish ∷ Io → Store → TileCoord → IO (Either Done Store)
removeAndPublish io store tile = do
  (store', _, progress) ← settle io store (start store (removalPlanner sceneEnv store tile))
  case progress of
    ReadyToPublish tid _ → case publish tid store' of
      Right (_, published) → pure (Right published)
      Left refusal → fail ("publish refused: " <> show refusal)
    Finished d → pure (Left d)
    Blocked _ → fail "settle returned a wait"
    More → fail "settle returned a step"

-- | The claims of an ended transaction are retired: the store takes the next transaction from the same
-- committed root (a claim left behind would refuse it as busy).
plansAgain ∷ Io → Store → IO ()
plansAgain io store = do
  (_, _, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 3 3 3)))
  case progress of
    ReadyToPublish {} → pure ()
    Finished d → expectationFailure ("the next transaction was refused: " <> show d)
    Blocked _ → expectationFailure "settle returned a wait"
    More → expectationFailure "settle returned a step"

-- | Read the runs of columns from the committed version through the backend, as the owner does: every
-- step masked, one blocking wait between steps. The pin is released on every exit.
gatherRuns ∷ Io → Int → Store → [Column] → IO (Store, GProgressResult, Int)
gatherRuns io pin store0 columns = case startGatherWith pin store0 columns of
  Left refusal → fail ("no reader: " <> show refusal)
  Right (store1, g0) → do
    let loop g = do
          (g', progress) ← mask_ (stepGather io OwnerRunning store1 g)
          case progress of
            GMore → loop g'
            GBlocked wait → atomically wait >> loop g'
            GDone runs → pure (g', Right runs)
            GFailed handling → pure (g', Left handling)
            GDrained → pure (g', Left HandleClosing)
    (g, result) ← loop g0
    pure (endGather store1 g, result, gatherPeakWindow g)

type GProgressResult = Either Handling [(Column, Int64, Int64)]

-- | The reference's runs of the columns, in the order the columns were asked.
refRuns ∷ Retained → [Column] → [(Column, Int64, Int64)]
refRuns ref columns = [(c, lo, hi) | c ← columns, (KeyRun c' lo, RecRun hi) ← Map.toAscList (retainedRecordMap ref), c' == c]
  where
    retainedRecordMap = Map.fromList . retainedRecords

-- | The reference's records after the same removal: #661's own retained model, applied to the
-- candidate it stages.
refRemove ∷ Retained → TileCoord → IO Retained
refRemove ref tile =
  case stageRemoval sceneEnv (retainedHeader ref) (retainedProvider ref) (allowanceOf (envLimits sceneEnv)) tile of
    Right D.NoChange → pure ref
    Right (D.Staged cand) → either (\e → fail ("reference apply: " <> show e)) pure (applyCandidate cand ref)
    Right (D.EditSuspended why) → fail ("reference staging suspended: " <> show why)
    Left e → fail ("reference staging: " <> show e)

-- | The file's pages below the high-water mark, read back through the backend, as a disk the
-- store model's checker understands.
fileAsH ∷ Env → Io → Store → IO H
fileAsH env io store = do
  let cfg = storeConfig store
      hw = rHw (storeRoots store)
      chunks = takeWhile (< hw) [0, 256 ..]
  pages ← fmap concat . forM chunks $ \firstPage → do
    r ← readPages env (ioBacking io) cfg firstPage (fromIntegral (min 256 (hw - firstPage))) ReadProbe
    either (\f → fail ("read back: " <> show f)) pure r
  pure ((newH smallSpec ident0) {hStore = store, hDisk = foldl (\d (p, bs) → diskWrite p bs d) emptyDisk pages})

spec ∷ Spec
spec = describe "the owner's transaction runner, through the production storage backend on real files" $ do
  it "plans a removal, writes its pages and stops at ReadyToPublish: written and in flight are not published" $
    withArena $ \_ io store → do
      (store', run, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 2 2 3)))
      case progress of
        ReadyToPublish _ plan → do
          -- the committed roots are untouched until the owner publishes
          storeVersion store' `shouldBe` storeVersion store
          isJust (runTxnId run) `shouldBe` True
          length (plPages plan) `shouldSatisfy` (> 0)
        other → expectationFailure ("not ready: " <> show (finishedOf other))
  it "writes exactly the plan's pages to the file, at the plan's page numbers" $
    withArena $ \env io store → do
      (store', _, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 2 2 3)))
      case progress of
        ReadyToPublish _ plan → do
          back ← readPages env (ioBacking io) (storeConfig store') 0 (fromIntegral (maximum (map ((\(PageNo n) → n) . fst) (plPages plan)) + 1)) ReadProbe
          got ← either (\f → fail (show f)) (pure . Map.fromList . map (\(PageNo n, bs) → (n, bs))) back
          forM_ (plPages plan) $ \(PageNo n, bytes) → Map.lookup n got `shouldBe` Just bytes
        other → expectationFailure ("not ready: " <> show (finishedOf other))
  it "reads back from the file exactly the reference's records after a run of removals that each read pages the last one wrote" $
    withArena $ \env io store0 → do
      ref0 ← pure (newRetained (ArenaId 1))
      let tiles = [tileAt 2 2 z | z ← [3, 5, 4]] <> [tileAt 3 2 z | z ← [3, 4]]
      (store, ref, readCount) ← foldM
        ( \(s, r, n) tile → do
            readsBefore ← atomically (countEvents (envProbe env) isRead)
            out ← removeAndPublish io s tile
            readsAfter ← atomically (countEvents (envProbe env) isRead)
            r' ← refRemove r tile
            case out of
              Right s' → pure (s', r', n + (readsAfter - readsBefore))
              Left d → fail ("a removal ended without publishing: " <> show d)
        )
        (store0, ref0, 0)
        tiles
      -- the runner asked for pages and the backend really read them
      readCount `shouldSatisfy` (> 0)
      h ← fileAsH env io store
      either expectationFailure pure (compareRecords (retainedRecords ref) h)
      either expectationFailure pure (checkH h)
      storeVersion store `shouldBe` storeVersion store0 + fromIntegral (length tiles)
  it "appends no history for a removal that changes nothing (air)" $
    withArena $ \_ io store → do
      out ← removeAndPublish io store (tileAt 2 2 9)
      case out of
        Left NothingToDo → pure ()
        Left other → expectationFailure ("expected nothing to do, got " <> show other)
        Right _ → expectationFailure "a removal of air published"
  it "aborts a write that fails on a page: nothing is published, the pause is for io, the old root reads on" $
    withArena $ \env io store0 → do
      Right store ← removeAndPublish io store0 (tileAt 2 2 3)
      addRule (envProbe env) 1 isWrite (FailWith (Errno 5))
      (storeAfter, _, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 2 2 4)))
      case progress of
        Finished (Aborted handling) → handling `shouldSatisfy` \case HandlePause CondIo f → faultCode f == "storage_io"; _ → False
        other → expectationFailure ("expected an abort: " <> show (finishedOf other))
      -- the committed root is the one before: same version, and no transaction claims pages
      storeVersion storeAfter `shouldBe` storeVersion store
      h ← fileAsH env io storeAfter
      either expectationFailure pure (checkH h)
      -- the failed transaction's claims are retired
      plansAgain io storeAfter
  it "cancelling while the write job is running waits for the job: the claims stay until it returned" $
    withArena $ \env io store → do
      gate ← addGate (envProbe env) isWrite
      (s1, run, progress) ← mask_ (advance io OwnerRunning store (start store (removalPlanner sceneEnv store (tileAt 2 2 3))))
      -- drive to the write, stopping at the first wait that is the write job (the reads before it run to completion)
      let toWrite s r p = case p of
            More → mask_ (advance io OwnerRunning s r) >>= \(s', r', p') → toWrite s' r' p'
            Blocked wait | runPhaseName r /= "writing" → atomically wait >> mask_ (advance io OwnerRunning s r) >>= \(s', r', p') → toWrite s' r' p'
            _ → pure (s, r, p)
      (s2, run2, _) ← toWrite s1 run progress
      runPhaseName run2 `shouldBe` "writing"
      awaitReached gate 1
      (s3, run3, p3) ← mask_ (cancel io s2 run2)
      -- the job is held inside the native write: nothing is released, the runner waits for it
      runPhaseName run3 `shouldBe` "draining"
      case p3 of
        Blocked _ → pure ()
        More → pure ()
        other → expectationFailure ("cancel did not wait for the running job: " <> show (finishedOf other))
      openGate gate
      (s4, _, p4) ← settle io s3 run3
      finishedOf p4 `shouldBe` Just Drained
      -- nothing was published and nothing is claimed: the version is the old one
      storeVersion s4 `shouldBe` storeVersion store
      h ← fileAsH env io s4
      either expectationFailure pure (checkH h)
      plansAgain io s4
      openAllGates (envProbe env)
  it "cancelling a transaction that has written every page aborts without a write" $
    withArena $ \env io store → do
      (s1, run, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 2 2 3)))
      case progress of
        ReadyToPublish {} → pure ()
        other → expectationFailure ("not ready: " <> show (finishedOf other))
      writesBefore ← atomically (countEvents (envProbe env) isWrite)
      (s2, _, p2) ← mask_ (cancel io s1 run)
      finishedOf p2 `shouldBe` Just Drained
      writesAfter ← atomically (countEvents (envProbe env) isWrite)
      writesAfter `shouldBe` writesBefore
      storeVersion s2 `shouldBe` storeVersion store
      plansAgain io s2
  it "a read that fails while planning aborts as a pause for io, with nothing admitted" $
    withArena $ \env io store0 → do
      Right store ← removeAndPublish io store0 (tileAt 2 2 3)
      addRule (envProbe env) 1 isRead (FailWith (Errno 5))
      (storeAfter, run, progress) ← settle io store (start store (removalPlanner sceneEnv store (tileAt 2 2 4)))
      case progress of
        Finished (Aborted handling) → handling `shouldSatisfy` \case HandlePause CondIo _ → True; _ → False
        other → expectationFailure ("expected an abort: " <> show (finishedOf other))
      isJust (runTxnId run) `shouldBe` False
      storeVersion storeAfter `shouldBe` storeVersion store
  describe "reading the removed runs of columns from a pinned committed version through the backend" $ do
    it "gathers exactly the reference's runs, ascending, through reads the backend really made, and releases its pin" $
      withArena $ \env io store0 → do
        let tiles = [tileAt 2 2 z | z ← [3, 5, 4]] <> [tileAt 3 2 z | z ← [3, 4]]
            columns = [columnAt 3 2, columnAt 2 2, columnAt 9 9]
        (store, ref) ← foldM
          ( \(s, r) tile → do
              out ← removeAndPublish io s tile
              r' ← refRemove r tile
              either (\d → fail ("a removal ended without publishing: " <> show d)) (\s' → pure (s', r')) out
          )
          (store0, newRetained (ArenaId 1))
          tiles
        readsBefore ← atomically (countEvents (envProbe env) isRead)
        (released, result, _) ← gatherRuns io gatherPinLimit store columns
        readsAfter ← atomically (countEvents (envProbe env) isRead)
        result `shouldBe` Right (refRuns ref columns)
        refRuns ref columns `shouldSatisfy` (not . null)
        -- the pages were really read through the backend
        (readsAfter - readsBefore) `shouldSatisfy` (> 0)
        -- the pin is gone: every reader the store allows (16) can still be taken, and no more
        full ← foldM (\s _ → either (\e → fail ("a pin leaked: " <> show e)) (pure . snd) (acquireReader s)) released [1 .. maxReaders]
        case acquireReader full of
          Left _ → pure ()
          Right _ → expectationFailure "more readers than the store allows were taken"
    it "restarts a read that fills a small window with fewer records, and fails closed below what one lookup needs" $
      withArena $ \_ io store0 → do
        let tiles = [tileAt x 2 3 | x ← [0 .. 999]]
        (store, ref) ← foldM
          ( \(s, r) tile → do
              out ← removeAndPublish io s tile
              r' ← refRemove r tile
              either (\d → fail ("a removal ended without publishing: " <> show d)) (\s' → pure (s', r')) out
          )
          (store0, newRetained (ArenaId 1))
          tiles
        let columns = [columnAt x 2 | x ← [0, 400, 999]]
        -- the pages a full-width ranged read touches when the reader may pin all it may
        (_, wide, widePeak) ← gatherRuns io gatherPinLimit store columns
        wide `shouldBe` Right (refRuns ref columns)
        -- the smallest window the read succeeds in, by search: below it the read ends as a defect (never a loop
        -- and never an answer); at it the answer is the reference's, reached by asking for fewer records, in
        -- fewer pages than the full-width call touched
        outcomes ← forM [1 .. gatherPinLimit] $ \pin → (\(_, r, _) → (pin, r)) <$> gatherRuns io pin store columns
        let works = [pin | (pin, Right runs) ← outcomes, runs == refRuns ref columns]
            fails = [pin | (pin, Left (HandleDefect _)) ← outcomes]
            others = [pin | (pin, r) ← outcomes, pin `notElem` works, pin `notElem` fails, isRight' r]
        others `shouldBe` []
        case works of
          smallest : _ → do
            fails `shouldBe` [1 .. smallest - 1]
            smallest `shouldSatisfy` (< widePeak)
          [] → expectationFailure "no window up to the reader's limit answered"
  where
    isRight' = either (const False) (const True)
    isWrite op = case op of OpWriteAt _ _ → True; _ → False
    isRead op = case op of OpReadAt _ _ → True; _ → False
    finishedOf = \case Finished d → Just d; _ → Nothing
