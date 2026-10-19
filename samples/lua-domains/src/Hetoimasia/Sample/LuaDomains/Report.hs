-- | The headless session's one bounded report on stdout (requirement 13): the ticks committed, the
-- intentions by answer and by disposition, and the UI's update count.
--
-- The report is six lines, each a fixed label and numbers, so its size does not depend on the
-- session. It is the only thing the executable writes to stdout.
module Hetoimasia.Sample.LuaDomains.Report
  ( renderReport
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains.Domains (SessionReport (..))
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..))

-- | The report's lines.
renderReport ∷ SessionReport → [Text]
renderReport report =
  [ "hetoimasia-lua-domains: session " <> number (reportSession report) <> ", seed " <> number (reportSeed report)
  , "ticks committed: " <> number (reportTicks report)
  , "intentions answered: accepted " <> number (countAccepted counts) <> ", full " <> number (countFull counts) <> ", closed " <> number (countClosed counts) <> ", refused " <> number (countRefused counts) <> ", malformed " <> number (countMalformed counts)
  , "intentions settled: applied " <> number (countApplied counts) <> ", stale " <> number (countStale counts)
  , "ui updates: " <> number (reportUiUpdates report)
  , "intentions pending: 0"
  ]
  where
    counts = reportCounts report
    number ∷ Show a ⇒ a → Text
    number = Text.pack . show
