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
      reported `shouldContain` "samples=2"
      status `shouldBe` ExitSuccess
      grew reported

  it "survives callback threads cancelled repeatedly while Lua is calling them" $
    withHazard ["callback-cancellation"] EndsItself $ \reported status → do
      reported `shouldContain` "HAZARD callbacks-survived"
      -- The failure this guards against is a process that is no longer there
      -- to report anything, so the exit status carries as much as the line.
      status `shouldBe` ExitSuccess

-- | Assert that the counter grew between the hook's two samples.
--
-- Both are taken from inside Lua's instruction loop with nothing but Lua
-- instructions between them, so growth there happened while Lua was executing
-- and not inside a callback. The criterion is that they differ, not that they
-- differ by some amount: how much they differ is throughput, and this is not a
-- claim about throughput. Equal samples would mean no Haskell thread ran
-- between two points inside the foreign call, which is what an `unsafe` import
-- would produce.
grew ∷ String → Expectation
grew reported = case (number "first", number "second") of
  (Just first, Just second)
    | second > first → pure ()
    | otherwise →
        expectationFailure
          ("no Haskell progress between two samples taken inside Lua: " <> reported)
  _ → expectationFailure ("the report named no pair of samples: " <> reported)
  where
    fields = map (fmap (drop 1) . break (== '=')) (words reported)
    number key = case lookup key fields of
      Just value | [(parsed ∷ Int, "")] ← reads value → Just parsed
      _ → Nothing

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
