-- | Examples proving that 'Hetoimasia.Foundation.Time.Instant',
-- 'Hetoimasia.Foundation.Time.Duration', and the elapsed baseline can be built
-- only through the public constructors, from clients outside the foundation
-- package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@ and @hetoimasia-foundation@ and
-- hiding everything else.
--
-- Seven clients must be rejected, each for the specific diagnostic naming its
-- cause, so a missing package, an absent compiler, or an unrelated error can
-- never pass for the boundary holding: naming the instant, duration, or
-- baseline constructor; coercing a nanosecond count into a duration or an
-- instant; coercing a C @time_t@ wall-clock value into an instant; and writing
-- a numeric literal as a duration.
--
-- One client must be accepted, linked, and run. It is the environment control,
-- and it shows validated construction, arithmetic, scripted sampling, and a
-- production reading stay usable.
module Test.Foundation.Time.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Time opacity across the package boundary" $ do
  it "rejects a client that names the instant constructor" $
    rejected (constructorClient "Instant" "Word64") "does not export" "Instant"

  it "rejects a client that names the duration constructor" $
    rejected (constructorClient "Duration" "Word64") "does not export" "Duration"

  it "rejects a client that names the elapsed baseline constructor" $
    rejected (constructorClient "ElapsedBaseline" "Maybe Instant") "does not export" "ElapsedBaseline"

  it "rejects a client that coerces a nanosecond count into a duration" $
    rejected (coercionClient "Duration" "Data.Word (Word64)" "Word64") "Couldn't match representation" "Duration"

  it "rejects a client that coerces a nanosecond count into an instant" $
    rejected (coercionClient "Instant" "Data.Word (Word64)" "Word64") "Couldn't match representation" "Instant"

  it "rejects a client that coerces a wall-clock time_t into an instant" $
    rejected (coercionClient "Instant" "Foreign.C.Types (CTime)" "CTime") "Couldn't match representation" "CTime"

  it "rejects a client that writes a numeric literal as a duration" $
    rejected literalClient "No instance for" "Num Duration"

  it "accepts and runs a client using only the public constructors and operations" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) { cwd = Just (clientDirectory outcome) }
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "period = Right (Duration 16000000ns)"
                   , "zero period = Left DurationZero"
                   , "deadline = Right (Instant 16000100ns)"
                   , "remaining = Duration 6000000ns"
                   , "elapsed = [Duration 0ns,Duration 10000000ns,Duration 0ns]"
                   , "production ordered = True"
                   ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation"]

-- | Typecheck a client and require the named rejection, with the name the
-- client reached for in the diagnostic.
rejected ∷ String → String → String → IO ()
rejected source reason reached =
  withClient "Client.hs" source $ \compile → do
    outcome ← compile Typecheck
    rejectedBecause outcome reason
    clientOutput outcome `shouldContain` reached

constructorClient ∷ String → String → String
constructorClient name field =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Data.Word (Word64)"
    , "import Hetoimasia.Foundation.Time (Instant, " <> name <> " (" <> name <> "))"
    , ""
    , "forged ∷ " <> field <> " → " <> name
    , "forged = " <> name
    ]

coercionClient ∷ String → String → String → String
coercionClient target sourceImport sourceType =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import " <> sourceImport
    , "import Hetoimasia.Foundation.Time (" <> target <> ")"
    , ""
    , "forged ∷ " <> sourceType <> " → " <> target
    , "forged = coerce"
    ]

literalClient ∷ String
literalClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Foundation.Time (Duration)"
    , ""
    , "forged ∷ Duration"
    , "forged = 16000000"
    ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Data.IORef (atomicModifyIORef', newIORef)"
    , "import Hetoimasia.Foundation.Time"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let period = convertedDuration <$> durationFromSeconds RequirePositive 0.016"
    , "  putStrLn (\"period = \" <> show period)"
    , "  putStrLn (\"zero period = \" <> show (durationFromNanoseconds RequirePositive 0))"
    , "  let origin = either (error . show) scriptedInstant (durationFromNanoseconds AllowZero 100)"
    , "      step = either (error . show) id (durationFromNanoseconds RequirePositive 10000000)"
    , "      deadline = either (error . show) id . addDuration origin <$> period"
    , "  putStrLn (\"deadline = \" <> show deadline)"
    , "  let now = either (error . show) id (addDuration origin step)"
    , "  putStrLn (\"remaining = \" <> show (either (error . show) (remainingUntil now) deadline))"
    , "  script ← newIORef [origin, now, origin]"
    , "  let source = scriptedSource (atomicModifyIORef' script (\\readings → case readings of { r : rest → (rest, r); [] → ([], origin) }))"
    , "  (first, afterFirst) ← sampleElapsed source noBaseline"
    , "  (second, afterSecond) ← sampleElapsed source afterFirst"
    , "  (third, _) ← sampleElapsed source afterSecond"
    , "  putStrLn (\"elapsed = \" <> show [first, second, third])"
    , "  before ← readInstant monotonicSource"
    , "  after ← readInstant monotonicSource"
    , "  putStrLn (\"production ordered = \" <> show (after >= before))"
    ]
