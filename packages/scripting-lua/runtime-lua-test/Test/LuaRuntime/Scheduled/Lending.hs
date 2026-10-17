-- | A scheduled owner's collection, lent to its VM's synchronous callbacks
-- (LUA-25). Every example runs real Lua on a real supervised scheduled owner and
-- reaches the collection the way a binding's action does, through
-- 'lentToCallback', with barriers and gates instead of sleeps.
--
-- The groups follow the contract: what a callback can do with what it was lent,
-- when the loan is refused and that a refusal has no effect and does not
-- invalidate legitimate access, the callbacks the lifecycle runs (initialization,
-- a coroutine's closing handlers, a finalizer-eligible binding), and what the
-- owner's retirement does with the collection however the owner ends.
module Test.LuaRuntime.Scheduled.Lending (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , finally
  , fromException
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Foundation.Resource
  ( Assembly
  , acquirePart
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , releaseRank
  )
import Hetoimasia.Foundation.Resource.OwnedCollection (Member)
import Hetoimasia.Runtime.Supervision (WorkerPolicy, WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Lending
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- The fixture ------------------------------------------------------------------

-- | What the lending bindings observe and share, beside the scheduled fixture's
-- clock and timer.
data LFixture = LFixture
  { lfBase ∷ !SFixture
  , lfLog ∷ !(IORef [Text])
    -- ^ What happened, newest first.
  , lfMembers ∷ !(IORef (Map Text (Member Text)))
  , lfKept ∷ !(IORef (Maybe LentCollection))
  , lfReleases ∷ !(IORef [(Text, ThreadId)])
    -- ^ Each release and the thread it ran on, newest first.
  , lfGates ∷ !(IORef (Map Text (MVar ())))
  , lfEntered ∷ !(IORef (Map Text (MVar ())))
  }

newLFixture ∷ IO LFixture
newLFixture =
  LFixture
    <$> newSFixture
    <*> newIORef []
    <*> newIORef Map.empty
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef Map.empty
    <*> newIORef Map.empty

note ∷ LFixture → Text → IO ()
note fixture entry = atomicModifyIORef' (lfLog fixture) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ LFixture → IO [Text]
history fixture = reverse <$> readIORef (lfLog fixture)

gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

openGate ∷ LFixture → Text → IO ()
openGate fixture name = gateIn (lfGates fixture) name >>= void . (`tryPutMVar` ())

awaitReached ∷ LFixture → Text → IO ()
awaitReached fixture name = gateIn (lfEntered fixture) name >>= readMVar

blockAt ∷ LFixture → Text → IO ()
blockAt fixture name = do
  gateIn (lfEntered fixture) name >>= void . (`tryPutMVar` ())
  gateIn (lfGates fixture) name >>= readMVar

-- | A member that records its acquisition and its release, and the thread the
-- release ran on.
tracked ∷ LFixture → Text → Assembly Text
tracked fixture name =
  acquirePart
    name
    (releaseRank 0)
    (name <$ note fixture ("acquire " <> name))
    ( \_ → do
        thread ← myThreadId
        atomicModifyIORef' (lfReleases fixture) (\held → ((name, thread) : held, ()))
        note fixture ("release " <> name)
    )

-- | A member whose release records itself and then fails.
breaking ∷ LFixture → Text → Assembly Text
breaking fixture name =
  acquirePart
    name
    (releaseRank 0)
    (name <$ note fixture ("acquire " <> name))
    ( \_ → do
        note fixture ("release " <> name)
        throwIO (userError (Text.unpack name <> " released"))
    )

remember ∷ LFixture → Text → Member Text → IO ()
remember fixture name member = atomicModifyIORef' (lfMembers fixture) (\held → (Map.insert name member held, ()))

recall ∷ LFixture → Text → IO (Member Text)
recall fixture name =
  Map.lookup name <$> readIORef (lfMembers fixture) >>= maybe (throwIO (userError ("no member " <> Text.unpack name))) pure

-- | How a refusal reads in the history.
describeRefusal ∷ SomeException → Text
describeRefusal failure
  | Just refusal ← fromException failure = case refusal of
      NoLoan → "no loan"
      LoanEnded → "ended"
      LoanElsewhere → "elsewhere"
  | Just rejection ← fromException failure = Text.pack (show (rejection ∷ OwnedCollectionError))
  | otherwise = "unexpected: " <> Text.pack (show failure)

-- | Run an attempt, recording what it was refused with, or that it was not.
attemptNoting ∷ LFixture → Text → IO () → IO ()
attemptNoting fixture label attempt =
  try attempt >>= \case
    Right () → note fixture (label <> ": ok")
    Left failure → note fixture (label <> ": " <> describeRefusal failure)

-- Registration -----------------------------------------------------------------

ok ∷ Either RegistrationRefusal a → a
ok = either (error . ("registration refused: " <>) . show) id

-- | The scheduler operations and fixture bindings of the shared fixture, and the
-- lending bindings.
lendRegistration ∷ LFixture → Registration
lendRegistration fixture =
  ok (registration [] (registrationNamespaces (schedRegistration (lfBase fixture)) <> [lending]))
  where
    lending =
      namespace
        "lend"
        [ stateOperation "acquire" [SText] [] $ \arguments → do
            for1 arguments $ \name → do
              lent ← lentToCallback
              acquireLent lent (tracked fixture name) >>= remember fixture name
        , stateOperation "acquire_failing" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              acquireLent lent (breaking fixture name) >>= remember fixture name
        , -- Like @acquire@, noting a rejection instead of raising it.
          stateOperation "try_acquire" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              attemptNoting fixture ("try " <> name) (acquireLent lent (tracked fixture name) >>= remember fixture name)
        , stateOperation "borrow" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              member ← recall fixture name
              withLentMember lent member (\held → note fixture ("borrow " <> held))
        , stateOperation "retire" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              member ← recall fixture name
              retireLent lent member >>= \result → note fixture ("retired " <> name <> " " <> Text.pack (show result))
        , stateOperation "count" [] [SInteger] $ \_ → do
            lent ← lentToCallback
            (\n → [VInteger (fromIntegral n)]) <$> liveLentCount lent
        , -- Keeps this callback's loan for a later presentation.
          stateOperation "keep" [] [] $ \_ → do
            lentToCallback >>= \lent → atomicModifyIORef' (lfKept fixture) (\_ → (Just lent, ()))
            pure []
        , -- Presents the loan kept earlier, from this callback.
          stateOperation "reuse" [] [] $ \_ → do
            kept ← readIORef (lfKept fixture)
            case kept of
              Nothing → note fixture "reuse: nothing kept"
              Just lent → attemptNoting fixture "reuse" (void (acquireLent lent (tracked fixture "reused")))
            pure []
        , -- A thread this callback starts presents the loan, and asks for one.
          stateOperation "child" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              finished ← newEmptyMVar
              _ ←
                forkIO $ do
                  attemptNoting fixture "child acquire" (void (acquireLent lent (tracked fixture name)))
                  attemptNoting fixture "child ask" (void lentToCallback)
                  putMVar finished ()
              takeMVar finished
              -- The refusals did not invalidate this callback's own access.
              attemptNoting fixture "after child" (acquireLent lent (tracked fixture "legit") >>= remember fixture "legit")
        , -- Keeps this callback's loan and holds the callback open until the gate
          -- is opened, then uses the loan it was lent.
          stateOperation "hold" [SText] [] $ \arguments →
            for1 arguments $ \gate → do
              lent ← lentToCallback
              atomicModifyIORef' (lfKept fixture) (\_ → (Just lent, ()))
              blockAt fixture gate
              attemptNoting fixture "after hold" (acquireLent lent (tracked fixture "legit") >>= remember fixture "legit")
        , -- Keeps this callback's loan and fails the callback.
          stateOperation "keep_fail" [SText] [] $ \arguments →
            for1 arguments $ \kind → do
              lentToCallback >>= \lent → atomicModifyIORef' (lfKept fixture) (\_ → (Just lent, ()))
              throwIO (Broken kind)
        , stateOperation "block" [SText] [] $ \arguments → for1 arguments (blockAt fixture)
        , finalizerEligible . stateOperation "note" [SText] [] $ \arguments →
            for1 arguments (note fixture)
        , -- What a finalizer or a closing handler does with the collection.
          finalizerEligible . stateOperation "gc_acquire" [SText] [] $ \arguments →
            for1 arguments $ \name → do
              lent ← lentToCallback
              acquireLent lent (tracked fixture name) >>= remember fixture name
        ]
    for1 arguments act = case arguments of
      [VText name] → act name >> pure []
      _ → pure []

-- The module -------------------------------------------------------------------

required ∷ Text → [Schema] → [Schema] → EntryPoint
required name = EntryPoint name Required

lendEntries ∷ [EntryPoint]
lendEntries =
  [ required "basic" [SText] [SInteger]
  , required "across" [SText] [SInteger]
  , required "reuses" [SText] [SInteger]
  , required "spawns" [SText] [SInteger]
  , required "holds" [SText] []
  , required "presents" [SText] []
  , required "fills" [SText] []
  , required "keeps_failing" [SText] []
  , required "suspends_holding" [SText] []
  , required "suspends_with_closer" [SText] []
  , required "holds_two" [SText] []
  , required "holds_one" [SText] []
  , required "closes_badly_holding" [SText] []
  ]

lendSource ∷ ByteString
lendSource =
  Text.encodeUtf8 . Text.unlines $
    [ "function basic(label)"
    , "  lend.acquire('a')"
    , "  lend.acquire('b')"
    , "  lend.borrow('a')"
    , "  lend.retire('a')"
    , "  return lend.count()"
    , "end"
    , "function across(label)"
    , "  lend.acquire('kept')"
    , "  sched.yield()"
    , "  lend.borrow('kept')"
    , "  lend.retire('kept')"
    , "  lend.retire('kept')"
    , "  return lend.count()"
    , "end"
    , "function reuses(label)"
    , "  lend.keep()"
    , "  sched.yield()"
    , "  lend.reuse()"
    , "  lend.acquire('later')"
    , "  return lend.count()"
    , "end"
    , "function spawns(label)"
    , "  lend.child('c')"
    , "  return lend.count()"
    , "end"
    , "function holds(gate) lend.hold(gate) end"
    , "function presents(label) lend.reuse() end"
    , "function fills(label)"
    , "  lend.try_acquire('a')"
    , "  lend.try_acquire('b')"
    , "  lend.try_acquire('c')"
    , "  lend.retire('a')"
    , "  lend.try_acquire('d')"
    , "end"
    , "function keeps_failing(kind)"
    , "  lend.acquire('doomed')"
    , "  lend.keep_fail(kind)"
    , "end"
    , "function suspends_holding(label)"
    , "  lend.acquire('x')"
    , "  lend.acquire_failing('y')"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function suspends_with_closer(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() lend.acquire('from close') end})"
    , "  lend.acquire('before suspend')"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function holds_one(label)"
    , "  lend.acquire(label)"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function holds_two(label)"
    , "  lend.acquire('first')"
    , "  lend.acquire('second')"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function closes_badly_holding(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
    , "  lend.acquire_failing('held')"
    , "  sched.wait_ticks(1)"
    , "end"
    ]

lendModule ∷ ModuleSource
lendModule = ModuleSource theModule lendSource lendEntries

-- Configurations ---------------------------------------------------------------

-- | A scheduled owner of this label that exposes the lending bindings, with the
-- shared fixture's clock and fake timer and these initial chunks.
lendingSpec ∷ LFixture → Text → WorkerPolicy → [(ChunkName, ByteString)] → ScheduledSpec
lendingSpec fixture label worker chunks =
  base {scheduledVm = (scheduledVm base) {vmRegistration = lendRegistration fixture, vmModules = [lendModule], vmInitialChunks = chunks}}
  where
    base = scheduledWith (lfBase fixture) label ["sched", "fx", "lend"] worker defaultSchedulerBounds

chunk ∷ Text → [(ChunkName, ByteString)]
chunk source = [(chunkName "init", Text.encodeUtf8 source)]

startLending ∷ LFixture → LuaRuntime → ScheduledSpec → IO ScheduledOwner
startLending fixture = startScheduled (lfBase fixture)

task ∷ LFixture → ScheduledOwner → Text → [Value] → IO ScheduledTicket
task fixture owner entry arguments =
  admitTask' (lfBase fixture) owner entry (request entry arguments OrdinaryClass OneShot Nothing)

-- | The thread the owner runs on, once it has run a segment.
ownerThread ∷ LFixture → IO ThreadId
ownerThread = readMVar . sfOwnerThread . lfBase

-- The examples -----------------------------------------------------------------

spec ∷ Spec
spec = describe "a collection lent to the owner's callbacks (LUA-25)" $ do
  describe "during a callback" $ do
    it "acquires, borrows and retires members, and counts them" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy [])
        ticket ← task fixture owner "basic" [VText "t"]
        taskReturned <$> outcomeOf ticket >>= (`shouldBe` Just [VInteger 1])
        history fixture >>= (`shouldBe` ["acquire a", "acquire b", "borrow a", "release a", "retired a Retired"])
        retireScheduled owner

    it "retires in a later callback what an earlier callback acquired, and answers already retired" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy [])
        ticket ← task fixture owner "across" [VText "t"]
        taskReturned <$> outcomeOf ticket >>= (`shouldBe` Just [VInteger 0])
        history fixture
          >>= (`shouldBe` ["acquire kept", "borrow kept", "release kept", "retired kept Retired", "retired kept AlreadyRetired"])
        retireScheduled owner

    it "refuses an acquisition past the limit before the assembly runs, and frees the slot when a member retires" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        let spec' = (lendingSpec fixture "lends" requiredPolicy []) {scheduledMemberLimit = 2}
        owner ← startLending fixture runtime spec'
        _ ← task fixture owner "fills" [VText "t"] >>= outcomeOf
        history fixture
          >>= (`shouldBe` [ "acquire a"
                          , "try a: ok"
                          , "acquire b"
                          , "try b: ok"
                          , "try c: OwnedLimitReached 2"
                          , "release a"
                          , "retired a Retired"
                          , "acquire d"
                          , "try d: ok"
                          ])
        retireScheduled owner

    it "refuses an owner created with a collection limit below one, before anything starts" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        let refused limit = do
              started ← tryWithContext @SomeException (startScheduledOwner runtime ((lendingSpec fixture "lends" requiredPolicy []) {scheduledMemberLimit = limit}))
              case started of
                Left (ExceptionWithContext _ failure) → pure (fromException failure ∷ Maybe OwnedCollectionError)
                Right _ → pure Nothing
        forM_ [0, -1] $ \limit → refused limit >>= (`shouldBe` Just (OwnedInvalidMemberLimit limit))
        history fixture >>= (`shouldBe` [])

  describe "refused loans" $ do
    it "refuses a loan kept past its callback in a later callback of the same VM, with no effect, while the later callback's own loan works" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy [])
        void (outcomeOf =<< task fixture owner "reuses" [VText "t"])
        -- Nothing was acquired by the refused presentation.
        history fixture >>= (`shouldBe` ["reuse: ended", "acquire later"])
        retireScheduled owner

    it "refuses a loan presented from a thread the callback started, while the callback is running, and the callback goes on using its loan" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy [])
        void (outcomeOf =<< task fixture owner "spawns" [VText "t"])
        history fixture
          >>= (`shouldBe` ["child acquire: elsewhere", "child ask: no loan", "acquire legit", "after child: ok"])
        retireScheduled owner

    it "refuses a loan presented from another VM's callback while the callback it was lent to is running, and that callback goes on using it" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        holder ← startLending fixture runtime (lendingSpec fixture "holder" requiredPolicy [])
        presenter ← startLending fixture runtime (lendingSpec fixture "presenter" requiredPolicy [])
        held ← task fixture holder "holds" [VText "g"]
        awaitReached fixture "g"
        -- The holder's callback is running and its loan is kept; another VM's
        -- callback presents it. The gate is opened however the checks go, so a
        -- failing example fails instead of leaving the holder stuck.
        ( do
            _ ← task fixture presenter "presents" [VText "p"] >>= outcomeOf
            history fixture >>= (`shouldBe` ["reuse: elsewhere"])
          )
          `finally` openGate fixture "g"
        _ ← outcomeOf held
        history fixture >>= (`shouldBe` ["reuse: elsewhere", "acquire legit", "after hold: ok"])
        retireScheduled holder
        retireScheduled presenter
        _ ← awaitScheduledTerminal control holder
        _ ← awaitScheduledTerminal control presenter
        pure ()

    it "refuses a thread that is running no lending callback, with nothing to ask for" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy [])
        outcome ← try lentToCallback
        case outcome of
          Left NoLoan → pure ()
          Left other → expectationFailure ("expected no loan, found " <> show other)
          Right _ → expectationFailure "expected no loan, found one"
        retireScheduled owner

    it "ends a loan when its callback throws, so the loan kept refuses every operation afterwards" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" (optionalPolicy (brokenIs "boom")) [])
        _ ← task fixture owner "keeps_failing" [VText "boom"]
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
        Just kept ← readIORef (lfKept fixture)
        refusal ← try (liveLentCount kept)
        refusal `shouldSatisfy` \case Left LoanEnded → True; _ → False
        acquisition ← try (void (acquireLent kept (tracked fixture "late")))
        acquisition `shouldSatisfy` \case Left LoanEnded → True; _ → False
        -- The refused presentations acquired nothing; the owner released what it held.
        history fixture >>= (`shouldBe` ["acquire doomed", "release doomed"])

  describe "the callbacks the lifecycle runs" $ do
    it "lends the collection to an initial chunk, and keeps what it acquired for the tasks that follow" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "lends" requiredPolicy (chunk "lend.acquire('init')"))
        _ ← task fixture owner "basic" [VText "t"] >>= outcomeOf
        history fixture >>= (`shouldBe` ["acquire init", "acquire a", "acquire b", "borrow a", "release a", "retired a Retired"])
        retireScheduled owner

    it "releases what a failed initialization acquired, on retirement of the half-built owner and after its VM closed" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \_ runtime → do
        let source =
              Text.unlines
                [ "keep_alive = setmetatable({}, {__gc = function() lend.note('vm closed') end})"
                , "lend.acquire('init')"
                , "error('init boom')"
                ]
        started ← startScheduledOwner runtime (lendingSpec fixture "broken" (optionalPolicy (const True)) (chunk source))
        case started of
          ScheduledUnavailable _ → pure ()
          _ → expectationFailure "expected the optional owner to be unavailable"
        -- The VM was closed first, and the collection released afterwards.
        history fixture >>= (`shouldBe` ["acquire init", "vm closed", "release init"])

    it "lends the collection to a coroutine's closing handler when the owner retires, and releases what the handler acquired at the collection's exit" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "closing" requiredPolicy [])
        suspended ← task fixture owner "suspends_with_closer" [VText "t"]
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        retireScheduled owner
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        _ ← outcomeOf suspended
        -- The handler ran while the collection was open; both members were released
        -- by its exit, newest first.
        history fixture
          >>= (`shouldBe` ["acquire before suspend", "acquire from close", "release from close", "release before suspend"])

    it "lends the collection to a finalizer-eligible binding reached while the VM closes, and releases what it acquired afterwards" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        let source = "keep_alive = setmetatable({}, {__gc = function() lend.gc_acquire('from gc') lend.note('finalized') end})"
        owner ← startLending fixture runtime (lendingSpec fixture "finalizing" requiredPolicy (chunk source))
        _ ← task fixture owner "basic" [VText "t"] >>= outcomeOf
        retireScheduled owner
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        history fixture
          >>= (`shouldBe` ["acquire a", "acquire b", "borrow a", "release a", "retired a Retired", "acquire from gc", "finalized", "release from gc", "release b"])

  describe "retirement" $ do
    it "releases what remains, newest first and on the owner's thread, after the VM has closed" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        let source = "keep_alive = setmetatable({}, {__gc = function() lend.note('vm closed') end})"
        owner ← startLending fixture runtime (lendingSpec fixture "retiring" requiredPolicy (chunk source))
        _ ← task fixture owner "holds_two" [VText "t"]
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        retireScheduled owner
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
        history fixture
          >>= (`shouldBe` ["acquire first", "acquire second", "vm closed", "release second", "release first"])
        thread ← ownerThread fixture
        releases ← readIORef (lfReleases fixture)
        map snd releases `shouldBe` [thread, thread]

    it "ends the owner as fatal even under an optional policy that recognizes everything when a release fails, keeping its evidence" $ bounded $ do
      fixture ← newLFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "failing release" (optionalPolicy (const True)) [])
        _ ← task fixture owner "suspends_holding" [VText "t"]
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        retireScheduled owner
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "y"
      -- The failing release did not stop the other from running.
      history fixture >>= (`shouldBe` ["acquire x", "acquire y", "release y", "release x"])

    it "keeps both the VM close's and the collection's evidence when both fail" $ bounded $ do
      fixture ← newLFixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "both" (optionalPolicy (const True)) [])
        _ ← task fixture owner "closes_badly_holding" [VText "t"]
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        retireScheduled owner
        awaitScheduledTerminal control owner
      let labels = map cleanupFailureLabel (cleanupFailuresInContext context)
      labels `shouldSatisfy` elem "held"
      labels `shouldSatisfy` elem "lua task close"

    it "releases what remains when the owner fails, with the failure primary" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "failing" (optionalPolicy (brokenIs "boom")) [])
        _ ← task fixture owner "keeps_failing" [VText "boom"]
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
        history fixture >>= (`shouldBe` ["acquire doomed", "release doomed"])

    it "releases what remains when the owner is cancelled" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        owner ← startLending fixture runtime (lendingSpec fixture "cancelled" (optionalPolicy (const True)) [])
        _ ← task fixture owner "holds_two" [VText "t"]
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        cancelScheduled owner
        _ ← awaitScheduledTerminal control owner
        history fixture >>= (`shouldBe` ["acquire first", "acquire second", "release second", "release first"])

    it "gives each owner a collection of its own" $ bounded $ do
      fixture ← newLFixture
      withBoundary $ \control runtime → do
        left ← startLending fixture runtime ((lendingSpec fixture "left" requiredPolicy []) {scheduledMemberLimit = 1})
        right ← startLending fixture runtime ((lendingSpec fixture "right" requiredPolicy []) {scheduledMemberLimit = 1})
        -- Each owner's one member fills its own collection. Were the collection
        -- shared, the second acquisition would be refused for the limit.
        leftTask ← task fixture left "holds_one" [VText "l"]
        rightTask ← task fixture right "holds_one" [VText "r"]
        awaitDiagnostics left (\counts → diagWaiting counts >= 1)
        awaitDiagnostics right (\counts → diagWaiting counts >= 1)
        history fixture >>= (`shouldSatisfy` \events → "acquire l" `elem` events && "acquire r" `elem` events)
        retireScheduled left
        retireScheduled right
        _ ← awaitScheduledTerminal control left
        _ ← awaitScheduledTerminal control right
        forM_ [leftTask, rightTask] $ \ticket →
          outcomeOf ticket >>= (`shouldSatisfy` \case SettledDiscarded _ → True; _ → False)
        history fixture >>= (`shouldSatisfy` \events → "release l" `elem` events && "release r" `elem` events)
