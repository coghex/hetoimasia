-- | The examples that need a process of their own, and their report.
--
-- Two of them. One is a hazard: cancelling a Haskell thread that is inside Lua
-- does not interrupt Lua, so a chunk that never returns holds its thread for
-- the life of the process. A suite that ran that in its own process would leave
-- a thread and an interpreter running for the rest of the run and would have no
-- way to report what it observed.
--
-- The other needs an RTS option the suite cannot have: exactly one capability.
-- That is what makes the independent-progress claim falsifiable. Under one
-- capability, a Haskell thread can run during a foreign call only if the call
-- released the capability; if @lua_pcall@ were imported @unsafe@ it would not,
-- and the Haskell work that the chunk's own exit condition depends on could
-- never happen. With two capabilities the same example passes either way and
-- proves nothing.
--
-- Each mode prints one report line on stdout. The suite reads it, ends the
-- process when the mode cannot end itself, and keeps the exit status.
module Main (main) where

import Control.Concurrent
  ( forkIO
  , myThreadId
  , threadDelay
  , throwTo
  , yield
  )
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , SomeException
  , fromException
  , try
  )
import Control.Monad (forever, void, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C (CInt (CInt), CLong (CLong), CSize (CSize))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.StablePtr (StablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (peek)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
  , Installed
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (vmState)
import Lua (State (State))
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Timeout (timeout)

-- | The cancellation the hazard tries to deliver.
data Hazard = Hazard
  deriving (Show)

instance Exception Hazard

-- | Long enough that a deliverable cancellation would have arrived, short
-- enough to stay a test. Nothing either mode concludes depends on the length:
-- each reports which observation it made.
boundMicroseconds ∷ Int
boundMicroseconds = 5000000

-- | How many times the handshake window may swallow the cancellation before
-- the hazard gives up and says so.
attemptLimit ∷ Int
attemptLimit = 5

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments ← getArgs
  case arguments of
    ["uninterruptible-lua"] → uninterruptibleLua 1
    ["capability-release"] → capabilityRelease
    ["callback-cancellation"] → callbackCancellation
    ["allocation-failure"] → allocationFailure
    _ → do
      hPutStrLn
        stderr
        ( "usage: lua-hazard "
            <> "uninterruptible-lua|capability-release|callback-cancellation"
            <> "|allocation-failure"
        )
      exitWith (ExitFailure 2)

-- | Run a chunk that never returns, cancel the thread running it, and report
-- whether the cancellation was delivered.
--
-- The evidence is @throwTo@'s own: it returns when the exception is delivered,
-- so a @throwTo@ that has not returned is a cancellation that has not been
-- delivered. There is one window in which it can be delivered -- the instant
-- the chunk spends inside the handshake callback, which is Haskell -- and
-- landing in it is reported and retried rather than assumed away.
uninterruptibleLua ∷ Int → IO ()
uninterruptibleLua attempt
  | attempt > attemptLimit = do
      putStrLn ("HAZARD delivered-every-attempt attempts=" <> show attemptLimit)
      exitWith (ExitFailure 3)
  | otherwise = do
      entered ← newEmptyMVar
      delivered ← newEmptyMVar
      -- No standard library: the loop is language syntax, and a VM with
      -- nothing open is still a VM.
      vm ← newVm []
      installCallback vm "ready" (putMVar entered () >> pure NoResult) (pure ())
      runner ←
        forkIO . void . try @SomeException $
          evalChunk vm (chunkName "hazard") "ready() while true do end"
      takeMVar entered
      _ ← forkIO (throwTo runner Hazard >> putMVar delivered ())
      landed ← timeout boundMicroseconds (takeMVar delivered)
      case landed of
        -- The cancellation reached the thread while it was still inside the
        -- handshake callback rather than inside Lua. That is the window this
        -- mode exists to exclude, so it tries again.
        Just () → uninterruptibleLua (attempt + 1)
        Nothing → do
          putStrLn ("HAZARD uninterrupted attempts=" <> show attempt)
          -- The interpreter is still running Lua and no longer reachable: this
          -- process cannot end itself cleanly, which is the whole reason the
          -- example lives here. The suite ends it.
          forever (threadDelay maxBound)

-- | Show that Haskell runs while Lua is executing instructions, on a runtime
-- with one capability.
--
-- The difficulty is not showing that Haskell ran. It is showing /when/. Every
-- signal Haskell can observe from a running chunk arrives through a callback,
-- and a callback is Haskell: work seen around one proves only that a Haskell
-- thread ran while another Haskell thread was running, which is not the claim.
--
-- So the observation is made from inside Lua. A count hook samples the counter
-- twice, both times from within Lua's instruction loop, with nothing but Lua
-- instructions in between. Growth between those two samples happened while Lua
-- was executing and could not have happened in a callback, because no callback
-- runs between them.
--
-- With one capability that growth is possible only because @lua_pcall@ is
-- imported @safe@ and releases the capability for its duration. An @unsafe@
-- import would hold it for the whole call, no Haskell thread could run between
-- two hook firings, and the two samples would be equal. The test is that they
-- differ -- not that they differ by some amount, which would be a claim about
-- throughput rather than about the foreign call.
--
-- What the hook costs is worth stating: it interrupts the interpreter every
-- @probeInstructions@ instructions, which slows the chunk and creates yield
-- points. That affects how much growth is seen. It does not create the growth,
-- and nothing here reads a latency bound out of it.
capabilityRelease ∷ IO ()
capabilityRelease = do
  vm ← newVm [LibraryBase]
  started ← newEmptyMVar
  finished ← newEmptyMVar
  stop ← newIORef False
  installCallback vm "started" (putMVar started () >> pure NoResult) (pure ())
  installCallback
    vm
    "keep_going"
    (BooleanResult . not <$> readIORef stop)
    (pure ())
  hetoimasia_lua_arm_probe (vmState vm) probeInstructions
  _ ← forkIO $ do
    outcome ←
      try @SomeException
        ( evalChunk
            vm
            (chunkName "busy")
            ( "started()\n"
                <> "local total = 0\n"
                <> "repeat\n"
                <> "  for index = 1, 4000000 do total = total + index end\n"
                <> "until not keep_going()\n"
            )
        )
    putMVar finished outcome
  takeMVar started
  -- Increment until the hook has both samples. Nothing here reads the clock.
  let count = do
        (taken, _, _) ← readSamples
        if taken >= 2
          then pure ()
          else do
            -- An atomic increment in the probe's own C, because the thread Lua
            -- runs on reads it.
            _ ← hetoimasia_lua_probe_advance
            yield
            count
  counted ← timeout boundMicroseconds count
  writeIORef stop True
  outcome ← timeout boundMicroseconds (takeMVar finished)
  (taken, first, second) ← readSamples
  closeVm vm
  case (counted, outcome) of
    (Just (), Just (Right ()))
      | taken >= 2 →
          putStrLn
            ( "HAZARD progressed samples="
                <> show taken
                <> " first="
                <> show first
                <> " second="
                <> show second
            )
      | otherwise → report "the hook never sampled twice inside the chunk"
    (Nothing, _) → report "the counting thread never saw two samples"
    (_, Nothing) → report "the chunk never returned"
    (_, Just (Left failure)) → report ("the chunk failed: " <> show failure)
  where
    report reason = do
      putStrLn ("HAZARD no-progress reason=" <> reason)
      exitWith (ExitFailure 4)
    readSamples =
      alloca $ \first → alloca $ \second → do
        taken ← hetoimasia_lua_probe_samples first second
        (,,) (fromIntegral taken ∷ Int) <$> peek first <*> peek second

-- | Cancel callback threads while Lua is calling them, over and over.
--
-- This is a manually runnable diagnostic of an unsupported path, excluded
-- from the suite's assertions. The trampoline catches a failure delivered
-- inside the callback's own action, but cannot mask the runtime's
-- foreign-export prologue or epilogue. Direct cancellation of that thread can
-- end the process; surviving this run does not establish containment. Supported
-- cancellation targets the VM's execution owner instead.
--
-- The cancellation is coordinated, not hoped for: the callback publishes its
-- thread and parks interruptibly, so the first exception is delivered inside
-- the action and the count of observed deliveries is reported. The two that
-- follow it race the entry's masked bookkeeping and the runtime's unprotected
-- return path, which the fixture cannot coordinate and can only repeat.
callbackCancellation ∷ IO ()
callbackCancellation = do
  vm ← newVm [LibraryBase]
  live ← newEmptyMVar
  delivered ← newIORef (0 ∷ Int)
  let attempt = do
        outcome ← newEmptyMVar
        _ ←
          forkIO
            ( try @SomeException (evalChunk vm (chunkName "emit") "emit()")
                >>= putMVar outcome
            )
        -- The callback has published its thread and is parked in its own
        -- action: a cancellation aimed here is delivered, not merely sent.
        target ← takeMVar live
        -- Three of them. The first reaches the action, where the entry can
        -- catch it. The later deliveries race masked bookkeeping and the
        -- runtime's return path, which this package cannot protect. They may
        -- end the process instead of reaching the operation's failure result.
        mapM_ (\_ → forkIO (throwTo target ThreadKilled)) [1 .. 3 ∷ Int]
        result ← timeout boundMicroseconds (takeMVar outcome)
        case result of
          Just (Left thrown)
            | Just ThreadKilled ← fromException thrown →
                atomicModifyIORef' delivered (\value → (value + 1, ()))
          _ → pure ()
  installCallback
    vm
    "emit"
    ( do
        target ← myThreadId
        putMVar live target
        -- Parked interruptibly, so the cancellation lands inside the action.
        threadDelay maxBound
        pure NoResult
    )
    (pure ())
  mapM_ (const attempt) [1 .. attempts]
  landed ← readIORef delivered
  -- If the process survived, report whether the VM remains usable. This
  -- observation does not establish callback-thread cancellation as supported.
  usable ← try @SomeException (evalChunk vm (chunkName "after") "local ignored = 1")
  closeVm vm
  putStrLn
    ( "HAZARD callbacks-survived attempts="
        <> show attempts
        <> " delivered="
        <> show landed
        <> " usable="
        <> either (const "no") (const "yes") usable
    )
  where
    attempts = 50 ∷ Int

-- | Ask each of this package's protected Lua operations what it does when Lua
-- cannot allocate -- at every point along it, not only the first.
--
-- Publishing allocates several times over, and an allocation failure in Lua is
-- a Lua error. Raised from a call Haskell made directly it would find no
-- protected frame and end the process, which is why the bridge puts the whole
-- publication inside one. The binding exports no @lua_newstate@, so an
-- allocator that fails on demand cannot be installed from Haskell; this builds
-- one in C and walks its budget from nothing upwards, so every allocation on
-- each path is the one that fails in some run. Publication, reading a global,
-- and opening a standard library are all swept: each replaced a binding wrapper
-- that allocated its arguments before entering its own protected call, and each
-- must now answer a status instead of ending this process.
--
-- Two things are checked at each budget, and they are the ones a partially
-- built state would break. The same state is published to again with room to
-- spare, and must succeed: a failure part-way must leave nothing behind that
-- makes the next attempt wrong. And the number of carriers the state finalizes
-- must equal the number of publications that took ownership -- no more, which
-- would be a double free, and no fewer, which would be a stable pointer nothing
-- will ever release.
--
-- The lookup and library paths are checked for the three things a caller of
-- theirs relies on: that a refusal is Lua's own memory status and not something
-- else, that the shim leaves exactly one value on the stack whether it
-- succeeded or failed, and that the state still works afterwards.
allocationFailure ∷ IO ()
allocationFailure = do
  swept ← traverse sweepPublication [0 .. budgets]
  lookups ← traverse (sweepOne hetoimasia_lua_getglobal_sweep) [0 .. budgets]
  libraries ← traverse (sweepOne hetoimasia_lua_requiref_sweep) [0 .. budgets]
  let refusedPublications = [() | (_, status, _, _, _, _) ← swept, status /= luaOk]
      madePublications = [() | (_, status, _, _, _, _) ← swept, status == luaOk]
      retriesRefused = [budget | (budget, _, _, retry, _, _) ← swept, retry /= luaOk]
      miscounted =
        [ budget
        | (budget, _, first, _, second, finalized) ← swept
        , finalized /= fromIntegral (first + second)
        ]
      -- Every refusal on either replacement path must be Lua's own memory
      -- status; anything else would mean the failure came from somewhere other
      -- than the allocator being starved.
      misclassified =
        [ budget
        | (budget, status, _, _) ← lookups <> libraries
        , status /= luaOk && status /= luaErrMem
        ]
      unbalanced = [budget | (budget, _, left, _) ← lookups <> libraries, left /= 1]
      unusable = [budget | (budget, _, _, usable) ← lookups <> libraries, usable /= 1]
      refusals outcomes = length [() | (_, status, _, _) ← outcomes, status /= luaOk]
      successes outcomes = length [() | (_, status, _, _) ← outcomes, status == luaOk]
  case (retriesRefused, miscounted, misclassified, unbalanced <> unusable) of
    ([], [], [], [])
      | not (null refusedPublications)
      , not (null madePublications)
      , refusals lookups > 0
      , successes lookups > 0
      , refusals libraries > 0
      , successes libraries > 0 →
          putStrLn
            ( "HAZARD allocation-swept budgets="
                <> show (length swept)
                <> " publish-refused="
                <> show (length refusedPublications)
                <> " publish-made="
                <> show (length madePublications)
                <> " lookup-refused="
                <> show (refusals lookups)
                <> " lookup-made="
                <> show (successes lookups)
                <> " library-refused="
                <> show (refusals libraries)
                <> " library-made="
                <> show (successes libraries)
                <> " retries=all-accepted finalization=exact"
                <> " statuses=all-memory stack=balanced state=usable"
            )
    (refused, miscount, misclass, misbehaved)
      | null refusedPublications → report "no budget refused a publication"
      | null madePublications → report "no budget published"
      | refusals lookups == 0 → report "no budget refused a lookup"
      | successes lookups == 0 → report "no budget completed a lookup"
      | refusals libraries == 0 → report "no budget refused a library"
      | successes libraries == 0 → report "no budget opened a library"
      | not (null refused) →
          report ("a retry on the same state was refused at budgets " <> show refused)
      | not (null miscount) →
          report ("carriers finalized did not match those acquired at budgets " <> show miscount)
      | not (null misclass) →
          report ("a refusal was not Lua's memory status at budgets " <> show misclass)
      | otherwise →
          report ("a shim left the state wrong at budgets " <> show misbehaved)
  where
    budgets = 39 ∷ Int
    luaOk = 0 ∷ CInt
    -- Lua 5.4's LUA_ERRMEM.
    luaErrMem = 4 ∷ CInt
    report reason = do
      putStrLn ("HAZARD allocation-unswept reason=" <> reason)
      exitWith (ExitFailure 4)
    sweepOne sweep budget =
      alloca $ \status →
        alloca $ \left →
          alloca $ \usable → do
            _ ← sweep (fromIntegral budget) status left usable
            (,,,) budget <$> peek status <*> peek left <*> peek usable
    sweepPublication budget = do
      first ← newStablePtr trivialCallback
      second ← newStablePtr trivialCallback
      (status, firstTook, retry, secondTook, finalized) ←
        alloca $ \firstAcquired →
          alloca $ \retryStatus →
            alloca $ \secondAcquired →
              alloca $ \finalizedCount → do
                reported ←
                  hetoimasia_lua_publish_sweep
                    first
                    second
                    (fromIntegral budget)
                    firstAcquired
                    retryStatus
                    secondAcquired
                    finalizedCount
                (,,,,) reported
                  <$> peek firstAcquired
                  <*> peek retryStatus
                  <*> peek secondAcquired
                  <*> peek finalizedCount
      -- Freed here only by whoever still owns it; a carrier that took one has
      -- already released it at the state's close.
      when (firstTook == 0) (freeStablePtr first)
      when (secondTook == 0) (freeStablePtr second)
      pure (budget, status, firstTook, retry, secondTook, finalized)

-- | A callback that does nothing, for the publications the sweep makes.
trivialCallback ∷ Installed
trivialCallback = error "the sweep never calls what it publishes"

-- | How many Lua instructions separate the hook's samples.
--
-- Large enough that the interpreter is unmistakably executing between them,
-- small enough that both fall inside the chunk's first block.
probeInstructions ∷ CInt
probeInstructions = 200000

-- | Arm Lua's count hook to sample the probe's counter from inside the
-- instruction loop.
foreign import ccall unsafe "hetoimasia_lua_probe.h hetoimasia_lua_arm_probe"
  hetoimasia_lua_arm_probe ∷ State → CInt → IO ()

-- | Advance the probe's counter, atomically.
foreign import ccall unsafe "hetoimasia_lua_probe.h hetoimasia_lua_probe_advance"
  hetoimasia_lua_probe_advance ∷ IO CLong

-- | Walk the publication path's allocations, and report what each budget did.
--
-- @safe@ for the same reason publication itself is: it can run Lua.
foreign import ccall safe "hetoimasia_lua_probe.h hetoimasia_lua_publish_sweep"
  hetoimasia_lua_publish_sweep
    ∷ StablePtr Installed
    → StablePtr Installed
    → CSize
    → Ptr CInt
    → Ptr CInt
    → Ptr CInt
    → Ptr CLong
    → IO CInt

-- | The hook's first two samples, and how many it took.
foreign import ccall unsafe "hetoimasia_lua_probe.h hetoimasia_lua_probe_samples"
  hetoimasia_lua_probe_samples ∷ Ptr CLong → Ptr CLong → IO CInt

-- | Starve the global-lookup path at one budget.
foreign import ccall safe "hetoimasia_lua_probe.h hetoimasia_lua_getglobal_sweep"
  hetoimasia_lua_getglobal_sweep
    ∷ CSize → Ptr CInt → Ptr CInt → Ptr CInt → IO CInt

-- | Starve the library-opening path at one budget.
foreign import ccall safe "hetoimasia_lua_probe.h hetoimasia_lua_requiref_sweep"
  hetoimasia_lua_requiref_sweep
    ∷ CSize → Ptr CInt → Ptr CInt → Ptr CInt → IO CInt
