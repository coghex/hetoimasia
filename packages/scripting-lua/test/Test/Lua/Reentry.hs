-- | A callback that asks its own VM for an operation.
--
-- The operation that ran the callback holds the VM until the callback returns,
-- so anything the callback asks of the same VM could only wait for its own
-- caller -- which is inside a @safe@ foreign call, where no cancellation
-- reaches it. The bridge refuses such an operation instead, with a failure of
-- its own that travels back like any other callback failure.
--
-- Every example here runs its VM through 'detached'. Without the refusal the
-- owner never returns, and neither a bound around the owner nor a synchronous
-- close afterwards could end the example; the bound is on a thread that is
-- never inside Lua, and a stuck owner is left where it is.
--
-- The examples make Lua dismiss the stand-in error wherever it can, catching it
-- with @pcall@ and carrying on, because the claim is that the refusal reaches
-- the owner regardless.
module Test.Lua.Reentry (spec) where

import Control.Concurrent (ThreadId, forkIO, yield)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryTakeMVar
  )
import Control.Exception (SomeException, finally, fromException, try)
import Control.Monad (void)
import Data.List (sort)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnMVar), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Failure
  ( FailureCause (EngineOrigin)
  , FailureEvidence (failureCause, failureContexts)
  , FailureOrigin (originComponent, originOperation)
  , OperationContext (contextOperation)
  , failureEvidence
  , operationText
  )
