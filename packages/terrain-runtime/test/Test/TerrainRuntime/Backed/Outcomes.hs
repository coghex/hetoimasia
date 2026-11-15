-- | Table (B) of #665: every outcome of the storage backend and of the store planner, and
-- what the terrain owner does with each.
--
-- The decision is a pure function ("Hetoimasia.Terrain.Runtime.Backed.Backend") with no
-- wildcard over any outcome type, so a constructor the backend or the store gains is a
-- compile error there. These examples are the other half: they enumerate every
-- constructor, with every sub-reason that is decided differently, crossed with every kind
-- of job it can answer, and state the expected decision as plain data written here, not
-- computed by the code under test.
module Test.TerrainRuntime.Backed.Outcomes (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( CancelResult (..)
  , CloseReport (..)
  , Outcome (..)
  , PageResult (..)
  , WriteReport (..)
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (BusyWhy (CachePressure, ControlPressure, StagingPressure))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageError (..), PageNo (..), TreeId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (AdmitRefusal (..), Condition (..), TxnId, WriteOutcome (..), admit)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (CapacityWhy (..), IntegrityWhy (..), PlanRefusal (..), Planned (..), StaleWhy (..), TxClass (..))
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Plan as P
import Hetoimasia.Terrain.Runtime.Store.Internal.State (ConfigError (..), OffsetError (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Protocol (Stall (..), Supply (..))
import Test.Hspec
import Test.TerrainRuntime.Store.Harness (H (..), deltaFor, fillPlan, ident0, newH, runKey, runRec, smallSpec)

-- | A real transaction identity: one planned and admitted against a fresh store, as the owner does.
aTxn ∷ IO TxnId
aTxn = do
  let h = newH smallSpec ident0
  planned ← either (\e → fail ("not planned: " <> e)) pure (fillPlan h (deltaFor (hStore h) False False 1 [(runKey 1 1 1, Just (runRec 2))]) Ordinary)
  case planned of
    Planned plan → either (\e → fail ("not admitted: " <> show e)) (pure . fst) (admit plan (hStore h))
    other → fail ("not planned: " <> take 120 (show other))

-- | What the owner does, as data independent of the code that decides it.
data Expect
  = EDomain !Text
  | EPause !Condition !Text
  | EPausedFor !Condition
  | ERetry
  | ESerialize
  | EReplan
  | EWait
  | EClosing
  | EExhausted
  | EDefect
  deriving stock (Eq, Show)

expectOf ∷ Handling → Expect
expectOf = \case
  HandleDomain f → EDomain (faultCode f)
  HandlePause c f → EPause c (faultCode f)
  HandlePausedFor c → EPausedFor c
  HandleRetryLater _ → ERetry
  HandleSerialize → ESerialize
  HandleReplan → EReplan
  HandleWaitReclaim _ _ → EWait
  HandleClosing → EClosing
  HandleExhausted → EExhausted
  HandleDefect _ → EDefect

-- | The kinds, in the order every row below lists its expectations.
kinds ∷ [JobKind]
kinds = [JkOpen, JkRead, JkWrite, JkGrowth, JkRelease]

-- A row: a failure, and what the owner does about it for an open, a read, a write, a growth
-- and a release.
type Row = (String, StorageFailure, [Expect])

io ∷ IoFailure
io = IoFailure IoWrite (IoErrno (Errno 5)) (Just (PageNo 3)) (Just 12288) 0 4096

failureRows ∷ [Row]
failureRows =
  [ ("unsupported: filesystem not qualified", StorageUnsupported (FilesystemNotQualified (BC.pack "tmpfs")), [unsupported, x, x, unsupported, x])
  , ("unsupported: native allocation", StorageUnsupported (NativeUnsupported StepAllocate (Errno 45)), [unsupported, x, x, unsupported, x])
  ]
    <> [ ("reservation: " <> label, ReservationFailed why, [reservation, x, x, reservation, x])
       | (label, why) ←
           [ ("insufficient headroom", InsufficientHeadroom 1 2 3)
           , ("allocation refused", AllocationRefused (Errno 28))
           , ("allocation short", AllocationShort 1 2)
           , ("length failed", LengthFailed (Errno 5))
           , ("length mismatch", LengthMismatch 1 2)
           , ("coverage short", CoverageShort 1 2)
           , ("overhead exceeds model", OverheadExceedsModel 1 2)
           , ("pending reservation blocks", PendingReservationBlocks 5)
           ]
       ]
    <> [ ("io: " <> label, StorageIo f, [EDomain "storage_io", EPause CondIo "storage_io", EPause CondIo "storage_io", EDomain "storage_io", EDomain "storage_io"])
       | (label, f) ←
           [ ("errno", io)
           , ("zero progress", io {ioKind = IoZeroProgress})
           , ("interrupt storm", io {ioKind = IoInterruptStorm})
           , ("overrun", io {ioKind = IoOverrun})
           , ("state wrong", io {ioKind = IoStateWrong})
           ]
       ]
    <> [ ("integrity: " <> label, StorageIntegrity f, [x, EPause CondIntegrity "storage_integrity", x, x, x])
       | (label, f) ←
           [ ("page invalid", PageInvalid (PageNo 1) 0 BadMagic)
           , ("page truncated", PageTruncated (PageNo 1) 2 3 4)
           ]
       ]
    <> [ ("invalid: " <> label, InvalidRequest why, expected)
       | (label, why, expected) ←
           [ ("allowance", AllowanceInvalid (AllowanceBelowMinimum 1), allDefect)
           , ("page outside file", PageOutsideFile (PageNo 1) OffsetOverflow, allDefect)
           , ("page wrong size", PageWrongSize (PageNo 1) 7, allDefect)
           , ("duplicate page", DuplicatePage (PageNo 1), allDefect)
           , ("too many pages", TooManyPages 300, allDefect)
           , ("empty request", EmptyRequest, allDefect)
           , ("beyond committed cap", BeyondCommittedCap 2 1, allDefect)
           , ("payload beyond backing", PayloadBeyondBacking 2 1, allDefect)
           , ("identity mismatch", IdentityMismatch, allDefect)
           , ("growth not increasing", GrowthNotIncreasing 2 1, [x, x, x, EDomain "storage_size_not_increased", x])
           , ("growth stale base", GrowthStaleBase 2 1, allDefect)
           , ("no prepared growth", NoPreparedGrowth, allDefect)
           , ("directory", DirectoryInvalid, allDefect)
           , ("credit", CreditInvalid (A.CreditExceedsAccount "cache" 2 1), allDefect)
           ]
       ]
    <> [ ("busy: " <> label, BusyNow why, replicate 5 ERetry)
       | (label, why) ←
           [ ("queue full", QueueFull)
           , ("records full", RecordsFull)
           , ("mutation active", MutationActive)
           , ("growth active", GrowthActive)
           , ("cache pressure", AccountPressure (CachePressure 1 0))
           , ("staging pressure", AccountPressure (StagingPressure 1 0))
           , ("control pressure", AccountPressure (ControlPressure 1 0))
           ]
       ]
    <> [ ("backing closed", BackingClosed, allDefect)
       , ("foreign handle", ForeignHandle, allDefect)
       , ("host failure", HostFailure "a defect", allDefect)
       ]
  where
    unsupported = EDomain "storage_unsupported"
    reservation = EDomain "reservation_failed"
    x = EDefect
    allDefect = replicate 5 EDefect

spec ∷ Spec
spec = describe "table (B): every outcome of the storage backend and the store planner, and what the owner does" $ do
  it "decides every storage failure for every kind of job as the table states, while the owner runs" $
    mapM_
      ( \(label, failure, expected) → do
          let got = [expectOf (classifyFailure OwnerRunning k failure) | k ← kinds]
          (label, got) `shouldBe` (label, expected)
      )
      failureRows
  it "reads a closed backing and a stopped service as the owner's own closure only while it is closing, and a defect while it runs" $
    mapM_
      ( \failure → do
          [expectOf (classifyFailure OwnerClosing k failure) | k ← kinds] `shouldBe` replicate 5 EClosing
          [expectOf (classifyFailure OwnerRunning k failure) | k ← kinds] `shouldBe` replicate 5 EDefect
      )
      [ServiceStopped, BackingClosed]
  it "reads a job cancelled by nobody the owner knows of as the closure while it closes and a defect while it runs, and a page the window refuses as an integrity pause" $ do
    expectOf (classifyUnaskedCancel OwnerClosing) `shouldBe` EClosing
    expectOf (classifyUnaskedCancel OwnerRunning) `shouldBe` EDefect
    expectOf (classifySupply (PageRefusedByWindow (PageNo 3) BadMagic)) `shouldBe` EPause CondIntegrity "storage_integrity"
    expectOf (classifySupply (ProtocolError (UnaskedPage (PageNo 3)))) `shouldBe` EDefect
  it "decides every other failure the same whether the owner runs or closes: closing hides no defect" $
    mapM_
      ( \(label, failure, _) → case failure of
          ServiceStopped → pure ()
          BackingClosed → pure ()
          _ → (label, [expectOf (classifyFailure OwnerClosing k failure) | k ← kinds]) `shouldBe` (label, [expectOf (classifyFailure OwnerRunning k failure) | k ← kinds])
      )
      failureRows
  it "answers each outcome constructor for the one kind of job it belongs to and calls it a mismatch for every other" $ do
    tid ← aTxn
    let table ∷ [(String, Outcome, [JobKind])]
        table =
          [ ("Pages", Pages [], [JkRead])
          , ("Written", Written (WriteReport tid []), [JkWrite])
          , ("GrowthNoChange", GrowthNoChange, [JkGrowth])
          , ("Released", Released, [JkRelease])
          ]
    mapM_
      ( \(label, outcome, owners) →
          mapM_
            ( \k → case (k `elem` owners, reactTo OwnerRunning k outcome) of
                (False, GotMismatch _) → pure ()
                (True, GotMismatch why) → expectationFailure (label <> " was a mismatch for its own kind " <> show k <> ": " <> show why)
                (True, _) → pure ()
                (False, _) → expectationFailure (label <> " answered a " <> show k <> " job")
            )
            kinds
      )
      table
  it "carries a failure's decision and its cleanup for every kind, and a cancellation for every kind" $
    mapM_
      ( \k → do
          reactTo OwnerRunning k (Failed (StorageIo io) [CleanupNote IoClose (Errno 9)]) `shouldSatisfy` \case
            GotFailure h notes → notes == [CleanupNote IoClose (Errno 9)] && expectOf h == expectOf (classifyFailure OwnerRunning k (StorageIo io))
            _ → False
          reactTo OwnerRunning k (Cancelled [CleanupNote IoUnlink (Errno 2)]) `shouldSatisfy` \case
            GotCancelled notes → notes == [CleanupNote IoUnlink (Errno 2)]
            _ → False
      )
      kinds
  it "decides every planner refusal: window results never reach the owner, a full allowance pauses, integrity pauses" $ do
    let cap = Capacity
        rows ∷ [(String, PlanRefusal, Expect)]
        rows =
          [ ("stale window", Stale (StaleWindow 1 2), EReplan)
          , ("stale foreign window", Stale ForeignWindow, EReplan)
          , ("disk full", cap (DiskFull 9 4 2), EPause CondCapacity "storage_full")
          , ("tree too tall", cap (TreeTooTall TreeRuns), EPause CondCapacity "storage_full")
          , ("retirement backlog", cap (RetirementBacklog 3 40), EWait)
          , ("pages exceeded", cap (TxnPagesExceeded 300), EDefect)
          , ("ram exceeded", cap (TxnRamExceeded 5000000), EDefect)
          , ("window exceeded", cap (WindowExceeded 400), EDefect)
          , ("window bytes exceeded", cap (WindowBytesExceeded 400), EDefect)
          , ("overlay exceeded", cap (OverlayExceeded 400), EDefect)
          , ("list too large", cap (ListTooLarge 600), EDefect)
          , ("probes exceeded", cap (ProbesExceeded 600), EDefect)
          , ("bookkeeping exceeded", cap (BookkeepingExceeded 90), EDefect)
          , ("loose exceeded", cap (LooseExceeded 2000), EDefect)
          , ("integrity: counters", Integrity CorruptCounters, EPause CondIntegrity "storage_integrity")
          , ("integrity: bad page", Integrity (BadPage BadMagic (PageNo 1)), EPause CondIntegrity "storage_integrity")
          , ("integrity: double free", Integrity (DoubleFree (PageNo 1)), EPause CondIntegrity "storage_integrity")
          , ("integrity: broken invariant", Integrity (BrokenInvariant TreeFree), EPause CondIntegrity "storage_integrity")
          ]
    mapM_ (\(label, refusal, expected) → (label, expectOf (classifyPlanRefusal refusal)) `shouldBe` (label, expected)) rows
    -- a refusal of the candidate itself is never a domain result on a valid store
    expectOf (classifyPlanRefusal (P.Invalid P.InconsistentRevisions)) `shouldBe` EDefect
    -- except a revision, the version or #661's authority reaching its last value: exhaustion, never a wrap
    map (expectOf . classifyPlanRefusal . P.Invalid) [P.RevisionArithmetic, P.VersionArithmetic, P.DiscoveryRefusal D.AuthorityOverflow]
      `shouldBe` replicate 3 EExhausted
  it "decides every refusal to admit a planned transaction" $
    mapM_
      (\(label, refusal, expected) → (label, expectOf (classifyAdmitRefusal refusal)) `shouldBe` (label, expected))
      ( [ ("another transaction", BusyTransaction, ESerialize)
      , ("a growth", BusyGrowth, ESerialize)
      , ("stale plan", StalePlan, EReplan)
      , ("paused for capacity", Paused CondCapacity, EPausedFor CondCapacity)
      , ("paused for io", Paused CondIo, EPausedFor CondIo)
      , ("paused for integrity", Paused CondIntegrity, EPausedFor CondIntegrity)
        , ("no capacity", NoCapacity 9 4, EPause CondCapacity "storage_full")
        ] ∷ [(String, AdmitRefusal, Expect)]
      )
  it "reports a write page by page: a failed page and the pages not attempted are not written, and the first failure is the cause" $ do
    tid ← aTxn
    let r =
          writeReaction OwnerRunning (WriteReport tid [(PageNo 1, Wrote), (PageNo 2, WriteFailedAt (StorageIo io)), (PageNo 3, NotAttempted), (PageNo 4, NotAttempted)])
    wrOutcomes r `shouldBe` [(PageNo 1, WriteDone), (PageNo 2, WriteFailed), (PageNo 3, WriteFailed), (PageNo 4, WriteFailed)]
    wrAllWritten r `shouldBe` False
    wrNotAttempted r `shouldBe` [PageNo 3, PageNo 4]
    fmap (\(p, h) → (p, expectOf h)) (wrFirstFailure r) `shouldBe` Just (PageNo 2, EPause CondIo "storage_io")
    -- every page written: eligible for the owner's arbitration, no failure
    let ok = writeReaction OwnerRunning (WriteReport tid [(PageNo 1, Wrote), (PageNo 2, Wrote)])
    (wrAllWritten ok, wrFirstFailure ok) `shouldBe` (True, Nothing)
    -- pages not attempted with no failed page (the job stopped at a cancellation): not written, no cause
    let stopped = writeReaction OwnerRunning (WriteReport tid [(PageNo 1, Wrote), (PageNo 2, NotAttempted)])
    (wrAllWritten stopped, wrFirstFailure stopped) `shouldBe` (False, Nothing)
  it "decides what a cancellation request found" $ do
    reactToCancel CancelledBeforeDispatch `shouldBe` CancelWithdrawn
    reactToCancel CancelRequested `shouldBe` CancelWaitsForDrain
    reactToCancel CancelTooLate `shouldBe` CancelOutcomeStands
    reactToCancel CancelUnknown `shouldSatisfy` \case CancelDefect _ → True; _ → False
  it "records what a close left: the platform's error, a raised exception, an extra reservation, and a HELD reservation" $ do
    let clean = CloseReport True Nothing Nothing Nothing False
    reactToClose clean `shouldBe` CloseHandling True [] False Nothing
    let failed = CloseReport True (Just (Errno 5)) (Just 4096) (Just "raised") True
        h = reactToClose failed
    chReservationHeld h `shouldBe` True
    length (chEvidence h) `shouldBe` 3
    chPendingBytes h `shouldBe` Just 4096
    -- a second close finds nothing to close
    chClosedHere (reactToClose (CloseReport False Nothing Nothing Nothing False)) `shouldBe` False
