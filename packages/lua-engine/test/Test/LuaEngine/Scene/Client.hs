{-# LANGUAGE OverloadedStrings #-}

-- | The scene boundary composed from outside the packages: a separately compiled client, given only the
-- Lua engine's configuration and scene sublibraries, the host's public modules and the pure renderer
-- packages, prepares a scene and turns it into a validated frame through public modules alone, with no
-- private Lua handle, Vulkan, GLFW, game, sample or window; and what the facade keeps hidden, it cannot name.
module Test.LuaEngine.Scene.Client (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "composition from outside the packages" $ do
  it "lets a separately compiled client prepare a scene and build and validate its frame through public modules alone" $
    withClient "Main.hs" composingClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome <> "/client") []) ""
      (status, out, err) `shouldBe` (ExitSuccess, "prepared 0 sprites\nframe valid: True\nrefused: scene.clear.g: a colour channel is a whole number\n", "")

  it "keeps a prepared scene's construction and the limits' record out of a client's reach where they would let it skip a check" $ do
    withClient "Client.hs" limitsClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
  where
    withClient = withStorePackageClient ["base", "text", "hetoimasia-lua-engine-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace-scene", "hetoimasia-scripting-lua-0.1.0.0-inplace", "hetoimasia-scripting-lua-0.1.0.0-inplace-runtime-lua", "hetoimasia-render-2d-0.1.0.0-inplace", "hetoimasia-render-api-0.1.0.0-inplace"]

composingClient ∷ String
composingClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.Text as Text"
    , "import Hetoimasia.LuaEngine.Profile (fixedM1Profile)"
    , "import Hetoimasia.LuaEngine.Scene"
    , "import Hetoimasia.Render.TwoD.Metrics (PixelExtent (PixelExtent), TargetMetrics (TargetMetrics))"
    , "import Hetoimasia.Render.TwoD.Validation (validateSnapshot)"
    , "import Hetoimasia.Scripting.Lua.Lease (newLeases)"
    , "import Hetoimasia.Scripting.Lua.Lending (newLending)"
    , "import Hetoimasia.Scripting.Lua.Value (Value (VFloat, VInteger, VList, VRecord))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  limits ← either (fail . show) pure (sceneLimits fixedM1Profile)"
    , "  lending ← newLending"
    , "  leases ← newLeases lending 1"
    , "  let clear g = VRecord [(Text.pack \"r\", VInteger 0), (Text.pack \"g\", g), (Text.pack \"b\", VInteger 0)]"
    , "      scene g = VRecord [(Text.pack \"clear\", clear g), (Text.pack \"sprites\", VList [])]"
    , "  prepared ← prepareScene limits leases (scene (VInteger 7)) >>= either (fail . show) pure"
    , "  putStrLn (\"prepared \" ++ show (length (sceneSprites (preparedContent prepared))) ++ \" sprites\")"
    , "  let metrics = TargetMetrics (PixelExtent 640 480) (PixelExtent 1280 960) 2 2"
    , "  frame ← either (fail . show) pure (sceneCandidate (const Nothing) metrics (preparedContent prepared))"
    , "  putStrLn (\"frame valid: \" ++ show (either (const False) (const True) (validateSnapshot frame)))"
    , "  refused ← prepareScene limits leases (scene (VFloat 1.5))"
    , "  putStrLn (either (\\r → \"refused: \" ++ Text.unpack (refusalReasonText r)) (const \"accepted\") refused)"
    ]

limitsClient ∷ String
limitsClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.LuaEngine.Scene (SceneLimits (SceneLimits))"
    , ""
    , "forged ∷ Maybe SceneLimits"
    , "forged = Nothing"
    ]
