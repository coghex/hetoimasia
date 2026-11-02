-- | Optional nonterminating-Lua probe. The child deliberately exhausts its
-- five-second cancellation observation window and must then be terminated.
module Main (main) where

import Control.Exception (throwIO)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (CreateProcess (env), proc, terminateProcess)
import Test.Hspec (Expectation, describe, expectationFailure, it, shouldContain, shouldNotBe)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)
import Test.Support.Bounded (boundMicroseconds)
import Test.Support.Subprocess
  ( Line (..), Output (Stdout), RunBound (Within), Stream (Inherited), ChildSpec (specStderr, specStdin), childProcess, childSpec, nextLine, waitChild, withScopedChild )

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
              { env = Just [("PATH", "/usr/bin:/bin")]
              }
          -- Standard input and error stay inherited, as they were. The 10-minute run bound is the budget of the group that runs
          -- this probe; each read and wait below keeps its own 10-second bound.
          child = (childSpec (Within (600 * 1000000)) started) {specStdin = Inherited, specStderr = Inherited}
      withScopedChild child $ \hazard → do
        reported ← nextLine hazard Stdout boundMicroseconds >>= \case
          Line text → pure text
          other → expectationFailure ("the hazard runner reported nothing: " <> show other) >> pure ""
        terminateProcess (childProcess hazard)
        status ← waitChild hazard boundMicroseconds >>= maybe (throwIO (userError "a bounded test call never returned")) pure
        check reported status
