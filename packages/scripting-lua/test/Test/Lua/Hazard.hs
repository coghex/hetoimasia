-- | The execution path this bridge does not support, proved in a process that
-- can be ended.
--
-- A thread inside Lua cannot be cancelled. @lua_pcall@ is a @safe@ foreign
-- call, and an asynchronous exception is not delivered to a thread that is
-- inside one, so a chunk that never returns holds its thread for the life of
-- the process. Running that here would leave a thread and an interpreter
-- running for the rest of the suite; so the @lua-hazard@ executable runs it,
-- reports what it observed, and this example ends that process and keeps its
-- exit status.
--
-- The evidence the child reports is @throwTo@'s own behaviour rather than a
-- guess about scheduling: @throwTo@ returns when the exception is delivered, so
-- a @throwTo@ that has not returned is a cancellation that has not been
-- delivered.
--
-- What this fixes for later slices: cancelling a task that is inside Lua is a
-- rejected path. A supervisor that has to reclaim such a task needs something
-- other than an asynchronous exception -- a hook Lua itself consults, or a
-- process boundary. Both are later slices' work; that they will be needed is
-- this example's finding.
module Test.Lua.Hazard (spec) where

import Control.Exception (throwIO)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (BufferMode (LineBuffering), hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (env, std_out)
  , StdStream (CreatePipe)
  , proc
  , terminateProcess
  , waitForProcess
  , withCreateProcess
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain, shouldNotBe)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "hazard" $
  it "cannot cancel a thread that is inside Lua, and says so from a child process" $ do
    found ← findExecutable "lua-hazard"
    case found of
      Nothing →
        expectationFailure
          "no lua-hazard on PATH, so the uninterruptible path cannot be exercised"
      Just executable → do
        -- A controlled environment: the child must not read this machine's
        -- settings, and its report must not be buffered away.
        let started =
              (proc executable ["uninterruptible-lua"])
                { std_out = CreatePipe
                , env = Just [("PATH", "/usr/bin:/bin")]
                }
        withCreateProcess started $ \_ out _ handle → case out of
          Nothing → expectationFailure "the hazard runner was given no stdout"
          Just reading → do
            hSetBuffering reading LineBuffering
            reported ← bounded (hGetLine reading)
            reported `shouldContain` "HAZARD uninterrupted"
            -- The child cannot end itself: its only remaining thread is the one
            -- inside Lua. Ending it is this example's job, and its exit status
            -- is the evidence that it had to be ended.
            terminateProcess handle
            status ← bounded (waitForProcess handle)
            status `shouldNotBe` ExitSuccess
            if "attempts=" `isInfixOf` reported
              then pure ()
              else throwIO (userError ("the report named no attempt count: " <> reported))
