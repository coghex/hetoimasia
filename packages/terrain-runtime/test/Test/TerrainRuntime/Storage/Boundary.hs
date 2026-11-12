-- | THE PUBLIC BOUNDARY (round 6). Rounds 1 to 5 were about the inside of the service; round 6's findings were at its edge: a
-- query that never checked whose handle it was given, and a retained value that held more than it looked like. Two
-- things here:
--
-- * the export list of the public module is READ from its source and every exported function must have a row in the
--   boundary table below, so an export added without a row fails this suite (the table is checked against the list, not
--   against itself);
-- * every public function that takes a handle is run with a handle of ANOTHER service whose numeric ids overlap (every
--   service numbers its backings and jobs from 1), and with a handle of a service that has ENDED: the typed refusal or
--   'Nothing', nothing effected, and nothing of the other service's state shown (the whole snapshot of the service
--   that was handed the handle is compared before and after).
module Test.TerrainRuntime.Storage.Boundary (spec, boundaryTable, typeTable, Row (..), TypeRow (..)) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isLower, isUpper)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import System.Directory (doesFileExist)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

h0 ∷ H
h0 = newStoreH smallSpec

-- | One row of the boundary table: an export of the public module.
data Row = Row
  { rName ∷ String
  , rArgs ∷ String
  -- ^ its arguments and what validates each
  , rRetains ∷ String
  -- ^ what it retains from them and how it makes that its own
  , rReturns ∷ String
  -- ^ what it returns, and whether that aliases service state or shows anything of another service or backing
  , rAtomic ∷ String
  -- ^ masked or atomic
  , rAnswers ∷ String
  -- ^ its answer on a stopped, a sealed and a foreign service
  }

