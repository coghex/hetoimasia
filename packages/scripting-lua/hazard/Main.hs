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
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , SomeException
  , try
  )
import Control.Monad (forever, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Foreign.C (CInt (CInt), CLong)
import Foreign.Marshal.Alloc (alloca, free, malloc)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, poke)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
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
    _ → do
      hPutStrLn
        stderr
        "usage: lua-hazard uninterruptible-lua|capability-release|callback-cancellation"
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
  -- Plain memory, not an IORef: the sampling hook is C and reads it directly.
  counter ← malloc
  poke counter (0 ∷ CLong)
  installCallback vm "started" (putMVar started () >> pure NoResult) (pure ())
  installCallback
    vm
    "keep_going"
    (BooleanResult . not <$> readIORef stop)
    (pure ())
  hetoimasia_lua_arm_probe (vmState vm) counter probeInstructions
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
            value ← peek counter
            poke counter (value + 1)
            yield
            count
  counted ← timeout boundMicroseconds count
  writeIORef stop True
  outcome ← timeout boundMicroseconds (takeMVar finished)
  (taken, first, second) ← readSamples
  closeVm vm
  free counter
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

-- | Cancel callback threads repeatedly while Lua is calling them.
--
-- The trampoline runs the callback's own action unmasked, so a cancellation
-- aimed there is delivered and caught. Everything after it is masked, because
-- the frame this returns through is C: an exception unwinding out of it is
-- undefined, not an error report, and the failure it would produce is a crashed
-- process rather than a failed example. So it is provoked here, where a crash
-- is the suite's evidence rather than its own death.
--
-- Each call publishes its thread and is then cancelled several times over, so
-- both windows are covered: inside the action, and after it while the
-- trampoline is finishing.
callbackCancellation ∷ IO ()
callbackCancellation = do
  vm ← newVm [LibraryBase]
  targets ← newChan
  calls ← newIORef (0 ∷ Int)
  installCallback
    vm
    "emit"
    ( do
        target ← myThreadId
        atomicModifyIORef' calls (\value → (value + 1, ()))
        writeChan targets target
        pure NoResult
    )
    (pure ())
  _ ← forkIO . forever $ do
    target ← readChan targets
    -- Each throw on a thread of its own: throwTo waits for delivery, and the
    -- masked stretch is exactly what it may have to wait for.
    mapM_ (\_ → forkIO (throwTo target ThreadKilled)) [1 .. 3 ∷ Int]
  outcome ←
    try @SomeException
      (evalChunk vm (chunkName "callbacks") "for index = 1, 500 do emit() end")
  made ← readIORef calls
  closeVm vm
  putStrLn
    ( "HAZARD callbacks-survived calls="
        <> show made
        <> " outcome="
        <> either (const "cancelled") (const "completed") outcome
    )

-- | How many Lua instructions separate the hook's samples.
--
-- Large enough that the interpreter is unmistakably executing between them,
-- small enough that both fall inside the chunk's first block.
probeInstructions ∷ CInt
probeInstructions = 200000

-- | Arm Lua's count hook to sample a counter from inside the instruction loop.
foreign import ccall unsafe "hetoimasia_lua_probe.h hetoimasia_lua_arm_probe"
  hetoimasia_lua_arm_probe ∷ State → Ptr CLong → CInt → IO ()

-- | The hook's first two samples, and how many it took.
foreign import ccall unsafe "hetoimasia_lua_probe.h hetoimasia_lua_probe_samples"
  hetoimasia_lua_probe_samples ∷ Ptr CLong → Ptr CLong → IO CInt
