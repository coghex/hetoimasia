-- | Two VMs, and what one of them running Lua does to everything else.
--
-- Two claims. The first is that VMs share nothing: a global set in one is
-- absent from the other, because each has its own interpreter and its own
-- globals table.
--
-- The second is that a VM running Lua does not stop the rest of the process.
-- The binding imports @lua_pcall@ as a @safe@ foreign call, which releases the
-- capability for its duration, so Haskell threads and a second VM keep running
-- while the first is inside a chunk. The example below shows that during
-- substantial pure-Lua computation, not merely while the first VM waits inside
-- a Haskell callback -- waiting in a callback would prove only that a blocked
-- Haskell thread is a blocked Haskell thread.
--
-- No callback of the busy VM blocks. @started@ fills an empty slot and returns,
-- @keep_going@ reads a flag and returns; neither waits on anything. So the time
-- the busy VM's call is outstanding is time it spends executing Lua, and the
-- other work completing while that call is outstanding is progress during Lua
-- execution rather than progress while a Haskell thread sat in a callback.
--
-- Its handshake is an exit condition, not a probe. The chunk runs a block of
-- pure Lua, then asks @keep_going@ whether to run another; the other work
-- signals completion, and the next answer ends the loop. That makes the
-- ordering deterministic without a sleep: the first VM cannot finish before the
-- other work has, so observing the other work complete while the first VM's
-- call is still outstanding needs no timing assumption.
--
-- What it does not show is any latency bound. @keep_going@ is consulted between
-- blocks, so the loop exits some time after the flag is set, and how long that
-- takes is a property of the block size, not of the boundary.
module Test.Lua.Independence (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , chunkName
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
  , installCallback
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Support (newRecorder, recorded, recordingCallback, withVm)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "independence" $ do
  it "gives each VM its own globals" $
    withVm [LibraryBase] $ \first →
      withVm [LibraryBase] $ \second → do
        firstTrace ← newRecorder
        secondTrace ← newRecorder
        recordingCallback first firstTrace "present"
        recordingCallback first firstTrace "absent"
        recordingCallback second secondTrace "present"
        recordingCallback second secondTrace "absent"
        evalChunk first (chunkName "define") "shared_value = 'set in the first VM'"
        let probe = "if shared_value == nil then absent() else present() end"
        evalChunk first (chunkName "probe") probe
        evalChunk second (chunkName "probe") probe
        recorded firstTrace >>= (`shouldBe` ["present"])
        recorded secondTrace >>= (`shouldBe` ["absent"])

  it "lets Haskell and a second VM progress while one VM runs a long computation" $
    withVm [LibraryBase] $ \busy →
      withVm [LibraryBase] $ \other → do
        started ← newEmptyMVar
        otherWorkDone ← newIORef False
        busyFinished ← newIORef False
        blocks ← newIORef (0 ∷ Int)
        counter ← newIORef (0 ∷ Int)
        outcome ← newEmptyMVar
        otherTrace ← newRecorder
        recordingCallback other otherTrace "second_vm_ran"
        installCallback busy "started" (putMVar started () >> pure NoResult) (pure ())
        installCallback
          busy
          "keep_going"
          ( do
              atomicModifyIORef' blocks (\count → (count + 1, ()))
              done ← readIORef otherWorkDone
              pure (BooleanResult (not done))
          )
          (pure ())
        _ ←
          forkIO $ do
            ran ←
              try @SomeException
                ( evalChunk
                    busy
                    (chunkName "busy")
                    ( "started()\n"
                        <> "local total = 0\n"
                        <> "repeat\n"
                        <> "  for index = 1, 4000000 do total = total + index end\n"
                        <> "until not keep_going()\n"
                    )
                )
            writeIORef busyFinished True
            putMVar outcome ran
        -- The first VM is inside Lua from here: the handshake callback has
        -- returned and the chunk is in its first block of pure Lua.
        bounded (takeMVar started)
        -- Whatever happens below, the busy VM has to be let go: it holds that
        -- VM's gate until its chunk returns, and a failed assertion must not
        -- leave it running for the rest of the suite.
        flip finally (writeIORef otherWorkDone True) $ do
          -- Haskell work, on this thread, while that block runs.
          forM_ [1 .. 100000 ∷ Int] $ \_ →
            atomicModifyIORef' counter (\count → (count + 1, ()))
          -- And a second interpreter, through the same bridge.
          evalChunk
            other
            (chunkName "other")
            ( "second_vm_total = 0\n"
                <> "for index = 1, 1000 do second_vm_total = second_vm_total + index end\n"
                <> "second_vm_ran()\n"
            )
          recorded otherTrace >>= (`shouldBe` ["second_vm_ran"])
          readIORef counter >>= (`shouldBe` 100000)
          -- All of that happened while the first VM's call was still
          -- outstanding.
          readIORef busyFinished >>= (`shouldBe` False)
        ran ← bounded (takeMVar outcome)
        case ran of
          Left thrown → expectationFailure ("the busy VM failed: " <> show thrown)
          Right () → pure ()
        readIORef blocks >>= (`shouldSatisfy` (>= 1))
