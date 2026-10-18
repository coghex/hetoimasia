-- | What the request examples share: a fake request provider the examples drive by hand, a
-- registration with the request bindings, instances and tasks written in Lua that start,
-- wait for, take and cancel requests, and the coordination the examples use instead of sleeping.
--
-- Every example runs real instances (or tasks) on a real supervised scheduled owner under the
-- injected clock and fake timer of "Test.LuaRuntime.Scheduled.Support". The provider is a
-- value: it records what it was handed, answers when an example tells it to, from the
-- example's own thread, and reports its retirement as the example sets it. Nothing sleeps; an
-- example knows what has happened by blocking in STM, on a gate, or on what a script recorded.
module Test.LuaRuntime.Request.Support
  ( -- * The fake provider
    Fake (..)
  , Submitted (..)
  , newFake
  , fakeEndpoint
  , fakeEndpointOf
  , finishAll
  , providersFinish
  , awaitSubmitted
  , submissions
  , submissionAt
  , answerWith
  , answerResult
  , finishWork
  , failWorkWith
  , cancelledOrder
  , awaitCancelled
  , onSubmit
  , onCancel

    -- * The registration and the modules
  , requestRegistration
  , asker
  , initAsker
  , shutdownAsker
  , updateAsker
  , closingAsker
  , waitInitAsker
  , waitShutdownAsker
  , taskAsker
  , cmdSource
  , cmdConfig

    -- * Owners
  , grantOf
  , logicalGrant
  , requestSpec
  , startRequester
  , startRequesterWith
  , diagnostics
  , taskOf
  , smallLimits

    -- * Commanding
  , command
  , commandFrom
  , admitAsker
  , askerRequest
  , lineIn
  , awaitLine
  , awaitTaken
  , awaitLines
  , linesOf
  , countOf
  , awaitDiagnostic
  , refusalOf
  , tickReached
  , awaitTick
  , sync
  , planned
  , grantAndWait
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (SomeException, finally, throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl, WorkerPolicy)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Request
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled hiding (Policy (..))
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (..), defaultSchedulerBounds, scheduled, schedRegistration, startScheduled)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)

-- The fake provider --------------------------------------------------------------------

-- | A request the provider was handed.
data Submitted = Submitted
  { sbIndex ∷ !Int
  , sbArguments ∷ [Value]
  , sbCompletion ∷ !Completion
  , sbInfo ∷ !RequestInfo
  , sbRetirement ∷ !(TVar RetirementState)
  }

-- | A provider the examples drive by hand.
data Fake = Fake
  { fkSubmitted ∷ !(TVar [Submitted])
  , fkCancels ∷ !(TVar [Int])
  , fkOnSubmit ∷ !(IORef (Submission → IO ()))
  , fkOnCancel ∷ !(IORef (Int → IO ()))
  }

newFake ∷ IO Fake
newFake = Fake <$> newTVarIO [] <*> newTVarIO [] <*> newIORef (\_ → pure ()) <*> newIORef (\_ → pure ())

-- | What the provider does when it is handed a request, before it keeps it: an example makes it
-- raise.
onSubmit ∷ Fake → (Submission → IO ()) → IO ()
onSubmit fake action = atomicModifyIORef' (fkOnSubmit fake) (const (action, ()))

-- | What the provider does when told interest was withdrawn, after it noted it.
onCancel ∷ Fake → (Int → IO ()) → IO ()
onCancel fake action = atomicModifyIORef' (fkOnCancel fake) (const (action, ()))

-- | The endpoint of this name backed by the fake. Results are integers.
fakeEndpoint ∷ Fake → Text → RequestEndpoint
fakeEndpoint fake name = fakeEndpointOf fake name SInteger

