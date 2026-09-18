-- | The two examples that need a process of their own.
--
-- The first is the execution path this bridge does not support. A thread inside
-- Lua cannot be cancelled: @lua_pcall@ is a @safe@ foreign call, and an
-- asynchronous exception is not delivered to a thread that is inside one, so a
-- chunk that never returns holds its thread for the life of the process.
-- Running that here would leave a thread and an interpreter running for the
-- rest of the suite; so the @lua-hazard@ executable runs it, reports what it
-- observed, and this example ends that process and keeps its exit status. The
-- evidence it reports is @throwTo@'s own behaviour rather than a guess about
-- scheduling: @throwTo@ returns when the exception is delivered, so a @throwTo@
-- that has not returned is a cancellation that has not been delivered.
--
-- What that fixes for later slices: cancelling a task that is inside Lua is a
-- rejected path. A supervisor that must reclaim a running task needs something
-- other than an asynchronous exception -- a hook Lua itself consults, or a
-- process boundary. Both are later slices' work; that they will be needed is
-- this example's finding.
--
-- The second is requirement 8's independent-progress proof, and it is here
-- because it needs an RTS option this suite cannot have: exactly one
-- capability. That is what makes the claim falsifiable. Under one capability a
-- Haskell thread can run during a foreign call only if the call released the
-- capability; if @lua_pcall@ were imported @unsafe@ it would not, and the count
-- taken at the end of the chunk's first block of pure Lua would be zero. With
-- the suite's own two capabilities the same example passes either way.
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
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  )
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "hazard" $ do
  it "cannot cancel a thread that is inside Lua, and says so from a child process" $
    withHazard ["uninterruptible-lua"] EndedByTheSuite $ \reported status → do
      reported `shouldContain` "HAZARD uninterrupted"
      -- It could not end itself: its only remaining thread is inside Lua.
      status `shouldNotBe` ExitSuccess
      if "attempts=" `isInfixOf` reported
        then pure ()
        else throwIO (userError ("the report named no attempt count: " <> reported))

  it "lets Haskell progress inside a Lua computation on a one-capability runtime" $
    -- -N1 overrides the executable's own -with-rtsopts=-N2, which is the whole
    -- point: with a second capability the other thread could have run there
    -- instead, and the example would prove nothing about the foreign call.
    withHazard ["capability-release", "+RTS", "-N1", "-RTS"] EndsItself $ \reported status → do
      reported `shouldContain` "HAZARD progressed"
      reported `shouldContain` "baseline=0"
      status `shouldBe` ExitSuccess
      counted reported

-- | Assert that the child counted substantial Haskell progress inside the
-- chunk's first block of pure Lua.
--
-- Zero would mean the capability was never released. The threshold is not a
-- latency claim: it separates a thread that ran for the length of a
-- four-million-iteration Lua loop from the handful of instructions between the
-- handshake callback reading the counter and returning into C, which is the
-- only other window in which the count could move.
counted ∷ String → Expectation
counted reported = case lookup "during-first-block" (fields reported) of
  Nothing → expectationFailure ("the report named no count: " <> reported)
  Just value → case reads value of
    [(progress ∷ Int, "")]
      | progress >= 1000 → pure ()
      | otherwise →
          expectationFailure
            ("Haskell made no real progress inside the Lua block: " <> reported)
    _ → expectationFailure ("the count was not a number: " <> reported)
  where
    fields = map (fmap (drop 1) . break (== '=')) . words

-- | Whether a mode can end its own process.
data Ending
  = -- | It returns from @main@; the suite waits for it.
    EndsItself
  | -- | Its only remaining thread is inside Lua, so the suite ends it and the
    -- exit status is the evidence that it had to.
    EndedByTheSuite

-- | Run one hazard mode, read its report, and hand it and the exit status to
-- the example.
withHazard ∷ [String] → Ending → (String → ExitCode → Expectation) → Expectation
withHazard arguments ending check = do
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
          case ending of
            EndsItself → pure ()
            EndedByTheSuite → terminateProcess handle
          status ← bounded (waitForProcess handle)
          check reported status
