-- | Optional nonterminating-Lua probe. The child deliberately exhausts its
-- five-second cancellation observation window and must then be terminated.
module Main (main) where

import Control.Exception (throwIO)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (BufferMode (LineBuffering), hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (env, std_out), StdStream (CreatePipe), proc
  , terminateProcess, waitForProcess, withCreateProcess
  )
import Test.Hspec (Expectation, describe, expectationFailure, it, shouldContain, shouldNotBe)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)
import Test.Support.Bounded (bounded)

main ∷ IO ()
main = hspecWith defaultConfig { configFailOnEmpty = True } $ describe "Lua nontermination probe" $ do
  it "cannot cancel a thread that is inside Lua, and says so from a child process" $
    withHazard ["uninterruptible-lua"] $ \reported status → do
      reported `shouldContain` "HAZARD uninterrupted"
      -- It could not end itself: its only remaining thread is inside Lua.
      status `shouldNotBe` ExitSuccess
      if "attempts=" `isInfixOf` reported
        then pure ()
        else throwIO (userError ("the report named no attempt count: " <> reported))

withHazard ∷ [String] → (String → ExitCode → Expectation) → Expectation
withHazard arguments check = do
  found ← findExecutable "lua-hazard"
  case found of
    Nothing →
      expectationFailure
        "no lua-hazard on PATH, so the out-of-process examples cannot be exercised"
    Just executable → do
      -- A controlled environment: the child must not read this machine's
      -- settings, and its report must not be buffered away.
      let started =
            (proc executable arguments)
              { std_out = CreatePipe
              , env = Just [("PATH", "/usr/bin:/bin")]
              }
      withCreateProcess started $ \_ out _ handle → case out of
        Nothing → expectationFailure "the hazard runner was given no stdout"
        Just reading → do
          hSetBuffering reading LineBuffering
          reported ← bounded (hGetLine reading)
          terminateProcess handle
          status ← bounded (waitForProcess handle)
          check reported status