-- | The endpoint of this name backed by the fake, whose results are of this schema.
fakeEndpointOf ∷ Fake → Text → Schema → RequestEndpoint
fakeEndpointOf fake name schema =
  RequestEndpoint
    { endpointName = name
    , endpointResult = schema
    , endpointSubmit = \submission → do
        readIORef (fkOnSubmit fake) >>= ($ submission)
        (index, retirement) ← atomically $ do
          held ← readTVar (fkSubmitted fake)
          retirement ← newTVar ProviderPending
          let index = length held
          writeTVar (fkSubmitted fake) (held <> [Submitted index (submissionArguments submission) (submissionCompletion submission) (submissionInfo submission) retirement])
          pure (index, retirement)
        pure
          ProviderWork
            { workCancel = do
                atomically (modifyTVar' (fkCancels fake) (<> [index]))
                readIORef (fkOnCancel fake) >>= ($ index)
            , workRetirement = readTVar retirement
            }
    }

-- | The provider proves every piece of work it was handed over. An example that leaves work
-- outstanding when it ends would leave its owner waiting for it for ever, as it should, so
-- the examples that do finish it here.
finishAll ∷ Fake → IO ()
finishAll fake = atomically $ do
  held ← readTVar (fkSubmitted fake)
  mapM_ (\found → writeTVar (sbRetirement found) ProviderComplete) held

-- | Run an example, and prove all the provider's work over however it ends.
providersFinish ∷ Fake → IO a → IO a
providersFinish fake body = body `finally` finishAll fake

-- | Block until the provider has been handed this many requests.
awaitSubmitted ∷ Fake → Int → IO ()
awaitSubmitted fake wanted = atomically $ do
  held ← readTVar (fkSubmitted fake)
  if length held >= wanted then pure () else retry

-- | How many requests the provider was handed.
submissions ∷ Fake → IO Int
submissions fake = length <$> atomically (readTVar (fkSubmitted fake))

-- | The nth request the provider was handed.
submissionAt ∷ Fake → Int → IO Submitted
submissionAt fake index = do
  held ← atomically (readTVar (fkSubmitted fake))
  case drop index held of
    found : _ → pure found
    [] → throwIO (userError ("the provider was handed no request " <> show index))

-- | Answer the nth request.
answerWith ∷ Fake → Int → ProviderReply → IO ReplyAnswer
answerWith fake index reply = do
  found ← submissionAt fake index
  completeRequest (sbCompletion found) reply

-- | Answer the nth request with an integer.
answerResult ∷ Fake → Int → Int → IO ReplyAnswer
answerResult fake index n = answerWith fake index (ProviderResult (VInteger (fromIntegral n)))

-- | The provider proves the nth request's work over.
finishWork ∷ Fake → Int → IO ()
finishWork fake index = do
  found ← submissionAt fake index
  atomically (writeTVar (sbRetirement found) ProviderComplete)

-- | The provider reports the nth request's retirement failed.
failWorkWith ∷ Fake → Int → SomeException → IO ()
failWorkWith fake index failure = do
  found ← submissionAt fake index
  atomically (writeTVar (sbRetirement found) (ProviderFailed failure))

-- | The requests the provider was told interest in was withdrawn from, in the order.
cancelledOrder ∷ Fake → IO [Int]
cancelledOrder fake = atomically (readTVar (fkCancels fake))

-- | Block until the provider has been told about this many withdrawals.
awaitCancelled ∷ Fake → Int → IO ()
awaitCancelled fake wanted = atomically $ do
  held ← readTVar (fkCancels fake)
  if length held >= wanted then pure () else retry

-- The registration and the modules -----------------------------------------------------

-- | The sources: a command a script is told, as a record.
cmdSource ∷ EventSource
cmdSource = EventSource "cmd" (SRecord [("op", SText), ("key", SOptional SText), ("endpoint", SOptional SText), ("n", SOptional SInteger)])

-- | Bounds and sources for an owner of askers.
cmdConfig ∷ InstanceConfig
cmdConfig = (testConfig instanceBounds') {instanceSources = [cmdSource, tickSource]}

-- | The registration of the request examples: the scheduler and fixture namespaces, a counter,
-- @rq.start@ that starts a request of an endpoint with an integer, and the request bindings in
-- @req@. A request's dependency is disposed of by recording @disposed <n>@.
requestRegistration ∷ IFixture → Registration
requestRegistration fixture =
  either (error . show) id $
    registration [requestHandleType "request"] (registrationNamespaces (schedRegistration (ifBase fixture)) <> [inst, rq, requestNamespace "req" "request" SInteger])
  where
    inst =
      namespace
        "inst"
        [ stateOperation "next" [] [SInteger] $ \_ → do
            n ← atomicModifyIORef' (ifCounter fixture) (\held → (held + 1, held + 1))
            pure [VInteger (fromIntegral n)]
        ]
    rq =
      namespace
        "rq"
        [ asynchronousNativeRequestIn "start" [SText, SInteger] [SCapability "request"] $ \context arguments → case arguments of
            [VText endpoint, VInteger n] → do
              handle ← startRequest context endpoint [VInteger n] (note ("disposed " <> Text.pack (show n)))
              pure [requestHandleValue "request" handle]
            _ → pure [VNil]
        , -- A request of an endpoint the grant does not name: the application's own mistake.
          asynchronousNativeRequestIn "start_unnamed" [] [SCapability "request"] $ \context _ → do
            handle ← startRequest context "nowhere" [] (pure ())
            pure [requestHandleValue "request" handle]
        ]
    note entry = atomicModifyIORef' (sfLog (ifBase fixture)) (\held → (entry : held, ()))

-- | Lua every asker shares: a deterministic rendering of what came back.
prelude ∷ [Text]
prelude =
  [ "local function fmt(v)"
  , "  if type(v) ~= 'table' then return tostring(v) end"
  , "  local keys = {}"
  , "  for k in pairs(v) do keys[#keys + 1] = tostring(k) end"
  , "  table.sort(keys)"
  , "  local out = {}"
  , "  for _, k in ipairs(keys) do"
  , "    local x = v[k]"
  , "    if x == nil then x = v[tonumber(k)] end"
  , "    out[#out + 1] = k .. '=' .. fmt(x)"
  , "  end"
  , "  return '{' .. table.concat(out, ',') .. '}'"
  , "end"
  , "local function run(self, p)"
  , "  fx.delay()"
  , "  local key = p.key or 'a'"
  , "  local out = '?'"
  , "  if p.op == 'start' then"
  , "    self.hs[key] = rq.start(p.endpoint or 'path', p.n or 0)"
  , "    out = 'started'"
  , "  elseif p.op == 'ready' then out = tostring(req.ready(self.hs[key]))"
  , "  elseif p.op == 'take' then out = fmt(req.take(self.hs[key]))"
  , "  elseif p.op == 'cancel' then out = req.cancel(self.hs[key])"
  , "  elseif p.op == 'wait' then"
  , "    fx.record('waiting ' .. key)"
  , "    req.wait(self.hs[key])"
  , "    out = 'woke'"
  , "  elseif p.op == 'wait_take' then"
  , "    fx.record('waiting ' .. key)"
  , "    req.wait(self.hs[key])"
  , "    out = fmt(req.take(self.hs[key]))"
  , "  elseif p.op == 'start_wait_take' then"
  , "    self.hs[key] = rq.start(p.endpoint or 'path', p.n or 0)"
  , "    fx.record('waiting ' .. key)"
  , "    req.wait(self.hs[key])"
  , "    out = fmt(req.take(self.hs[key]))"
  , "  elseif p.op == 'start_cancel' then"
  , "    self.hs[key] = rq.start(p.endpoint or 'path', p.n or 0)"
  , "    out = req.cancel(self.hs[key])"
  , "  elseif p.op == 'block' then"
  , "    fx.block(key)"
  , "    out = 'unblocked'"
  , "  elseif p.op == 'other' then"
  , "    out = fmt(req.take(OTHER))"
  , "  elseif p.op == 'stash' then"
  , "    OTHER = self.hs[key]"
  , "    out = 'stashed'"
  , "  elseif p.op == 'wait_other' then"
  , "    req.wait(OTHER)"
  , "    out = 'woke'"
  , "  elseif p.op == 'block_start' then"
  , "    fx.block(key)"
  , "    self.hs[key] = rq.start(p.endpoint or 'path', p.n or 0)"
  , "    out = 'started'"
  , "  elseif p.op == 'noop' then"
  , "    out = 'noop'"
  , "  elseif p.op == 'hostfail' then"
  , "    fx.fail('boom')"
  , "  elseif p.op == 'boom' then"
  , "    error('script boom')"
  , "  elseif p.op == 'unnamed' then"
  , "    rq.start_unnamed()"
  , "  end"
  , "  fx.record('cmd ' .. p.op .. ' ' .. key .. ' ' .. out)"
  , "end"
  , "local function connect(self, api) api.connect('cmd', function(self, event) run(self, event.payload) end) end"
  ]

-- | An instance that does what it is told with its requests, and records the answers.
asker ∷ ModuleSource
asker =
  hooksModule "asker" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that starts a request in @init@, and can then be told what to do with it.
initAsker ∷ ModuleSource
initAsker =
  hooksModule "initasker" $
    prelude
      <> [ "function init(self, api)"
         , "  self.hs = {}"
         , "  self.hs['a'] = rq.start('path', 1)"
         , "  fx.record('init started')"
         , "  connect(self, api)"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance that asks in its @shutdown@ hook, which is past taking requests.
shutdownAsker ∷ ModuleSource
shutdownAsker =
  hooksModule "shutdownasker" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason)"
         , "  fx.record('shutdown ' .. reason)"
         , "  rq.start('path', 99)"
         , "  fx.record('shutdown after')"
         , "end"
         ]

-- | A periodic instance that starts a request in each update, and can be told what to do.
updateAsker ∷ ModuleSource
updateAsker =
  hooksModule "updateasker" $
    prelude
      <> [ "function init(self, api) self.hs = {} self.updates = 0 connect(self, api) end"
         , "function update(self, dt)"
         , "  self.updates = self.updates + 1"
         , "  self.hs['u' .. self.updates] = rq.start('path', 100 + self.updates)"
         , "  fx.record('update started u' .. self.updates)"
         , "end"
         , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
         ]

-- | An instance whose callback holds a closing handler that asks, and waits.
closingAsker ∷ ModuleSource
closingAsker =
  hooksModule "closingasker" $
    prelude
      <> [ "function init(self, api)"
         , "  self.hs = {}"
         , "  api.connect('cmd', function(self, event)"
         , "    self.hs['a'] = rq.start('path', 5)"
         , "    local guard <close> = setmetatable({}, {__close = function()"
         , "      fx.record('closing')"
         , "      rq.start('path', 6)"
         , "      fx.record('closing after')"
         , "    end})"
         , "    fx.record('waiting a')"
         , "    req.wait(self.hs['a'])"
         , "  end)"
         , "end"
         ]

-- | An instance that starts a request in @init@ and waits for it there, where nothing can wait.
waitInitAsker ∷ ModuleSource
waitInitAsker =
  hooksModule "waitinitasker" $
    prelude
      <> [ "function init(self, api)"
         , "  self.hs = {}"
         , "  self.hs['a'] = rq.start('path', 1)"
         , "  fx.record('init waiting')"
         , "  req.wait(self.hs['a'])"
         , "  fx.record('init after')"
         , "end"
         ]

-- | An instance that waits for a request in @shutdown@, where nothing can wait.
waitShutdownAsker ∷ ModuleSource
waitShutdownAsker =
  hooksModule "waitshutdownasker" $
    prelude
      <> [ "function init(self, api) self.hs = {} connect(self, api) end"
         , "function shutdown(self, reason)"
         , "  fx.record('shutdown waiting')"
         , "  req.wait(self.hs['a'])"
         , "  fx.record('shutdown after')"
         , "end"
         ]

-- | Tasks, for an owner whose scripts are not instances: a task owns its requests.
taskAsker ∷ ModuleSource
taskAsker =
  ModuleSource
    (ModuleRef "taskasker" "1")
    ( Text.encodeUtf8 . Text.unlines $
        [ "function ask(endpoint, n)"
        , "  local h = rq.start(endpoint, n)"
        , "  fx.record('task started ' .. n)"
        , "  req.wait(h)"
        , "  local r = req.take(h)"
        , "  fx.record('task took ' .. n .. ' ' .. r.status .. ' ' .. tostring(r.value))"
        , "  return n"
        , "end"
        , "function start_only(endpoint, n)"
        , "  rq.start(endpoint, n)"
        , "  fx.record('task started ' .. n)"
        , "  return n"
        , "end"
        , "function wait_other(n) local h = rq.start('path', n) req.wait(h) return n end"
        , "function close_block(endpoint, n)"
        , "  local guard <close> = setmetatable({}, {__close = function()"
        , "    fx.record('task closing')"
        , "    fx.block('upd')"
        , "  end})"
        , "  local h = rq.start(endpoint, n)"
        , "  fx.record('task started ' .. n)"
        , "  req.wait(h)"
        , "  return n"
        , "end"
        , "function close_ask(endpoint, n)"
        , "  local guard <close> = setmetatable({}, {__close = function()"
        , "    fx.record('task closing')"
        , "    rq.start('path', 99)"
        , "    fx.record('task closing after')"
        , "  end})"
        , "  local h = rq.start(endpoint, n)"
        , "  fx.record('task started ' .. n)"
        , "  req.wait(h)"
        , "  return n"
        , "end"
        ]
    )
    [EntryPoint "ask" Required [SText, SInteger] [SInteger], EntryPoint "start_only" Required [SText, SInteger] [SInteger], EntryPoint "wait_other" Required [SInteger] [SInteger], EntryPoint "close_ask" Required [SText, SInteger] [SInteger], EntryPoint "close_block" Required [SText, SInteger] [SInteger]]

-- Owners ----------------------------------------------------------------------------------

-- | A grant over this fake's @path@ endpoint, settling on arrival, with room for this many.
grantOf ∷ Fake → Int → RequestGrant
grantOf fake bound = RequestGrant [fakeEndpoint fake "path"] bound SettleOnArrival

-- | A grant that settles at the tick the application assigned: by default the next.
logicalGrant ∷ Fake → Int → Maybe AssignRequest → RequestGrant
logicalGrant fake bound assign = RequestGrant [fakeEndpoint fake "path"] bound (SettleAtAssignedTick assign)

-- | A specification of an owner of askers granted requests.
requestSpec ∷ IFixture → Text → [ModuleSource] → InstanceConfig → RequestGrant → WorkerPolicy → ScheduledSpec
requestSpec fixture label modules config grant worker =
  base
    { scheduledVm =
        (scheduledVm base)
          { vmRegistration = requestRegistration fixture
          , vmPolicy = ["sched", "fx", "inst", "rq", "req"]
          , vmModules = modules <> [taskAsker]
          }
    , scheduledInstances = Just config
    , scheduledRequests = Just grant
    }
  where
    base = scheduled (ifBase fixture) label worker defaultSchedulerBounds

-- | Start an owner of askers.
startRequester ∷ IFixture → LuaRuntime → Text → [ModuleSource] → InstanceConfig → RequestGrant → WorkerPolicy → IO ScheduledOwner
startRequester fixture runtime label modules config grant worker =
  startScheduled (ifBase fixture) runtime (requestSpec fixture label modules config grant worker)

-- | Start an owner from a specification.
startRequesterWith ∷ IFixture → LuaRuntime → ScheduledSpec → IO ScheduledOwner
startRequesterWith fixture = startScheduled (ifBase fixture)

-- | The owner's request service, read in one transaction.
diagnostics ∷ ScheduledOwner → IO ProviderDiagnostics
diagnostics owner = do
  found ← atomically (requestDiagnostics (scheduledEndpoint owner))
  maybe (throwIO (userError "the owner has no request service")) pure found

-- Commanding ---------------------------------------------------------------------------------

-- | An event-only instance of this module, granted the @cmd@ and @tick@ sources.
askerRequest ∷ Text → Text → InstanceRequest
askerRequest name moduleName = InstanceRequest (moduleNamed moduleName) EventOnly (Just name) OrdinaryClass ["cmd", "tick"]

-- | Admit an instance of this module under this name and wait until it is active.
admitAsker ∷ IFixture → ScheduledOwner → Text → Text → IO ()
admitAsker fixture owner name moduleName = do
  _ ← admitWith fixture owner name (askerRequest name moduleName)
  awaitPhase fixture owner name Active

-- | Tell the asker of this name to do this: an operation on the request it keeps under the key.
command ∷ IFixture → ScheduledOwner → Text → Text → Text → IO ()
command fixture owner name op key = commandFrom fixture owner name op key Nothing Nothing

-- | The same, with the endpoint and the integer a start asks with.
commandFrom ∷ IFixture → ScheduledOwner → Text → Text → Text → Maybe Text → Maybe Int → IO ()
commandFrom fixture owner name op key endpoint n = do
  identity ← idOf fixture name
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key)]
            <> [("endpoint", VText found) | Just found ← [endpoint]]
            <> [("n", VInteger (fromIntegral found)) | Just found ← [n]]
  deliverEvent (scheduledEndpoint owner) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → throwIO (userError ("expected the command accepted, found " <> show other))

