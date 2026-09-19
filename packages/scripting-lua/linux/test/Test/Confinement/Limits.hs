-- | The two limits the parent owns: how much the child may allocate, and how
-- long it may run.
--
-- Requirements 5 and 6.
--
-- The memory ceiling is an address-space limit installed before the child
-- execs, so it covers the Lua allocator, ordinary native allocation, and the
-- Haskell runtime together rather than any one of them. What it measures is
-- virtual address space, which is why the child is built with a bounded runtime
-- reservation: an unbounded one would exhaust the ceiling before @main@ ran and
-- the experiment would be about startup. The accounting that follows from that
-- choice -- reservations counted, resident size not, swap not separately -- is
-- the verdict's to record, and this example's job is only to establish that the
-- ceiling is reached and that reaching it is terminal.
--
-- The execution bound is not a property the child has; it is one the parent
-- enforces. The child holds @SIGTERM@ and then enters a chunk that never
-- yields, which LUA-1 established cannot be interrupted from Haskell, so the
-- cooperative request provably cannot end it and the escalation is the path
-- actually exercised. The grace period below is the configured bound of that
-- escalation, not a sleep standing in for coordination: every other wait in
-- this suite is a handshake, and this one is the thing under test.
module Test.Confinement.Limits (spec) where

import Control.Concurrent (threadDelay)
import Test.Confinement.Support
  ( Availability
  , Environment
  , Confined
  , Controls
  , Launch (launchMemoryLimit, launchRoot)
  , Ledger
  , admittedOwners
  , announce
  , awaitReady
  , collect
  , describeStatus
  , fieldIn
  , forceStop
  , launchFor
  , observationsIn
  , observationKind
  , observeExit
  , outputClosed
  , releaseAfter
  , requestStop
  , stillRunning
  , whenAvailable
  , withLaunch
  , withRoot
  )
import System.Exit (ExitCode (ExitFailure))
import System.Posix.Process (ProcessStatus (Exited, Terminated))
import System.Posix.Signals (Signal, sigKILL)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

-- | How much address space the memory experiment's child may have.
--
-- Small enough that a modest Lua workload reaches it in seconds, large enough
-- that the child can start at all. Starting is not free under an address-space
-- ceiling: the runtime's bounded reservation, the shared libraries, and eight
-- megabytes of reserved stack for every thread the threaded runtime creates all
-- come out of it before `main` runs, and a ceiling that fits the workload but
-- not the startup measures the startup.
ceilingBytes ∷ Integer
ceilingBytes = 1024 * 1024 * 1024

-- | The status the child exits with once it has observed its own refusal.
memoryRefusedStatus ∷ Int
memoryRefusedStatus = 20

-- | How long the parent waits for a cooperative stop before escalating.
graceMicroseconds ∷ Int
graceMicroseconds = 750000

-- | The signal the escalation ends with, and the one the example requires to
-- have been the cause of death.
forceSignal ∷ Signal
forceSignal = sigKILL

spec ∷ Ledger → Controls → [FilePath] → Environment → Availability → Spec
spec ledger available sentinels machine installed = describe "limits" $ do
  it "enforces one whole-process memory ceiling over Lua, native, and runtime allocation" $
    whenAvailable machine installed "whole-process-memory" $
      withRoot $ \root → do
        let request =
              (launchFor "memory" root available sentinels "hetoimasia-confine-memory")
                { launchRoot = root
                , launchMemoryLimit = ceilingBytes
                }
        withLaunch ledger request $ \outcome → case outcome of
          Left _ →
            expectationFailure
              "the profile installed for the trial child but refused the memory experiment"
          Right child → do
            reported ← collect child
            status ← releaseAfter ledger child
            case [entry | entry ← observationsIn reported, observationKind entry == "MEMORY"] of
              [] → expectationFailure ("the child reported no memory outcome: " <> show reported)
              (memory : _) → do
                let lua = fieldIn "lua" memory
                    native = fieldIn "native-errno" memory
                    installedCeiling = fieldIn "address-space" memory
                -- The ceiling was really installed: a child that reported none
                -- would be reporting about a workload that simply finished.
                installedCeiling `shouldBe` show ceilingBytes
                -- And it was really reached, by at least one of the two
                -- allocators the requirement names.
                if lua == "refused" || native /= "0"
                  then pure ()
                  else
                    expectationFailure
                      ( "neither Lua nor native allocation was refused under a "
                          <> show ceilingBytes
                          <> " byte ceiling: "
                          <> show reported
                      )
                -- Reaching it is terminal for the child, and the parent's
                -- evidence for that is the exit status it observed.
                status `shouldBe` Exited (ExitFailure memoryRefusedStatus)
                announce
                  ( "PROVED whole-process-memory ceiling="
                      <> show ceilingBytes
                      <> " measures=address-space lua="
                      <> lua
                      <> " native-errno="
                      <> native
                      <> " surfaced-as=allocation-failure terminal="
                      <> describeStatus status
                  )

  it "ends a child that never yields, through the escalation the profile uses" $
    whenAvailable machine installed "execution-bound" $
      withRoot $ \root → do
        let request =
              (launchFor "spin" root available sentinels "hetoimasia-confine-spin")
                {launchRoot = root}
        withLaunch ledger request $ \outcome → case outcome of
          Left _ →
            expectationFailure
              "the profile installed for the trial child but refused the execution experiment"
          Right child → do
            -- The chunk is running: the child said so from inside it.
            _ ← awaitReady child
            (escalated, status) ← enforce child
            owners ← releaseAfter ledger child >> admittedOwners ledger
            owners `shouldBe` []
            -- The escalation is the claim, so it is asserted rather than
            -- recorded. A child that the cooperative request had ended would
            -- leave the path this example exists to exercise unexercised, and
            -- an example that accepted that outcome would pass without it.
            escalated `shouldBe` True
            -- The confined process, not just the supervisor: its output
            -- reaches end-of-file only once nothing holds the far end.
            drained ← outputClosed child
            drained `shouldBe` True
            -- And termination by the force signal specifically, observed
            -- rather than inferred from a signal having been sent.
            status `shouldBe` Terminated forceSignal False
            announce
              ( "PROVED execution-bound reason=deadline-exceeded grace-microseconds="
                  <> show graceMicroseconds
                  <> " escalated="
                  <> (if escalated then "yes" else "no")
                  <> " confined-process-gone=yes"
                  <> " observed="
                  <> describeStatus status
              )

-- | Ask the child to stop, wait out the configured bound, then end it.
--
-- Answers whether the escalation was needed and the termination the parent
-- observed. The wait is the bound itself; nothing here concludes anything from
-- how long the child took, only from whether it was still there afterwards.
enforce ∷ Confined → IO (Bool, ProcessStatus)
enforce child = do
  requestStop child
  threadDelay graceMicroseconds
  remaining ← stillRunning child
  if remaining
    then do
      forceStop child
      status ← observeExit child
      pure (True, status)
    else do
      status ← observeExit child
      pure (False, status)
