-- | What the harness was asked to do, decided before it does anything.
--
-- Two modes, and the difference between them is what may be written
-- afterwards. The headless mode runs the pure examples and writes no record,
-- so selecting a subset of them is harmless and useful. The native mode opens
-- a session and writes a compatibility record carrying a verdict, and that
-- verdict is the record's own claim about the whole contract.
--
-- So the native mode takes no test options at all. A selector such as
-- @--match@ would run a subset of the examples and still have its result
-- written as the verdict for all of them: a run that stopped could be recorded
-- as @Verdict: pass@ because the examples that would have caught it were never
-- selected. Refusing is better than ignoring, because a caller who passed one
-- is told rather than quietly given something else.
--
-- This is a pure function of the argument list so that
-- "Test.Vulkan.Proof.InvocationSpec" can hold it to that, headlessly.
module Test.Vulkan.Proof.Invocation
  ( Mode (..)
  , headlessFlag
  , selectMode
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | The flag that selects the headless examples and nothing else. It is this
-- harness's own, so it is taken out of the arguments before Hspec's runner
-- sees them rather than left for it to reject.
headlessFlag ∷ String
headlessFlag = "--headless"

data Mode
  = Headless [String]
    -- ^ The pure examples, with whatever Hspec options were passed alongside.
    -- No consent is read, no session is opened, and no record is written.
  | Native
    -- ^ The whole native procedure, and the complete spec, and a record.
  | Refused Text
    -- ^ Nothing is run. The text says what was passed and what to pass
    -- instead.
  deriving (Eq, Show)

selectMode ∷ [String] → Mode
selectMode arguments
  | headlessFlag `elem` arguments = Headless (filter (/= headlessFlag) arguments)
  | null arguments = Native
  | otherwise =
      Refused
        ( "the native run takes no test options, and was given "
            <> Text.unwords (map Text.pack arguments)
            <> ". Its record carries a verdict for the whole contract, so a"
            <> " selector that ran a subset of the examples would still be"
            <> " written as a verdict for all of them — a run that stopped"
            <> " could be recorded as a pass because what would have caught it"
            <> " was never selected. Pass --headless to select the release"
            <> " decision's own examples; those write no record."
        )
