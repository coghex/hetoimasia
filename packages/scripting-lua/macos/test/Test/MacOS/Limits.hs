-- | The two enforced limits: whole-process memory, and execution time.
--
-- The memory example is bounded twice over on purpose. The workload has its own
-- finite ceiling, and the parent has its own external termination guard; both
-- are recorded separately from the mechanism under test, because a run that
-- ended because one of them fired is not evidence that the memory cap did
-- anything.
module Test.MacOS.Limits (spec) where

import Control.Monad (unless, void)
import Data.Word (Word64, Word8)
import Test.Hspec

import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( Exit (..)
  , LaunchFailure (..)
  , LaunchRequest (..)
  , Launched (..)
  , awaitExit
  , awaitExitWithin
  , awaitReady
  , awaitReport
  , awaitStreamEnd
  , collectReports
  , jetsamAvailable
  , jetsamFlags
  , launch
  , processGone
  , sendSignal
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Report (..))
import System.Posix.Signals (sigKILL)

import Test.MacOS.Driver

-- | The per-instance cap the memory experiment installs, in mebibytes.
admittedMiB ∷ Int
admittedMiB = 64

-- | The parent's external termination guard for the memory experiment. It is
-- far longer than the workload needs, so a guard that fires is a failure.
memoryGuardMicroseconds ∷ Int
memoryGuardMicroseconds = 60000000

