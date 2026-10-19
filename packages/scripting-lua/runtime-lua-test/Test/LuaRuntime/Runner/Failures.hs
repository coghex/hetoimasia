-- | A failed instance, a failing shutdown, several failures in one run, and the failures of the host.
module Test.LuaRuntime.Runner.Failures (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO)
import Control.Monad (forM, forM_)
import Data.IORef (readIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
  ( InstancePhase (Active, Initializing)
  , InstanceSettlement (resultTermination)
  , ShutdownDisposition (ShutdownSkippedNoInit, ShutdownSkippedUnsafe)
  , Termination (terminationShutdown)
  , pollInstance
  )
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryChunk))
import Hetoimasia.Scripting.Lua.Runner
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, withBoundary)

-- | A module that fails where its name says, and records every hook that runs.
failing ∷ Text → [Text]
failing where' =
  [ "function init(self, api) fx.record('init ' .. '" <> where' <> "') " <> (if where' == "init" then "error('init boom')" else "") <> " end"
  , "function run(self) fx.record('run " <> where' <> "') " <> (if where' == "run" then "error('run boom')" else "") <> " end"
  , "function shutdown(self, reason) fx.record('shutdown " <> where' <> " ' .. reason) end"
  ]

-- | The report lines in a sink's lines: each begins with this word, and no other line does.
reportHeaders ∷ [Text] → [Text]
reportHeaders = filter (Text.isPrefixOf "failure: ")

-- | The report's lines of a failure: the header and what is indented under it.
reportOf ∷ Text → [Text] → [Text]
reportOf tid ls = case dropWhile (not . Text.isPrefixOf ("failure: instance " <> tid <> " ")) ls of
  header : rest → header : takeWhile (Text.isPrefixOf "  ") rest
  [] → []

failedOf ∷ InstanceReport → FailureReport
failedOf report = case instanceEnd report of
  EndFailed failure → failure
  other → error ("expected a failed instance, found " <> show other)

-- | The sinks keep to the owner's amendment: the tables go to the output sink only, the reports of
-- failures to the error sink only.
expectSinksKept ∷ RFixture → IO ()
expectSinksKept fixture = do
  out ← outLines fixture
  err ← errLines fixture
  filter (Text.isPrefixOf "failure: ") out `shouldBe` []
  filter (Text.isPrefixOf "  error: ") out `shouldBe` []
  filter (\line → line == startTitle || line == endTitle || Text.isPrefixOf "TID" line) err `shouldBe` []

