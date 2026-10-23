{-# LANGUAGE OverloadedStrings #-}

-- | The texture pipeline composed from outside the packages: a separately compiled client, given
-- only the content package, the Lua engine's configuration and texture sublibraries and the base
-- libraries, opens a root, scans it, starts the shared read pool and runs the pipeline over a backend
-- of its own, through public modules alone; and what the facade keeps hidden, the client cannot name.
module Test.LuaEngine.Texture.Client (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "composition from outside the packages" $ do
  it "lets a separately compiled client run the pipeline over its own backend through public modules alone: no private host handle, no Vulkan, no GLFW" $
    withSystemTempDirectory "hetoimasia-lua-engine-texture-client" $ \tree →
      withClient "Main.hs" composingClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status → expectationFailure ("the client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree]) ""
        (status, out, err) `shouldBe` (ExitSuccess, "(2,1)\n", "")

  it "keeps a texture's resource record and a texture owner's banks out of a client's reach" $ do
    withClient "Client.hs" resourceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
    withClient "Client.hs" ownerClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-88464"
  where
    withClient = withStorePackageClient ["base", "bytestring", "stm", "hetoimasia-content-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace-texture"]
    a </> b = a <> "/" <> b

composingClient ∷ String
composingClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically, retry)"
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity (rootKey)"
    , "import Hetoimasia.Content.Inventory"
    , "import Hetoimasia.Content.ReadPool (poolSpec, withReadPool)"
    , "import Hetoimasia.LuaEngine.Boot"
    , "import Hetoimasia.LuaEngine.Profile (fixedM1Profile)"
    , "import Hetoimasia.LuaEngine.Texture"
    , "import System.Environment (getArgs)"
    , ""
    , "-- A backend that is never asked: the client requests no texture."
    , "backend ∷ TextureBackend"
    , "backend = TextureBackend (\\_ _ → fail \"no upload is expected\")"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  configuration ← either (fail . show) pure (contentConfiguration fixedM1Profile)"
    , "  key ← either (fail . show) pure (rootKey (BC.pack \"client\"))"
    , "  spec ← either (fail . show) pure (textureSpec fixedM1Profile 4)"
    , "  pool ← either (fail . show) pure (poolSpec (specIoWorkers spec) 8)"
    , "  withContentRoot (configContentLimits configuration) directory $ \\root → do"
    , "    inventory ← scanInventory (configInventoryLimits configuration) key root >>= either (fail . show) pure"
    , "    withReadPool pool inventory root $ \\readPool →"
    , "      withTexturePipeline spec backend readPool inventory $ \\pipeline → do"
    , "        reading ← atomically $ do"
    , "          now ← pipelineReading pipeline"
    , "          if readingDecodeWorkers now == 1 then pure now else retry"
    , "        print (length (readingLanes reading), readingDecodeWorkers reading)"
    ]

resourceClient ∷ String
resourceClient =
  unlines
    [ "module Client (resource) where"
    , ""
    , "import Hetoimasia.LuaEngine.Texture (TextureResource)"
    , ""
    , "resource ∷ Maybe TextureResource"
    , "resource = Nothing"
    ]

ownerClient ∷ String
ownerClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.LuaEngine.Texture (TextureOwner (..))"
    , ""
    , "forged ∷ TextureOwner → Int"
    , "forged owner = ownerSlotLimit owner"
    ]