-- | Every exported FUNCTION (not types, constructors or fields) of 'Hetoimasia.Terrain.Runtime.Storage', one row each.
boundaryTable ∷ [Row]
boundaryTable =
  [ Row "withStorage" "config (validated when made), the shared admission, a worker group, a logger; the threaded runtime is checked" "nothing of the arguments beyond the handles it was given (the group and the logger are the caller's)" "the body's result; a service whose scope ends with the body" "workers started masked, the body unmasked, the drain masked" "n/a (starts); a refusal to start is `StartFailure`"
  , Row "mkStorageConfig" "the qualified list and the headroom (at least `minHeadroomBytes`)" "its own EVALUATED copy of every name (a name cut from a large buffer keeps that buffer alive otherwise)" "a typed `StorageConfigError` or a config" "pure" "n/a"
  , Row "backingIdentity" "a backing handle" "nothing" "the store identity the handle was made for (two scalars); reads nothing of any service" "pure" "the same for any service: a handle carries its identity"
  , Row "preparedFrom" "a growth token" "nothing" "a scalar" "pure" "n/a"
  , Row "preparedTo" "a growth token" "nothing" "a scalar" "pure" "n/a"
  , Row "preparedAllocated" "a growth token" "nothing" "a scalar" "pure" "n/a"
  , Row "stageWrite" "a store and its active transaction (the model's)" "the transaction's pages, shared (the owner's)" "a staged write or a typed `WriteRefusal`" "pure" "n/a"
  , Row "stagedPages" "a staged write" "nothing" "the owner's page list, shared" "pure" "n/a"
  , Row "stagedTxn" "a staged write" "nothing" "a scalar" "pure" "n/a"
  , Row "submitOpen" "the directory (non-empty, at most `maxDirectoryBytes`, no NUL), a store identity, a configuration" "an OWN COPY of the directory (`BS.copy`, forced) in the queued and the finished job; the identity and the configuration are scalars" "a ticket, or a typed refusal; nothing aliasing service state" "one transaction" "stopped: `ServiceStopped`; sealed: `ServiceStopped`; no handle to be foreign"
  , Row "submitRead" "a backing handle (service identity, then id, then phase), a configuration (against the committed allowance), a first page and a count (1 to 256, inside the file)" "scalars only" "a ticket or a typed refusal" "one transaction" "stopped/sealed: `ServiceStopped` or `BackingClosed`; foreign: `ForeignHandle`"
  , Row "submitWrite" "a backing handle, a staged write (the identity equals the backing's, at most 256 pages, each exactly one page, inside the file, each named once)" "the owner's page list, shared while the job is queued or running and DROPPED when it finishes" "a ticket or a typed refusal" "one transaction" "stopped/sealed: `ServiceStopped` or `BackingClosed`; foreign: `ForeignHandle`"
  , Row "submitGrowth" "a backing handle, a base (the committed allowance) and a target (larger, 1 MiB grid, minimum, offset limit)" "scalars only" "a ticket or a typed refusal" "one transaction (the slot moves with the admission)" "stopped/sealed: `ServiceStopped` or `BackingClosed`; foreign: `ForeignHandle`"
  , Row "submitAbandon" "a backing handle, a growth token (this service's, the current preparation)" "scalars" "a ticket or a typed refusal" "one transaction" "foreign handle or foreign token: `ForeignHandle`; sealed: `BackingClosed`"
  , Row "submitReleasePending" "a backing handle" "scalars" "a ticket or a typed refusal" "one transaction" "foreign: `ForeignHandle`; sealed: `BackingClosed`"
  , Row "commitBackingGrowth" "a backing handle, a growth token (this service's, the current preparation)" "scalars" "`()` or a typed refusal" "one transaction" "foreign handle or foreign token: `ForeignHandle`; sealed: `BackingClosed`"
  , Row "writeOutcomes" "a write report" "nothing" "a fresh list of page numbers and outcomes" "pure" "n/a"
  , Row "awaitTicket" "a ticket (service identity, then id)" "nothing" "`()` once the job has finished; a ticket that names no job here (taken, discarded or foreign) is finished at once, which shows nothing of another service" "an STM read" "stopped/sealed/foreign: returns at once"
  , Row "pollTicket" "a ticket" "nothing" "whether the job has finished (a ticket that names nothing here: yes)" "an STM read" "stopped/sealed/foreign: `True`"
  , Row "withOutcome" "a ticket, a body" "nothing: the body runs over an EVALUATED outcome the service made" "the body's result, or `Nothing` (not finished, taken, discarded or foreign); the callback never runs then" "borrow committed masked, body unmasked, release masked" "foreign: `Nothing`; sealed: `Nothing`"
  , Row "discardTicket" "a ticket" "nothing" "unit; no effect on a ticket that names nothing here" "masked end to end" "foreign: no effect; sealed: no effect"
  , Row "cancelTicket" "a ticket" "nothing" "`CancelResult` (foreign or unknown: `CancelUnknown`)" "one transaction" "foreign/sealed: `CancelUnknown`"
  , Row "withUse" "a backing handle, an action" "nothing" "the action's result or a typed refusal; the action never runs on a refusal" "borrow committed masked, action unmasked, release masked" "foreign: `ForeignHandle`; sealed: `BackingClosed`"
  , Row "closeBacking" "a backing handle" "nothing" "a copy of the close's report (a foreign or closed handle: nothing closed, no native call)" "masked end to end" "foreign/sealed: a report that closed nothing"
  , Row "backingView" "a backing handle (service identity, then id)" "nothing" "a COPY of scalars (committed, length, pending, borrows, flags), or `Nothing` for a handle of another service or a closed backing" "an STM read" "foreign/sealed: `Nothing`"
  , Row "maxQueuedJobs" "none" "n/a" "a constant (8)" "pure" "n/a"
  , Row "maxRunningJobs" "none" "n/a" "a constant (2)" "pure" "n/a"
  , Row "maxIoJobBytes" "none" "n/a" "a constant" "pure" "n/a"
  , Row "maxIoPages" "none" "n/a" "a constant (256)" "pure" "n/a"
  , Row "maxJobRecords" "none" "n/a" "a constant (32)" "pure" "n/a"
  , Row "jobRecordBytes" "none" "n/a" "a constant (4,096)" "pure" "n/a"
  , Row "writeEntryBytes" "none" "n/a" "a constant (112)" "pure" "n/a"
  , Row "writeFailureBytes" "none" "n/a" "a constant (512)" "pure" "n/a"
  , Row "transferBufferBytes" "a page count" "n/a" "a number" "pure" "n/a"
  , Row "resultPageBytes" "none" "n/a" "a constant (4,864)" "pure" "n/a"
  , Row "backingRecordBytes" "none" "n/a" "a constant (4,096)" "pure" "n/a"
  , Row "serviceView" "none" "nothing" "a COPY of counts and the volume figures of THIS service; no handle to be foreign" "an STM read" "stopped/sealed: the counts of that state"
  , Row "failureCode" "a failure" "nothing" "a stable code" "pure" "n/a"
  , Row "defaultQualified" "none" "n/a" "the qualified list" "pure" "n/a"
  , Row "minHeadroomBytes" "none" "n/a" "a constant (256 MiB)" "pure" "n/a"
  ]