spec ∷ SpecWith Fixture
spec = describe "enforced limits" $ do
  it "installs the whole-process memory limit itself, or refuses the launch" $ \fixture → do
    available ← jetsamAvailable
    available `shouldBe` True
    flags ← jetsamFlags
    refused ←
      launch
        LaunchRequest
          { requestExecutable = fixtureHelper fixture <> "-does-not-exist"
          , requestArguments = []
          , requestMemoryLimitMiB = admittedMiB
          }
    case refused of
      Left (LaunchRejected _) → pure ()
      other → expectationFailure ("a launch that cannot happen must refuse, got " <> show (void other))
    putStrLn
      ( "      proved: the spawn-time memory limit is installable here (flags 0x"
          <> showHex flags
          <> ") and a launch that cannot be made refuses rather than producing an unlimited child"
      )

  it "reaches its own ceiling with no limit installed, so the workload really does exceed the cap" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "grow" 0
    ready ← awaitReady launched guardMicroseconds
    ready `shouldBe` True
    status ← awaitExitWithin launched memoryGuardMicroseconds
    case status of
      Nothing → do
        void (sendSignal launched sigKILL)
        void (awaitExit launched)
        expectationFailure "the unlimited control never finished"
      Just observed → do
        reports ← completeReports launched
        observed `shouldBe` ExitedWith 0
        payloads reports `shouldBe` expectedPayloads
        ceilings reports `shouldBe` [(expectedLuaBytes, expectedNativeBytes, expectedTotalBytes)]
        putStrLn
          ( "      proved: unlimited, the same workload retained "
              <> showPayload expectedLuaBytes
              <> " of Lua payload and "
              <> showPayload expectedNativeBytes
              <> " of native payload ("
              <> showPayload expectedTotalBytes
              <> " total) and reached its own ceiling, which is above the "
              <> show admittedMiB
              <> " MiB cap the later example installs"
          )

  it "retains every completed step's native buffer, still live and distinct, at the ceiling" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "grow" 0
    ready ← awaitReady launched guardMicroseconds
    ready `shouldBe` True
    status ← awaitExitWithin launched memoryGuardMicroseconds
    case status of
      Nothing → do
        void (sendSignal launched sigKILL)
        void (awaitExit launched)
        expectationFailure "the retention workload never finished"
      Just observed → do
        reports ← completeReports launched
        observed `shouldBe` ExitedWith 0
        -- One reading, taken after a major collection, of every native buffer
        -- still live. The expected bytes are the workload's own step pattern,
        -- not a total read off the held counter.
        [(count, each, fills, sums) | Retained count each fills sums ← reports]
          `shouldBe` [(stepCount, nativeStepBytes, expectedFills, expectedSums)]
        putStrLn
          ( "      proved: after a major collection, one ceiling reading found "
              <> show stepCount
              <> " simultaneously live native buffers, oldest step first, each "
              <> show nativeStepBytes
              <> " materialized bytes and each a distinct fill, including the earliest step. This is not the held counter."
          )

  it "terminates the helper when its whole-process footprint crosses the installed cap" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "grow" admittedMiB
    ready ← awaitReady launched guardMicroseconds
    ready `shouldBe` True
    guarded ← awaitExitWithin launched memoryGuardMicroseconds
    case guarded of
      Nothing → do
        void (sendSignal launched sigKILL)
        void (awaitExit launched)
        expectationFailure
          "the external guard fired: guard-triggered termination is not evidence that the cap worked"
      Just observed → do
        reports ← completeReports launched
        -- The cap is fatal, so the violation is a kill the parent observes; it
        -- is never reported to the child as a failed allocation it could catch.
        observed `shouldBe` Signalled 9
        [() | Ceiling _ _ _ ← reports] `shouldBe` []
        gone ← processGone (launchedPid launched)
        gone `shouldBe` True
        let (lua, native, total) = lastPayload reports
            (footprint, virtualSize) = lastFootprint reports
        putStrLn
          ( "      proved: with a "
              <> show admittedMiB
              <> " MiB cap the helper was killed by signal 9. The last complete report, before termination, was "
              <> showPayload lua
              <> " of Lua payload and "
              <> showPayload native
              <> " of native payload ("
              <> showPayload total
              <> " total). That is a pre-termination observation, not a measurement at the kill. It was before the workload's own "
              <> show ceilingMiB
              <> " MiB ceiling and before the external guard. The ledger is the physical footprint ("
              <> showMiB footprint
              <> " MiB last reported), not address space ("
              <> showMiB virtualSize
              <> " MiB reserved by the threaded RTS) and not the payload counter."
          )

  it "records that no public address-space limit could have been installed instead" $ \fixture →
    case [(bytes, code) | RlimitFloor bytes code ← fixtureSweep fixture] of
      [] → expectationFailure "the helper reported no RLIMIT_AS measurement"
      ((bytes, code) : _) → do
        -- The public API is not merely unhelpful here: a cap anywhere near a
        -- mod budget is rejected outright, because the process already maps
        -- more than that before it runs a line of its own code.
        (fromIntegral bytes ∷ Integer) `shouldSatisfy` (> fromIntegral (admittedMiB * 1024 * 1024))
        putStrLn
          ( "      proved: the smallest installable RLIMIT_AS in the confined helper is "
              <> showMiB bytes
              <> " MiB, with errno "
              <> show code
              <> " below it, so the documented limit cannot express a "
              <> show admittedMiB
              <> " MiB budget at all"
          )

  it "enforces a granted execution budget on a helper that never yields, within its total bound" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0
    running ← awaitReport launched guardMicroseconds isFootprint
    running `shouldSatisfy` isJust'
    -- The budget really runs out: the parent waits out the granted time, finds
    -- the helper still running, and only then escalates. A helper that had
    -- stopped on its own would be reported as completed and fail this example.
    enforcement ← enforceExecutionBudget launched
    enforcementReason enforcement `shouldBe` "execution-budget-exceeded"
    [() | Done ← enforcementReports enforcement] `shouldBe` []
    gone ← processGone (launchedPid launched)
    gone `shouldBe` True
    let ceilingMicros =
          executionBudgetMicroseconds + escalationGraceMicroseconds + hardStopMicroseconds
    enforcementElapsedMicros enforcement `shouldSatisfy` (< ceilingMicros)
    case enforcementExit enforcement of
      Signalled signal →
        putStrLn
          ( "      proved: a helper spinning inside Lua outlived its granted "
              <> show (executionBudgetMicroseconds `div` 1000)
              <> " ms, so the parent recorded enforcement reason "
              <> show (enforcementReason enforcement)
              <> " and ended it by signal "
              <> show signal
              <> (if enforcementEscalated enforcement then " after escalation from SIGTERM" else " at the first signal")
              <> "; the status was reaped "
              <> show (enforcementElapsedMicros enforcement `div` 1000)
              <> " ms in, inside the "
              <> show (ceilingMicros `div` 1000)
              <> " ms total bound, and its output was read to end of file"
          )
      other → expectationFailure ("a helper inside Lua should end by signal, got " <> show other)
 where
  ceilingMiB = 256 ∷ Int

  isFootprint = \case
    Footprint _ _ → True
    _ → False

  isJust' = \case
    Just _ → True
    Nothing → False

