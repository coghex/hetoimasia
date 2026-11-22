-- | The terrain views' package boundary: the implementation, with the graphics owner's capability records, the copy
-- hooks and the held target, is a private sub-library; the public library is one module whose composition is opaque.
-- The examples read the Cabal description and compile separate single-module clients ("Test.Support.ExternalClient")
-- against the public library alone: a client composing the service through 'productionPorts' compiles; one importing a
-- private module is refused as hidden, against the private unit; one asking the public module for a capability record
-- or forging the composition is refused. So nothing a client supplies can run inside the service's ownership commits.
module Test.LuaEngine.Graphics.TerrainViewsBoundary (spec) where

import Control.Monad (forM_)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

cabalName ∷ FilePath
cabalName = "hetoimasia-lua-engine-graphics.cabal"

-- The Cabal description, found above the working directory.
cabal ∷ IO String
cabal = search "." (10 ∷ Int)
  where
    search _ 0 = fail (cabalName <> " was not found above the working directory")
    search directory budget = do
      here ← doesFileExist (directory </> cabalName)
      if here then readFile (directory </> cabalName) else search (directory </> "..") (budget - 1)

trim ∷ String → String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- The stanza with this header, up to the next one.
stanza ∷ String → IO [String]
stanza header = do
  description ← cabal
  pure $ case dropWhile (/= header) (lines description) of
    [] → []
    (_ : rest) → takeWhile (\line → null (trim line) || " " `isPrefixOf` line) rest

-- The entries of a list field of the stanza with this header.
fieldEntries ∷ String → String → IO [String]
fieldEntries header field = do
  body ← stanza header
  pure
    [ name
    | line ← takeWhile (not . endOfField) (drop 1 (dropWhile ((/= field) . trim) body))
    , let name = trim (takeWhile (\character → character /= ' ' && character /= ',') (trim line))
    , not (null name)
    ]
  where
    endOfField line = not (null (trim line)) && not ("        " `isPrefixOf` line)

-- The public library's unit, by its in-place id.
withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "hetoimasia-lua-engine-graphics-0.1.0.0-inplace-terrain-views"] "Client.hs"

publicModule ∷ String
publicModule = "Hetoimasia.LuaEngine.Graphics.TerrainView"

-- The private sub-library's modules a client might reach for.
privateModules ∷ [String]
privateModules =
  [ "Hetoimasia.LuaEngine.Graphics.TerrainView.Internal"
  , "Hetoimasia.LuaEngine.Graphics.TerrainView.Owner"
  , "Hetoimasia.LuaEngine.Graphics.TerrainView.Session"
  , "Hetoimasia.LuaEngine.Graphics.TerrainView.Surface"
  ]

-- What the service runs inside its own transactions, or hands to its owner, none of which the public module exports.
capabilities ∷ [String]
capabilities =
  [ "OwnerPorts"
  , "Hands"
  , "Grant"
  , "Receipt"
  , "Allocated"
  , "CopyHooks"
  , "noCopyHooks"
  , "productionOwner"
  , "viewGrant"
  , "stepOwner"
  , "kick"
  , "ViewSurface"
  , "HeldTarget"
  , "newHeldTarget"
  , "surfaceRevalidation"
  , "HeldAuthority"
  , "LeaseAuthority"
  ]

spec ∷ Spec
spec = describe "the terrain views' package boundary" $ do
  it "keeps the implementation in a private sub-library, and exposes only the opaque public module over it" $ do
    private ← stanza "library terrain-views-internal"
    take 3 private `shouldBe` ["    import: language", "    visibility: private", "    hs-source-dirs: terrain-views"]
    fieldEntries "library terrain-views" "exposed-modules:" `shouldReturn` [publicModule]
    fieldEntries "library terrain-views" "build-depends:" `shouldReturn` ["base", "hetoimasia-lua-engine-graphics:terrain-views-internal"]

  it "accepts a client that composes the service through productionPorts and opens views on targets the host issues" $
    withClient composing $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)

  forM_ privateModules $ \hidden →
    it ("rejects a client that imports the private module " <> hidden) $
      withClient (importClient hidden "") $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess → expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
        -- found in the private sub-library and refused as hidden: naming that unit tells this apart from a missing module
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-lua-engine-graphics-0.1.0.0:terrain-views-internal"
        clientOutput outcome `shouldNotContain` "cannot satisfy"

  forM_ capabilities $ \capability →
    it ("rejects a client that asks the public module for " <> capability) $
      withClient (importClient publicModule capability) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-61689"
        clientOutput outcome `shouldContain` capability

  -- the scene ledger and the receipts, whose commits the views watch: no client code runs in them
  forM_ [("Hetoimasia.LuaEngine.Graphics.Scene.Ledger", "ledgerListen"), ("Hetoimasia.LuaEngine.Graphics.Scene.Receipts", "receiptsListen")] $ \(moduleName, listener) →
    it ("rejects a client that asks " <> moduleName <> " for a listener (" <> listener <> ")") $
      withSessionClient (importClient moduleName listener) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-61689"
        clientOutput outcome `shouldContain` listener

  it "rejects a client that notes an offscreen batch with a ticket reader of its own" $
    withSessionClient
      ( unlines
          [ "module Client (noted) where"
          , "import Control.Concurrent.STM (STM)"
          , "import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (noteOffscreenBatch)"
          , "noted receipts tag metrics = noteOffscreenBatch receipts (pure undefined ∷ STM ()) tag metrics"
          ]
      )
      $ \compile → do
        outcome ← compile Typecheck
        -- the ticket is the backend's own batch ticket: a transaction does not type
        rejectedBecause outcome "GHC-83865"
        clientOutput outcome `shouldContain` "BatchTicket"

  it "rejects a client that hands an offscreen target's facts raw metrics, unprepared" $
    withClient
      ( unlines
          [ "module Client (raw) where"
          , "import Hetoimasia.LuaEngine.Graphics.TerrainView"
          , "raw facts metrics = setOffscreenMetrics facts (Just metrics)"
          ]
      )
      $ \compile → do
        outcome ← compile Typecheck
        -- the writer takes only a prepared, fully evaluated value
        rejectedBecause outcome "GHC-83865"
        clientOutput outcome `shouldContain` "Prepared"

  forM_ ["TerrainViewsPorts", "ViewTarget"] $ \constructor →
    it ("rejects a client that forges the public module's opaque " <> constructor) $
      withClient (unlines ["module Client (forged) where", "import " <> publicModule, "forged = " <> constructor]) $ \compile → do
        outcome ← compile Typecheck
        -- no data constructor of that name is in scope: only the type is exported
        rejectedBecause outcome "GHC-01928"
        clientOutput outcome `shouldContain` constructor

-- The main library's unit, by its in-place id: the scene ledger and receipts as a client reaches them.
withSessionClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withSessionClient = withStorePackageClient ["base", "stm", "hetoimasia-lua-engine-graphics-0.1.0.0-inplace"] "Client.hs"

-- A client that imports these names from a module, or only the module when no name is given.
importClient ∷ String → String → String
importClient moduleName names =
  unlines
    [ "module Client () where"
    , "import " <> moduleName <> (if null names then "" else " (" <> names <> ")")
    ]

-- The supported composition: the ports from the running host, the service over them, and a view opened on a target
-- the host issued.
composing ∷ String
composing =
  unlines
    [ "module Client (compose, open) where"
    , "import Hetoimasia.LuaEngine.Graphics.TerrainView"
    , "compose = productionPorts"
    , "open service host depth receipts window lease style anchor light ="
    , "  openView service (OpenRequest (windowViewTarget host depth receipts [] window) lease style anchor light)"
    ]
