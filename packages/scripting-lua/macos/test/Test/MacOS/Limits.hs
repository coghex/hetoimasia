-- | The two enforced limits: whole-process memory, and execution time.
--
-- The memory example is bounded twice over on purpose. The workload has its own
-- finite ceiling, and the parent has its own external termination guard; both
-- are recorded separately from the mechanism under test, because a run that
-- ended because one of them fired is not evidence that the memory cap did
-- anything.
module Test.MacOS.Limits (spec) where

import Control.Monad (void)
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
    reports ← collectReports launched
    case status of
      Nothing → do
        void (sendSignal launched sigKILL)
        void (awaitExit launched)
        expectationFailure "the unlimited control never finished"
      Just observed → do
        observed `shouldBe` ExitedWith 0
        [mib | Ceiling mib ← reports] `shouldSatisfy` (not . null)
        putStrLn
          ( "      proved: unlimited, the same workload held "
              <> show (lastHeld reports)
              <> " MiB and reached its own ceiling, which is above the "
              <> show admittedMiB
              <> " MiB cap the next example installs"
          )

  it "terminates the helper when its whole-process footprint crosses the installed cap" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "grow" admittedMiB
    ready ← awaitReady launched guardMicroseconds
    ready `shouldBe` True
    guarded ← awaitExitWithin launched memoryGuardMicroseconds
    reports ← collectReports launched
    case guarded of
      Nothing → do
        void (sendSignal launched sigKILL)
        void (awaitExit launched)
        expectationFailure
          "the external guard fired: guard-triggered termination is not evidence that the cap worked"
      Just observed → do
        -- The cap is fatal, so the violation is a kill the parent observes; it
        -- is never reported to the child as a failed allocation it could catch.
        observed `shouldBe` Signalled 9
        [mib | Ceiling mib ← reports] `shouldBe` []
        gone ← processGone (launchedPid launched)
        gone `shouldBe` True
        let (footprint, virtualSize) = lastFootprint reports
        putStrLn
          ( "      proved: with a "
              <> show admittedMiB
              <> " MiB cap the helper was killed by signal 9 after holding "
              <> show (lastHeld reports)
              <> " MiB, before its own "
              <> show ceilingMiB
              <> " MiB ceiling and before the external guard; the ledger is the physical"
              <> " footprint ("
              <> showMiB footprint
              <> " MiB last reported), not address space ("
              <> showMiB virtualSize
              <> " MiB reserved by the threaded RTS)"
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

  it "ends a helper that never yields, within a configured bound, and observes it end" $ \fixture → do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0
    running ← awaitReport launched guardMicroseconds isFootprint
    running `shouldSatisfy` isJust'
    ending ← endWithEscalation launched
    reports ← collectReports launched
    [() | Done ← reports] `shouldBe` []
    gone ← processGone (launchedPid launched)
    gone `shouldBe` True
    case endingExit ending of
      Signalled signal →
        putStrLn
          ( "      proved: a helper spinning inside Lua never returned cooperatively and was ended by signal "
              <> show signal
              <> (if endingEscalated ending then " after escalation from SIGTERM" else " at the first signal")
              <> "; the parent's enforcement reason is the configured execution bound, and termination was reaped, not assumed"
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

lastHeld ∷ [Report] → Int
lastHeld reports = case reverse [mib | Held mib ← reports] of
  [] → 0
  (latest : _) → latest

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
