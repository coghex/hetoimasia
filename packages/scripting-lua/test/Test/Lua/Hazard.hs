-- | Fast foreign-call progress and allocation-failure contracts.
-- The deliberate nontermination experiment lives in lua-hazard-probes.
--
-- The separate mode @callback-cancellation@ is a diagnostic rather than an
-- example. It cancels callback threads, which the contract does not support --
-- a callback thread is the runtime's machinery, not an endpoint an owner
-- addresses -- and it ends this process some of the time, which is the evidence
-- for saying so. It is kept runnable by hand and is not asserted on here,
-- because an example that accepts either outcome asserts nothing. The supported
-- cancellation, of a VM's execution owner, is exercised in
-- "Test.Lua.Faults".
--
-- The allocation-failure example exercises the publication path under memory
-- exhaustion. It needs an allocator that fails on demand; the binding exports no
-- way to install from Haskell.
--
-- The progress example is requirement 8's independent-progress proof. It needs
-- an RTS option this suite cannot have: exactly one
-- capability. That is what makes the claim falsifiable. Under one capability a
-- Haskell thread can run during a foreign call only if the call released the
-- capability; if @lua_pcall@ were imported @unsafe@ it would not, and the count
-- taken at the end of the chunk's first block of pure Lua would be zero. With
-- the suite's own two capabilities the same example passes either way.
module Test.Lua.Hazard (spec) where

import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (BufferMode (LineBuffering), hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (env, std_out)
  , StdStream (CreatePipe)
  , proc
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
  )
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "hazard" $ do
  it "lets Haskell progress inside a Lua computation on a one-capability runtime" $
    -- -N1 overrides the executable's own -with-rtsopts=-N2, which is the whole
    -- point: with a second capability the other thread could have run there
    -- instead, and the example would prove nothing about the foreign call.
    withHazard ["capability-release", "+RTS", "-N1", "-RTS"] $ \reported status → do
      reported `shouldContain` "HAZARD progressed"
      reported `shouldContain` "samples=2"
      status `shouldBe` ExitSuccess
      grew reported

  it "reports memory exhaustion on every protected path instead of dying of it" $
    withHazard ["allocation-failure"] $ \reported status → do
      -- Publishing a callback, reading a global, and opening a standard library
      -- each replaced a binding wrapper that allocated its arguments before
      -- entering its own protected call. Each is starved at every point along
      -- it, and each has to answer rather than end the process.
      reported `shouldContain` "HAZARD allocation-swept"
      refusedAndMade reported "publish"
      refusedAndMade reported "lookup"
      refusedAndMade reported "library"
      -- A refusal is Lua's own memory status and not something else; the shim
      -- leaves exactly one value either way; the state still works afterwards.
      reported `shouldContain` "statuses=all-memory"
      reported `shouldContain` "stack=balanced"
      reported `shouldContain` "state=usable"
      -- And for publication alone: a failed attempt leaves the state fit to
      -- publish to again, and carriers are finalized exactly as often as they
      -- were acquired.
      reported `shouldContain` "retries=all-accepted"
      reported `shouldContain` "finalization=exact"
      status `shouldBe` ExitSuccess

-- | Assert that a swept path was both refused and completed at some budget.
--
-- Neither alone would mean anything: a path that is never refused was never
-- starved, and one that never completes was starved past the point the sweep is
-- about.
refusedAndMade ∷ String → String → Expectation
refusedAndMade reported path = do
  positive (path <> "-refused")
  positive (path <> "-made")
  where
    fields = map (fmap (drop 1) . break (== '=')) (words reported)
    positive key = case lookup key fields of
      Just value | [(count ∷ Int, "")] ← reads value, count > 0 → pure ()
      _ →
        expectationFailure
          ("the sweep reported no " <> key <> " in: " <> reported)

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

-- | Run one hazard mode, read its report, and hand it and the exit status to
-- the example.
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
          status ← bounded (waitForProcess handle)
          check reported status