-- | One row for an exported TYPE: who builds a value of it, what is checked when a caller does, and whether a value
-- retained by the service can alias anything of the caller's.
data TypeRow = TypeRow
  { tName ∷ String
  , tKind ∷ String
  -- ^ a handle, an input a caller builds, an output the service makes, a failure value, or a service
  , tBuilt ∷ String
  -- ^ who builds it
  , tChecked ∷ String
  -- ^ what is validated when a caller supplies it
  , tAliasing ∷ String
  -- ^ whether a retained value can alias a larger allocation or another service's state, and what makes it the service's own
  }

-- | Every exported TYPE of the public module, one row each (checked against the export list like the functions).
typeTable ∷ [TypeRow]
typeTable =
  [ TypeRow "StorageService" "a service" "`withStorage`" "n/a" "an abstract handle to the running service; a value is valid only inside its scope"
  , TypeRow "StartFailure" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "StorageConfig" "an input a caller builds (abstract)" "`mkStorageConfig`" "the headroom at least `minHeadroomBytes`" "the qualified names are the configuration's OWN evaluated copies (a name cut from a large buffer would keep it alive)"
  , TypeRow "StorageConfigError" "a failure value" "`mkStorageConfig`" "n/a" "scalars"
  , TypeRow "Backing" "a handle (abstract)" "the service, in an opened backing's outcome" "service identity, then id, in the one resolver" "two scalars and the store identity; names nothing of another service"
  , TypeRow "Ticket" "a handle (abstract)" "the service, at each submission" "service identity, then id, in the one resolver" "two scalars"
  , TypeRow "PreparedGrowth" "a handle (abstract)" "the service, in a growth outcome" "its service identity, in the one place (`ownsPrepared`), and the current preparation" "scalars"
  , TypeRow "WorkClass" "an input a caller builds" "the caller" "total" "a tag"
  , TypeRow "OpenSpec" "an input a caller builds" "the caller" "the directory: non-empty, at most `maxDirectoryBytes`, no NUL" "the directory is COPIED at `submitOpen` before anything retains it; the identity and the configuration are scalars"
  , TypeRow "ReadMode" "an input a caller builds" "the caller" "total" "a tag"
  , TypeRow "StagedWrite" "an input a caller builds (abstract)" "`stageWrite`" "the identity equals the backing's; at most 256 pages, each one page, in the file, each once" "the page list is the OWNER's, shared while the job is queued or running and dropped when it finishes (documented; the transaction's own reservation pays for it)"
  , TypeRow "WriteRefusal" "a failure value" "`stageWrite`" "n/a" "scalars"
  , TypeRow "Outcome" "an output the service makes" "the service" "n/a" "an EVALUATED value (`forceOutcome`): a read's pages are the service's own per-page copies, charged; no view into a caller's or the platform's buffer"
  , TypeRow "Reservation" "an output the service makes" "the service" "n/a" "scalars and the filesystem name, which is the profile's own copy"
  , TypeRow "WriteReport" "an output the service makes" "the service" "n/a" "page numbers and results, evaluated; never the pages"
  , TypeRow "PageResult" "an output the service makes" "the service" "n/a" "a tag or a failure value"
  , TypeRow "CancelResult" "an output the service makes" "the service" "n/a" "a tag"
  , TypeRow "CloseReport" "an output the service makes" "the service" "n/a" "a COPY of the close's result (the service keeps its own typed failure)"
  , TypeRow "BackingView" "an output the service makes" "the service" "n/a" "scalars copied out of the entry"
  , TypeRow "ServiceView" "an output the service makes" "the service" "n/a" "counts and the volume figures of THIS service; copies"
  , TypeRow "StorageFailure" "a failure value" "the service" "n/a" "strict scalars; a text is a bounded evaluated copy"
  , TypeRow "IoOp" "a failure value" "the service" "n/a" "a tag"
  , TypeRow "IoKind" "a failure value" "the service" "n/a" "a tag and an errno"
  , TypeRow "IoFailure" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "IntegrityFailure" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "UnsupportedWhy" "a failure value" "the service" "n/a" "the refused filesystem's name is the profile's own copy"
  , TypeRow "ReservationFailure" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "ReservationOp" "a failure value" "the service" "n/a" "a tag"
  , TypeRow "InvalidWhy" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "BusyReason" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "CleanupNote" "a failure value" "the service" "n/a" "scalars"
  , TypeRow "Errno" "a failure value" "the platform" "n/a" "a scalar"
  ]

