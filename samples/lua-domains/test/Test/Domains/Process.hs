-- | The executable run as a child process (requirement 13): its report, @--help@ and its exit statuses.
-- It is reached through this suite's @build-tool-depends@ on it, the only way anything launches it,
-- and each child is bounded.
module Test.Domains.Process (spec) where

import Data.List (isPrefixOf)
import qualified Data.Text as Text
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Domains.Support (generous)
import Test.Hspec

run ∷ [String] → IO (ExitCode, String, String)
run arguments = do
  executable ← findExecutable "hetoimasia-lua-domains" >>= maybe (fail "the executable is not on this test's search path") pure
  generous (readCreateProcessWithExitCode (proc executable arguments) "")

spec ∷ Spec
spec = describe "the executable" $ do
  it "runs a session, exits 0 and writes one bounded report on stdout and nothing on stderr" $ do
    (status, out, err) ← run ["--ticks", "20", "--seed", "1"]
    status `shouldBe` ExitSuccess
    err `shouldBe` ""
    let reported = lines out
    length reported `shouldBe` 6
    take 1 reported `shouldBe` ["hetoimasia-lua-domains: session 1, seed 1"]
    reported !! 1 `shouldBe` "ticks committed: 20"
    let accepted = numberAfter "accepted " (reported !! 2)
        applied = numberAfter "applied " (reported !! 3)
        stale = numberAfter "stale " (reported !! 3)
    -- Every accepted intention is accounted for, and none is left.
    accepted `shouldBe` applied + stale
    reported !! 5 `shouldBe` "intentions pending: 0"
    numberAfter "ui updates: " (reported !! 4) `shouldSatisfy` (>= 0)

  it "commits the ticks it is asked for, at the seed it is asked for" $ do
    (status, out, _) ← run ["--ticks", "3", "--seed", "99"]
    status `shouldBe` ExitSuccess
    take 2 (lines out) `shouldBe` ["hetoimasia-lua-domains: session 1, seed 99", "ticks committed: 3"]

  it "prints the usage on stdout for --help and exits 0" $ do
    (status, out, err) ← run ["--help"]
    status `shouldBe` ExitSuccess
    err `shouldBe` ""
    take 1 (lines out) `shouldBe` ["usage: hetoimasia-lua-domains [--ticks N] [--seed N] | --help"]

  mapM_
    usageError
    [ ("an unknown argument", ["--bogus"], "unknown argument '--bogus'")
    , ("a malformed ticks value", ["--ticks", "many"], "malformed value 'many' for --ticks")
    , ("a malformed seed value", ["--seed", "-3"], "malformed value '-3' for --seed")
    , ("a missing value", ["--ticks"], "missing value after --ticks")
    , ("a repeated option", ["--ticks", "2", "--ticks", "3"], "repeated option --ticks")
    ]

  it "escapes a forged argument, so the one line on stderr stays one line" $ do
    (status, out, err) ← run ["--x\nusage: forged"]
    status `shouldBe` ExitFailure 2
    out `shouldBe` ""
    length (lines err) `shouldBe` 1
    err `shouldSatisfy` ("hetoimasia-lua-domains: unknown argument '--x\\x0ausage: forged'" `isPrefixOf`)
  where
    numberAfter marker text =
      let rest = snd (breakOn marker (Text.pack text))
       in read (Text.unpack (Text.takeWhile (`elem` ['0' .. '9']) (Text.drop (length marker) rest))) ∷ Int
    breakOn marker = Text.breakOn (Text.pack marker)
    usageError (label, arguments, reason) = it ("exits 2 for " <> label <> ", with one line on stderr and nothing on stdout") $ do
      (status, out, err) ← run arguments
      status `shouldBe` ExitFailure 2
      out `shouldBe` ""
      length (lines err) `shouldBe` 1
      err `shouldSatisfy` (("hetoimasia-lua-domains: " <> reason) `isPrefixOf`)
