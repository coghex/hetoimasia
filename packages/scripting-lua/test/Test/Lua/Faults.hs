-- | What happens when something fails on either side of the boundary.
--
-- Two failures cross this boundary in opposite directions, and neither may be
-- allowed to become the other. A Lua error is contained on Lua's side by the
-- protected call and arrives in Haskell as an ordinary exception; a Haskell
-- exception raised inside a callback is contained on Haskell's side and is
-- never left as an error Lua can catch and dismiss.
--
-- The second containment is the one with teeth, so the examples make Lua try
-- its hardest to dismiss it: they catch the bridge's stand-in error with
-- @pcall@ and go on to finish the chunk successfully. The boundary still
-- raises the original exception, with its own type and the context it was
-- caught with.
module Test.Lua.Faults (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
  ( modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception
  ( AsyncException (UserInterrupt)
  , Exception
  , SomeException
  , fromException
  , throwIO
  , try
  )
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureEvidence (failureContexts)
  , OperationContext (contextOperation)
  , failureEvidence
  , operationText
  )
import Hetoimasia.Scripting.Lua.Bridge
  ( ErrorValue (ErrorMessage, ErrorOpaque)
  , FaultKind (CallFailed, ChunkRejected, HandlerFailed, MemoryExhausted)
  , Library (LibraryBase, LibraryString)
  , LuaFault (faultKind, faultValue)
  , callGlobal
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Call
  ( MessageHandler (HandlerGlobal)
  , evalChunkWith
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Fault (classify, diagnosticLimit)
import Hetoimasia.Scripting.Lua.Internal.Vm (stackDepth)
import Lua (data LUA_ERRERR, data LUA_ERRMEM, data LUA_ERRRUN, data LUA_ERRSYNTAX)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldSatisfy
  )
import Test.Lua.Support
  ( cancelling
  , newRecorder
  , recorded
  , recordingCallback
  , referenceSlot
  , withVm
  )
import Test.Support.Bounded (bounded)

-- | The failure a callback raises when an example wants one.
newtype CallbackBroke = CallbackBroke String
  deriving (Eq, Show)

instance Exception CallbackBroke

spec ∷ Spec
spec = describe "faults" $ do
  it "reports a syntax error as a fault and leaves the VM usable" $
    withVm [] $ \vm → do
      outcome ← try (evalChunk vm (chunkName "bad") "this is not lua")
      case outcome of
        Right () → expectationFailure "the chunk was accepted"
        Left fault → faultKind fault `shouldBe` ChunkRejected
      -- Nothing unwound Haskell through the C frame, so the same VM still runs.
      evalChunk vm (chunkName "after") "local ignored = 1"

  it "reports a Lua error raised inside a call as a Lua fault" $
    withVm [LibraryBase] $ \vm → do
      outcome ← try (evalChunk vm (chunkName "raise") "error('boom')")
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → do
          faultKind fault `shouldBe` CallFailed
          case faultValue fault of
            ErrorMessage message truncated → do
              Text.unpack message `shouldContain` "boom"
              truncated `shouldBe` False
            other → expectationFailure ("the error value was " <> show other)

  it "propagates a callback's exception even when Lua catches it and finishes" $
    withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      installCallback vm "boom" (throwIO (CallbackBroke "the callback failed")) (pure ())
      recordingCallback vm trace "finished"
      outcome ←
        try @SomeException
          ( evalChunk
              vm
              (chunkName "swallow")
              "local ok, message = pcall(boom) finished()"
          )
      case outcome of
        Right () → expectationFailure "the boundary reported success"
        Left raised → do
          -- The original exception, not a rendering of it and not a Lua fault.
          fromException raised `shouldBe` Just (CallbackBroke "the callback failed")
          -- The boundary named the operation it was performing.
          map (operationText . contextOperation) (failureContexts (failureEvidence raised))
            `shouldContain` ["eval-chunk"]
      -- Lua really did carry on after catching the stand-in error: the failure
      -- the boundary raised is not a report that the chunk stopped.
      recorded trace >>= (`shouldBe` ["finished"])

  it "never turns a cancellation of the calling thread into a Lua error" $
    withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      entered ← newEmptyMVar
      released ← newEmptyMVar
      unreachable ← newEmptyMVar
      raised ← newEmptyMVar
      -- A callback that parks the chunk, so the cancellation is aimed at a
      -- thread that is demonstrably inside a Lua call rather than at one that
      -- happens to be between calls.
      installCallback
        vm
        "wait"
        (putMVar entered () >> takeMVar released >> pure NoResult)
        (pure ())
      recordingCallback vm trace "finished"
      runner ←
        forkIO $ do
          outcome ←
            try @SomeException
              ( do
                  evalChunk vm (chunkName "cancel") "wait() finished()"
                  -- The cancellation is owed to this thread. It is delivered
                  -- when the native call it was aimed across has returned, so
                  -- the example waits for it here instead of assuming when it
                  -- lands. Nothing ever fills this slot.
                  takeMVar unreachable
              )
          putMVar raised outcome
      bounded (takeMVar entered)
      -- Delivered and waited for: the owner is inside the native call when the
      -- sender starts, so the sender returns only once that call has returned
      -- and the cancellation has landed.
      cancelling runner UserInterrupt (putMVar released ())
      outcome ← bounded (takeMVar raised)
      case outcome of
        Right () → expectationFailure "the thread was never cancelled"
        Left thrown → fromException thrown `shouldBe` Just UserInterrupt
      -- The chunk ran to its end. The cancellation did not become an error Lua
      -- could see, catch, or be stopped by.
      recorded trace >>= (`shouldBe` ["finished"])

  it "keeps the first callback failure when a later call fails differently" $
    withVm [LibraryBase] $ \vm → do
      installCallback vm "first" (throwIO (CallbackBroke "first")) (pure ())
      installCallback vm "second" (throwIO (CallbackBroke "second")) (pure ())
      outcome ←
        try @SomeException
          ( evalChunk
              vm
              (chunkName "twice")
              "pcall(first) pcall(second)"
          )
      case outcome of
        Right () → expectationFailure "the boundary reported success"
        Left thrown → fromException thrown `shouldBe` Just (CallbackBroke "first")

  it "renders a non-string error value without running its __tostring" $
    withVm [LibraryBase] $ \vm → do
      trace ← newRecorder
      recordingCallback vm trace "rendered"
      outcome ←
        try
          ( evalChunk
              vm
              (chunkName "opaque")
              "error(setmetatable({}, {__tostring = function() rendered() return 'x' end}))"
          )
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → case faultValue fault of
          ErrorOpaque named → named `shouldBe` "table"
          other → expectationFailure ("the error value was " <> show other)
      -- The metamethod is arbitrary Lua on the error path. It did not run.
      recorded trace >>= (`shouldBe` [])

  it "bounds a diagnostic the failing script chose the length of" $
    withVm [LibraryBase, LibraryString] $ \vm → do
      outcome ←
        try (evalChunk vm (chunkName "long") "error(string.rep('x', 100000))")
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → case faultValue fault of
          ErrorMessage message truncated → do
            truncated `shouldBe` True
            Text.length message `shouldSatisfy` (<= diagnosticLimit)
          other → expectationFailure ("the error value was " <> show other)

  it "names a non-string error value by its type and nothing else" $
    withVm [LibraryBase] $ \vm → do
      -- A boolean is a value, not an absence, and its rendering carries no
      -- address: this type crosses the package boundary.
      outcome ← try (evalChunk vm (chunkName "boolean") "error(true)")
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → faultValue fault `shouldBe` ErrorOpaque "boolean"
      table ← try (evalChunk vm (chunkName "table") "error({})")
      case table of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → faultValue fault `shouldBe` ErrorOpaque "table"

  it "reads a numeric error value without asking Lua to convert it" $
    withVm [LibraryBase] $ \vm → do
      slot ← referenceSlot vm
      outcome ← try (evalChunk vm (chunkName "number") "error(0.1 + 0.2)")
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → case faultValue fault of
          -- Lua's own number formatting would answer "0.3". This is Haskell's,
          -- which is the observable difference between reading the number and
          -- asking `lua_tolstring` to convert it -- and that conversion
          -- allocates, so it can raise a memory error where there is no longer
          -- a protected frame to catch it.
          ErrorMessage rendered truncated → do
            Text.unpack rendered `shouldBe` show (0.1 + 0.2 ∷ Double)
            truncated `shouldBe` False
          other → expectationFailure ("the error value was " <> show other)
      -- And the report took no registry reference, which `luaL_ref` could have
      -- raised on for the same reason.
      referenceSlot vm >>= (`shouldBe` slot)

  it "keeps a cancellation from stranding the stack of a call that faulted" $
    withVm [LibraryBase] $ \vm → do
      entered ← newEmptyMVar
      released ← newEmptyMVar
      raised ← newEmptyMVar
      installCallback
        vm
        "wait"
        (putMVar entered () >> takeMVar released >> pure NoResult)
        (pure ())
      before ← stackDepth vm
      runner ←
        forkIO $ do
          outcome ← try @SomeException (evalChunk vm (chunkName "fault") "wait() error('boom')")
          putMVar raised outcome
      bounded (takeMVar entered)
      cancelling runner UserInterrupt (putMVar released ())
      outcome ← bounded (takeMVar raised)
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        -- Two failures are owed to this thread at once: the chunk's, and the
        -- cancellation. Which of them it ends up carrying is the runtime's to
        -- decide, and this example is not about that -- it is about what the VM
        -- looks like afterwards, which is the same either way.
        Left thrown → case (fromException thrown, fromException thrown) of
          (Just UserInterrupt, _) → pure ()
          (_, Just (_ ∷ LuaFault)) → pure ()
          _ → expectationFailure ("the operation failed with " <> show thrown)
      -- The cancellation arrives the instant the protected call returns. It
      -- must not arrive between that and the stack being put back.
      stackDepth vm >>= (`shouldBe` before)
      evalChunk vm (chunkName "after") "local ignored = 1"
      stackDepth vm >>= (`shouldBe` before)

  it "keeps a cancellation from leaving a callback's failure for the next call" $
    withVm [LibraryBase] $ \vm → do
      entered ← newEmptyMVar
      released ← newEmptyMVar
      raised ← newEmptyMVar
      installCallback vm "boom" (throwIO (CallbackBroke "stranded")) (pure ())
      installCallback
        vm
        "wait"
        (putMVar entered () >> takeMVar released >> pure NoResult)
        (pure ())
      runner ←
        forkIO $ do
          outcome ← try @SomeException (evalChunk vm (chunkName "strand") "pcall(boom) wait()")
          putMVar raised outcome
      bounded (takeMVar entered)
      cancelling runner UserInterrupt (putMVar released ())
      outcome ← bounded (takeMVar raised)
      case outcome of
        Right () → expectationFailure "the operation reported success"
        Left _ → pure ()
      -- Whichever of the two the cancelled operation raised, it took the
      -- recorded failure with it. The next chunk is unrelated and succeeds.
      evalChunk vm (chunkName "after") "local ignored = 1"

  it "retains a cancelled operation's borrowed dependencies until the close" $ do
    vm ← newVm [LibraryBase]
    releases ← newMVar (0 ∷ Int)
    entered ← newEmptyMVar
    released ← newEmptyMVar
    raised ← newEmptyMVar
    installCallback
      vm
      "wait"
      (putMVar entered () >> takeMVar released >> pure NoResult)
      (modifyMVar_ releases (pure . succ))
    runner ←
      forkIO $ do
        outcome ← try @SomeException (evalChunk vm (chunkName "cancel") "wait()")
        putMVar raised outcome
    bounded (takeMVar entered)
    cancelling runner UserInterrupt (putMVar released ())
    _ ← bounded (takeMVar raised)
    -- Cancelling the owner does not retire what its callbacks borrowed. Lua can
    -- still call them, right up to the close.
    readMVar releases >>= (`shouldBe` 0)
    evalChunk vm (chunkName "again") "local ignored = 1"
    closeVm vm
    readMVar releases >>= (`shouldBe` 1)

  it "reports a callback that failed inside a globals metamethod as that failure" $
    withVm [LibraryBase] $ \vm → do
      installCallback vm "boom" (throwIO (CallbackBroke "through __index")) (pure ())
      evalChunk
        vm
        (chunkName "trap")
        "setmetatable(_G, {__index = function(table, key) return boom() end})"
      outcome ← try @SomeException (callGlobal vm "anything")
      case outcome of
        Right () → expectationFailure "the call succeeded"
        Left thrown →
          fromException thrown `shouldBe` Just (CallbackBroke "through __index")
      -- Not left behind for something unrelated to raise.
      evalChunk vm (chunkName "after") "rawset(_G, 'ignored', 1)"

  it "classifies Lua's own status codes, memory exhaustion included" $ do
    -- The other half of this is in "Test.Lua.Hazard": a starved allocator makes
    -- the library-opening and lookup paths answer LUA_ERRMEM rather than end
    -- the process, and this is what the bridge does with that answer. Reading
    -- it as a rejected chunk, which is what it did before those paths were
    -- protected, would report a script's syntax for the machine's memory.
    classify LUA_ERRMEM `shouldBe` MemoryExhausted
    classify LUA_ERRSYNTAX `shouldBe` ChunkRejected
    classify LUA_ERRRUN `shouldBe` CallFailed
    classify LUA_ERRERR `shouldBe` HandlerFailed

  it "classifies a message handler that fails as the handler's own failure" $
    withVm [LibraryBase] $ \vm → do
      evalChunk vm (chunkName "handler") "function blows_up() error('the handler failed') end"
      outcome ←
        try
          ( evalChunkWith
              vm
              (HandlerGlobal "blows_up")
              (chunkName "body")
              "error('the body failed')"
          )
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left fault → faultKind fault `shouldBe` HandlerFailed
