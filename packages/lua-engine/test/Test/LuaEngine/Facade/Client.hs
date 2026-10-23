{-# LANGUAGE OverloadedStrings #-}

-- | The facade composed from outside the packages: a separately compiled client, given only the Lua engine's
-- configuration and facade sublibraries, the host's public modules and the content package's, makes the
-- session's authored output, resolves a lexical import, validates a root and writes a call through public
-- modules alone, with no private Lua handle, graphics, console, game or window; and what the facade keeps
-- hidden, it cannot name.
module Test.LuaEngine.Facade.Client (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "composition from outside the packages" $ do
  it "lets a separately compiled client make the authored output, resolve an import and write a call through public modules alone" $
    withClient "Main.hs" composingClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome <> "/client") []) ""
      (status, out, err) `shouldBe` (ExitSuccess, "stdout: [\"a\\tb\"]\nstderr: []\nroot ok: True, bad: False\nresolved: mod-b lua/x.lua\nrefused: root \"other\" is not enabled\nafter the scope: refused\n", "")

  it "keeps a facade's construction out of a client's reach: it can be made only by the function that checks it" $
    withClient "Client.hs" forgingClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-01928"

  it "keeps a facade's fields and the engine's own records out of a client's reach where they would let it skip a check" $
    withClient "Client.hs" fieldsClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
  where
    withClient = withStorePackageClient ["base", "bytestring", "text", "hetoimasia-lua-engine-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace-facade", "hetoimasia-lua-engine-0.1.0.0-inplace-modules", "hetoimasia-lua-engine-0.1.0.0-inplace-request", "hetoimasia-lua-engine-0.1.0.0-inplace-data", "hetoimasia-scripting-lua-0.1.0.0-inplace", "hetoimasia-scripting-lua-0.1.0.0-inplace-runtime-lua", "hetoimasia-content-0.1.0.0-inplace", "hetoimasia-foundation-0.1.0.0-inplace"]

composingClient ∷ String
composingClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Exception (SomeException, try)"
    , "import qualified Data.ByteString as ByteString"
    , "import Data.IORef (modifyIORef', newIORef, readIORef)"
    , "import qualified Data.Text as Text"
    , "import qualified Data.Text.Encoding as Text"
    , "import Hetoimasia.Content.Identity (contentKeyPath, identityLimits, logicalPathBytes)"
    , "import Hetoimasia.LuaEngine.Facade"
    , "import Hetoimasia.Scripting.Lua.Owner (ExportIdentity (ExportIdentity), ImportContext (ImportContext))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  out ← newIORef []"
    , "  err ← newIORef []"
    , "  let sink ref = OutputSink {sinkLine = \\line → modifyIORef' ref (<> [line]), sinkFlush = pure ()}"
    , "  kept ← withOutput (sink out) (sink err) $ \\output → do"
    , "    writeAuthored output Stdout [Text.pack \"a\\tb\"]"
    , "    pure output"
    , "  readIORef out >>= putStrLn . (\"stdout: \" <>) . show . map Text.unpack"
    , "  readIORef err >>= putStrLn . (\"stderr: \" <>) . show . map Text.unpack"
    , "  putStrLn (\"root ok: \" <> show (validRootId (Text.pack \"game\")) <> \", bad: \" <> show (validRootId (Text.pack \"Game\")))"
    , "  limits ← either (fail . show) pure (identityLimits 1024 255 32 10000)"
    , "  let importer = ImportContext (ExportIdentity (ByteString.cons 5 (Text.encodeUtf8 (Text.pack \"mod-blua/main.lua\")))) (Text.pack \"main\")"
    , "      resolve = lexicalResolver limits [Text.pack \"mod-b\"]"
    , "  found ← resolve importer (Text.pack \"lua/x.lua\") Nothing"
    , "  putStrLn (either (\\why → \"refused: \" <> Text.unpack why) (\\key → \"resolved: mod-b \" <> Text.unpack (Text.decodeUtf8 (logicalPathBytes (contentKeyPath key)))) found)"
    , "  refused ← resolve importer (Text.pack \"lua/x.lua\") (Just (Text.pack \"other\"))"
    , "  putStrLn (either (\\why → \"refused: \" <> Text.unpack why) (const \"resolved\") refused)"
    , "  late ← try (writeAuthored kept Stdout [Text.pack \"late\"])"
    , "  putStrLn (\"after the scope: \" <> either (\\e → const \"refused\" (e ∷ SomeException)) (const \"written\") late)"
    ]

forgingClient ∷ String
forgingClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.LuaEngine.Facade (Facade (..))"
    , ""
    , "forged ∷ Facade → Facade"
    , "forged facade = Facade {}"
    ]

fieldsClient ∷ String
fieldsClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Hetoimasia.LuaEngine.Facade (Facade (fcRegistry))"
    , ""
    , "reach ∷ Maybe Facade"
    , "reach = Nothing"
    ]
