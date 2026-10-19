-- | The forced exit of the @lua@ subcommand, proven by running the executable.
--
-- A second SIGINT or SIGTERM during the orderly stop exits at once with status 130, without waiting for
-- the shutdown hooks that have not run (D-42). Showing it needs a script whose @shutdown@ never returns,
-- which is deliberate nontermination, so this is an optional local probe
-- (@docs/test_classification.md@): never selected by affected inputs, never named in a pull request's
-- validation request. The routine suite covers the rule through the coordinator's own examples.
--
-- Each example delivers the first signal only after the child has said its script is running and the
-- second only after it has said its stop has begun, and bounds every wait. The child is killed and
-- reaped on every way out by 'withChild', independently of the signals under test: a child that does
-- not exit by itself is a failed example and not a hang.
module Main (main) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import System.Exit (ExitCode (ExitFailure))
import System.Posix.Signals (Signal, sigINT, sigTERM)
import Test.Engine.Console.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotSatisfy, shouldSatisfy)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

-- | An event-only instance whose shutdown says it has begun and then never returns: a loop that never
-- yields, in Lua that cannot be interrupted from outside.
hanging ∷ String
hanging =
  unlines
    [ "function init(self) print('running') end"
    , "function shutdown(self, reason)"
    , "  print('stopping')"
    , "  while true do end"
    , "  print('hook finished')"
    , "end"
    ]

-- | A routine of two signals, in this order: the first, then the second.
forced ∷ [(String, Signal)] → Spec
forced signals = forM_ [(first, second) | first ← signals, second ← signals] $ \((one, firstSignal), (other, secondSignal)) →
  it ("exits 130 at once for " <> one <> " and then " <> other <> ", the hook never having finished") $
    withLuaFiles [("hang.lua", hanging)] $ \at →
      withChild [("HETOIMASIA_LOG_LEVEL", "warn")] ["lua", "--script", at "hang.lua"] $ \child → do
        _ ← awaitMarker child "running"
        sendSignal firstSignal child
        _ ← awaitMarker child "stopping"
        sendSignal secondSignal child
        code ← awaitExit child
        rest ← readRest child
        code `shouldBe` ExitFailure 130
        -- The shutdown never finished, so the orderly stop never reached its table.
        lines rest `shouldNotSatisfy` elem "hook finished"
        lines rest `shouldNotSatisfy` elem "instances at end"
        unlines (lines rest) `shouldSatisfy` (not . ("instances at end" `isInfixOf`))

spec ∷ Spec
spec = describe "lua forced exit" $ do
  describe "a second signal during the orderly stop" $
    forced [("SIGINT", sigINT), ("SIGTERM", sigTERM)]

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} spec
