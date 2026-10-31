-- | What the default and CPU builds of the root suite add to the console examples: that the @run@ command does not
-- exist in them. It is not dispatched ('Hetoimasia.App.Run' in @app-cpu/@), so @hetoimasia run@ is an unknown
-- argument (usage, 2), the usage line and the help text are the ones these builds always had, and nothing about
-- the new command is in them. The full build has the module of this name in @test-full/@.
module Test.Engine.Variant
  ( variantSpec
  , childEntry
  ) where

import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Engine.Console.Support (runConsole)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain)

variantSpec ∷ Spec
variantSpec = describe "Run (absent from this build)" $ do
  it "has no run command: it is an unknown argument with the usage line this build always had" $ do
    (code, out, err) ← runConsole [] ["run", "game"]
    code `shouldBe` ExitFailure 2
    out `shouldBe` ""
    err `shouldContain` "Usage: hetoimasia [--smoke | --resource-smoke | --help | lua OPTIONS]\n"
    err `shouldContain` "unknown argument 'run'"

  it "names no run command in the usage line or the help text" $ do
    (code, out, _) ← runConsole [] ["--help"]
    code `shouldBe` ExitSuccess
    out `shouldContain` "Usage: hetoimasia [--smoke | --resource-smoke | --help | lua OPTIONS]\n"
    out `shouldNotContain` "run [--]"
    out `shouldNotContain` "GAME_ROOT"

-- | Whether this process was launched as the full build's signal child. It never is here.
childEntry ∷ IO Bool
childEntry = pure False
