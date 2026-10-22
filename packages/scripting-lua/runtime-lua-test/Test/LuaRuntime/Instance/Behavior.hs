-- | M1 behavior instances: an instance of a behavior a module returned in its
-- export table, which the owner kept in its VM as real Lua values.
--
-- Every example runs real instances on a real supervised scheduled owner whose
-- export modules were evaluated at start, under the injected clock and the fake
-- timer, with gates and barriers and no sleeps. What an example knows, it knows from
-- what the hooks recorded and from the instances' settlements. The cadence rule an
-- application chooses is the application's: these examples use a small one of their
-- own, and the real M1 rule is tested where it lives.
module Test.LuaRuntime.Instance.Behavior (spec) where

import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Data.Text.Encoding as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfTimer), awaitEffect, awaitRegistrations, defaultSchedulerBounds, setClock)
import Test.LuaRuntime.Scheduler.Support (fireReg, liveRegs, nanoseconds)
import Test.LuaRuntime.Support (Gated (..), bounded, failExample, requiredPolicy, withBoundaryOpening)

-- Building exports ------------------------------------------------------------------

-- | An export module under an identity, labelled by it.
exportOf ∷ ByteString → [Text] → ExportSource
exportOf identity source = ExportSource (ExportIdentity identity) (Text.decodeUtf8 identity) (Text.encodeUtf8 (Text.unlines source))

-- | A logical rule: an @update@ hook falls due every @every_ticks@ ticks, one by
-- default; a behavior without one has no interval.
logicalRule ∷ BehaviorShape → Either Text (Maybe Interval)
logicalRule shape
  | not (shapeUpdate shape) = Right Nothing
  | otherwise = case shapeEveryTicks shape of
      FieldAbsent → Right (Just (LogicalTicks 1))
      FieldInteger count → Right (Just (LogicalTicks (toInteger count)))
      other → Left ("every_ticks: " <> Text.pack (show other))

-- | An elapsed rule: @every_seconds@ is a whole number of hundreds of nanoseconds.
elapsedRule ∷ BehaviorShape → Either Text (Maybe Interval)
elapsedRule shape
  | not (shapeUpdate shape) = Right Nothing
  | otherwise = case shapeEverySeconds shape of
      FieldInteger count → Right (Just (ElapsedEvery (nanoseconds (fromIntegral count * 100))))
      other → Left ("every_seconds: " <> Text.pack (show other))

-- | The request for the behavior this module's field holds.
requestFor ∷ ByteString → Text → Value → (BehaviorShape → Either Text (Maybe Interval)) → BehaviorRequest
requestFor identity select facade rule =
  BehaviorRequest
    { behaviorExport = ExportIdentity identity
    , behaviorLabel = Text.decodeUtf8 identity
    , behaviorSelect = select
    , behaviorFacade = facade
    , behaviorCadence = rule
    , behaviorName = Just select
    , behaviorClass = OrdinaryClass
    }

-- | The facade a name stands for: a record, so that the examples can tell instances
-- apart by what their hooks read from it.
facadeNamed ∷ Text → Value
facadeNamed name = VRecord [("name", VText name)]

-- | Admit a behavior instance, expecting it accepted, under this name.
admitBehavior ∷ IFixture → ScheduledOwner → Text → BehaviorRequest → IO InstanceTicket
admitBehavior fixture owner name request =
  admitBehaviorInstance (scheduledEndpoint owner) request >>= expectAccepted fixture name

