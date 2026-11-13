-- | Opening a backing: private exclusive creation, the unlink before readiness, the
-- qualified reservation and the failure at every stage, with the complete cleanup
-- evidence.
--
-- Each example drives the production service on the production native adapter
-- through the harness's seam (see "Test.TerrainRuntime.Storage.Harness"): the seam
-- only observes the native calls and perturbs a chosen one. After every example the
-- environment checks that no credit leaked, and the examples that fail an open check
-- that no descriptor is left open and no name is left in the directory.
module Test.TerrainRuntime.Storage.Open (spec) where

import Control.Concurrent.STM (atomically, check)
import Control.Monad (forM_)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes, cfgOverheadBytes, cfgTotalPages)
import System.Directory (listDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (proc)
import Test.Support.ExternalClient (clientRunBound)
import Test.Support.Subprocess (runCaptured)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec, specOf)

-- | A platform errno as the backend's own.
er ∷ C.Errno → Errno
er (C.Errno c) = Errno (fromIntegral c)

cfg64 ∷ H
cfg64 = newStoreH smallSpec

spec ∷ Spec
spec = describe "Storage backend: opening a backing" $ do
  it "creates a private, close-on-exec, unlinked file whose reservation is real, before reporting readiness" $
    withEnv $ \env → do
      let cfg = hCfg cfg64
      o ← openBackingAt env (envDir env) ident cfg
      case o of
        Opened _ rs → do
          [fd] ← fdHandles (envProbe env)
          st ← either (fail . show) pure =<< nativeStat posixNative fd
          cx ← either (fail . show) pure =<< nativeCloexec posixNative fd
          nsMode st .&. 0o777 `shouldBe` 0o600
          nsLinks st `shouldBe` 0
          cx `shouldBe` True
          -- THE PAYLOAD RULE: the file holds the model's usable pages (the allowance less its overhead budget), and
          -- what it physically occupies never exceeds the allowance
          nsSize st `shouldBe` payloadBytes cfg
          nsAllocated st `shouldSatisfy` (>= payloadBytes cfg)
          nsAllocated st `shouldSatisfy` (<= cfgAllowanceBytes cfg)
          rsAllocated rs `shouldBe` nsAllocated st
          rsOverhead rs `shouldBe` nsAllocated st - payloadBytes cfg
          listDirectory (envDir env) `shouldReturn` []
          evs ← events (envProbe env)
          -- the name is gone, and the allocation was made, before the outcome exists
          let at op = length (takeWhile (/= op) evs)
          at OpUnlinkFile `shouldSatisfy` (< at (OpReserveRange 0 (payloadBytes cfg)))
        other → expectationFailure ("not opened: " <> show other)

  it "keeps the descriptor out of a child process: the child cannot use its number, and can use an inherited one" $
    withEnv $ \env → do
      _ ← openBacking env ident (hCfg cfg64)
      [fd] ← fdHandles (envProbe env)
      let child n = runCaptured clientRunBound (proc "python3" ["-I", "-c", "import os, sys\ntry:\n os.fstat(" <> show n <> ")\nexcept OSError:\n sys.exit(3)"]) ""
      (closedStatus, _, _) ← child (fdNumber fd)
      closedStatus `shouldBe` ExitFailure 3
      -- the control: a descriptor the child does inherit (its standard input) is visible to the same probe
      (openStatus, _, _) ← child (0 ∷ Int)
      openStatus `shouldBe` ExitSuccess

  it "refuses at every stage with a typed failure and complete cleanup, leaving no descriptor and no name" $
    forM_ stages $ \(name, setup, expected) →
      withEnv $ \env → do
        setup (envProbe env)
        o ← openBackingAt env (envDir env) ident (hCfg cfg64)
        case o of
          Failed f notes → do
            (name, expected f) `shouldBe` (name, True)
            length notes `shouldSatisfy` (>= 0)
          other → expectationFailure (name <> ": not refused: " <> show other)
        fds ← openFds (envProbe env)
        (name, fds) `shouldBe` (name, [])
        left ← listDirectory (envDir env)
        -- only a failed unlink can leave the name; the example removes it
        (name, null left || name == "unlink fails") `shouldBe` (name, True)
        forM_ left (\n → nativeUnlink posixNative (BC.pack (envDir env)) (BC.pack n))
        v ← atomically (serviceView (envSvc env))
        (name, svBackings v, svRecords v) `shouldBe` (name, 0, 0)

  it "keeps the failed unlink and the failed cleanup together" $
    withEnv $ \env → do
      addRule (envProbe env) (-1) (== OpUnlinkFile) (FailWith (Errno 13))
      o ← openBackingAt env (envDir env) ident (hCfg cfg64)
      -- the second attempt, made as cleanup, failed too and is kept beside the first
      case o of
        Failed (StorageIo (IoFailure IoUnlink _ _ _ _ _)) notes → notes `shouldBe` [CleanupNote IoUnlink (Errno 13)]
        other → expectationFailure ("unexpected: " <> show other)
      left ← listDirectory (envDir env)
      forM_ left (\n → nativeUnlink posixNative (BC.pack (envDir env)) (BC.pack n))

  it "refuses a sparse file of the right length: the reservation must be allocated" $
    withEnv $ \env → do
      addRule (envProbe env) 1 (isReserve) Lie
      o ← openBackingAt env (envDir env) ident (hCfg cfg64)
      o `shouldBeFailure` \f → case f of
        ReservationFailed (CoverageShort got want) → got < want && want == payloadBytes (hCfg cfg64)
        _ → False

  -- A CHECK USES WHAT WAS OBTAINED, NOT WHAT WAS ASKED: exactly the length and the headroom are available, so the
  -- precheck passes; the file then occupies 4,096 bytes more than asked (the native overhead, an extent block on
  -- ext4), which takes some of the required headroom. The reservation is refused and unwound.
  it "refuses an open whose obtained bytes, overhead included, leave less than the headroom" $
    withEnv $ \env → do
      -- the headroom is kept after the ALLOWANCE; the platform then occupies 4,096 bytes beyond it (the budget plus 4,096), so
      -- the bytes obtained take some of the required headroom
      let allowance = cfgAllowanceBytes (hCfg cfg64)
          over = budgetBytes (hCfg cfg64) + 4096
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (allowance + minHeadroomBytes))
      addRuleAfter (envProbe env) 2 1 (== OpStatFile) (OverAllocated over)
      o ← openBackingAt env (envDir env) ident (hCfg cfg64)
      o `shouldBeFailure` \f → case f of ReservationFailed (InsufficientHeadroom avail got room) → avail == allowance + minHeadroomBytes && got == payloadBytes (hCfg cfg64) + over && room == minHeadroomBytes; _ → False
      rulesConsumed (envProbe env) >>= (`shouldBe` True)
      -- unwound: no descriptor, no name, no record, nothing reserved
      openFds (envProbe env) >>= (`shouldBe` [])
      left ← listDirectory (envDir env)
      left `shouldBe` []
      (svBackings <$> atomically (serviceView (envSvc env))) `shouldReturn` 0

  it "admits an open that leaves exactly the headroom after the allowance" $ do
    withEnv $ \env → do
      let allowance = cfgAllowanceBytes (hCfg cfg64)
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (allowance + minHeadroomBytes))
      o ← openBackingAt env (envDir env) ident (hCfg cfg64)
      case o of
        Opened _ rv → rsAllocated rv `shouldSatisfy` (<= allowance)
        other → expectationFailure ("expected the open to be admitted, got " <> show other)
      -- one byte less is refused before any native allocation
    withEnv $ \env → do
      let allowance = cfgAllowanceBytes (hCfg cfg64)
      addRule (envProbe env) 1 (== OpStatFilesystem) (FreeBytesAre (allowance + minHeadroomBytes - 1))
      o ← openBackingAt env (envDir env) ident (hCfg cfg64)
      o `shouldBeFailure` \f → case f of ReservationFailed (InsufficientHeadroom avail got room) → avail == allowance + minHeadroomBytes - 1 && got == allowance && room == minHeadroomBytes; _ → False
      evs ← events (envProbe env)
      length [() | OpReserveRange _ _ ← evs] `shouldBe` 0

  -- THE PAYLOAD RULE IS THE MODEL'S OWN FIGURE: the file's length is usable pages x page for every configuration the suite
  -- builds, and a page in the tail between the payload and the allowance (below the allowance, at or beyond the usable
  -- pages) is refused before any native call, leaving the file's length and allocation unchanged.
  it "asks the platform for exactly the model's usable pages, and refuses a page in the tail between the payload and the allowance" $
    withEnv $ \env → do
      let cfg = hCfg cfg64
      forM_ [cfg64, newStoreH smallSpec] $ \h →
        payloadOf (cfgAllowanceBytes (hCfg h)) (cfgOverheadBytes (hCfg h)) `shouldBe` payloadBytes (hCfg h)
      o ← openBackingAt env (envDir env) ident cfg
      b ← case o of Opened b _ → pure b; other → fail (show other)
      [fd] ← fdHandles (envProbe env)
      st0 ← either (fail . show) pure =<< nativeStat posixNative fd
      nsSize st0 `shouldBe` payloadBytes cfg
      let tailPage = PageNo (cfgTotalPages cfg)
      readPages env b cfg (cfgTotalPages cfg) 1 ReadProbe >>= (`shouldSatisfy` either (\f → case f of InvalidRequest (PageOutsideFile p _) → p == tailPage; _ → False) (const False))
      let plan = either error id (planFor cfg64 1)
      (tid, s1) ← either (fail . show) pure (admit plan (hStore cfg64))
      sw ← either (fail . show) pure (stageWrite s1 tid)
      t ← submitWrite (envSvc env) b sw {swPages = [(tailPage, BS.replicate pageSize 7)]}
      t `shouldSatisfy` either (\f → case f of InvalidRequest (PageOutsideFile p _) → p == tailPage; _ → False) (const False)
      st1 ← either (fail . show) pure =<< nativeStat posixNative fd
      (nsSize st1, nsAllocated st1) `shouldBe` (nsSize st0, nsAllocated st0)
      evs ← events (envProbe env)
      length [() | OpWriteAt {} ← evs] `shouldBe` 0

  -- THE BACKING'S OWN FIGURES ARE THE AUTHORITY, never the caller's configuration (round 7, manager's read): a configuration with
  -- the SAME allowance and a SMALLER overhead has more usable pages than the file the backing holds. A read or a write of a page
  -- in that tail is refused before any native call, with a typed failure, and the file's length and allocation are unchanged.
  it "refuses a request whose configuration has the same allowance and a smaller overhead, for a page past the backing's payload" $
    withEnv $ \env → do
      let cfg = hCfg cfg64
          smallerH = newStoreH (specOf (toInteger (cfgAllowanceBytes cfg)) (Just 4096))
          loose = hCfg smallerH
          tailPage = PageNo (cfgTotalPages cfg)
          refused f = case f of InvalidRequest (PayloadBeyondBacking got has) → got == payloadBytes loose && has == payloadBytes cfg; _ → False
      -- the control of the example: the looser configuration really has more usable pages than the backing's payload
      (cfgAllowanceBytes loose, payloadBytes loose > payloadBytes cfg) `shouldBe` (cfgAllowanceBytes cfg, True)
      o ← openBackingAt env (envDir env) ident cfg
      b ← case o of Opened b _ → pure b; other → fail (show other)
      [fd] ← fdHandles (envProbe env)
      st0 ← either (fail . show) pure =<< nativeStat posixNative fd
      readPages env b loose (cfgTotalPages cfg) 1 ReadProbe >>= (`shouldSatisfy` either refused (const False))
      let plan = either error id (planFor smallerH 1)
      (tid, s1) ← either (fail . show) pure (admit plan (hStore smallerH))
      sw ← either (fail . show) pure (stageWrite s1 tid)
      t ← submitWrite (envSvc env) b sw {swPages = [(tailPage, BS.replicate pageSize 7)]}
      t `shouldSatisfy` either refused (const False)
      st1 ← either (fail . show) pure =<< nativeStat posixNative fd
      (nsSize st1, nsAllocated st1) `shouldBe` (nsSize st0, nsAllocated st0)
      evs ← events (envProbe env)
      (length [() | OpWriteAt {} ← evs], length [() | OpReadAt {} ← evs]) `shouldBe` (0, 0)

  -- THE PHYSICAL INVARIANT AT ITS BOUNDARY (round 7): the platform's own overhead must fit in what the allowance leaves
  -- for it, so that the file never occupies more than the allowance. A seam that over-allocates by EXACTLY that budget
  -- is admitted with allocated == allowance; one byte more is refused and unwound.
  it "admits an open whose physical allocation is exactly the allowance, and refuses one byte more, unwinding it" $ do
    let cfg = hCfg cfg64
    -- the real overhead the platform adds, measured without an injection
    real ← withEnv $ \env → do
      o0 ← openBackingAt env (envDir env) ident cfg
      case o0 of
        Opened _ rv → pure (rsOverhead rv)
        other → fail ("the baseline open failed: " <> show other)
    let exact = budgetBytes cfg - real
    withEnv $ \env → do
      addRuleAfter (envProbe env) 2 1 (== OpStatFile) (OverAllocated exact)
      o ← openBackingAt env (envDir env) ident cfg
      case o of
        Opened _ rv → do
          rsAllocated rv `shouldBe` cfgAllowanceBytes cfg
          rsLength rv `shouldBe` payloadBytes cfg
        other → expectationFailure ("an allocation of exactly the allowance must be admitted: " <> show other)
    withEnv $ \env → do
      addRuleAfter (envProbe env) 2 1 (== OpStatFile) (OverAllocated (exact + 1))
      o ← openBackingAt env (envDir env) ident cfg
      o `shouldBeFailure` \f → case f of ReservationFailed (OverheadExceedsModel got room) → got == budgetBytes cfg + 1 && room == budgetBytes cfg; _ → False
      rulesConsumed (envProbe env) >>= (`shouldBe` True)
      openFds (envProbe env) >>= (`shouldBe` [])
      listDirectory (envDir env) >>= (`shouldBe` [])
      (svBackings <$> atomically (serviceView (envSvc env))) `shouldReturn` 0

  it "serializes reservations on one volume, so two arenas cannot spend the same observed headroom" $
    withEnv $ \env → do
      let allowance = payloadBytes (hCfg cfg64)
      -- a baseline with room for exactly one reservation beside the headroom
      addRule (envProbe env) (-1) (== OpStatFilesystem) (FreeAfterOwn (minHeadroomBytes + allowance + 32 * 1024 * 1024))
      gate ← addGate (envProbe env) isReserve
      t1 ← submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg cfg64))
      t2 ← submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident2 (hCfg cfg64))
      awaitReached gate 1
      bounded (atomically (countEvents (envProbe env) isWait >>= \n → check (n >= 2)))
      -- the second worker is waiting for the volume: it has not looked at the free space
      evs ← events (envProbe env)
      length (filter (== OpStatFilesystem) evs) `shouldBe` 1
      openGate gate
      outs ← mapM (outcomeOf env) [t1, t2]
      let opened = [() | Opened _ _ ← outs]
          refused = [() | Failed (ReservationFailed (InsufficientHeadroom {})) _ ← outs]
      (length opened, length refused) `shouldBe` (1, 1)
  where
    isReserve op = case op of OpReserveRange _ _ → True; _ → False
    isWait op = case op of OpVolumeWait _ → True; _ → False
    stages =
      [ ("create fails", \p → addRule p (-1) (== OpCreateFile) (FailWith (Errno 13)), \f → case f of StorageIo (IoFailure IoCreate _ _ _ _ _) → True; _ → False)
      , ("unlink fails", \p → addRule p (-1) (== OpUnlinkFile) (FailWith (Errno 13)), \f → case f of StorageIo (IoFailure IoUnlink _ _ _ _ _) → True; _ → False)
      , ("descriptor leaks through exec", \p → addRule p 1 (== OpCloexecFlag) NotCloexec, \f → case f of StorageIo (IoFailure IoCloexec IoStateWrong _ _ _ _) → True; _ → False)
      , ("filesystem query fails", \p → addRule p 1 (== OpStatFilesystem) (FailWith (Errno 5)), \f → case f of StorageIo (IoFailure IoStatFs _ _ _ _ _) → True; _ → False)
      , ("filesystem not qualified", \p → addRule p 1 (== OpStatFilesystem) (FilesystemIs "tmpfs"), \f → case f of StorageUnsupported (FilesystemNotQualified "tmpfs") → True; _ → False)
      , ("headroom", \p → addRule p 1 (== OpStatFilesystem) (FreeBytesAre (payloadBytes (hCfg cfg64) + 255 * 1024 * 1024)), \f → case f of ReservationFailed (InsufficientHeadroom {}) → True; _ → False)
      , ("native allocation unsupported", \p → addRule p 1 isReserve' (FailWith (er C.eNOTSUP)), \f → case f of StorageUnsupported (NativeUnsupported StepAllocate _) → True; _ → False)
      , ("native allocation refused", \p → addRule p 1 isReserve' (FailWith (er C.eNOSPC)), \f → case f of ReservationFailed (AllocationRefused _) → True; _ → False)
      , ("length cannot be established", \p → addRule p 1 isLength (FailWith (er C.eIO)), \f → case f of ReservationFailed (LengthFailed _) → True; _ → False)
      , ("overhead beyond the model", \p → addRuleAfter p 2 1 (== OpStatFile) (OverAllocated (10 * 1024 * 1024)), \f → case f of ReservationFailed (OverheadExceedsModel _ _) → True; _ → False)
      ]
    isReserve' op = case op of OpReserveRange _ _ → True; _ → False
    isLength op = case op of OpSetFileLength _ → True; _ → False
