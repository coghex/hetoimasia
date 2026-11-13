-- | Exact page I/O and the staged-write protocol: short and interrupted transfers,
-- zero progress, premature end of file, integrity failures, every failed or
-- cancelled prefix of a transaction, and the refusals made before any I/O.
--
-- The offsets asserted here are the native calls' own: the harness's seam records
-- every @pread@ and @pwrite@ with its file offset and length, so "no repeated
-- prefix" and "advances the checked offset" are read off the calls that were made,
-- not inferred from the final bytes.
module Test.TerrainRuntime.Storage.Io (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word64)
import Foreign.Ptr (castPtr)
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgUsablePages, pageFileOffset)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (StoreIdentity)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (Plan)
import Test.TerrainRuntime.Store.Harness (H (..), commitPlan, newH, smallSpec, specOf)

er ∷ C.Errno → Errno
er (C.Errno c) = Errno (fromIntegral c)

h0 ∷ H
h0 = newStoreH smallSpec

isWrite, isRead ∷ NativeOp → Bool
isWrite op = case op of OpWriteAt _ _ → True; _ → False
isRead op = case op of OpReadAt _ _ → True; _ → False

offsetOf ∷ H → PageNo → Word64
offsetOf h p = either (error . show) id (pageFileOffset (hCfg h) p)

-- | The write calls a page's transfer makes when each call moves at most @k@
-- bytes: the offset advances by what was moved and the length is what remains.
expectedCalls ∷ Word64 → Int → [(Word64, Int)]
expectedCalls off k = go 0
  where
    go done
      | done >= pageSize = []
      | otherwise = (off + fromIntegral done, pageSize - done) : go (done + min k (pageSize - done))

planOf ∷ H → Integer → Plan
planOf h k = either error id (planFor h k)

-- | The first page a plan writes.
firstPage ∷ Plan → (PageNo, BS.ByteString)
firstPage plan = case gridPages plan of
  x : _ → x
  [] → error "a plan that writes no page"

-- | The harness after a plan is committed through the model alone.
afterOne ∷ H → Plan → H
afterOne h plan = either error id (commitPlan h plan)

withIdent ∷ H → StoreIdentity → H
withIdent _ i = newH smallSpec i