-- | Everything a finished helper wrote, waited out rather than sampled.
completeReports ∷ Launched → IO [Report]
completeReports launched = do
  complete ← awaitStreamEnd launched guardMicroseconds
  unless complete (expectationFailure "the helper ended but its output never reached end of file")
  collectReports launched

-- | Payload of one completed step, in bytes. Lua is the string
-- 'hmp_grow_step' retains; native is the helper's buffer. Neither is read
-- from the helper's counter, and neither is the process footprint.
luaStepBytes ∷ Word64
luaStepBytes = 8 * 1024 * 1024

nativeStepBytes ∷ Word64
nativeStepBytes = 8 * 1024 * 1024

-- | The ceiling 'helperArguments' passes, in bytes.
ceilingBytes ∷ Word64
ceilingBytes = 256 * 1024 * 1024

stepCount ∷ Int
stepCount = fromIntegral (ceilingBytes `div` (luaStepBytes + nativeStepBytes))

expectedLuaBytes ∷ Word64
expectedLuaBytes = fromIntegral stepCount * luaStepBytes

expectedNativeBytes ∷ Word64
expectedNativeBytes = fromIntegral stepCount * nativeStepBytes

expectedTotalBytes ∷ Word64
expectedTotalBytes = expectedLuaBytes + expectedNativeBytes

expectedPayloads ∷ [(Word64, Word64, Word64)]
expectedPayloads =
  [ (k * luaStepBytes, k * nativeStepBytes, k * (luaStepBytes + nativeStepBytes))
  | k ← [1 .. fromIntegral stepCount]
  ]

-- | Fill byte of step 1, then step 2, and so on. Step 0 is not a step, so the
-- earliest retained buffer is fill 1.
expectedFills ∷ [Word8]
expectedFills = [1 .. fromIntegral stepCount]

expectedSums ∷ [Word64]
expectedSums = [fromIntegral fill * nativeStepBytes | fill ← expectedFills]

payloads ∷ [Report] → [(Word64, Word64, Word64)]
payloads reports = [(lua, native, total) | Held lua native total ← reports]

ceilings ∷ [Report] → [(Word64, Word64, Word64)]
ceilings reports = [(lua, native, total) | Ceiling lua native total ← reports]

lastPayload ∷ [Report] → (Word64, Word64, Word64)
lastPayload reports = case reverse (payloads reports) of
  [] → (0, 0, 0)
  (latest : _) → latest

showPayload ∷ Word64 → String
showPayload bytes =
  show (bytes `div` (1024 * 1024)) <> " MiB (" <> show bytes <> " bytes)"

lastFootprint ∷ [Report] → (Integer, Integer)
lastFootprint reports = case reverse [(a, b) | Footprint a b ← reports] of
  [] → (0, 0)
  ((footprint, virtualSize) : _) → (fromIntegral footprint, fromIntegral virtualSize)

showMiB ∷ Integral a ⇒ a → String
showMiB bytes = show (fromIntegral bytes `div` (1024 * 1024 ∷ Integer))

showHex ∷ Int → String
showHex value = case value of
  0 → "0"
  _ → go value ""
 where
  digits = "0123456789abcdef"
  go 0 acc = acc
  go n acc = go (n `div` 16) (digit (n `mod` 16) : acc)
  digit index = case drop index digits of
    (character : _) → character
    [] → '?'
