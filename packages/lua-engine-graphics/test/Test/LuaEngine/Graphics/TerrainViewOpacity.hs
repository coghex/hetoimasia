-- | What the terrain-views library exposes of a pick's consistency reference to a client.
--
-- A suite inside the package reaches every module, so it cannot observe the boundary. These examples compile separate
-- single-module clients with the harness from "Test.Support.ExternalClient", exposing the terrain-views library and
-- hiding everything else. A client that reads a reference through its accessors is accepted. Every other client must be
-- refused for the specific diagnostic that names its cause, so a reference can be neither made nor altered outside the
-- adapter's picker:
--
-- * the constructor of a reference or of its identity cannot be named: @GHC-10237@;
-- * an identity's accessors are functions, never field labels, so record-update syntax cannot rewrite one:
--   @GHC-22385@;
-- * the module that holds the constructors is hidden: @GHC-87110@;
-- * the picker's constructor function is exported by no module: @GHC-61689@.
module Test.LuaEngine.Graphics.TerrainViewOpacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "terrain views' pick references across the library boundary" $ do
  it "accepts a client that reads a reference through its accessors" $
    withClient (clientImporting ["import Data.Word (Word64)", "import Hetoimasia.LuaEngine.Graphics.TerrainView (PickRef, pickRefIdentity, pickResidency, pickRevision)"] ["residencyOf :: PickRef k -> (Word64, Word64)", "residencyOf ref = (pickResidency (pickRefIdentity ref), pickRevision (pickRefIdentity ref))"]) $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the reading client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)

  forM_ ["PickRef", "PickIdentity"] $ \name →
    it ("rejects a client that names the constructor of " <> name) $
      withClient (clientImporting ["import Hetoimasia.LuaEngine.Graphics.TerrainView (" <> name <> " (" <> name <> "))"] []) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ ["pickResidency", "pickRevision", "pickContent"] $ \field →
    it ("rejects a client that rewrites an identity through " <> field <> " with record-update syntax") $
      withClient (clientImporting ["import Hetoimasia.LuaEngine.Graphics.TerrainView (PickIdentity, " <> field <> ")"] ["forged :: PickIdentity k -> PickIdentity k", "forged identity = identity {" <> field <> " = " <> field <> " identity}"]) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"
        clientOutput outcome `shouldContain` field

  it "rejects a client that imports the module holding the constructors" $
    withClient (clientImporting ["import Hetoimasia.LuaEngine.Graphics.TerrainView.Internal.Pick"] []) $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the constructors' module is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "Hetoimasia.LuaEngine.Graphics.TerrainView.Internal.Pick"

  it "rejects a client that asks the library's types module for the picker's constructor function" $
    withClient (clientImporting ["import Hetoimasia.LuaEngine.Graphics.TerrainView.Types (mkPickRef)"] []) $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "mkPickRef"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withStorePackageClient ["base", "hetoimasia-lua-engine-graphics-0.1.0.0-inplace-terrain-views"] "Client.hs"

clientImporting ∷ [String] → [String] → String
clientImporting imports body = unlines (["module Client () where", ""] <> imports <> [""] <> body)
