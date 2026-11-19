-- | The capability count of a suite's multi-capability pass: one documented setting, its validation, and the guard that makes
-- the pass fail by itself when fewer capabilities are in force than it claims. Shared by the suites that run such a pass
-- (@terrain-runtime-tests@ and @lua-engine-tests@).
--
-- A suite's concurrent examples run twice: once on one capability, as they always did, and once more, last, on
-- 'defaultPassCapabilities' capabilities (the repository's @-N2@ convention), so that two threads of one example can execute at
-- the same instant. The count is one setting, read from, in this order:
--
-- 1. the environment variable 'passEnvironmentVariable', when it is set (a whole number from 2 to 1024; anything else, the empty
--    string included, is refused, and so is a count below 2);
-- 2. otherwise the capability count the process started with, when it is 2 or more: @+RTS -N4 -RTS@ is how the lab's
--    @quruntul flake --rts-capabilities 4@ asks for it, and it sets /this pass's/ count and nothing else (the sequential and the
--    measurement phases return to one capability by their own guards);
-- 3. otherwise 'defaultPassCapabilities'.
--
-- A started count of 1 is the runtime's default and cannot be told from an explicit @-N1@, so it selects the default of 2; the
-- control of the suite's own documentation is how @-N1@ is observed to fail.
--
-- 'inPass' is the guard: before and after each example of the pass it sets the capability count to the pass's and fails the
-- example when the runtime does not report that count (a non-threaded runtime never does). It sleeps nowhere, starts no thread
-- and reads no clock.
module Test.Support.Capabilities
  ( PassSetting (..)
  , PassSource (..)
  , passEnvironmentVariable
  , defaultPassCapabilities
  , minimumPassCapabilities
  , maximumPassCapabilities
  , resolvePass
  , resolvePassFromEnvironment
  , passLine
  , enterPass
  , inPass
  ) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Monad (when)
import Data.Char (isDigit)
import GHC.Conc (getNumProcessors)
import System.Environment (lookupEnv)
import Test.Hspec (expectationFailure)

-- | Where the pass's count came from.
data PassSource = FromEnvironment | FromRtsOption | FromDefault
  deriving (Eq, Show)

-- | The pass's requested capability count and where it came from.
data PassSetting = PassSetting
  { passRequested ∷ Int
  , passSource ∷ PassSource
  , passStartedWith ∷ Int
  }
  deriving (Eq, Show)

-- | The environment variable that overrides the count.
passEnvironmentVariable ∷ String
passEnvironmentVariable = "HETOIMASIA_CONCURRENT_PASS_CAPABILITIES"

-- | The count when nothing says otherwise: the repository's @-N2@ convention.
defaultPassCapabilities ∷ Int
defaultPassCapabilities = 2

-- | A pass on fewer than two capabilities proves nothing a single capability does not.
minimumPassCapabilities ∷ Int
minimumPassCapabilities = 2

-- | The largest count accepted: a larger one is a typing mistake, not a machine.
maximumPassCapabilities ∷ Int
maximumPassCapabilities = 1024

-- | The setting for an environment value and the count the process started with; 'Left' names the refusal. Pure.
resolvePass ∷ Maybe String → Int → Either String PassSetting
resolvePass (Just text) started = do
  n ← parseCount ("the environment variable " <> passEnvironmentVariable) text
  pure (PassSetting n FromEnvironment started)
resolvePass Nothing started
  | started >= minimumPassCapabilities = do
      n ← checkRange "the started capability count (+RTS -N)" started
      pure (PassSetting n FromRtsOption started)
  | otherwise = pure (PassSetting defaultPassCapabilities FromDefault started)

parseCount ∷ String → String → Either String Int
parseCount what text
  | null text || not (all isDigit text) || length text > 6 =
      Left (what <> " must be a whole number from " <> show minimumPassCapabilities <> " to " <> show maximumPassCapabilities <> ", not " <> show text)
  | otherwise = checkRange what (read text)

checkRange ∷ String → Int → Either String Int
checkRange what n
  | n < minimumPassCapabilities = Left (what <> " is " <> show n <> ": a multi-capability pass needs at least " <> show minimumPassCapabilities)
  | n > maximumPassCapabilities = Left (what <> " is " <> show n <> ": more than " <> show maximumPassCapabilities)
  | otherwise = Right n

-- | 'resolvePass' for this process: the variable's value and the count it started with, which the caller reads before anything
-- changes it.
resolvePassFromEnvironment ∷ Int → IO (Either String PassSetting)
resolvePassFromEnvironment started = (`resolvePass` started) <$> lookupEnv passEnvironmentVariable

-- | The line a suite prints once, when its pass begins: the requested count and its source, the count in force, and the
-- processors (a count above them is time-sliced, not simultaneous).
passLine ∷ PassSetting → IO String
passLine setting = do
  effective ← getNumCapabilities
  processors ← getNumProcessors
  pure
    ( "PASS multi-capability: requested=" <> show (passRequested setting) <> " (" <> sourceText (passSource setting) <> ") effective="
        <> show effective <> " (at start " <> show (passStartedWith setting) <> ", processors " <> show processors <> ")"
    )

sourceText ∷ PassSource → String
sourceText FromEnvironment = passEnvironmentVariable
sourceText FromRtsOption = "+RTS -N"
sourceText FromDefault = "default"

-- | Set the pass's capability count and fail unless the runtime reports exactly it.
enterPass ∷ PassSetting → IO ()
enterPass setting = do
  setNumCapabilities (passRequested setting)
  effective ← getNumCapabilities
  when (effective /= passRequested setting) $
    expectationFailure
      ( "the multi-capability pass claims " <> show (passRequested setting) <> " capabilities but " <> show effective
          <> " are in force (a non-threaded runtime cannot run it)"
      )

-- | The pass's guard around one example: enter the pass before it, and fail the example when the count was lowered while it ran.
inPass ∷ PassSetting → IO () → IO ()
inPass setting example = do
  enterPass setting
  example
  effective ← getNumCapabilities
  when (effective /= passRequested setting) $
    expectationFailure
      ("the multi-capability pass claims " <> show (passRequested setting) <> " capabilities but " <> show effective <> " were in force at the end of the example")