-- | The first line a script recorded that starts with this, if any.
lineIn ∷ IFixture → Text → IO (Maybe Text)
lineIn fixture prefix = (\recorded → case filter (Text.isPrefixOf prefix) recorded of line : _ → Just line; [] → Nothing) <$> logged fixture

-- | Wait, without sleeping, until a script has recorded exactly this.
awaitLine ∷ IFixture → Text → IO ()
awaitLine fixture wanted = do
  recorded ← logged fixture
  if wanted `elem` recorded then pure () else yield >> awaitLine fixture wanted

-- | Wait until the log has recorded this many lines.
awaitLines ∷ IFixture → Int → IO ()
awaitLines = awaitCount

-- | What the scripts recorded, oldest first.
linesOf ∷ IFixture → IO [Text]
linesOf = logged

-- | How many times this exact line was recorded.
countOf ∷ IFixture → Text → IO Int
countOf = logCount

-- | Block, in STM, until the owner's request service reads like this.
awaitDiagnostic ∷ ScheduledOwner → (ProviderDiagnostics → Bool) → IO ()
awaitDiagnostic owner wanted = atomically $ do
  found ← requestDiagnostics (scheduledEndpoint owner)
  case found of
    Just reading | wanted reading → pure ()
    _ → retry

-- | Grant one logical step without waiting for the tick to complete, and answer the grant.
grantAndWait ∷ RuntimeControl → ScheduledOwner → IO GrantAnswer
grantAndWait _ owner = grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1)