spec ∷ Spec
spec = describe "Storage backend: page I/O" $ do
  it "writes a transaction's staged pages at their checked offsets and reads them back validated" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
      t ← runTxn env b (hStore h0) plan
      fmap wrPages (txReport t) `shouldBe` Just [(p, Wrote) | (p, _) ← gridPages plan]
      evs ← events (envProbe env)
      [(o, n) | OpWriteAt o n ← evs] `shouldBe` [(offsetOf h0 p, pageSize) | (p, _) ← gridPages plan]
      s1 ← finishPublish t
      storeVersion s1 `shouldBe` storeVersion (hStore h0) + 1
      forM_ (gridPages plan) $ \(PageNo n, bytes) → do
        r ← readPages env b (hCfg h0) n 1 ReadValidated
        r `shouldBe` Right [(PageNo n, bytes)]

  it "advances the offset and the buffer after short writes and short reads, at several boundaries" $
    forM_ [1, 100, 4095, 4096] $ \k →
      withEnv $ \env → do
        b ← openBacking env ident (hCfg h0)
        let plan = planOf h0 1
        addRule (envProbe env) (-1) isWrite (ShortTo k)
        t ← runTxn env b (hStore h0) plan
        fmap wrPages (txReport t) `shouldBe` Just [(p, Wrote) | (p, _) ← gridPages plan]
        evs ← events (envProbe env)
        [(o, n) | OpWriteAt o n ← evs] `shouldBe` concat [expectedCalls (offsetOf h0 p) k | (p, _) ← gridPages plan]
        clearEvents (envProbe env)
        addRule (envProbe env) (-1) isRead (ShortTo k)
        let (PageNo first, bytes) = firstPage plan
        r ← readPages env b (hCfg h0) first 1 ReadValidated
        r `shouldBe` Right [(PageNo first, bytes)]
        evs2 ← events (envProbe env)
        [(o, n) | OpReadAt o n ← evs2] `shouldBe` expectedCalls (offsetOf h0 (PageNo first)) k

  it "retries an interrupted call without repeating the bytes already transferred" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
          (p1, _) = firstPage plan
      addRule (envProbe env) 1 isWrite (ShortTo 100)
      addRule (envProbe env) 1 isWrite (FailWith (er C.eINTR))
      t ← runTxn env b (hStore h0) plan
      fmap wrPages (txReport t) `shouldBe` Just [(p, Wrote) | (p, _) ← gridPages plan]
      evs ← events (envProbe env)
      take 3 [(o, n) | OpWriteAt o n ← evs]
        `shouldBe` [(offsetOf h0 p1, pageSize), (offsetOf h0 p1 + 100, pageSize - 100), (offsetOf h0 p1 + 100, pageSize - 100)]

  it "ends a storm of interruptions, a zero-progress write and a premature end of file with a bounded failure" $ do
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
          (p1, _) = firstPage plan
      addRule (envProbe env) (-1) isWrite (FailWith (er C.eINTR))
      t ← runTxn env b (hStore h0) plan
      case fmap wrPages (txReport t) of
        Just ((p, WriteFailedAt (StorageIo f)) : rest) → do
          (p, ioKind f, ioOffset f, ioPage f) `shouldBe` (p1, IoInterruptStorm, Just (offsetOf h0 p1), Just p1)
          map snd rest `shouldSatisfy` all (== NotAttempted)
        other → expectationFailure ("unexpected report " <> show other)
      evs ← events (envProbe env)
      -- the contract: at most maxInterrupts interruptions in a row, so one call more and then the failure
      length [() | OpWriteAt _ _ ← evs] `shouldBe` maxInterrupts + 1
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
      addRule (envProbe env) (-1) isWrite ZeroBytes
      t ← runTxn env b (hStore h0) plan
      case fmap wrPages (txReport t) of
        Just ((_, WriteFailedAt (StorageIo f)) : _) → ioKind f `shouldBe` IoZeroProgress
        other → expectationFailure ("unexpected report " <> show other)
      evs ← events (envProbe env)
      length [() | OpWriteAt _ _ ← evs] `shouldBe` 1
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
          (p1@(PageNo n1), _) = firstPage plan
      _ ← runTxn env b (hStore h0) plan
      addRule (envProbe env) 1 isRead (ShortTo 100)
      addRule (envProbe env) 1 isRead ZeroBytes
      r ← readPages env b (hCfg h0) n1 1 ReadValidated
      r `shouldBe` Left (StorageIntegrity (PageTruncated p1 (offsetOf h0 p1) 100 (fromIntegral pageSize)))

  it "reports an actual transfer error with its operation, page and offset" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
          (p1@(PageNo n1), _) = firstPage plan
      _ ← runTxn env b (hStore h0) plan
      addRule (envProbe env) 1 isRead (FailWith (er C.eIO))
      r ← readPages env b (hCfg h0) n1 1 ReadValidated
      r `shouldBe` Left (StorageIo (IoFailure IoRead (IoErrno (er C.eIO)) (Just p1) (Just (offsetOf h0 p1)) 0 (fromIntegral pageSize)))

  it "refuses a corrupt, foreign or never-written page as an integrity failure, never as absence" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = planOf h0 1
          (p1@(PageNo n1), bytes) = firstPage plan
          off = offsetOf h0 p1
      _ ← runTxn env b (hStore h0) plan
      [fd] ← fdHandles (envProbe env)
      let poke at bs = BSU.unsafeUseAsCStringLen bs $ \(ptr, len) → () <$ nativePwrite posixNative fd (castPtr ptr) len at
      -- a flipped byte: the checksum no longer matches
      poke (off + 50) (BS.singleton (BS.index bytes 50 + 1))
      r ← readPages env b (hCfg h0) n1 1 ReadValidated
      r `shouldSatisfy` \x → case x of Left (StorageIntegrity (PageInvalid q _ _)) → q == p1; _ → False
      -- the same bytes are returned to a probe, which tolerates garbage
      readPages env b (hCfg h0) n1 1 ReadProbe >>= (`shouldSatisfy` either (const False) ((== 1) . length))
      -- a valid page of another arena at this place
      let other = either error id (planFor (newStoreH smallSpec `withIdent` ident2) 1)
          (PageNo m, ob) = firstPage other
      poke (offsetOf h0 (PageNo m)) ob
      r2 ← readPages env b (hCfg h0) m 1 ReadValidated
      r2 `shouldSatisfy` \x → case x of Left (StorageIntegrity (PageInvalid {})) → True; _ → False
      -- a page that was never written
      r3 ← readPages env b (hCfg h0) 9000 1 ReadValidated
      r3 `shouldSatisfy` \x → case x of Left (StorageIntegrity (PageInvalid {})) → True; _ → False

  it "refuses a request outside the file, the committed cap, the incarnation or the handle before any I/O" $ do
    foreign' ← withEnv $ \env → openBacking env ident (hCfg h0)
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let usable = cfgUsablePages (hCfg h0)
          big = newStoreH (specOf (128 * 1024 * 1024) Nothing)
      r1 ← submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo usable) 1 ReadValidated
      r1 `shouldSatisfy` \x → case x of Left (InvalidRequest (PageOutsideFile {})) → True; _ → False
      r2 ← submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo (usable - 1)) 2 ReadValidated
      r2 `shouldSatisfy` \x → case x of Left (InvalidRequest (PageOutsideFile {})) → True; _ → False
      r3 ← submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 0) 257 ReadValidated
      r3 `shouldBe` Left (InvalidRequest (TooManyPages 257))
      r4 ← submitRead (envSvc env) b ExplicitWork (hCfg big) (PageNo 0) 1 ReadValidated
      r4 `shouldSatisfy` \x → case x of Left (InvalidRequest (BeyondCommittedCap {})) → True; _ → False
      r5 ← submitRead (envSvc env) foreign' ExplicitWork (hCfg h0) (PageNo 0) 1 ReadValidated
      r5 `shouldBe` Left ForeignHandle
      -- a staged write of another incarnation
      let other = withIdent h0 ident2
          plan2 = planOf other 1
      (tid, s1) ← either (fail . show) pure (admit plan2 (hStore other))
      sw ← either (fail . show) pure (stageWrite s1 tid)
      submitWrite (envSvc env) b sw >>= (`shouldBe` Left (InvalidRequest IdentityMismatch)) . fmap (const ())
      evs ← events (envProbe env)
      length [() | OpReadAt _ _ ← evs] + length [() | OpWriteAt _ _ ← evs] `shouldBe` 0
      -- a closed handle
      _ ← closeBacking (envSvc env) b
      submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 0) 1 ReadValidated >>= (`shouldBe` Left BackingClosed) . fmap (const ())

  it "preserves every old committed page when a staged write fails or is cancelled after any prefix, and aborts without a write" $ do
    let plan1 = planOf h0 1
        h1 = afterOne h0 plan1
        plan2 = planOf h1 2
        nPages = length (gridPages plan2)
    forM_ [0 .. nPages - 1] $ \k →
      forM_ [False, True] $ \cancelling →
        withEnv $ \env → do
          b ← openBacking env ident (hCfg h0)
          t1 ← runTxn env b (hStore h0) plan1
          s1 ← finishPublish t1
          clearEvents (envProbe env)
          t2 ←
            if cancelling
              then do
                g ← addGateAfter (envProbe env) k isWrite
                runTxnWith env b s1 plan2 $ \tk → do
                  -- the (k+1)th write is held in flight: ask for cancellation, let it go on
                  awaitReached g 1
                  cancelTicket (envSvc env) tk >>= (`shouldBe` CancelRequested)
                  openGate g
              else do
                addRuleAfter (envProbe env) k (-1) isWrite (FailWith (er C.eIO))
                runTxn env b s1 plan2
          report ← maybe (fail "no report") (pure . map snd . wrPages) (txReport t2)
          if cancelling
            then do
              take (k + 1) report `shouldSatisfy` all (== Wrote)
              drop (k + 1) report `shouldSatisfy` all (== NotAttempted)
            else do
              take k report `shouldSatisfy` all (== Wrote)
              (report !! k) `shouldSatisfy` \r → case r of WriteFailedAt (StorageIo f) → ioOp f == IoWrite; _ → False
              drop (k + 1) report `shouldSatisfy` all (== NotAttempted)
              evs ← events (envProbe env)
              -- nothing was written after the first failure
              length [() | OpWriteAt _ _ ← evs] `shouldBe` k + 1
          -- the model, told the outcomes, has nothing in flight: the claims are returned without a write
          s2 ← finishAbort t2
          storeVersion s2 `shouldBe` storeVersion s1
          -- every old committed page is still there, byte for byte
          forM_ (gridPages plan1) $ \(PageNo n, bytes) →
            readPages env b (hCfg h0) n 1 ReadValidated >>= (`shouldBe` Right [(PageNo n, bytes)])

  it "does not publish a root when every byte was written: the owner alone decides" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      t ← runTxn env b (hStore h0) (planOf h0 1)
      eligibility (txTid t) (txStore t) `shouldBe` Eligible
      -- all pages are on disk and the model's committed roots are still the old ones
      storeVersion (txStore t) `shouldBe` storeVersion (hStore h0)
      s' ← finishAbort t
      storeVersion s' `shouldBe` storeVersion (hStore h0)
