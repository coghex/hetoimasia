-- | Two VMs, and what one of them running Lua does to everything else.
--
-- Two claims, and they need different kinds of evidence.
--
-- The first is that VMs share nothing: a global set in one is absent from the
-- other, because each has its own interpreter and its own globals table. That
-- is observable in one process.
--
-- The second is that a VM running Lua does not stop the rest of the process.
-- The example here shows a second VM running to completion while the first VM's
-- call is still outstanding, which is deterministic: the first chunk's exit
-- condition is set only after the second has finished. What it does /not/ show
-- is where the second VM's work ran. With two capabilities it could have run on
-- the other one, so this example would pass whether or not the interpreter
-- releases a capability -- and that is exactly the property requirement 8 is
-- about.
--
-- The proof of that lives in "Test.Lua.Hazard", which runs it in a process with
-- one capability. There, a Haskell thread can run during a foreign call only if
-- the call released the capability, so an @unsafe@ import would make it fail.
module Test.Lua.Independence (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , chunkName
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
  , installCallback
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
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

  it "runs a second VM to completion while the first VM's call is outstanding" $
    withVm [LibraryBase] $ \busy →
      withVm [LibraryBase] $ \other → do
        started ← newEmptyMVar
        release ← newIORef False
        busyFinished ← newIORef False
        outcome ← newEmptyMVar
        otherTrace ← newRecorder
        recordingCallback other otherTrace "second_vm_ran"
        installCallback busy "started" (putMVar started () >> pure NoResult) (pure ())
        -- The first chunk cannot end until this answers false, and only the
        -- code below sets that. So everything below happens while its call is
        -- outstanding, with no timing assumption at all.
        installCallback
          busy
          "keep_going"
          (BooleanResult . not <$> readIORef release)
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
                        <> "  for index = 1, 100000 do total = total + index end\n"
                        <> "until not keep_going()\n"
                    )
                )
            writeIORef busyFinished True
            putMVar outcome ran
        bounded (takeMVar started)
        -- Whatever happens below, the first VM has to be let go: it holds that
        -- VM's gate until its chunk returns, and a failed assertion must not
        -- leave it running for the rest of the suite.
        flip finally (writeIORef release True) $ do
          evalChunk
            other
            (chunkName "other")
            ( "second_vm_total = 0\n"
                <> "for index = 1, 1000 do second_vm_total = second_vm_total + index end\n"
                <> "second_vm_ran()\n"
            )
          recorded otherTrace >>= (`shouldBe` ["second_vm_ran"])
          readIORef busyFinished >>= (`shouldBe` False)
        ran ← bounded (takeMVar outcome)
        case ran of
          Left thrown → expectationFailure ("the first VM failed: " <> show thrown)
          Right () → pure ()
