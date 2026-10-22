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
import Data.Word (Word64)
import Hetoimasia.Runtime.Supervision (RuntimeControl, awaitSupervised)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Hetoimasia.Scripting.Lua.Loading
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal, defaultSchedulerBounds)
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
loaderSpec fixture rig bound modules =
  (instanceSpec fixture "loading" modules (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds)
    { scheduledLoader = Just (planOf rig bound)
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

-- | Wait for an identity's outcome, composed with the owner's supervision.
awaitOutcome ∷ RuntimeControl → LoaderEndpoint → Text → IO LoaderOutcome
awaitOutcome control endpoint path = awaitSupervised control (awaitLoaderOutcome endpoint (ident path))

-- | Wait, without sleeping, until the owner has drained what was left for it.
awaitDrained ∷ LoaderEndpoint → IO ()
awaitDrained endpoint = do
  diagnostics ← loaderDiagnostics endpoint
  if loadingSubmitted diagnostics == 0 && loadingNotified diagnostics == 0 then pure () else yield >> awaitDrained endpoint

-- | Wait, without sleeping, until the owner holds this tick for a due chain.
awaitHeld ∷ LoaderEndpoint → Maybe Word64 → IO ()
awaitHeld endpoint wanted = do
  diagnostics ← loaderDiagnostics endpoint
  if loadingHeld diagnostics == wanted then pure () else yield >> awaitHeld endpoint wanted

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
    it "holds the next tick while a due chain is unfinished, and lets it go when the chain ends" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "due" ["local late = import('late')", "return { late = late }"]
        submitRoot endpoint (request "due") (DueTick 1) >>= (`shouldBe` SubmitAccepted)
        -- The root's tick has not been reached, so nothing starts and nothing is held.
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing
        grantOne control owner
        awaitAsked rig 2
        awaitHeld endpoint (Just 2)
        -- The next grant is made and not applied; the owner serves another instance meanwhile.
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture 1
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        -- The source arrives; the chain ends; the tick is let go and the grant is applied.
        _ ← notifySource endpoint (ident "late") (SourceVerified (Text.encodeUtf8 "return {}"))
        outcome ← awaitOutcome control endpoint "due"
        outcome `shouldSatisfy` \case OutcomeSettled (ModuleReady _) → True; _ → False
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing

    it "applies the same grant at once when no chain is due, so that the held tick above is not the example's own timing" $
      bounded . withLoader 4 [echoer] $ \fixture rig control owner endpoint → do
        have rig "later" ["return {}"]
        submitRoot endpoint (request "later") (DueTick 5) >>= (`shouldBe` SubmitAccepted)
        grantOne control owner
        loaderDiagnostics endpoint >>= \found → loadingHeld found `shouldBe` Nothing
        _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)
        _ ← admit fixture owner "a" (moduleNamed "echoer")
        awaitCount fixture 1
        _ ← awaitTicksComplete control owner
        atomically (scheduledTick (scheduledEndpoint owner)) >>= (`shouldBe` 2)

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
