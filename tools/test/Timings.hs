-- | Hspec coverage for the run-timing report.
--
-- The report never decides a verdict, so the contract worth holding is that it
-- renders what GitHub supplied and says so plainly when a job's timings are
-- not available yet, rather than inventing a duration for a job still running.
module Timings (spec) where

import Sandbox (run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain)

spec ∷ Spec
spec = describe "Run timings" $ do
  it "renders queue, setup, and execution time for a finished job" $
    withListing listing $ \(result, output, _) → do
      result `shouldBe` ExitSuccess
      output `shouldContain` "| plan |"
      output `shouldContain` "success"
      -- Queued 20s, a 5s setup step, and 55s of work inside the 60s the job ran.
      output `shouldContain` "| 20s | 5s | 55s | 1m20s |"

  it "reports an unfinished job as unavailable rather than as a duration" $
    withListing listing $ \(_, output, _) →
      output `shouldContain` "| haskell-engine | in_progress | 10s | — | — | — |"

withListing ∷ String → ((ExitCode, String, String) → IO a) → IO a
withListing document action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-timings" $ \directory → do
    writeFixtureFile directory "jobs.json" document
    outcome ←
      run
        settings
        directory
        "python3"
        [checkout </> "tools/validation/timings.py", "--jobs", directory </> "jobs.json"]
    action outcome

listing ∷ String
listing =
  unlines
    [ "{"
    , "  \"total_count\": 2,"
    , "  \"jobs\": ["
    , "    {"
    , "      \"name\": \"plan\","
    , "      \"status\": \"completed\","
    , "      \"conclusion\": \"success\","
    , "      \"created_at\": \"2026-09-11T12:00:00Z\","
    , "      \"started_at\": \"2026-09-11T12:00:20Z\","
    , "      \"completed_at\": \"2026-09-11T12:01:20Z\","
    , "      \"steps\": ["
    , "        {"
    , "          \"name\": \"Set up job\","
    , "          \"started_at\": \"2026-09-11T12:00:20Z\","
    , "          \"completed_at\": \"2026-09-11T12:00:25Z\""
    , "        }"
    , "      ]"
    , "    },"
    , "    {"
    , "      \"name\": \"haskell-engine\","
    , "      \"status\": \"in_progress\","
    , "      \"conclusion\": null,"
    , "      \"created_at\": \"2026-09-11T12:01:00Z\","
    , "      \"started_at\": \"2026-09-11T12:01:10Z\","
    , "      \"completed_at\": null,"
    , "      \"steps\": []"
    , "    }"
    , "  ]"
    , "}"
    ]