-- | An owner whose export modules were evaluated at start, with these ceilings and
-- the standard instance configuration, run over a body. Whatever way the example ends,
-- every gate of its fixture is opened.
withExports ∷ [ExportSource] → ExportLimits → (IFixture → RuntimeControl → ScheduledOwner → IO a) → IO a
withExports exports limits body = do
  fixture ← newIFixture
  withBoundaryOpening [openAllGates fixture] $ \control runtime → do
    let base = instanceSpec fixture "behavior" [] (testConfig instanceBounds') requiredPolicy defaultSchedulerBounds
        spec' = base {scheduledVm = (scheduledVm base) {vmExports = exports, vmExportLimits = limits}}
    owner ← startWith fixture runtime spec'
    body fixture control owner

-- | The same with the default ceilings.
withDefaults ∷ [ExportSource] → (IFixture → RuntimeControl → ScheduledOwner → IO a) → IO a
withDefaults exports = withExports exports defaultExportLimits

-- | The failure a settlement holds, or the example fails.
failureIn ∷ InstanceSettlement → IO InstanceFailure
failureIn settlement = case failureOf' settlement of
  Just failure → pure failure
  Nothing → failExample ("the instance did not fail: " <> show (resultOutcome settlement))

-- | Grant a step of each of these many nanoseconds, and wait for each tick to complete.
grantEach ∷ RuntimeControl → ScheduledOwner → [Word64] → IO ()
grantEach control owner steps = forM_ steps $ \step → do
  _ ← grantScheduledStep (scheduledEndpoint owner) (nanoseconds step)
  void (awaitTicksComplete control owner)

-- | Fire every registration the timer holds live, as its backend would on expiry.
fireLive ∷ IFixture → IO ()
fireLive fixture = liveRegs (sfTimer (sf fixture)) >>= mapM_ fireReg

-- The modules -----------------------------------------------------------------------

-- | A behavior with every hook, which records what it is handed and what it reads
-- from its facade, and a counter its functions share.
tickerExport ∷ ExportSource
tickerExport =
  exportOf
    "ticker"
    [ "local function ns(x) return math.floor(x * 1e9 + 0.5) end"
    , "local shared = 0"
    , "local behavior = {"
    , "  every_ticks = 3,"
    , "  init = function(self, api)"
    , "    self.name = api.name"
    , "    self.own = (self.own or 0)"
    , "    shared = shared + 1"
    , "    " <> record <> "('init ' .. api.name .. ' same=' .. tostring(rawequal(self.api, api)) .. ' shared=' .. shared)"
    , "  end,"
    , "  update = function(self, dt)"
    , "    self.own = self.own + 1"
    , "    shared = shared + 1"
    , "    " <> record <> "('update ' .. self.name .. ' dt=' .. ns(dt) .. ' own=' .. self.own .. ' shared=' .. shared)"
    , "  end,"
    , "  shutdown = function(self, reason) " <> record <> "('shutdown ' .. self.name .. ' ' .. reason) end,"
    , "}"
    , "return { gameplay = behavior }"
    ]

-- | An export module whose @init@ rewrites every place its behavior was read from.
rewriter ∷ ExportSource
rewriter =
  exportOf
    "rewriter"
    [ "local exports"
    , "local behavior"
    , "behavior = {"
    , "  every_ticks = 2,"
    , "  init = function(self, api)"
    , "    " <> record <> "('init ' .. api.name)"
    , "    -- Everything the capture was read from changes under it."
    , "    behavior.update = function() " <> record <> "('replaced update') end"
    , "    behavior.shutdown = function() " <> record <> "('replaced shutdown') end"
    , "    behavior.every_ticks = 1"
    , "    behavior.bogus = true"
    , "    exports.gameplay = { init = function() " <> record <> "('replaced role') end }"
    , "  end,"
    , "  update = function(self, dt) " <> record <> "('update ' .. api_name(self)) end,"
    , "  shutdown = function(self, reason) " <> record <> "('shutdown ' .. api_name(self) .. ' ' .. reason) end,"
    , "}"
    , "function api_name(self) return self.api.name end"
    , "exports = { gameplay = behavior }"
    , "return exports"
    ]

-- Examples --------------------------------------------------------------------------

spec ∷ Spec
spec = describe "M1 behavior instances" $ do
  describe "construction and hooks" $ do
    it "runs init with a fresh self and the injected facade, then updates on the cadence the rule resolved from the table, then shutdown" $ bounded $
      withDefaults [tickerExport] $ \fixture control owner → do
        _ ← admitBehavior fixture owner "a" (requestFor "ticker" "gameplay" (facadeNamed "alpha") logicalRule)
        awaitPhase fixture owner "a" Active
        logged fixture >>= (`shouldBe` ["init alpha same=true shared=1"])
        -- Every three ticks: nothing falls due before the third.
        grantEach control owner [10, 20]
        logged fixture >>= (`shouldBe` ["init alpha same=true shared=1"])
        grantEach control owner [30]
        logged fixture >>= (`shouldBe` ["init alpha same=true shared=1", "update alpha dt=60 own=1 shared=2"])
        snapshotOf fixture owner "a" >>= (`shouldSatisfy` maybe False ((== Periodic (LogicalTicks 3)) . snapshotKind))
        _ ← askControl fixture owner "a" InstanceStop
        settled ← awaitSettled fixture "a"
        resultPhase settled `shouldBe` Stopped
        resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
        terminationShutdown (resultTermination settled) `shouldBe` ShutdownRan
        logCount fixture "shutdown alpha stopped" >>= (`shouldBe` 1)

    it "shares the export module's functions and upvalues between instances, and gives each its own self and facade, and a peer outlives another's end" $ bounded $
      withDefaults [tickerExport] $ \fixture control owner → do
        _ ← admitBehavior fixture owner "a" (requestFor "ticker" "gameplay" (facadeNamed "alpha") logicalRule)
        awaitPhase fixture owner "a" Active
        _ ← admitBehavior fixture owner "b" (requestFor "ticker" "gameplay" (facadeNamed "beta") logicalRule)
        awaitPhase fixture owner "b" Active
        -- The upvalue counter ran on from the first's init into the second's.
        logged fixture >>= (`shouldBe` ["init alpha same=true shared=1", "init beta same=true shared=2"])
        grantEach control owner [1, 1, 1]
        logged fixture
          >>= \entries → entries `shouldSatisfy` \seen → all (`elem` seen) ["update alpha dt=3 own=1 shared=3", "update beta dt=3 own=1 shared=4"] || all (`elem` seen) ["update beta dt=3 own=1 shared=3", "update alpha dt=3 own=1 shared=4"]
        -- Ending one leaves the other and the module usable.
        _ ← askControl fixture owner "a" InstanceStop
        _ ← awaitSettled fixture "a"
        grantEach control owner [1, 1, 1]
        logCount fixture "update beta dt=3 own=2 shared=5" >>= \n → logCount fixture "update beta dt=3 own=2 shared=6" >>= \m → (n + m) `shouldBe` 1
        snapshotOf fixture owner "b" >>= (`shouldSatisfy` maybe False ((== Active) . snapshotPhase))

    it "runs the hooks the instance captured, whatever the behavior table and the role table become, and a later instance captures what is there then" $ bounded $
      withDefaults [rewriter] $ \fixture control owner → do
        _ ← admitBehavior fixture owner "first" (requestFor "rewriter" "gameplay" (facadeNamed "one") logicalRule)
        awaitPhase fixture owner "first" Active
        -- Its init replaced the update, removed the shutdown, edited the cadence and
        -- added a field, and replaced the role table. None of it reached the instance.
        grantEach control owner [1]
        logged fixture >>= (`shouldBe` ["init one"])
        grantEach control owner [1]
        logged fixture >>= (`shouldBe` ["init one", "update one"])
        grantEach control owner [1, 1]
        logCount fixture "update one" >>= (`shouldBe` 2)
        logCount fixture "replaced update" >>= (`shouldBe` 0)
        -- A later instance reads the export table as it is now: the role table was
        -- replaced, so it captures that one, and its init is the replacement's.
        _ ← admitBehavior fixture owner "second" (requestFor "rewriter" "gameplay" (facadeNamed "two") logicalRule)
        awaitPhase fixture owner "second" Active
        logCount fixture "replaced role" >>= (`shouldBe` 1)
        snapshotOf fixture owner "second" >>= (`shouldSatisfy` maybe False ((== EventOnly) . snapshotKind))
        -- The first instance still runs its captured shutdown, not the replacement.
        _ ← askControl fixture owner "first" InstanceStop
        _ ← awaitSettled fixture "first"
        logCount fixture "shutdown one stopped" >>= (`shouldBe` 1)
        logCount fixture "replaced shutdown" >>= (`shouldBe` 0)

    it "is an instance with no update when the behavior has none: alive until stopped, with no cadence, and its shutdown still runs" $ bounded $
      withDefaults
        [exportOf "passive" ["return { gameplay = { init = function(self, api) " <> record <> "('init') end, shutdown = function(self, reason) " <> record <> "('shutdown ' .. reason) end } }"]]
        $ \fixture control owner → do
          _ ← admitBehavior fixture owner "p" (requestFor "passive" "gameplay" (facadeNamed "p") logicalRule)
          awaitPhase fixture owner "p" Active
          grantEach control owner [1, 1, 1, 1]
          snapshotOf fixture owner "p" >>= (`shouldSatisfy` maybe False (\snapshot → snapshotKind snapshot == EventOnly && not (snapshotUpdateOwed snapshot) && snapshotPhase snapshot == Active))
          logged fixture >>= (`shouldBe` ["init"])
          _ ← askControl fixture owner "p" InstanceStop
          settled ← awaitSettled fixture "p"
          resultPhase settled `shouldBe` Stopped
          logged fixture >>= (`shouldBe` ["init", "shutdown stopped"])

    it "gives a module's top level no facade and no instance: only a hook is handed one" $ bounded $
      withDefaults
        [ exportOf
            "toplevel"
            [ record <> "('top level: api=' .. tostring(api) .. ' self=' .. tostring(self))"
            , "return { gameplay = { init = function(self, api) " <> record <> "('hook: api=' .. type(api)) end } }"
            ]
        ]
        $ \fixture _ owner → do
          -- The top level ran when the owner started, before any instance existed.
          logged fixture >>= (`shouldBe` ["top level: api=nil self=nil"])
          _ ← admitBehavior fixture owner "t" (requestFor "toplevel" "gameplay" (facadeNamed "t") logicalRule)
          awaitPhase fixture owner "t" Active
          logged fixture >>= (`shouldBe` ["top level: api=nil self=nil", "hook: api=table"])

    it "installs self.api for an instance with no init, and runs no init for it" $ bounded $
      withDefaults
        [exportOf "noinit" ["return { gameplay = { update = function(self, dt) " <> record <> "('api=' .. self.api.name) end } }"]]
        $ \fixture control owner → do
          _ ← admitBehavior fixture owner "n" (requestFor "noinit" "gameplay" (facadeNamed "seen") logicalRule)
          awaitPhase fixture owner "n" Active
          grantEach control owner [1]
          logged fixture >>= (`shouldBe` ["api=seen"])

  describe "construction refusals" $ do
    let noHooksRan ∷ IFixture → InstanceSettlement → IO ()
        noHooksRan fixture settled = do
          logged fixture >>= (`shouldBe` [])
          terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedNoInit
    it "fails an instance of an export module the owner does not hold, at construction, before any hook" $ bounded $
      withDefaults [] $ \fixture _ owner → do
        _ ← admitBehavior fixture owner "m" (requestFor "absent" "gameplay" (facadeNamed "m") logicalRule)
        settled ← awaitSettled fixture "m"
        failure ← failureIn settled
        failureStage failure `shouldBe` StageConstruct
        failureError failure `shouldSatisfy` \case ErrorExportMissing _ → True; _ → False
        noHooksRan fixture settled

    it "fails an instance of a module whose evaluation failed as a module failure, not as a behavior failure, with the module's fault" $ bounded $
      withDefaults [exportOf "broken" ["error('top level failed')"], exportOf "shapeless" ["return 5"]] $ \fixture _ owner → do
        _ ← admitBehavior fixture owner "broken" (requestFor "broken" "gameplay" (facadeNamed "x") logicalRule)
        _ ← admitBehavior fixture owner "shapeless" (requestFor "shapeless" "gameplay" (facadeNamed "x") logicalRule)
        forM_ [("broken", True), ("shapeless", False)] $ \(name, scripted) → do
          settled ← awaitSettled fixture name
          failure ← failureIn settled
          failureStage failure `shouldBe` StageConstruct
          case failureError failure of
            ErrorExportFailed fault
              | scripted → boundaryReason fault `shouldSatisfy` \case ScriptFailed _ _ → True; _ → False
              | otherwise → boundaryReason fault `shouldBe` ExportShapeRefused (ExportNotTable "number")
            other → failExample ("not a module failure: " <> show other)
        logged fixture >>= (`shouldBe` [])

    it "fails an instance whose selected behavior does not fit, naming why and running no hook, while a module with other invalid roles is no failure" $ bounded $
      withDefaults
        [ exportOf
            "roles"
            [ "local f = function() " <> record <> "('ran') end"
            , "return {"
            , "  missing_role_here = true,"
            , "  not_a_table = 5,"
            , "  has_meta = setmetatable({ init = f }, {}),"
            , "  unknown_key = { init = f, other = 1 },"
            , "  bad_hook = { init = 5 },"
            , "  cadence_without_update = { init = f, every_ticks = 2 },"
            , "  gameplay = { init = f },"
            , "}"
            ]
        ]
        $ \fixture _ owner → do
          forM_ [("absent", BehaviorMissing), ("not_a_table", BehaviorNotTable "number"), ("has_meta", BehaviorHasMetatable), ("unknown_key", BehaviorUnknownKey "other"), ("bad_hook", BehaviorHookNotFunction HookInit "number")] $ \(role, problem) → do
            _ ← admitBehavior fixture owner role (requestFor "roles" role (facadeNamed role) logicalRule)
            failure ← awaitSettled fixture role >>= failureIn
            failureStage failure `shouldBe` StageConstruct
            failureError failure `shouldSatisfy` \case ErrorBehavior found → found == problem; _ → False
          -- No hook of any of them ran.
          logged fixture >>= (`shouldBe` [])
          -- A valid one of the same module is unaffected.
          _ ← admitBehavior fixture owner "ok" (requestFor "roles" "gameplay" (facadeNamed "ok") logicalRule)
          awaitPhase fixture owner "ok" Active
          logged fixture >>= (`shouldBe` ["ran"])

    it "fails an instance whose cadence the rule refuses, or whose interval does not resolve, or whose table and rule disagree, before init" $ bounded $
      withDefaults
        [ exportOf "cadences" ["local f = function() " <> record <> "('ran') end", "return { text = { update = f, every_ticks = 'x' }, none = { init = f }, zero = { update = f, every_ticks = 0 }, orphan = { init = f } }"]
        ]
        $ \fixture _ owner → do
          let rule ∷ BehaviorShape → Either Text (Maybe Interval)
              rule shape = case (shapeUpdate shape, shapeEveryTicks shape) of
                (True, FieldInteger 0) → Right (Just (LogicalTicks 0))
                (False, _) → Right (Just (LogicalTicks 1))
                _ → logicalRule shape
          forM_ ["text", "zero", "orphan"] $ \role → do
            _ ← admitBehavior fixture owner role (requestFor "cadences" role (facadeNamed role) rule)
            failure ← awaitSettled fixture role >>= failureIn
            failureStage failure `shouldBe` StageConstruct
            failureError failure `shouldSatisfy` \case ErrorCadence _ → True; _ → False
          logged fixture >>= (`shouldBe` [])

    it "fails an instance whose facade is past the owner's value limits, at construction, running nothing" $ bounded $
      withDefaults [exportOf "small" ["return { gameplay = { init = function() " <> record <> "('ran') end } }"]] $ \fixture _ owner → do
        let large = VRecord [("name", VText (Text.replicate 200000 "x")), ("number", VInteger 1)]
        _ ← admitBehavior fixture owner "big" (requestFor "small" "gameplay" large logicalRule)
        settled ← awaitSettled fixture "big"
        failure ← failureIn settled
        failureStage failure `shouldBe` StageConstruct
        failureError failure `shouldSatisfy` \case ErrorFault _ → True; _ → False
        logged fixture >>= (`shouldBe` [])

  describe "failure and stop" $ do
    it "fails at init without running update or shutdown, a failed init being no init, and its captured references are let go" $ bounded $
      withDefaults
        [ exportOf
            "failinit"
            [ "local weak = setmetatable({}, { __mode = 'k' })"
            , "local function weak_count() local n = 0 for _ in pairs(weak) do n = n + 1 end return n end"
            , "return {"
            , "  gameplay = {"
            , "    every_ticks = 1,"
            , "    init = function(self, api) weak[self] = true " <> record <> "('init') error('init boom') end,"
            , "    update = function() " <> record <> "('update') end,"
            , "    shutdown = function() " <> record <> "('shutdown') end,"
            , "  },"
            , "  census = { init = function() collectgarbage() collectgarbage() " <> record <> "('alive ' .. weak_count()) end },"
            , "}"
            ]
        ]
        $ \fixture control owner → do
          _ ← admitBehavior fixture owner "f" (requestFor "failinit" "gameplay" (facadeNamed "f") logicalRule)
          settled ← awaitSettled fixture "f"
          failure ← failureIn settled
          failureStage failure `shouldBe` StageInit
          terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedNoInit
          grantEach control owner [1, 1]
          logged fixture >>= (`shouldBe` ["init"])
          -- Its self was only reachable through its capture, which is gone: after a
          -- collection the weak table holds nothing.
          _ ← admitBehavior fixture owner "census" (requestFor "failinit" "census" (facadeNamed "c") logicalRule)
          awaitEffect (sf fixture) "alive 0"

    it "refuses a wait or a yield in init and in shutdown as it always did, failing the instance at that hook" $ bounded $
      withDefaults
        [ exportOf "waitinit" ["return { gameplay = { init = function() sched.wait_ticks(1) end, shutdown = function() " <> record <> "('shutdown') end } }"]
        , exportOf "waitshutdown" ["return { gameplay = { init = function() " <> record <> "('init') end, shutdown = function() sched.wait_ticks(1) end } }"]
        ]
        $ \fixture _ owner → do
          _ ← admitBehavior fixture owner "init" (requestFor "waitinit" "gameplay" (facadeNamed "i") logicalRule)
          initFailure ← awaitSettled fixture "init" >>= failureIn
          failureStage initFailure `shouldBe` StageInit
          _ ← admitBehavior fixture owner "shutdown" (requestFor "waitshutdown" "gameplay" (facadeNamed "s") logicalRule)
          awaitPhase fixture owner "shutdown" Active
          _ ← askControl fixture owner "shutdown" InstanceStop
          shutdownSettled ← awaitSettled fixture "shutdown"
          terminationShutdown (resultTermination shutdownSettled) `shouldBe` ShutdownRaised
          logged fixture >>= (`shouldBe` ["init"])

    it "suspends and resumes a captured update cooperatively, closes it on stop, runs shutdown, and releases what the instance held" $ bounded $
      withDefaults
        [ exportOf
            "waiter"
            [ "local weak = setmetatable({}, { __mode = 'k' })"
            , "local function weak_count() local n = 0 for _ in pairs(weak) do n = n + 1 end return n end"
            , "return {"
            , "  gameplay = {"
            , "    every_ticks = 1,"
            , "    init = function(self, api) weak[self] = true end,"
            , "    update = function(self, dt)"
            , "      local guard <close> = setmetatable({}, { __close = function() " <> record <> "('closed') end })"
            , "      " <> record <> "('begin')"
            , "      sched.wait_ticks(3)"
            , "      " <> record <> "('end')"
            , "    end,"
            , "    shutdown = function(self, reason) " <> record <> "('shutdown ' .. reason) end,"
            , "  },"
            , "  census = { init = function() collectgarbage() collectgarbage() " <> record <> "('alive ' .. weak_count()) end },"
            , "}"
            ]
        ]
        $ \fixture control owner → do
          _ ← admitBehavior fixture owner "w" (requestFor "waiter" "gameplay" (facadeNamed "w") logicalRule)
          awaitPhase fixture owner "w" Active
          grantEach control owner [1]
          awaitEffect (sf fixture) "begin"
          -- Suspended in the wait; stopping closes its coroutine, then runs shutdown.
          _ ← askControl fixture owner "w" InstanceStop
          settled ← awaitSettled fixture "w"
          resultPhase settled `shouldBe` Stopped
          terminationClosed (resultTermination settled) `shouldBe` 1
          logged fixture >>= (`shouldBe` ["begin", "closed", "shutdown stopped"])
          -- The instance's references are gone with it.
          _ ← admitBehavior fixture owner "census" (requestFor "waiter" "census" (facadeNamed "c") logicalRule)
          awaitEffect (sf fixture) "alive 0"

    it "fails at update as any hook fails, ending only that instance and leaving a peer and the module usable" $ bounded $
      withDefaults
        [ exportOf
            "faulty"
            [ "local count = 0"
            , "return { gameplay = { every_ticks = 1, update = function(self, dt) count = count + 1 if self.api.name == 'bad' then error('update boom') end " <> record <> "('ok ' .. count) end } }"
            ]
        ]
        $ \fixture control owner → do
          _ ← admitBehavior fixture owner "bad" (requestFor "faulty" "gameplay" (facadeNamed "bad") logicalRule)
          _ ← admitBehavior fixture owner "good" (requestFor "faulty" "gameplay" (facadeNamed "good") logicalRule)
          awaitPhase fixture owner "bad" Active
          awaitPhase fixture owner "good" Active
          grantEach control owner [1]
          failure ← awaitSettled fixture "bad" >>= failureIn
          failureStage failure `shouldBe` StageUpdate
          grantEach control owner [1]
          snapshotOf fixture owner "good" >>= (`shouldSatisfy` maybe False ((== Active) . snapshotPhase))
          logCount fixture "ok 3" >>= \found → found `shouldSatisfy` (>= 0)

  describe "cadence" $ do
    it "runs an elapsed update on the owner's clock, handed the actual elapsed time, through the existing scheduler" $ bounded $
      withDefaults
        [exportOf "ui" ["local function ns(x) return math.floor(x * 1e9 + 0.5) end", "return { presentation = { every_seconds = 1, update = function(self, dt) " <> record <> "('update ' .. ns(dt)) end } }"]]
        $ \fixture _ owner → do
          setClock (sf fixture) 1000
          _ ← admitBehavior fixture owner "ui" (requestFor "ui" "presentation" (facadeNamed "ui") elapsedRule)
          awaitPhase fixture owner "ui" Active
          awaitRegistrations (sf fixture) 1
          -- A stall: the demand is coalesced into one refresh handed the time that passed.
          setClock (sf fixture) 1950
          fireLive fixture
          awaitEffect (sf fixture) "update 950"
          logged fixture >>= (`shouldBe` ["update 950"])
          snapshotOf fixture owner "ui" >>= (`shouldSatisfy` maybe False ((== Periodic (ElapsedEvery (nanoseconds 100))) . snapshotKind))

  describe "ceilings on an instance-hosting owner" $ do
    it "holds 256 export identities beside the instance driver, and an instance of the last one runs" $ bounded $ do
      let identities = [Char8.pack ("module" <> show n) | n ← [1 .. 256 ∷ Int]]
          exports = [exportOf identity ["return { gameplay = { init = function(self, api) " <> record <> "('init ' .. api.name) end } }"] | identity ← identities]
      withDefaults exports $ \fixture _ owner → do
        _ ← admitBehavior fixture owner "last" (requestFor (last identities) "gameplay" (facadeNamed "last") logicalRule)
        awaitPhase fixture owner "last" Active
        logged fixture >>= (`shouldBe` ["init last"])

    it "names a source one byte past the limit as a failed identity the instance reports, running nothing of it" $ bounded $ do
      let padded prefix = prefix <> ByteString.replicate (1048576 - ByteString.length prefix) 32
          exact = ExportSource (ExportIdentity "exact") "exact" (padded "return { gameplay = { init = function() fx.record('exact ran') end } }")
          over = ExportSource (ExportIdentity "over") "over" (padded "fx.record('over ran') return { gameplay = {} }" <> " ")
      withDefaults [exact, over] $ \fixture _ owner → do
        _ ← admitBehavior fixture owner "exact" (requestFor "exact" "gameplay" (facadeNamed "e") logicalRule)
        awaitPhase fixture owner "exact" Active
        _ ← admitBehavior fixture owner "over" (requestFor "over" "gameplay" (facadeNamed "o") logicalRule)
        failure ← awaitSettled fixture "over" >>= failureIn
        case failureError failure of
          ErrorExportFailed fault → boundaryReason fault `shouldBe` ModuleRefused (SourceTooLarge 1048576)
          other → failExample ("not the oversized source: " <> show other)
        logged fixture >>= (`shouldBe` ["exact ran"])