-- | The functions of the public module that take a handle, each as one case of the sweep.
data HandleFn
  = FnSubmitRead
  | FnSubmitWrite
  | FnSubmitGrowth
  | FnSubmitAbandon
  | FnSubmitReleasePending
  | FnCommit
  | FnAwait
  | FnPoll
  | FnWithOutcome
  | FnDiscard
  | FnCancel
  | FnWithUse
  | FnCloseBacking
  | FnBackingView
  deriving stock (Eq, Show, Enum, Bounded)

fnName ∷ HandleFn → String
fnName f = case f of
  FnSubmitRead → "submitRead"
  FnSubmitWrite → "submitWrite"
  FnSubmitGrowth → "submitGrowth"
  FnSubmitAbandon → "submitAbandon"
  FnSubmitReleasePending → "submitReleasePending"
  FnCommit → "commitBackingGrowth"
  FnAwait → "awaitTicket"
  FnPoll → "pollTicket"
  FnWithOutcome → "withOutcome"
  FnDiscard → "discardTicket"
  FnCancel → "cancelTicket"
  FnWithUse → "withUse"
  FnCloseBacking → "closeBacking"
  FnBackingView → "backingView"

-- | The names the public module exports as functions, read from its source.
exportedFunctions ∷ IO [String]
exportedFunctions = filter (\t → case t of c : _ → isLower c; [] → False) <$> exportedNames

-- | The names the public module exports as TYPES, read from its source.
exportedTypes ∷ IO [String]
exportedTypes = filter (\t → case t of c : _ → isUpper c; [] → False) <$> exportedNames

exportedNames ∷ IO [String]
exportedNames = do
  let path = "src/Hetoimasia/Terrain/Runtime/Storage.hs"
  there ← doesFileExist path
  unless there (expectationFailure ("the public module's source is not at " <> path <> " (the suite runs in the package directory)"))
  src ← readFile path
  let ls = lines src
      body = takeWhile (not . (") where" `isPrefixOfAny`)) (drop 1 (dropWhile (not . ("module Hetoimasia.Terrain.Runtime.Storage" `isPrefixOfAny`)) ls))
      code = [takeWhile (/= '-') l | l ← body, not (null (dropWhile (== ' ') l))]
      tokens = concatMap (words . map (\c → if c `elem` ("(),." :: String) then ' ' else c)) code
  pure (nub [t | t@(c : _) ← tokens, isLower c || isUpper c, all (`notElem` ("*" :: String)) t])
  where
    isPrefixOfAny p l = take (length p) (dropWhile (== ' ') l) == p