spec ∷ Spec
spec = describe "failures" $ do
  describe "of an instance" $ do
    it "reports a failed init once, with its fields, runs none of its later hooks and lets the others go on" $ bounded $ do
      fixture ← newRFixture
      withScripts [("bad.lua", lua (failing "init")), ("good.lua", lua ["function run(self) fx.record('good ran') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture [Script (scriptAt paths 0) (Just "bad") Nothing, noWait (scriptAt paths 1)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          statusOf report `shouldBe` StatusFailure
          case instancesOf report of
            [bad, good] → do
              let failure = failedOf bad
              frTid failure `shouldBe` instanceTid bad
              frVm failure `shouldBe` "vm"
              frName failure `shouldBe` "bad"
              frFile failure `shouldBe` Text.pack (scriptAt paths 0)
              frPhase failure `shouldBe` Initializing
              frStage failure `shouldBe` "init"
              frError failure `shouldSatisfy` Text.isInfixOf "init boom"
              case instanceEnd good of
                EndCompleted → pure ()
                other → fail ("the other instance should have gone on: " <> show other)
              err ← errLines fixture
              reportHeaders err `shouldSatisfy` ((== 1) . length)
              reportOf (tidText (instanceTid bad)) err `shouldSatisfy` (\ls → any (Text.isInfixOf "name=\"bad\"") ls && any (Text.isInfixOf "stage=init") ls && any (Text.isInfixOf "init boom") ls)
            other → fail ("expected two instances, found " <> show (length other))
          -- No later hook of the failed instance ran: not run, not shutdown.
          found ← recorded fixture
          found `shouldContain` ["init init"]
          found `shouldContain` ["good ran"]
          found `shouldNotContain` ["run init"]
          filter (Text.isPrefixOf "shutdown init") found `shouldBe` []
          expectSinksKept fixture

    it "reports a failing run, with its stage, and runs its shutdown once with reason failed" $ bounded $ do
      fixture ← newRFixture
      withScripts [("run.lua", lua (failing "run"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          statusOf report `shouldBe` StatusFailure
          case instancesOf report of
            [one] → do
              frStage (failedOf one) `shouldBe` "run"
              frPhase (failedOf one) `shouldBe` Active
              frError (failedOf one) `shouldSatisfy` Text.isInfixOf "run boom"
            other → fail ("expected one instance, found " <> show (length other))
          filter (Text.isPrefixOf "shutdown") <$> recorded fixture `shouldReturn` ["shutdown run failed"]
          expectSinksKept fixture

    it "reports a failing update, and runs its shutdown once with reason failed" $ bounded $ do
      fixture ← newRFixture
      withScripts [("up.lua", lua ["function update(self, dt) fx.record('update') error('update boom') end", "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitOut fixture 3 >> awaitLive fixture 1 >> tickClock fixture 10000000 >> fireLive fixture) $
              run fixture runtime (config fixture [Script (scriptAt paths 0) Nothing (Just (ns 10000000))]) >>= expectRan
          statusOf report `shouldBe` StatusFailure
          case instancesOf report of
            [one] → frStage (failedOf one) `shouldBe` "update"
            other → fail ("expected one instance, found " <> show (length other))
          recorded fixture `shouldReturn` ["update", "shutdown failed"]

    it "reports a failing callback, with the source it was connected to" $ bounded $ do
      fixture ← newRFixture
      withScripts [("cb.lua", lua ["function init(self, api) api.connect('tick', function(self, event) fx.record('tick') error('callback boom') end) end", "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitOut fixture 3 >> deliverTick fixture 0 1 >>= \_ → pure ()) $
              runTick fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          statusOf report `shouldBe` StatusFailure
          case instancesOf report of
            [one] → do
              frStage (failedOf one) `shouldBe` "event tick"
              frError (failedOf one) `shouldSatisfy` Text.isInfixOf "callback boom"
            other → fail ("expected one instance, found " <> show (length other))
          recorded fixture `shouldReturn` ["tick", "shutdown failed"]
          expectSinksKept fixture

    it "keeps a failing shutdown, which fails an instance that would have stopped" $ bounded $ do
      fixture ← newRFixture
      withScripts [("sd.lua", lua ["function shutdown(self, reason) fx.record('shutdown ' .. reason) error('shutdown boom') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitOut fixture 3 >> setStop fixture True) $
              run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedStopRequest
          -- A failure outranks the stop request.
          statusOf report `shouldBe` StatusFailure
          case instancesOf report of
            [one] → do
              frStage (failedOf one) `shouldBe` "shutdown"
              frError (failedOf one) `shouldSatisfy` Text.isInfixOf "shutdown boom"
            other → fail ("expected one instance, found " <> show (length other))
          recorded fixture `shouldReturn` ["shutdown stopped"]
          errLines fixture >>= (`shouldSatisfy` ((== 1) . length . reportHeaders))

    it "keeps a primary failure primary and lists the failing shutdown beside it" $ bounded $ do
      fixture ← newRFixture
      withScripts [("both.lua", lua ["function run(self) error('run boom') end", "function shutdown(self, reason) error('shutdown boom') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          case instancesOf report of
            [one] → do
              let failure = failedOf one
              frStage failure `shouldBe` "run"
              frError failure `shouldSatisfy` Text.isInfixOf "run boom"
              map secondaryStage (frSecondary failure) `shouldBe` ["shutdown"]
              map secondaryError (frSecondary failure) `shouldSatisfy` all (Text.isInfixOf "shutdown boom")
              frOmitted failure `shouldBe` 0
            other → fail ("expected one instance, found " <> show (length other))
          err ← errLines fixture
          reportHeaders err `shouldSatisfy` ((== 1) . length)
          err `shouldSatisfy` any (Text.isPrefixOf "  also failed: shutdown: ")

    it "reports every failure of a run once, in ascending TID order, all before the end table" $ bounded $ do
      fixture ← newRFixture
      withScripts [("a.lua", lua (failing "init")), ("b.lua", lua (failing "run")), ("c.lua", lua (failing "run")), ("d.lua", lua ["function run(self) fx.record('d ran') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture (map noWait paths)) >>= expectRan
          statusOf report `shouldBe` StatusFailure
          let failed = [instanceTid item | item ← instancesOf report, isJust (failureOf item)]
          length failed `shouldBe` 3
          err ← errLines fixture
          -- Each failure once, and in the order of the TIDs.
          map (Text.takeWhile (/= ' ') . Text.drop (Text.length "failure: instance ")) (reportHeaders err) `shouldBe` map tidText failed
          forM_ failed $ \tid → length (filter (Text.isPrefixOf ("failure: instance " <> tidText tid <> " ")) err) `shouldBe` 1
          -- All of them before the end table, whichever sink each went to.
          every ← readLines fixture
          let positionOf predicate = length (takeWhile (not . predicate) every)
              lastFailure = maximum (map (\(index, _) → index) (filter (\(_, (sink, line)) → sink == "err" && Text.isPrefixOf "failure: " line) (zip [0 ∷ Int ..] every)))
          lastFailure `shouldSatisfy` (< positionOf (\(_, line) → line == endTitle))
          expectSinksKept fixture

    it "writes a failure as it settles, and keeps every admitted instance in the tables when one fails before the last initializer finishes" $ bounded $ do
      fixture ← newRFixture
      withScripts [("early.lua", lua (failing "init")), ("slow.lua", lua ["function init(self) fx.block('slow') end", "function shutdown(self, reason) fx.record('shutdown slow ' .. reason) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              ( awaitGate fixture "slow"
                  -- The early failure is reported while the last initializer is still held, before the start table.
                  >> awaitCount (length . reportHeaders <$> errLines fixture) 1
                  >> openGate fixture "slow"
                  >> awaitOut fixture 4
                  >> setStop fixture True
              )
              (run fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          length (instancesOf report) `shouldBe` 2
          out ← outLines fixture
          -- The start table lists both: the failed instance and the one that was held.
          take 4 out `shouldBe` startTable report ["failed", "active"]
          expectSinksKept fixture

  describe "of the host" $ do
    it "propagates a failure a binding raised unchanged after the retirement, without a report" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("a.lua", lua (["function init(self) fx.record('a init') end"] <> ["function shutdown(self, reason) fx.record('shutdown a ' .. reason) end"]))
        , ("b.lua", lua ["function init(self) fx.fail('host') end"])
        , ("c.lua", lua ["function init(self) fx.record('c init') end", "function shutdown(self, reason) fx.record('shutdown c ' .. reason) end"])
        ]
        $ \paths → do
          failure ← expectFatal $ \_ runtime → run fixture runtime (config fixture (map noWait paths)) >>= void'
          expectBroken "host" failure
          -- Lua was not entered again: the instance whose init had succeeded keeps ShutdownSkippedUnsafe, and
          -- the one whose init raised and the one that had not begun keep ShutdownSkippedNoInit.
          (_, admitted) ← admittedOf fixture
          settled ← forM admitted (pollInstance . snd)
          map (fmap (terminationShutdown . resultTermination)) settled `shouldBe` [Just ShutdownSkippedUnsafe, Just ShutdownSkippedNoInit, Just ShutdownSkippedNoInit]
          recorded fixture >>= (`shouldNotContain` ["c init"])
          filter (Text.isPrefixOf "shutdown") <$> recorded fixture `shouldReturn` []
          errLines fixture >>= (`shouldBe` [])
          liveCount fixture `shouldReturn` 0
          pure (settled `seq` ())

    it "propagates a failure the output sink raised from a script's print, whatever the type" $ bounded $ do
      fixture ← newRFixture
      withScripts [("p.lua", lua ["function run(self) print('boom') end"])] $ \paths → do
        let failingSink = (config fixture [noWait (scriptAt paths 0)]) {runnerOutput = \line → if line == "boom" then throwIO (Broken "sink") else pure ()}
        failure ← expectFatal $ \_ runtime → run fixture runtime failingSink >>= void'
        expectBroken "sink" failure

    it "propagates a failure of a sink or a binding while a module loads, and is no source that did not load" $ bounded $ do
      fixture ← newRFixture
      withScripts [("p.lua", lua ["print('loading')", "function run(self) end"])] $ \paths → do
        let failingSink = (config fixture [noWait (scriptAt paths 0)]) {runnerOutput = \_ → throwIO (Broken "load sink")}
        failure ← expectFatal $ \_ runtime → run fixture runtime failingSink >>= void'
        expectBroken "load sink" failure
      fixture' ← newRFixture
      withScripts [("q.lua", lua ["fx.fail('load')", "function run(self) end"])] $ \paths → do
        failure ← expectFatal $ \_ runtime → run fixture' runtime (config fixture' [noWait (scriptAt paths 0)]) >>= void'
        expectBroken "load" failure
      -- An application's exception that has the shape of the host's fault of loading a module is still the application's.
      fixture'' ← newRFixture
      withScripts [("r.lua", lua ["fx.fail_load()", "function run(self) end"])] $ \paths → do
        failure ← expectFatal $ \_ runtime → run fixture'' runtime (config fixture'' [noWait (scriptAt paths 0)]) >>= void'
        let ExceptionWithContext _ raised = failure
        fmap boundaryChunk (fromException raised) `shouldBe` Just "application"
        errLines fixture'' >>= (`shouldBe` [])

    it "retires the owner in order when the runner's own write fails, then propagates the failure" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua ["function shutdown(self, reason) fx.record('shutdown ' .. reason) end"])] $ \paths → do
        let failingTable = (config fixture [noWait (scriptAt paths 0)]) {runnerOutput = \line → if line == startTitle then throwIO (Broken "table sink") else pure ()}
        failure ← expectFatal $ \_ runtime → run fixture runtime failingTable >>= void'
        expectBroken "table sink" failure
        -- The orderly retirement ran first: the hook ran, with reason stopped.
        recorded fixture `shouldReturn` ["shutdown stopped"]
        liveCount fixture `shouldReturn` 0

    it "keeps the first failure primary and the rest as evidence when failures arise together" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua ["function shutdown(self, reason) fx.fail('second') end"])] $ \paths → do
        let failingTable = (config fixture [noWait (scriptAt paths 0)]) {runnerOutput = \line → if line == startTitle then throwIO (Broken "first") else pure ()}
        failure ← expectFatal $ \_ runtime → run fixture runtime failingTable >>= void'
        expectBroken "first" failure
        let ExceptionWithContext context _ = failure
        [brokenIs "second" evidence | found ← cleanupFailuresInContext context, let ExceptionWithContext _ evidence = cleanupFailureException found] `shouldContain` [True]
  where
    void' _ = pure ()

expectBroken ∷ Text → ExceptionWithContext SomeException → IO ()
expectBroken expected (ExceptionWithContext _ raised) = raised `shouldSatisfy` brokenIs expected

readLines ∷ RFixture → IO [(Text, Text)]
readLines fixture = reverse <$> readIORef (rfLines fixture)

startTable ∷ RunReport → [Text] → [Text]
startTable report statuses =
  startTitle
    : tableLines
      [ TableRow (tidText (instanceTid item)) "vm" (instanceNameText item) status
      | (item, status) ← zip (instancesOf report) statuses
      ]
