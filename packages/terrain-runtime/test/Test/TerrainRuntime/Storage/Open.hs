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
import qualified Data.ByteString.Char8 as BC
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes)
import System.Directory (listDirectory)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

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
          nsSize st `shouldBe` cfgAllowanceBytes cfg
          nsAllocated st `shouldSatisfy` (>= cfgAllowanceBytes cfg)
          rsAllocated rs `shouldBe` nsAllocated st
          rsOverhead rs `shouldBe` nsAllocated st - cfgAllowanceBytes cfg
          listDirectory (envDir env) `shouldReturn` []
          evs ← events (envProbe env)
          -- the name is gone, and the allocation was made, before the outcome exists
          let at op = length (takeWhile (/= op) evs)
          at OpUnlinkFile `shouldSatisfy` (< at (OpReserveRange 0 (cfgAllowanceBytes cfg)))
        other → expectationFailure ("not opened: " <> show other)

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
        ReservationFailed (CoverageShort got want) → got < want && want == cfgAllowanceBytes (hCfg cfg64)
        _ → False

  it "serializes reservations on one volume, so two arenas cannot spend the same observed headroom" $
    withEnv $ \env → do
      let allowance = cfgAllowanceBytes (hCfg cfg64)
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
      , ("headroom", \p → addRule p 1 (== OpStatFilesystem) (FreeBytesAre (64 * 1024 * 1024 + 255 * 1024 * 1024)), \f → case f of ReservationFailed (InsufficientHeadroom {}) → True; _ → False)
      , ("native allocation unsupported", \p → addRule p 1 isReserve' (FailWith (er C.eNOTSUP)), \f → case f of StorageUnsupported (NativeUnsupported StepAllocate _) → True; _ → False)
      , ("native allocation refused", \p → addRule p 1 isReserve' (FailWith (er C.eNOSPC)), \f → case f of ReservationFailed (AllocationRefused _) → True; _ → False)
      , ("length cannot be established", \p → addRule p 1 isLength (FailWith (er C.eIO)), \f → case f of ReservationFailed (LengthFailed _) → True; _ → False)
      , ("overhead beyond the model", \p → addRuleAfter p 2 1 (== OpStatFile) (OverAllocated (10 * 1024 * 1024)), \f → case f of ReservationFailed (OverheadExceedsModel _ _) → True; _ → False)
      ]
    isReserve' op = case op of OpReserveRange _ _ → True; _ → False
    isLength op = case op of OpSetFileLength _ → True; _ → False