import Hetoimasia.Scripting.Lua.Bridge
  ( CloseFault (closeFailures)
  , Library (LibraryBase)
  , Vm
  , VmReentered (VmReentered)
  , callGlobal
  , chunkName
  , closeVm
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Call
  ( MessageHandler (HandlerGlobal)
  , evalChunkWith
  , globalIsFunction
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Fault (luaComponent)
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Phase (Closed, Open)
  , stackDepth
  , vmPhase
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  )
import Test.Lua.Support
  ( Recorder
  , acquireVm
  , detached
  , newRecorder
  , recorded
  , recordingCallback
  , withVm
  )
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "reentry" $ do
  it "refuses a chunk its own callback evaluates, and runs none of it" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "inner"
      refusal ←
        refusedIn vm trace (evalChunk vm (chunkName "inner") "inner() published = true")
      refusal `raisedAs` ("eval-chunk", ["eval-chunk", "eval-chunk"])
      recorded trace >>= (`shouldBe` ["finished"])
      evalChunk vm (chunkName "published") "assert(published == nil)"
      ownerContinues vm

  it "refuses a chunk under a message handler, and runs neither" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "handled"
      recordingCallback vm trace "inner"
      evalChunk vm (chunkName "handler") "function handler(message) handled() return message end"
      refusal ←
        refusedIn
          vm
          trace
          (evalChunkWith vm (HandlerGlobal "handler") (chunkName "inner") "inner() error('x')")
      refusal `raisedAs` ("eval-chunk", ["eval-chunk", "eval-chunk"])
      recorded trace >>= (`shouldBe` ["finished"])
      ownerContinues vm

  it "refuses a global its own callback calls" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "inner"
      refusal ← refusedIn vm trace (callGlobal vm "inner")
      refusal `raisedAs` ("call-global", ["call-global", "eval-chunk"])
      recorded trace >>= (`shouldBe` ["finished"])
      ownerContinues vm

  it "refuses a global probe from its own callback" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      refusal ← refusedIn vm trace (void (globalIsFunction vm "reenter"))
      -- The probe is a fixture and carries no boundary of its own; the
      -- refusal's origin still names it.
      refusal `raisedAs` ("probe-global", ["eval-chunk"])
      ownerContinues vm

  it "refuses a callback its own callback installs, retaining nothing for it" $
    detached $ do
      vm ← acquireVm [LibraryBase]
      trace ← newRecorder
      outer ← newMVar (0 ∷ Int)
      nested ← newMVar (0 ∷ Int)
      refusal ←
        refusedWith
          vm
          trace
          (count outer)
          (installCallback vm "nested" (pure NoResult) (count nested))
      refusal `raisedAs` ("install-callback", ["install-callback", "eval-chunk"])
      globalIsFunction vm "nested" >>= (`shouldBe` False)
      ownerContinues vm
      closeVm vm
      -- The callback that did the asking had its release retained and run; the
      -- one it asked for was never installed, so it had none to run.
      readMVar outer >>= (`shouldBe` 1)
      readMVar nested >>= (`shouldBe` 0)

  it "refuses a close its own callback asks for, and leaves the VM open" $
    detached $ do
      vm ← acquireVm [LibraryBase]
      trace ← newRecorder
      refusal ← refusedIn vm trace (closeVm vm)
      refusal `raisedAs` ("close-vm", ["close-vm", "eval-chunk"])
      vmPhase vm >>= (`shouldBe` Open)
      ownerContinues vm
      closeVm vm
      vmPhase vm >>= (`shouldBe` Closed)

  it "refuses re-entry from a callback an __index read ran" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "inner"
      depths ← newEmptyMVar
      installCallback vm "reenter" (reentering vm depths (evalChunk vm (chunkName "inner") "inner()")) (pure ())
      evalChunk
        vm
        (chunkName "trap")
        "setmetatable(_G, {__index = function(t, k) pcall(reenter) return nil end})"
      outcome ← try @SomeException (callGlobal vm "missing")
      balanced depths
      -- The lookup found no function, but the refusal outranks that: it is what
      -- the caller's code ran into.
      outcome `raisedAs` ("eval-chunk", ["eval-chunk", "call-global"])
      recorded trace >>= (`shouldBe` [])
      evalChunk vm (chunkName "untrap") "setmetatable(_G, nil)"
      ownerContinues vm

  it "refuses re-entry from a callback an __newindex publication ran, keeping the outer release" $
    detached $ do
      vm ← acquireVm [LibraryBase]
      depths ← newEmptyMVar
      later ← newMVar (0 ∷ Int)
      nested ← newMVar (0 ∷ Int)
      installCallback
        vm
        "reenter"
        (reentering vm depths (installCallback vm "nested" (pure NoResult) (count nested)))
        (pure ())
      evalChunk
        vm
        (chunkName "trap")
        "setmetatable(_G, {__newindex = function(t, k, v) pcall(reenter) rawset(t, k, v) end})"
      outcome ← try @SomeException (installCallback vm "later" (pure NoResult) (count later))
      balanced depths
      outcome `raisedAs` ("install-callback", ["install-callback", "install-callback"])
      evalChunk vm (chunkName "untrap") "setmetatable(_G, nil)"
      globalIsFunction vm "nested" >>= (`shouldBe` False)
      ownerContinues vm
      closeVm vm
      -- The outer installation retained its release before it published, as it
      -- always does; only the refused one retained nothing.
      readMVar later >>= (`shouldBe` 1)
      readMVar nested >>= (`shouldBe` 0)

  it "refuses re-entry from finalizers during the close, and still completes it" $
    detached $ do
      vm ← acquireVm [LibraryBase]
      trace ← newRecorder
      recordingCallback vm trace "inner"
      evaluated ← newEmptyMVar
      closed ← newEmptyMVar
      installCallback
        vm
        "reenter_eval"
        (reentering vm evaluated (evalChunk vm (chunkName "inner") "inner()"))
        (pure ())
      installCallback vm "reenter_close" (reentering vm closed (closeVm vm)) (pure ())
      evalChunk
        vm
        (chunkName "finalizers")
        ( "eval_guard = setmetatable({}, {__gc = function() reenter_eval() end})\n"
            <> "close_guard = setmetatable({}, {__gc = function() reenter_close() end})\n"
        )
      outcome ← try @CloseFault (closeVm vm)
      vmPhase vm >>= (`shouldBe` Closed)
      recorded trace >>= (`shouldBe` [])
      balanced evaluated
      balanced closed
      case outcome of
        Right () → expectationFailure "the close reported no failure"
        Left fault → do
          -- Lua runs finalizers in its own order; which ran first is not the
          -- claim.
          let refused = [operation | Just (VmReentered operation) ← map fromException (closeFailures fault)]
          length (closeFailures fault) `shouldBe` 2
          sort refused `shouldBe` ["close-vm", "eval-chunk"]

  it "makes another thread's operation wait for the owner's call, then run it" $
    detached $ withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "owner"
      recordingCallback vm trace "second"
      entered ← newEmptyMVar
      released ← newEmptyMVar
      installCallback
        vm
        "wait"
        (putMVar entered () >> takeMVar released >> pure NoResult)
        (pure ())
      ownerDone ← newEmptyMVar
      secondStarted ← newEmptyMVar
      secondDone ← newEmptyMVar
      _ ← forkIO (try @SomeException (evalChunk vm (chunkName "owner") "wait() owner()") >>= putMVar ownerDone)
      bounded (takeMVar entered)
      second ←
        forkIO $ do
          putMVar secondStarted ()
          try @SomeException (evalChunk vm (chunkName "second") "second()") >>= putMVar secondDone
      bounded (takeMVar secondStarted)
      -- The owner is parked inside its call and holds the gate, so the only
      -- thing the second thread can block on now is that gate.
      bounded (blockedOnMVar second)
      recorded trace >>= (`shouldBe` [])
      putMVar released ()
      bounded (takeMVar ownerDone) >>= succeeded
      bounded (takeMVar secondDone) >>= succeeded
      recorded trace >>= (`shouldBe` ["owner", "second"])

-- | Install @reenter@ to ask the VM for @nested@, then run a chunk that calls it
-- under @pcall@ and carries on to a recorded finish. Answers what the outer
-- operation raised, having checked that neither it nor the refusal moved the
-- stack.
refusedIn ∷ Vm → Recorder → IO () → IO (Either SomeException ())
refusedIn vm trace = refusedWith vm trace (pure ())

-- | 'refusedIn', retaining @release@ for the asking callback.
refusedWith ∷ Vm → Recorder → IO () → IO () → IO (Either SomeException ())
refusedWith vm trace release nested = do
  depths ← newEmptyMVar
  installCallback vm "reenter" (reentering vm depths nested) release
  recordingCallback vm trace "finished"
  before ← stackDepth vm
  outcome ←
    try @SomeException
      (evalChunk vm (chunkName "outer") "local ok = pcall(reenter) assert(not ok) finished()")
  stackDepth vm >>= (`shouldBe` before)
  balanced depths
  pure outcome

-- | A callback that asks its own VM for @nested@, noting the stack depth
-- either side. The failure is left to travel as it would from any callback.
reentering ∷ Vm → MVar (Int, Int) → IO () → IO CallbackResult
reentering vm depths nested = do
  before ← stackDepth vm
  (nested >> pure NoResult)
    `finally` (stackDepth vm >>= \after → putMVar depths (before, after))

-- | The depths either side of a refusal, which must be the same.
balanced ∷ MVar (Int, Int) → Expectation
balanced depths = do
  noted ← tryTakeMVar depths
  case noted of
    Nothing → expectationFailure "the callback never ran"
    Just (before, after) → after `shouldBe` before

-- | Assert the outer operation raised the refusal with its own type, naming the
-- refused operation, originating in the Lua component, and carrying the
-- boundaries it passed, innermost first.
raisedAs ∷ Either SomeException () → (Text, [Text]) → Expectation
raisedAs outcome (refused, boundaries) = case outcome of
  Right () → expectationFailure "the outer operation reported success"
  Left raised → do
    fromException raised `shouldBe` Just (VmReentered refused)
    let evidence = failureEvidence raised
    map (operationText . contextOperation) (failureContexts evidence) `shouldBe` boundaries
    case failureCause evidence of
      EngineOrigin origin → do
        originComponent origin `shouldBe` luaComponent
        operationText (originOperation origin) `shouldBe` refused
      other → expectationFailure ("the refusal carried no origin: " <> show other)

-- | The owner's next operation on the VM succeeds and leaves nothing behind.
ownerContinues ∷ Vm → Expectation
ownerContinues vm = do
  before ← stackDepth vm
  evalChunk vm (chunkName "after") "local ignored = 1"
  stackDepth vm >>= (`shouldBe` before)

count ∷ MVar Int → IO ()
count counter = modifyMVar_ counter (pure . succ)

succeeded ∷ Either SomeException () → Expectation
succeeded = either (\failed → expectationFailure ("the operation failed: " <> show failed)) pure

-- | Wait until a thread is blocked on an 'MVar'. Coordination, not timing: it
-- returns on the thread's own state, and 'bounded' is what ends it if that
-- state never comes.
blockedOnMVar ∷ ThreadId → IO ()
blockedOnMVar thread = do
  status ← threadStatus thread
  case status of
    ThreadBlocked BlockedOnMVar → pure ()
    _ → yield >> blockedOnMVar thread
