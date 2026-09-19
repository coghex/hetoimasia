-- | The Linux confinement probe's entry point.
--
-- The fixtures, the controls, the environment record, and the one trial launch
-- that establishes whether the candidate profile installs on this machine all
-- happen here, before any example runs, because every example is written
-- against them and none of them is an example's to create. The host sentinels
-- in particular have to outlive the whole run: they are the files the confined
-- children must not be able to read, and a fixture that vanished half way
-- through would turn the second half of the suite into a report about absence.
module Main (main) where

import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.IO.Temp (withSystemTempDirectory)
import qualified Test.Confinement.Spec
import Test.Confinement.Support
  ( availability
  , controls
  , environment
  , newLedger
  , reportedLines
  )
import Test.Hspec (hspec)

main ∷ IO ()
main =
  withSystemTempDirectory "hetoimasia-confine-fixtures" $ \directory → do
    hSetBuffering stdout LineBuffering
    let sentinels = [directory </> "alpha-sentinel", directory </> "beta-sentinel"]
    mapM_ (\path → writeFile path "a host file no confined child may read\n") sentinels
    ledger ← newLedger
    available ← controls sentinels
    machine ← environment
    installed ← availability ledger available sentinels
    -- The trial child's own report, verbatim and before any example reads it.
    -- Requirement 8 asks for retained evidence, and the examples below quote
    -- this report rather than reproducing it: without it a reader of a CI log
    -- would have the conclusions and not the observations.
    mapM_ (\line → putStrLn ("TRIAL " <> line)) (reportedLines installed)
    hspec (Test.Confinement.Spec.spec ledger available sentinels machine installed)