-- | Wait, without sleeping, for a line a script recorded that starts with this, and answer it.
awaitTaken ∷ IFixture → Text → IO Text
awaitTaken fixture prefix = lineIn fixture prefix >>= maybe (yield >> awaitTaken fixture prefix) pure

-- | Wait for the instance to settle as failed, and answer the refusal its failure was, if it was
-- one: the engine's own refusal of a call, which faults the call.
refusalOf ∷ IFixture → Text → IO (Maybe Text)
refusalOf fixture name = do
  settled ← awaitSettled fixture name
  pure $ do
    failure ← failureOf' settled
    case failureError failure of
      ErrorFault (BoundaryFailed fault) | BindingRefused why ← boundaryReason fault → Just why
      _ → Nothing

-- | The logical tick the owner has reached.
tickReached ∷ ScheduledOwner → IO Word64
tickReached owner = atomically (scheduledTick (scheduledEndpoint owner))

-- | Block, in STM, until the owner has reached this tick.
awaitTick ∷ ScheduledOwner → Word64 → IO ()
awaitTick owner wanted = atomically $ do
  reached ← scheduledTick (scheduledEndpoint owner)
  if reached >= wanted then pure () else retry

-- | Have the owner serve one more thing, and wait until it has: an asker of this name is told to
-- do nothing, under this number. When the owner is held at a tick, this shows it is serving
-- invocations all the same.
sync ∷ IFixture → ScheduledOwner → Text → Int → IO ()
sync fixture owner name number = do
  let key = "s" <> Text.pack (show number)
  command fixture owner name "noop" key
  awaitLine fixture ("cmd noop " <> key <> " noop")

-- | An assignment that places each request at the next place of a plan, in the order the engine
-- asks, declining when the plan has run out.
planned ∷ IORef [Maybe DueSlot] → AssignRequest
planned plan _ = atomicModifyIORef' plan (\case [] → ([], Nothing); next : rest → (rest, next))

-- | The same owner with small limits on every value that crosses for it.
smallLimits ∷ ScheduledSpec → ScheduledSpec
smallLimits = withLimits (either (error . show) id (valueLimits 512 8 64))

-- | A task of the asker module, admitted and its ticket.
taskOf ∷ ScheduledOwner → Text → [Value] → IO ScheduledTicket
taskOf owner entry arguments =
  admitScheduledTask (scheduledEndpoint owner) (TaskRequest (ModuleRef "taskasker" "1") entry arguments OrdinaryClass OneShot Nothing) >>= \case
    TaskAccepted _ ticket → pure ticket
    other → fail ("expected the task accepted, found " <> show other)
