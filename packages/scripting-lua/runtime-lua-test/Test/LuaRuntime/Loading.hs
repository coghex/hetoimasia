-- | The module loader on a scheduled owner: an import chain that waits for a source while
-- the owner serves its hooks and its stop, that resumes only on the owner's thread when
-- another thread's source is delivered, that holds the logical tick while it is due and
-- unfinished, and that ends with the owner.
--
-- Every example runs a real chain on a real supervised scheduled owner, under the injected
-- clock and the fake timer. A source is held by not having it and let go by notifying the
-- owner from another thread; what an example knows it knows from what the modules and the
-- hooks recorded, from the supplier's own record, and from the owner's published
-- outcomes. Nothing sleeps.
module Test.LuaRuntime.Loading (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (try)
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl, awaitSupervised)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Hetoimasia.Scripting.Lua.Loading
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEntered, awaitScheduledTerminal, defaultSchedulerBounds, releaseGate)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (Gated (openAllGates), bounded, failExample, requiredPolicy, withBoundaryOpening)

-- | What the supplier and the resolver observe and answer.
data Rig = Rig
  { rigAvailable ∷ !(IORef (Map ExportIdentity SourceAnswer))
  , rigAsked ∷ !(Chan ExportIdentity)
    -- ^ Told, as a source is asked for, so that an example knows a chain has reached a
    -- dependency without guessing how long that takes.
  , rigAcquired ∷ !(IORef [ExportIdentity])
  , rigReleased ∷ !(IORef [ExportIdentity])
  }

newRig ∷ IO Rig
newRig = Rig <$> newIORef Map.empty <*> newChan <*> newIORef [] <*> newIORef []

ident ∷ Text → ExportIdentity
ident path = ExportIdentity (Text.encodeUtf8 ("game:" <> path))

request ∷ Text → RootRequest
request path = RootRequest (ident path) ("game:" <> path)

-- | The plan over the rig: the supplier tells the example it was asked, and holds nothing
-- an example has not put there.
planOf ∷ Rig → Int → LoaderPlan
planOf rig bound =
  (loaderPlan supplier resolver) {planBound = bound}
  where
    supplier =
      SourceSupplier
        { supplierAcquire = \identity → do
            atomicModifyIORef' (rigAcquired rig) (\held → (identity : held, ()))
            writeChan (rigAsked rig) identity
            Map.findWithDefault SourcePending identity <$> readIORef (rigAvailable rig)
        , supplierRelease = \identity → atomicModifyIORef' (rigReleased rig) (\held → (identity : held, ()))
        }
    resolver _ path _ = pure (Right (ResolvedAddress (ident path) ("game:" <> path)))

-- | Put a source where the supplier finds it when asked.
have ∷ Rig → Text → [Text] → IO ()
have rig path source = atomicModifyIORef' (rigAvailable rig) (\held → (Map.insert (ident path) (SourceVerified (Text.encodeUtf8 (Text.unlines source))) held, ()))

-- | Wait, without sleeping, until the supplier has been asked for this many sources.
awaitAsked ∷ Rig → Int → IO ()
awaitAsked rig wanted = go 0
  where
    go seen
      | seen >= wanted = pure ()
      | otherwise = readChan (rigAsked rig) >> go (seen + 1)

-- | An owner of instances from these modules, with a loader.
loaderSpec ∷ IFixture → Rig → Int → [ModuleSource] → ScheduledSpec
loaderSpec fixture rig bound modules = loaderSpecWith fixture rig bound modules noLoaderHooks

