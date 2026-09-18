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

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
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
  , FaultKind (CallFailed, ChunkRejected, HandlerFailed)
  , Library (LibraryBase, LibraryString)
  , LuaFault (faultKind, faultValue)
  , chunkName
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Call
  ( MessageHandler (HandlerGlobal)
  , evalChunkWith
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Fault (diagnosticLimit)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldSatisfy
  )
import Test.Lua.Support (newRecorder, recorded, recordingCallback, withVm)
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
      -- throwTo blocks while the target is inside the native call, so it runs
      -- on a thread of its own.
      _ ← forkIO (throwTo runner UserInterrupt)
      putMVar released ()
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
          ErrorOpaque named _ → named `shouldBe` "table"
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