spec ∷ Spec
spec = describe "Storage backend: the public boundary" $ do
  it "has a row in the boundary table for every function the public module exports, and for nothing else" $ do
    exported ← exportedFunctions
    let tabled = map rName boundaryTable
    sort exported `shouldBe` sort tabled

  it "has a row in the type table for every type the public module exports, and for nothing else" $ do
    exported ← exportedTypes
    sort exported `shouldBe` sort (map tName typeTable)

  it "has every function that takes a handle in the sweep" $ do
    exported ← exportedFunctions
    let handleTaking = ["submitRead", "submitWrite", "submitGrowth", "submitAbandon", "submitReleasePending", "commitBackingGrowth", "awaitTicket", "pollTicket", "withOutcome", "discardTicket", "cancelTicket", "withUse", "closeBacking", "backingView"]
    -- a function that is exported and takes a handle is in the sweep; the sweep names no function that is not exported
    sort (map fnName [minBound .. maxBound]) `shouldBe` sort handleTaking
    forM_ handleTaking (`shouldSatisfy` (`elem` exported))

  it "refuses a handle of another service with overlapping ids, and a handle of an ended service, in every function that takes one" $
    withEnv $ \envB → do
      -- the service that RECEIVES the foreign handles holds a backing 1 and a finished, untaken job 1: the ids overlap
      tB ← submitOpen (envSvc envB) ExplicitWork (OpenSpec (dirOf envB) ident (hCfg h0)) >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc envB) tB))
      handlesRef ← newIORef Nothing
      -- a live service A hands out handles, which are tried on B while A is alive (a foreign handle) ...
      withEnv $ \envA → do
        bA ← openBacking envA ident (hCfg h0)
        tA ← submitOpen (envSvc envA) ExplicitWork (OpenSpec (dirOf envA) ident (hCfg h0)) >>= either (fail . show) pure
        bounded (atomically (awaitTicket (envSvc envA) tA))
        pA ← do
          o ← submitGrowth (envSvc envA) bA (64 * mib) (128 * mib) >>= outcomeOf envA
          case o of
            GrowthPrepared q _ → pure q
            other → fail ("no growth was prepared: " <> show other)
        w ← oneWrite
        let hs = Handles bA tA pA w
        writeIORef handlesRef (Just hs)
        sweep envB hs (Just envA)
      -- ... and again after A has ENDED (a handle of a service that is gone)
      stored ← readIORef handlesRef
      case stored of
        Nothing → expectationFailure "no handles were collected"
        Just hs → sweep envB hs Nothing
  where
    mib = 1024 * 1024 ∷ Word64
    dirOf = BC.pack . envDir

-- | The handles of the service that hands them out, and a one-page write for it.
data Handles = Handles Backing Ticket PreparedGrowth StagedWrite

-- | A staged write of one page, for the sweep.
oneWrite ∷ IO StagedWrite
oneWrite = do
  let plan = either error id (planFor h0 1)
  (tid, s1) ← either (fail . show) pure (admit plan (hStore h0))
  sw ← either (fail . show) pure (stageWrite s1 tid)
  pure sw {swPages = [(PageNo 100, BS.replicate pageSize 7)]}

-- | Try every handle-taking function on @env@ with another service's handles: the answer is the refusal the boundary
-- promises, and the whole state of the service that was handed them (and of the one that made them, when it is still live)
-- is the same before and after.
sweep ∷ Env → Handles → Maybe Env → Expectation
sweep env hs other = forM_ [minBound .. maxBound] $ \fn → do
  stateBefore ← state env
  beforeOther ← traverse state other
  answered ← runFn fn env hs
  stateAfter ← state env
  afterOther ← traverse state other
  (fnName fn, answered) `shouldBe` (fnName fn, True)
  (fnName fn, stateAfter) `shouldBe` (fnName fn, stateBefore)
  (fnName fn, afterOther) `shouldBe` (fnName fn, beforeOther)

-- | The whole observable state of a service: its snapshot and its view.
state ∷ Env → IO String
state env = atomically ((\sn v → show sn <> show v) <$> snapshotOf (envSvc env) <*> serviceView (envSvc env))

-- | One function with the foreign handles; True when its answer is the refusal (or nothing) the boundary promises.
runFn ∷ HandleFn → Env → Handles → IO Bool
runFn fn env (Handles b t p w) =
  let svc = envSvc env
   in case fn of
        FnSubmitRead → refused <$> submitRead svc b ExplicitWork (hCfg h0) (PageNo 1) 1 ReadProbe
        FnSubmitWrite → refused <$> submitWrite svc b w
        FnSubmitGrowth → refused <$> submitGrowth svc b (64 * 1024 * 1024) (128 * 1024 * 1024)
        FnSubmitAbandon → refused <$> submitAbandon svc b p
        FnSubmitReleasePending → refused <$> submitReleasePending svc b
        FnCommit → (== Left ForeignHandle) <$> commitBackingGrowth svc b p
        FnAwait → atomically (awaitTicket svc t) >> pure True
        FnPoll → atomically (pollTicket svc t)
        FnWithOutcome → (== Nothing) <$> withOutcome svc t (\_ → pure ())
        FnDiscard → discardTicket svc t >> pure True
        FnCancel → (== CancelUnknown) <$> cancelTicket svc t
        FnWithUse → (\r → either (== ForeignHandle) (const False) r) <$> withUse svc b (pure ())
        FnCloseBacking → (not . crClosed) <$> closeBacking svc b
        FnBackingView → (== Nothing) <$> atomically (backingView svc b)
  where
    refused r = case r of
      Left ForeignHandle → True
      _ → False
