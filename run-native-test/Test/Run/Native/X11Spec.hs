{-# LANGUAGE OverloadedStrings #-}

-- | The failure path of the X11 helper client, examined with no display (LFE-25, #540): a cancelled call has killed and
-- reaped the helper process before it returns, so a capture can never race a helper that is still running. A call that
-- times out leaves through the same release ('Test.Run.Native.Child.withChild'), so this one example covers both.
--
-- The call runs on an owned worker ('Test.Run.Native.Owned.withOwnedThread'): however the example ends (the helper never
-- publishing its pid, an assertion, a timeout of the example), the worker is stopped and joined, and with it the helper
-- process it owns is reaped, before the temporary directory goes.
module Test.Run.Native.X11Spec (spec) where

import Control.Concurrent (killThread, threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Directory (doesFileExist)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid (..))
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, it, shouldSatisfy)
import Test.Run.Native.Owned (withOwnedThread)
import Test.Run.Native.X11 (X11 (..), runBounded)

spec ∷ Spec
spec = describe "the X11 helper client's failure path" $
  it "has killed and reaped the helper before a cancelled call returns" $
    withSystemTempDirectory "x11-helper-cancel" $ \folder → do
      let script = folder <> "/sleeper.py"
          pidFile = folder <> "/pid"
      -- The pid is published by a rename, so the file is whole when it exists.
      writeFile script (unlines ["import os, sys, time", "open(sys.argv[1] + '.tmp', 'w').write(str(os.getpid()))", "os.rename(sys.argv[1] + '.tmp', sys.argv[1])", "time.sleep(600)"])
      outcome ← newIORef Nothing
      withOwnedThread (try @SomeException (runBounded (60 * 1000000) (X11 "python3" script) [pidFile]) >>= writeIORef outcome . Just) $ \worker awaitEnd -> do
        -- The helper has started once it has published its pid: a bounded poll of an external fact (a file), the only wait here.
        found ← timeout (20 * 1000000) (waitFor pidFile)
        maybe (throwIO (userError "the helper never published its pid")) pure found
        pid ← fmap read (readFile pidFile) ∷ IO Int
        killThread worker
        awaitEnd
        readIORef outcome >>= (`shouldSatisfy` maybe False (either (const True) (const False)))
        -- The call has returned, so the process was reaped by it: a signal-0 to a reaped pid finds nothing (a zombie would answer).
        stillThere ← try @SomeException (signalProcess nullSignal (CPid (fromIntegral pid)))
        stillThere `shouldSatisfy` either (const True) (const False)
  where
    waitFor path = do
      there ← doesFileExist path
      unless there (threadDelay 5000 >> waitFor path)