-- | The same, with these hooks on the plan.
loaderSpecWith ∷ IFixture → Rig → Int → [ModuleSource] → LoaderHooks → ScheduledSpec
loaderSpecWith fixture rig bound modules hooks =
  (instanceSpec fixture "loading" modules (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds)
    { scheduledLoader = Just ((planOf rig bound) {planHooks = hooks})
    }

-- | An owner with a loader, over a body, whatever way the example ends opening every gate.
withLoader ∷ Int → [ModuleSource] → (IFixture → Rig → RuntimeControl → ScheduledOwner → LoaderEndpoint → IO a) → IO a
withLoader bound modules body = do
  fixture ← newIFixture
  rig ← newRig
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    owner ← startWith fixture runtime (loaderSpec fixture rig bound modules)
    endpoint ← maybe (failExample "the owner has no loader endpoint") pure (scheduledLoaderEndpoint owner)
    body fixture rig control owner endpoint

-- | An owner with a loader whose plan has these hooks, over a body, whatever way the example ends opening every gate.
withLoaderHooks ∷ Int → [ModuleSource] → LoaderHooks → (IFixture → Rig → RuntimeControl → ScheduledOwner → LoaderEndpoint → IO a) → IO a
withLoaderHooks bound modules hooks body = do
  fixture ← newIFixture
  rig ← newRig
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    owner ← startWith fixture runtime (loaderSpecWith fixture rig bound modules hooks)
    endpoint ← maybe (failExample "the owner has no loader endpoint") pure (scheduledLoaderEndpoint owner)
    body fixture rig control owner endpoint

-- | Wait for an identity's outcome, composed with the owner's supervision.
awaitOutcome ∷ RuntimeControl → LoaderEndpoint → Text → IO LoaderOutcome
awaitOutcome control endpoint path = awaitSupervised control (awaitLoaderOutcome endpoint (ident path))

-- | Wait, without sleeping, until the owner has drained what was left for it.
awaitDrained ∷ LoaderEndpoint → IO ()
awaitDrained endpoint = do
  diagnostics ← loaderDiagnostics endpoint
  if loadingSubmitted diagnostics == 0 && loadingNotified diagnostics == 0 then pure () else yield >> awaitDrained endpoint

spec ∷ Spec
spec = describe "the module loader on a scheduled owner" $ do
  it "waits for a source while the owner serves its hooks, and resumes on the owner when another thread's source arrives" $
    bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
      have rig "main" ["fx.record('main:start')", "local dep = import('dep')", "fx.record('main:got ' .. dep.name)", "return { name = 'main', dep = dep }"]
      submitRoot endpoint (request "main") DueUi >>= (`shouldBe` SubmitAccepted)
      -- The chain reached its dependency and is suspended on it.
      awaitAsked rig 2
      -- The owner serves a hook meanwhile.
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitCount fixture 1
      expectDelivered fixture owner "a" 7
      awaitCount fixture 3
      before ← logged fixture
      before `shouldSatisfy` elem "main:start"
      before `shouldSatisfy` all (/= "main:got dep")
      before `shouldSatisfy` any ("tick" `Text.isPrefixOf`)
      loaderOutcome endpoint (ident "main") >>= (`shouldBe` Just OutcomeAdmitted)
      -- Another thread finds the source, tells the owner, and cannot do more.
      found ← newEmptyMVar
      void . forkIO $ do
        answered ← notifySource endpoint (ident "dep") (SourceVerified (Text.encodeUtf8 "fx.record('dep:run') return { name = 'dep' }"))
        putMVar found answered
      takeMVar found >>= (`shouldBe` NotifyAccepted)
      outcome ← awaitOutcome control endpoint "main"
      outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
      dep ← loaderOutcome endpoint (ident "dep")
      dep `shouldSatisfy` \case Just (OutcomeSettled (ModuleReady _)) → True; _ → False
      after ← logged fixture
      filter (`elem` ["main:start", "dep:run", "main:got dep"]) after `shouldBe` ["main:start", "dep:run", "main:got dep"]
      -- Every interest was taken and given back once.
      acquired ← readIORef (rigAcquired rig)
      released ← readIORef (rigReleased rig)
      (length acquired, length released) `shouldBe` (2, 2)

  it "does not make another owner wait for a chain that waits" $
    bounded $ do
      fixtureA ← newIFixture
      fixtureB ← newIFixture
      rigA ← newRig
      rigB ← newRig
      withBoundaryOpening [openAllGates fixtureA, openAllGates fixtureB] $ \control runtime → do
        ownerA ← startWith fixtureA runtime (loaderSpec fixtureA rigA 4 [echoer])
        ownerB ← startWith fixtureB runtime (loaderSpec fixtureB rigB 4 [echoer])
        endpointA ← maybe (failExample "no endpoint") pure (scheduledLoaderEndpoint ownerA)
        endpointB ← maybe (failExample "no endpoint") pure (scheduledLoaderEndpoint ownerB)
        have rigA "held" ["local never = import('never')", "return {}"]
        have rigB "free" ["fx.record('free:ran')", "return {}"]
        _ ← submitRoot endpointA (request "held") DueUi
        awaitAsked rigA 2
        _ ← submitRoot endpointB (request "free") DueUi
        outcomeB ← awaitOutcome control endpointB "free"
        outcomeB `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        logged fixtureB >>= (`shouldBe` ["free:ran"])
        loaderOutcome endpointA (ident "held") >>= (`shouldBe` Just OutcomeAdmitted)

  describe "the logical tick" $ do
    it "keeps the due tick open while a due chain is unfinished, and lets it go when the chain ends" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "due" ["local late = import('late')", "return { late = late }"]
        submitRoot endpoint (request "due") (DueTick 1) >>= (`shouldBe` SubmitAccepted)
        -- The root owes tick 1 from the submission on, before the owner has looked at anything; the
        -- root has not begun, for its tick has not been reached.
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 1
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        awaitAsked rig 2
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        -- Tick 1 is applied and is not complete: its grant is outstanding while the chain waits.
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        -- The next grant is made and not applied; the owner serves another instance meanwhile.
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture 1
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        -- The source arrives; the chain ends; the tick is complete and the next grant is applied.
        _ ← notifySource endpoint (ident "late") (SourceVerified (Text.encodeUtf8 "return {}"))
        outcome ← awaitOutcome control endpoint "due"
        outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing

    it "applies the same grants at once while the tick that is owed is further off, so that the held tick above is not the example's own timing" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "later" ["return {}"]
        submitRoot endpoint (request "later") (DueTick 5) >>= (`shouldBe` SubmitAccepted)
        grantOne control owner
        -- Tick 5 is owed; the grants before it are the example's own.
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 5
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture 1
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)

    it "keeps the due tick open however many grants were queued before the owner looked, and finishes it before the next begins" $
      bounded . withLoader 4 [echoer, holder] $ \fixture rig control owner endpoint → do
        have rig "due" ["local late = import('late')", "return { late = late }"]
        holdOwner fixture owner
        submitRoot endpoint (request "due") (DueTick 1) >>= (`shouldBe` SubmitAccepted)
        -- Three grants are queued while the owner is inside a hook; the loader has not run.
        mapM_ (const (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))) [1 ∷ Int, 2, 3]
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 1
        releaseOwner fixture
        awaitAsked rig 2
        -- Only tick 1 began, and it is not complete: the grants that would have carried the owner past
        -- it wait behind it, and all three are outstanding.
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 3)
        _ ← notifySource endpoint (ident "late") (SourceVerified (Text.encodeUtf8 "return {}"))
        outcome ← awaitOutcome control endpoint "due"
        outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        _ ← awaitTicksComplete control owner
        -- The owed tick is complete, and the grants that waited behind it are applied in order.
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 3)

    it "keeps the earliest obligation of a root submitted again, before it ran and while it waits" $
      bounded . withLoader 4 [echoer, holder] $ \fixture rig control owner endpoint → do
        have rig "due" ["local late = import('late')", "return { late = late }"]
        holdOwner fixture owner
        submitRoot endpoint (request "due") (DueTick 1) >>= (`shouldBe` SubmitAccepted)
        -- Submitted again, later, before the owner drained either.
        submitRoot endpoint (request "due") (DueTick 10) >>= (`shouldBe` SubmitAccepted)
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 1
        releaseOwner fixture
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        awaitAsked rig 2
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 1
        -- And again while the chain is suspended: still tick 1 that is owed.
        submitRoot endpoint (request "due") (DueTick 20) >>= (`shouldBe` SubmitAccepted)
        awaitDrained endpoint
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Just 1
        before ← length <$> logged fixture
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture (before + 1)
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        _ ← notifySource endpoint (ident "late") (SourceVerified (Text.encodeUtf8 "return {}"))
        outcome ← awaitOutcome control endpoint "due"
        outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing

    it "lets the due tick go when the owner exits with the chain unfinished" $
      bounded . withLoader 4 [echoer] $ \_ rig control owner endpoint → do
        have rig "due" ["local late = import('late')", "return {}"]
        _ ← submitRoot endpoint (request "due") (DueTick 1)
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        awaitAsked rig 2
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        loaderOutcome endpoint (ident "due") >>= (`shouldBe` Just OutcomeStopped)
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing

    it "holds nothing for a chain a UI asked for" $
      bounded . withLoader 4 [echoer] $ \_ rig control owner endpoint → do
        have rig "ui" ["local late = import('late')", "return {}"]
        _ ← submitRoot endpoint (request "ui") DueUi
        awaitAsked rig 2
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing
        -- The tick goes on while the chain waits.
        grantOne control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)

  describe "the inbox" $ do
    it "is bounded by admitted work: a full inbox refuses, a duplicate changes nothing, an order is kept" $
      bounded . withLoader 2 [echoer, holder] $ \fixture _ _ owner endpoint → do
        -- The owner is held inside a segment, so that nothing is drained meanwhile.
        holdOwner fixture owner
        submitRoot endpoint (request "one") (DueTick 5) >>= (`shouldBe` SubmitAccepted)
        submitRoot endpoint (request "two") (DueTick 7) >>= (`shouldBe` SubmitAccepted)
        submitRoot endpoint (request "three") DueUi >>= (`shouldBe` SubmitFull)
        loaderDiagnostics endpoint >>= \found → loadingSubmitted found `shouldBe` 2
        notifySource endpoint (ident "one") (SourceVerified "return {}") >>= (`shouldBe` NotifyAccepted)
        notifySource endpoint (ident "one") (SourceVerified "error('replaced')") >>= (`shouldBe` NotifyDuplicate)
        notifySource endpoint (ident "two") SourcePending >>= (`shouldBe` NotifyNothing)
        notifySource endpoint (ident "two") (SourceVerified "return {}") >>= (`shouldBe` NotifyAccepted)
        notifySource endpoint (ident "three") (SourceVerified "return {}") >>= (`shouldBe` NotifyFull)
        releaseOwner fixture
        -- Once drained there is room, and a logical root below one already submitted is refused.
        awaitDrained endpoint
        submitRoot endpoint (request "late") (DueTick 3) >>= (`shouldBe` SubmitOutOfOrder 7)
        submitRoot endpoint (request "later") (DueTick 7) >>= (`shouldBe` SubmitAccepted)

    it "reports a refusal as an outcome, and a root submitted and never drained as stopped when the owner exits" $
      bounded . withLoader 4 [echoer, holder] $ \fixture _ control owner endpoint → do
        let empty = ExportIdentity ""
        submitRoot endpoint (RootRequest empty "empty") DueUi >>= (`shouldBe` SubmitAccepted)
        awaitSupervised control (awaitLoaderOutcome endpoint empty) >>= (`shouldBe` OutcomeRefused (RootIdentityInvalid maxExportIdentityBytes))
        loaderRefusals endpoint >>= (`shouldBe` [(empty, RootIdentityInvalid maxExportIdentityBytes)])
        -- A root the owner never got to: told from one nobody sent, and stopped with the owner.
        holdOwner fixture owner
        submitRoot endpoint (request "queued") DueUi >>= (`shouldBe` SubmitAccepted)
        loaderOutcome endpoint (ident "queued") >>= (`shouldBe` Just OutcomeAdmitted)
        retireScheduled owner
        releaseOwner fixture
        _ ← awaitScheduledTerminal control owner
        loaderOutcome endpoint (ident "queued") >>= (`shouldBe` Just OutcomeStopped)
        loaderOutcome endpoint (ident "never sent") >>= (`shouldBe` Nothing)

    it "closes with the owner: nothing is taken, a waiting chain is stopped and its interests are given back" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "main" ["local guard <close> = setmetatable({}, { __close = function() fx.record('main:closed') end })", "local dep = import('dep')", "return {}"]
        _ ← submitRoot endpoint (request "main") DueUi
        awaitAsked rig 2
        loaderOutcome endpoint (ident "main") >>= (`shouldBe` Just OutcomeAdmitted)
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        loaderOutcome endpoint (ident "main") >>= (`shouldBe` Just OutcomeStopped)
        loaderOutcome endpoint (ident "dep") >>= (`shouldBe` Just OutcomeStopped)
        submitRoot endpoint (request "after") DueUi >>= (`shouldBe` SubmitClosed)
        notifySource endpoint (ident "dep") (SourceVerified "return {}") >>= (`shouldBe` NotifyClosed)
        -- The suspended module was closed on the owner, and every interest was given back.
        logged fixture >>= (`shouldSatisfy` elem "main:closed")
        acquired ← readIORef (rigAcquired rig)
        released ← readIORef (rigReleased rig)
        length released `shouldBe` length acquired
        loaderDiagnostics endpoint >>= \found → (loadingSubmitted found, loadingNotified found, loadingHeld found) `shouldBe` (0, 0, Nothing)

  describe "a stop asked of the owner" $ do
    it "runs no module that was queued, nor resumes one whose source arrived, once the stop was asked, whichever the order" $
      bounded . withLoader 4 [echoer, holder] $ \fixture rig control owner endpoint → do
        have rig "waits" ["fx.record('waits:start')", "local dep = import('dep')", "fx.record('waits:resumed')", "return {}"]
        have rig "fresh" ["fx.record('fresh:ran')", "return {}"]
        _ ← submitRoot endpoint (request "waits") DueUi
        awaitAsked rig 2
        logged fixture >>= (`shouldSatisfy` elem "waits:start")
        -- The owner is held inside a hook; a new root and the awaited source arrive; then a stop is asked.
        holdOwner fixture owner
        submitRoot endpoint (request "fresh") DueUi >>= (`shouldBe` SubmitAccepted)
        notifySource endpoint (ident "dep") (SourceVerified (Text.encodeUtf8 "fx.record('dep:ran') return {}")) >>= (`shouldBe` NotifyAccepted)
        retireScheduled owner
        releaseOwner fixture
        _ ← awaitScheduledTerminal control owner
        -- Nothing of either ran after the request.
        found ← logged fixture
        found `shouldSatisfy` all (`notElem` ["fresh:ran", "waits:resumed", "dep:ran"])
        loaderOutcome endpoint (ident "waits") >>= (`shouldBe` Just OutcomeStopped)
        loaderOutcome endpoint (ident "fresh") >>= (`shouldBe` Just OutcomeStopped)
        acquired ← readIORef (rigAcquired rig)
        released ← readIORef (rigReleased rig)
        length released `shouldBe` length acquired
        -- The root that was queued was never admitted, so nobody was asked for its source.
        acquired `shouldSatisfy` notElem (ident "fresh")

    it "starts no further root once a stop is asked in the middle of an advance" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "first" ["fx.record('first:start')", "fx.block('mid')", "fx.record('first:done')", "return {}"]
        have rig "second" ["fx.record('second:ran')", "return {}"]
        _ ← submitRoot endpoint (request "first") DueUi
        _ ← submitRoot endpoint (request "second") DueUi
        -- The first root is running on the owner, inside its top level, with the second queued behind it.
        awaitEntered (sf fixture) "mid"
        retireScheduled owner
        releaseGate (sf fixture) "mid"
        _ ← awaitScheduledTerminal control owner
        found ← logged fixture
        found `shouldSatisfy` elem "first:done"
        found `shouldSatisfy` notElem "second:ran"
        loaderOutcome endpoint (ident "second") >>= (`shouldBe` Just OutcomeStopped)

    it "does not resume an importer, nor start a dependency, once a stop is asked while its dependency or the importer runs" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "importer" ["fx.record('importer:start')", "local dep = import('dep')", "fx.record('importer:resumed')", "return {}"]
        have rig "dep" ["fx.record('dep:start')", "fx.block('mid')", "fx.record('dep:end')", "return {}"]
        _ ← submitRoot endpoint (request "importer") DueUi
        -- The dependency is running on the owner, inside its top level, with its importer suspended.
        awaitEntered (sf fixture) "mid"
        retireScheduled owner
        releaseGate (sf fixture) "mid"
        _ ← awaitScheduledTerminal control owner
        found ← logged fixture
        found `shouldSatisfy` elem "dep:end"
        found `shouldSatisfy` notElem "importer:resumed"
        loaderOutcome endpoint (ident "importer") >>= (`shouldBe` Just OutcomeStopped)
        acquired ← readIORef (rigAcquired rig)
        released ← readIORef (rigReleased rig)
        length released `shouldBe` length acquired

  describe "placed roots" $ do
    it "holds the tick a placed root is due in until the root has an outcome, and starts it only when everything before that tick is finished" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "due" ["fx.record('due:start')", "local late = import('late')", "fx.record('due:done')", "return { late = late }"]
        submitRoot endpoint (request "due") (DueAt 3 0) >>= (`shouldBe` SubmitAccepted)
        -- Nothing is kept open: the tick is held, not owed, and the root has not begun.
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing
        awaitAsked rig 1
        grantOne control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        length <$> readIORef (rigAcquired rig) >>= (`shouldBe` 1)
        logged fixture >>= (`shouldSatisfy` notElem "due:start")
        -- Tick two is finished, tick three has not begun: the root starts now and reaches its dependency.
        grantOne control owner
        awaitAsked rig 1
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        logged fixture >>= (`shouldSatisfy` elem "due:start")
        -- The grant that would reach tick three is accepted and not applied, while the owner goes on serving hooks.
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture 1
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        _ ← notifySource endpoint (ident "late") (SourceVerified (Text.encodeUtf8 "return {}"))
        outcome ← awaitOutcome control endpoint "due"
        outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 3)
        logged fixture >>= (`shouldSatisfy` elem "due:done")

    it "starts roots by tick and sequence, whatever order they were submitted in, and an earlier place moves a queued root up" $
      bounded . withLoader 8 [echoer] $ \fixture rig control owner endpoint → do
        mapM_ (\name → have rig name ["fx.record('ran " <> name <> "')", "return {}"]) ["p", "q", "r", "s"]
        mapM_ (\(name, tick, sequenceNumber) → submitRoot endpoint (request name) (DueAt tick sequenceNumber) >>= (`shouldBe` SubmitAccepted)) [("p", 5, 0), ("q", 3, 0), ("r", 8, 0), ("s", 7, 0)]
        atomically (promoteSubmitted endpoint (ident "r") (DueAt 6 0)) >>= (`shouldBe` PromoteAccepted)
        mapM_ (const (grantOne control owner)) [1 .. 8 ∷ Int]
        found ← logged fixture
        filter (Text.isPrefixOf "ran ") found `shouldBe` ["ran q", "ran p", "ran r", "ran s"]
        -- A root with an outcome has nothing to move, and the owner stopping takes no more.
        atomically (promoteSubmitted endpoint (ident "q") (DueAt 1 0)) >>= (`shouldBe` PromoteUnknown)
        atomically (promoteSubmitted endpoint (ident "nobody") (DueAt 1 0)) >>= (`shouldBe` PromoteUnknown)
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        atomically (promoteSubmitted endpoint (ident "q") (DueAt 1 0)) >>= (`shouldBe` PromoteClosed)

    it "moves the tick it holds with the earliest place, and never later" $
      bounded . withLoader 4 [echoer] $ \_ rig control owner endpoint → do
        have rig "late" ["local dep = import('dep')", "return {}"]
        submitRoot endpoint (request "late") (DueAt 9 0) >>= (`shouldBe` SubmitAccepted)
        atomically (promoteSubmitted endpoint (ident "late") (DueAt 4 0)) >>= (`shouldBe` PromoteAccepted)
        atomically (promoteSubmitted endpoint (ident "late") (DueAt 6 0)) >>= (`shouldBe` PromoteAccepted)
        mapM_ (const (grantOne control owner)) [1 .. 3 ∷ Int]
        -- Everything before tick four is finished: the root has begun, and tick four is held for it.
        awaitAsked rig 2
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 3)
        _ ← notifySource endpoint (ident "dep") (SourceVerified (Text.encodeUtf8 "return {}"))
        _ ← awaitOutcome control endpoint "late"
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 4)

    it "tells the application what the owner does: each outcome in the order it came, what the chain waits for, the room it has reserved, and the exit once" $ do
      served ← newIORef (0 ∷ Int)
      settledSeen ← newIORef ([] ∷ [[ExportIdentity]])
      blockedSeen ← newIORef ([] ∷ [Blocked])
      reservedAsked ← newIORef ([] ∷ [ExportIdentity])
      exits ← newIORef (0 ∷ Int)
      let hooks =
            noLoaderHooks
              { hookService = atomicModifyIORef' served (\n → (n + 1, ()))
              , hookSettled = \found → atomicModifyIORef' settledSeen (\held → (held <> [map fst found], ()))
              , hookBlocked = \found → atomicModifyIORef' blockedSeen (\held → (held <> [found], ()))
              , hookReserved = \identity → atomicModifyIORef' reservedAsked (\held → (held <> [identity], 0))
              , hookExit = atomicModifyIORef' exits (\n → (n + 1, ()))
              }
      bounded . withLoaderHooks 4 [echoer] hooks $ \_ rig control owner endpoint → do
        have rig "main" ["local dep = import('dep')", "return { dep = dep }"]
        _ ← submitRoot endpoint (request "main") DueUi
        awaitAsked rig 2
        _ ← notifySource endpoint (ident "dep") (SourceVerified (Text.encodeUtf8 "return {}"))
        _ ← awaitOutcome control endpoint "main"
        readIORef settledSeen >>= (`shouldBe` [[ident "dep", ident "main"]])
        readIORef blockedSeen >>= \found → (found, found) `shouldSatisfy` \(held, _) → BlockedSource (ident "dep") `elem` held && last held == BlockedIdle
        readIORef reservedAsked >>= (`shouldBe` [ident "dep"])
        readIORef served >>= (`shouldSatisfy` (> 0))
        readIORef exits >>= (`shouldBe` 0)
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        readIORef exits >>= (`shouldBe` 1)

    it "wakes the owner for a poke, so that a failure a thread of its own could only record is raised on the owner" $ do
      woken ← newChan
      let hooks = noLoaderHooks {hookService = writeChan woken ()}
      bounded . withLoaderHooks 4 [echoer] hooks $ \_ _ _ _ endpoint → do
        atomically (pokeLoader endpoint)
        readChan woken
        atomically (pokeLoader endpoint)
        readChan woken

  describe "a plan" $ do
    it "is refused before anything starts when its bound is below one, or the VM already names a loader" $
      bounded $ do
        fixture ← newIFixture
        rig ← newRig
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          zero ← refusedStart fixture runtime (loaderSpec fixture rig 0 [echoer])
          zero `shouldBe` Left (LoaderPlanRefused [LoaderBoundBelowOne 0])
          let spec' = loaderSpec fixture rig 4 [echoer]
              named = spec' {scheduledVm = (scheduledVm spec') {vmLoader = Just (loaderConfig (SourceSupplier (const (pure SourcePending)) (const (pure ()))) (\_ _ _ → pure (Left "none")))}}
          both ← refusedStart fixture runtime named
          both `shouldBe` Left (LoaderPlanRefused [LoaderAlreadyConfigured])
  where
    refusedStart fixture runtime spec' = fmap (const ()) <$> try @LoaderPlanRefused (startWith fixture runtime spec')
