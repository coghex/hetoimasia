-- | The storage backend's test harness: the production service on the production
-- native adapter, wrapped in a seam that records every native operation, holds a
-- chosen one at a gate, and replaces its result with a fault.
--
-- Nothing here substitutes a backend. The service the examples drive is the one an
-- application starts: its two workers, its queue, its accounting against a real
-- shared admission and its files on a real filesystem. The seam only observes and
-- perturbs the native calls, the way "Test.Content" examples do, so an example
-- can hold a worker inside a transfer with no sleep and assert exact offsets.
--
-- Every example runs in an 'Env' whose teardown checks that the service returned
-- every credit it took: a leaked record or buffer fails the example that leaked.
module Test.TerrainRuntime.Storage.Harness
  ( -- * Environment
    Env (..)
  , withEnv
  , withEnvWith
  , withEnvIn
  , EnvOptions (..)
  , defaultOptions
  , testConfigFor
  , fsNameOf
  , ident
  , ident2

    -- * The seam
  , Probe (..)
  , newProbe
  , seamFor
  , quiet
  , Gate (..)
  , Act (..)
  , newGate
  , openGate
  , awaitReached
  , addRule
  , addRuleAfter
  , addGate
  , addGateAfter
  , events
  , countEvents
  , clearEvents
  , openFds
  , fdsCreated
  , fdHandles

    -- * Driving the backend
  , openBacking
  , openBackingAt
  , awaitOutcome
  , outcomeOf
  , readPages
  , Txn (..)
  , planFor
  , newStoreH
  , runTxn
  , runTxnWith
  , finishPublish
  , finishAbort
  , gridPages
  , ledgerZero

    -- * Assertions
  , shouldBeFailure
  ) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (withWorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.File (Created (..), closeFile, createPrivate)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume (VolumeProfile (..), profileOf)
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), StoreIdentity)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan (..), Planned (..), TxClass (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.State (StoreConfig, StoreSpec)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (expectationFailure)
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Store.Harness (H (..), deltaFor, fillPlan, identOf, ident0, newH, runKey, runRec)

-- | The default incarnation of the examples, and a second one.
ident, ident2 ∷ StoreIdentity
ident = ident0
ident2 = identOf 2 9

-- ---------------------------------------------------------------------------
-- The seam

-- | A gate: a worker that reaches a matching operation announces it and waits
-- until the gate is opened.
data Gate = Gate {gReached ∷ !(TVar Int), gOpen ∷ !(TVar Bool)}

newGate ∷ IO Gate
newGate = Gate <$> newTVarIO 0 <*> newTVarIO False

openGate ∷ Gate → IO ()
openGate g = atomically (writeTVar (gOpen g) True)

-- | Wait until @n@ workers have reached the gate.
awaitReached ∷ Gate → Int → IO ()
awaitReached g n = bounded (atomically (readTVar (gReached g) >>= \r → check (r >= n)))

-- | What a rule does to a native call that matches it.
data Act
  = -- | Fail the call with this errno, without making it.
    FailWith !Errno
  | -- | Make the call for at most this many bytes.
    ShortTo !Int
  | -- | Answer zero bytes without making the call.
    ZeroBytes
  | -- | Answer success without making the call (a lying reservation).
    Lie
  | -- | Make the call and add this many bytes to the allocated size it reports.
    OverAllocated !Word64
  | -- | Make the call and report this much free space.
    FreeBytesAre !Word64
  | -- | Report this much free space less what the files the backend holds open
    -- occupy (the real allocation), so a fixed baseline shrinks as reservations
    -- are made, deterministically.
    FreeAfterOwn !Word64
  | -- | Make the call and report this filesystem name.
    FilesystemIs !BC.ByteString
  | -- | Make the call and report the descriptor as not close-on-exec.
    NotCloexec
  | -- | Raise an exception in the worker (a defect, not a storage result).
    Throw

data Rule = Rule
  { rMatch ∷ NativeOp → Bool
  , rAct ∷ Act
  , rSkip ∷ !(TVar Int)
  -- ^ How many matching calls pass before it applies.
  , rUses ∷ !(TVar Int)
  -- ^ How many matching calls it still applies to; negative is unlimited.
  }

data Probe = Probe
  { pLog ∷ !(TVar [NativeOp])
  , pRules ∷ !(TVar [Rule])
  , pGates ∷ !(TVar [(NativeOp → Bool, Gate, TVar Int)])
  , pCreated ∷ !(TVar [Int])
  , pOpen ∷ !(TVar (Set.Set Int))
  , pHandles ∷ !(TVar [Fd])
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO [] <*> newTVarIO [] <*> newTVarIO [] <*> newTVarIO Set.empty <*> newTVarIO []

-- | Apply a rule to the next @n@ matching calls (negative: all of them).
addRule ∷ Probe → Int → (NativeOp → Bool) → Act → IO ()
addRule p = addRuleAfter p 0

-- | 'addRule' after the first @skip@ matching calls have passed.
addRuleAfter ∷ Probe → Int → Int → (NativeOp → Bool) → Act → IO ()
addRuleAfter p skip n match act = do
  sk ← newTVarIO skip
  uses ← newTVarIO n
  atomically (modifyTVar' (pRules p) (<> [Rule match act sk uses]))

-- | Hold every matching call until the gate opens.
addGate ∷ Probe → (NativeOp → Bool) → IO Gate
addGate p = addGateAfter p 0

-- | 'addGate' after the first @skip@ matching calls have passed.
addGateAfter ∷ Probe → Int → (NativeOp → Bool) → IO Gate
addGateAfter p skip match = do
  g ← newGate
  sk ← newTVarIO skip
  atomically (modifyTVar' (pGates p) ((match, g, sk) :))
  pure g

-- | How many native operations so far satisfy a predicate (readable inside a
-- transaction, so an example can wait for a count).
countEvents ∷ Probe → (NativeOp → Bool) → STM Int
countEvents p f = length . filter f <$> readTVar (pLog p)

events ∷ Probe → IO [NativeOp]
events p = reverse <$> readTVarIO (pLog p)

clearEvents ∷ Probe → IO ()
clearEvents p = atomically (writeTVar (pLog p) [])

-- | Descriptors currently open, and every one ever created.
openFds ∷ Probe → IO [Int]
openFds p = Set.toList <$> readTVarIO (pOpen p)

-- | The descriptors the backend created, for an example to examine with the native
-- adapter itself.
fdHandles ∷ Probe → IO [Fd]
fdHandles p = readTVarIO (pHandles p)

fdsCreated ∷ Probe → IO [Int]
fdsCreated p = reverse <$> readTVarIO (pCreated p)

-- | The first rule that matches the operation and has uses left, consumed.
takeRule ∷ Probe → NativeOp → IO (Maybe Act)
takeRule p op = atomically $ do
  rules ← readTVar (pRules p)
  let go [] = pure Nothing
      go (r : rest)
        | rMatch r op = do
            skip ← readTVar (rSkip r)
            left ← readTVar (rUses r)
            if skip > 0
              then writeTVar (rSkip r) (skip - 1) >> go rest
              else
                if left == 0
                  then go rest
                  else do
                    unless (left < 0) (writeTVar (rUses r) (left - 1))
                    pure (Just (rAct r))
        | otherwise = go rest
  go rules

-- | The seam: production natives, perturbed by the probe's rules and gates.
seamFor ∷ Probe → Seam
seamFor p = Seam wrapped before after
  where
    real = posixNative
    before op = do
      atomically (modifyTVar' (pLog p) (op :))
      case op of
        OpWorkerStart _ → takeRule p op >>= \r → case r of
          Just Throw → ioError (userError "injected worker start failure")
          _ → pure ()
        _ → pure ()
      gates ← readTVarIO (pGates p)
      forM_ [(g, sk) | (m, g, sk) ← gates, m op] $ \(g, sk) → do
        skipped ← atomically (readTVar sk >>= \n → if n > 0 then writeTVar sk (n - 1) >> pure True else pure False)
        unless skipped $ do
          atomically (modifyTVar' (gReached g) (+ 1))
          atomically (readTVar (gOpen g) >>= check)
    after _ = pure ()
    wrapped =
      real
        { nativeCreate = \dir name → do
            a ← takeRule p OpCreateFile
            case a of
              Just (FailWith e) → pure (Left e)
              _ → do
                r ← nativeCreate real dir name
                case r of
                  Right fd → atomically (modifyTVar' (pCreated p) (fdNumber fd :) >> modifyTVar' (pOpen p) (Set.insert (fdNumber fd)) >> modifyTVar' (pHandles p) (<> [fd]))
                  Left _ → pure ()
                pure r
        , nativeUnlink = \d n → do
            a ← takeRule p OpUnlinkFile
            case a of
              Just (FailWith e) → pure (Left e)
              _ → nativeUnlink real d n
        , nativeCloexec = \fd → do
            r ← nativeCloexec real fd
            a ← takeRule p OpCloexecFlag
            pure $ case (a, r) of
              (Just NotCloexec, Right _) → Right False
              _ → r
        , nativeStat = \fd → do
            r ← nativeStat real fd
            a ← takeRule p OpStatFile
            pure $ case (a, r) of
              (Just (OverAllocated n), Right s) → Right s {nsAllocated = nsAllocated s + n}
              (Just (FailWith e), _) → Left e
              _ → r
        , nativeStatFs = \fd → do
            r ← nativeStatFs real fd
            a ← takeRule p OpStatFilesystem
            case (a, r) of
              (Just (FreeBytesAre n), Right f) → pure (Right f {nfAvailableBytes = n})
              (Just (FreeAfterOwn n), Right f) → do
                held ← atomically ((,) <$> readTVar (pHandles p) <*> readTVar (pOpen p))
                sizes ← mapM (\h → either (const 0) nsAllocated <$> nativeStat real h) [h | h ← fst held, fdNumber h `Set.member` snd held]
                pure (Right f {nfAvailableBytes = n - min n (sum sizes)})
              (Just (FilesystemIs n), Right f) → pure (Right f {nfTypeName = n})
              (Just (FailWith e), _) → pure (Left e)
              _ → pure r
        , nativeReserve = \fd off len → do
            a ← takeRule p (OpReserveRange off len)
            case a of
              Just (FailWith e) → pure (Left e)
              Just Lie → pure (Right len)
              _ → nativeReserve real fd off len
        , nativeSetLength = \fd len → do
            a ← takeRule p (OpSetFileLength len)
            case a of
              Just (FailWith e) → pure (Left e)
              _ → nativeSetLength real fd len
        , nativePread = \fd ptr n off → do
            a ← takeRule p (OpReadAt off n)
            case a of
              Just (FailWith e) → pure (Left e)
              Just ZeroBytes → pure (Right 0)
              Just Throw → ioError (userError "injected defect")
              Just (ShortTo k) → nativePread real fd ptr (min k n) off
              _ → nativePread real fd ptr n off
        , nativePwrite = \fd ptr n off → do
            a ← takeRule p (OpWriteAt off n)
            case a of
              Just (FailWith e) → pure (Left e)
              Just ZeroBytes → pure (Right 0)
              Just (ShortTo k) → nativePwrite real fd ptr (min k n) off
              _ → nativePwrite real fd ptr n off
        , nativeClose = \fd → do
            r ← nativeClose real fd
            atomically (modifyTVar' (pOpen p) (Set.delete (fdNumber fd)))
            a ← takeRule p OpCloseFile
            case a of
              Just (FailWith e) → pure (Left e)
              _ → pure r
        }

-- ---------------------------------------------------------------------------
-- The environment

data Env = Env
  { envSvc ∷ !StorageService
  , envAdmission ∷ !(TVar A.Admission)
  , envProbe ∷ !Probe
  , envDir ∷ !FilePath
  , envConfig ∷ !StorageConfig
  }

data EnvOptions = EnvOptions
  { eoQualified ∷ !(Maybe [BC.ByteString])
  -- ^ The qualified list; 'Nothing' qualifies the filesystem the examples run on.
  , eoHeadroom ∷ !Word64
  , eoUnbounded ∷ !Bool
  -- ^ Whether the body runs without the routine suite's bound (a probe's heavy steps).
  }

defaultOptions ∷ EnvOptions
defaultOptions = EnvOptions Nothing minHeadroomBytes False

quiet ∷ Logger
quiet = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))

-- | The filesystem name of a directory, as the backend itself reads it.
fsNameOf ∷ FilePath → IO BC.ByteString
fsNameOf dir = do
  made ← createPrivate productionSeam (BC.pack dir) 0
  case made of
    Left f → fail ("cannot probe the test filesystem: " <> show f)
    Right c → do
      pr ← profileOf productionSeam (crFd c)
      _ ← nativeUnlink posixNative (BC.pack dir) (crName c)
      _ ← closeFile productionSeam (crFd c)
      either (\e → fail ("cannot probe the test filesystem: " <> show e)) (pure . vpFilesystem) pr

-- | A configuration that qualifies the filesystem the examples run on, so the
-- routine suite exercises the production reservation on whatever volume a
-- developer or CI machine has. The production list stays @apfs@ and @ext4@; the
-- qualification itself is the probe's.
testConfigFor ∷ FilePath → EnvOptions → IO StorageConfig
testConfigFor dir opts = do
  name ← fsNameOf dir
  either (\e → fail (show e)) pure (mkStorageConfig (maybe [name] id (eoQualified opts)) (eoHeadroom opts))

withEnv ∷ (Env → IO a) → IO a
withEnv = withEnvWith defaultOptions

withEnvWith ∷ EnvOptions → (Env → IO a) → IO a
withEnvWith opts body = withSystemTempDirectory "hetoimasia-terrain-storage" $ \dir → withEnvIn dir opts body

-- | An environment whose files are made in a given directory (the probe's disposable
-- volume), with the same checks at its end.
withEnvIn ∷ FilePath → EnvOptions → (Env → IO a) → IO a
withEnvIn dir opts body = do
    cfg ← testConfigFor dir opts
    probe ← newProbe
    bank ← either (\e → fail (show e)) pure (A.mkEditBankConfig A.defaultEditBankSpec)
    admission ← newTVarIO (A.newAdmission bank)
    result ← newIORef Nothing
    withWorkerGroup $ \group →
      withStorageService (StoragePorts admission group quiet (seamFor probe) cfg) $ \svc →
        ((if eoUnbounded opts then id else bounded) (body (Env svc admission probe dir cfg)) `finally` openAllGates probe) >>= writeIORef result . Just
    leaked ← A.ledgers <$> readTVarIO admission
    unless (ledgerZero leaked) (expectationFailure ("the service leaked accounting: " <> show leaked))
    maybe (fail "the example produced no result") pure =<< readIORef result

-- | Open every gate of the probe, so a worker held by a failed example can finish and the service can
-- drain: a failing example is reported as a failure, never as a hang.
openAllGates ∷ Probe → IO ()
openAllGates p = readTVarIO (pGates p) >>= mapM_ (\(_, g, _) → openGate g)

-- | Every account returned to zero.
ledgerZero ∷ A.Ledger → Bool
ledgerZero l = A.lgCacheBacked l + A.lgCacheRamOnly l + A.lgStagingForeground l + A.lgStagingCamera l + A.lgControlReserved l == 0

-- ---------------------------------------------------------------------------
-- Driving the backend

-- | Wait for a job's outcome and take it (the record and bytes are retired).
awaitOutcome ∷ Env → Ticket → IO Outcome
awaitOutcome env t = do
  bounded (atomically (awaitTicket (envSvc env) t))
  r ← withOutcome (envSvc env) t pure
  maybe (fail "the ticket had no outcome") pure r

-- | A job's outcome, as the ticket of a submission.
outcomeOf ∷ Env → Either StorageFailure Ticket → IO Outcome
outcomeOf env r = case r of
  Left f → pure (Failed f [])
  Right t → awaitOutcome env t

openBackingAt ∷ Env → FilePath → StoreIdentity → StoreConfig → IO Outcome
openBackingAt env dir i cfg = submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack dir) i cfg) >>= outcomeOf env

-- | Open a backing in the example's directory; the example fails if it is refused.
openBacking ∷ Env → StoreIdentity → StoreConfig → IO Backing
openBacking env i cfg = do
  o ← openBackingAt env (envDir env) i cfg
  case o of
    Opened b _ → pure b
    other → fail ("expected an opened backing, got " <> show other)

readPages ∷ Env → Backing → StoreConfig → Word64 → Int → ReadMode → IO (Either StorageFailure [(PageNo, BS.ByteString)])
readPages env b cfg start n mode = do
  o ← submitRead (envSvc env) b ExplicitWork cfg (PageNo start) n mode >>= outcomeOf env
  pure $ case o of
    Pages ps → Right ps
    Failed f _ → Left f
    other → Left (HostFailure (T.pack (show other)))

-- | A store with a real transaction's pages: the harness's pure store.
newStoreH ∷ StoreSpec → H
newStoreH spec = newH spec ident

-- | Plan the @k@th small edit against the harness's store.
planFor ∷ H → Integer → Either String (Plan)
planFor h k = do
  p ← fillPlan h (deltaFor (hStore h) True False 1 [(runKey k k k, Just (runRec (k + 1)))]) Ordinary
  case p of
    Planned plan → Right plan
    other → Left ("not planned: " <> show other)

-- | One transaction driven through the backend: what the model did and what the
-- worker reported.
data Txn = Txn
  { txStore ∷ !Store
  , txTid ∷ !TxnId
  , txPlan ∷ !Plan
  , txReport ∷ !(Maybe WriteReport)
  , txOutcome ∷ !Outcome
  }

-- | Admit a plan, stage it, write it through the backend, and report the
-- worker's per-page outcomes to the model (the owner's part). It neither
-- publishes nor aborts: the example decides.
runTxn ∷ Env → Backing → Store → Plan → IO Txn
runTxn env b store plan = runTxnWith env b store plan (\_ → pure ())

-- | 'runTxn' with an action between the submission and the wait (to cancel, or
-- to open a gate).
runTxnWith ∷ Env → Backing → Store → Plan → (Ticket → IO ()) → IO Txn
runTxnWith env b store plan between = do
  (tid, s1) ← either (\e → fail ("admit: " <> show e)) pure (admit plan store)
  sw ← either (\e → fail ("stage: " <> show e)) pure (stageWrite s1 tid)
  let s2 = foldl (\s p → snd (dispatchWrite tid p s)) s1 (stagedPages sw)
  t ← submitWrite (envSvc env) b sw >>= either (\f → fail ("submit: " <> show f)) pure
  between t
  o ← awaitOutcome env t
  case o of
    Written report →
      let s3 = foldl (\s (p, out) → snd (completeWrite tid p out s)) s2 (writeOutcomes report)
       in pure (Txn s3 tid plan (Just report) o)
    _ → pure (Txn s2 tid plan Nothing o)

finishPublish ∷ Txn → IO Store
finishPublish t = either (\e → fail ("publish: " <> show e)) (pure . snd) (publish (txTid t) (txStore t))

finishAbort ∷ Txn → IO Store
finishAbort t = either (\e → fail ("abort: " <> show e)) pure (abortTransaction (txTid t) (txStore t))

-- | The pages a plan writes, in order, with their bytes.
gridPages ∷ Plan → [(PageNo, BS.ByteString)]
gridPages = plPages

shouldBeFailure ∷ Outcome → (StorageFailure → Bool) → IO ()
shouldBeFailure o p = case o of
  Failed f _ → unless (p f) (expectationFailure ("an unexpected failure: " <> show f))
  other → expectationFailure ("expected a failure, got " <> show other)
