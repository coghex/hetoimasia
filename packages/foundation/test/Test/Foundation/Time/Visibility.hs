-- | Examples proving that time's types and arithmetic modules stay inside the
-- foundation package while its public module keeps every name it exports.
--
-- "Hetoimasia.Foundation.Time" re-exports its values from
-- "Hetoimasia.Foundation.Time.Types" and its validated conversions and
-- arithmetic from "Hetoimasia.Foundation.Time.Arithmetic", both hidden modules
-- of the foundation's main library. An example in this suite cannot observe that
-- boundary, so these examples compile separate single-module clients with the
-- harness from "Test.Support.ExternalClient", exposing @base@ and
-- @hetoimasia-foundation@ and hiding everything else, as the opacity examples
-- in "Test.Foundation.Time.Opacity" do.
--
-- One client must be accepted: it imports, by name, every name the public
-- module exports, with every constructor and record selector it exports and
-- the abstract types without theirs, so a removed name fails it. Each hidden
-- module is imported by a client of its own, so one refusal cannot mask the
-- other, and each must be refused with @GHC-87110@ against the main library's
-- own unit.
module Test.Foundation.Time.Visibility (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient (Client (..), Mode (..), withPackageClient)

spec ∷ Spec
spec = describe "Time module visibility across the package boundary" $ do
  it "accepts a client that imports every public time name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

  forM_ hidden $ \module' →
    it ("rejects a client that imports the hidden module " <> module') $
      withClient (importClient module') $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        -- Found in the main library and refused as hidden; naming that unit
        -- tells this apart from a missing module or an unresolvable package.
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation"] "Client.hs"

-- | The modules hidden inside the main library.
hidden ∷ [String]
hidden = ["Hetoimasia.Foundation.Time.Types", "Hetoimasia.Foundation.Time.Arithmetic"]

importClient ∷ String → String
importClient module' = unlines ["module Client () where", "", "import " <> module']

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Foundation.Time"
    , "  ( Duration"
    , "  , durationNanoseconds"
    , "  , zeroDuration"
    , "  , minimumPositiveDuration"
    , "  , maximumDuration"
    , "  , DurationRequirement (AllowZero, RequirePositive)"
    , "  , DurationRejected"
    , "      ( DurationNegative"
    , "      , DurationZero"
    , "      , DurationNotFinite"
    , "      , DurationBelowResolution"
    , "      , DurationAboveMaximum"
    , "      )"
    , "  , durationFromNanoseconds"
    , "  , SecondsConversion (SecondsConversion, convertedDuration, convertedRounding)"
    , "  , durationFromSeconds"
    , "  , Instant"
    , "  , scriptedInstant"
    , "  , TimeOverflow (TimeOverflow)"
    , "  , addDuration"
    , "  , addDurations"
    , "  , elapsedBetween"
    , "  , remainingUntil"
    , "  , deadlineReached"
    , "  , MonotonicSource"
    , "  , monotonicSource"
    , "  , scriptedSource"
    , "  , readInstant"
    , "  , timeComponent"
    , "  , readClockOperation"
    , "  , ElapsedBaseline"
    , "  , noBaseline"
    , "  , baselineInstant"
    , "  , advanceBaseline"
    , "  , sampleElapsed"
    , "  )"
    ]
