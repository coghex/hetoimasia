-- | Examples proving a 'Hetoimasia.Asset.Image.Bc7.Bc7Image' can be made only
-- by 'Hetoimasia.Asset.Image.Bc7.bc7Image', and never changed afterwards, from
-- clients outside the asset-image package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @bytestring@, @text@,
-- @hetoimasia-asset@ and @hetoimasia-asset-image@ and hiding everything else.
-- The asset-image library depends on Hackage packages, so the build's
-- dependency store is exposed too.
--
-- Each rejected client is checked against the diagnostic naming its cause, so
-- a missing package, an absent compiler, or an unrelated error can never pass
-- for the boundary holding. Record updates of the public accessors would
-- otherwise let a client give a checked image a wider extent than its levels
-- hold, which the decoder reads without bounds checks, or replace its levels or
-- its mark without the checks.
--
-- One client must be accepted, linked, and run: the environment control,
-- showing that construction, the accessors, decoding and the fallback stay
-- usable.
module Test.Asset.Image.Bc7Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Bc7Image opacity across the package boundary" $ do
  forM_ [("bc7Width", "8"), ("bc7Height", "8"), ("bc7Levels", "[]"), ("bc7BinaryAlpha", "False"), ("bc7Asset", "undefined"), ("bc7Format", "Bc7Linear")] $
    \(field, value) →
      it ("rejects a client that updates " <> field <> " with record syntax") $
        rejected (updateClient field value) "GHC-22385" field

  it "rejects a client that updates the private field behind bc7Width" $
    rejected (updateClient "imageWidth" "8") "GHC-22385" "imageWidth"

  it "rejects a client that names the constructor in an import" $
    rejected constructorImportClient "GHC-10237" "Bc7Image"

  it "rejects a client that builds an image with the constructor" $
    rejected constructorClient "GHC-01928" "Bc7Image"

  it "accepts and runs a client using only bc7Image, the accessors, the decoder and the fallback" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "extent = (4,4)"
                   , "levels = [16]"
                   , "mark = True"
                   , "decoded = [64]"
                   , "kept = Nothing"
                   , "fallback = Just True"
                   , "refused = True"
                   ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "text", "hetoimasia-asset", "hetoimasia-asset-image"]

rejected ∷ String → String → String → IO ()
rejected source reason subject =
  withClient "Main.hs" source $ \compile → do
    outcome ← compile Typecheck
    outcome `rejectedBecause` reason
    outcome `rejectedBecause` subject

header ∷ String
header =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import qualified Data.ByteString as ByteString"
    , "import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))"
    , "import Hetoimasia.Asset.Image (DecodedImage (..))"
    ]

asset ∷ String
asset = "Asset (AssetId \"client\") (FromMemory \"client\")"

updateClient ∷ String → String → String
updateClient field value =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.Bc7"
      , ""
      , "widen ∷ Bc7Image → Bc7Image"
      , "widen image = image {" <> field <> " = " <> value <> "}"
      , ""
      , "main ∷ IO ()"
      , "main = either (const (pure ())) (print . bc7Width . widen) (bc7Image (" <> asset <> ") Bc7Srgb 4 4 [ByteString.replicate 16 64])"
      ]

constructorImportClient ∷ String
constructorImportClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.Bc7 (Bc7Image (Bc7Image))"
      , ""
      , "main ∷ IO ()"
      , "main = pure ()"
      ]

constructorClient ∷ String
constructorClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.Bc7"
      , ""
      , "forged ∷ Bc7Image"
      , "forged = Bc7Image (" <> asset <> ") Bc7Srgb 8 8 [] True"
      , ""
      , "main ∷ IO ()"
      , "main = print (bc7Width forged)"
      ]

supportedClient ∷ String
supportedClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.Bc7"
      , ""
      , "-- The sprites sample's mode-6 block: opaque in every texel."
      , "block ∷ ByteString.ByteString"
      , "block = ByteString.pack [0xc0, 0x3f, 0x00, 0x00, 0x00, 0xfc, 0xff, 0xff, 0x01, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff]"
      , ""
      , "main ∷ IO ()"
      , "main = case bc7Image (" <> asset <> ") Bc7Srgb 4 4 [block] of"
      , "  Left refusal → print refusal"
      , "  Right image → do"
      , "    putStrLn (\"extent = \" <> show (bc7Width image, bc7Height image))"
      , "    putStrLn (\"levels = \" <> show (map ByteString.length (bc7Levels image)))"
      , "    putStrLn (\"mark = \" <> show (bc7BinaryAlpha image))"
      , "    putStrLn (\"decoded = \" <> show (map ByteString.length (decodedLevels (decodeBc7 image))))"
      , "    putStrLn (\"kept = \" <> show (fallbackSoftwareDecode (bc7Fallback DeviceTakesBc7 image)))"
      , "    putStrLn (\"fallback = \" <> show (fmap ((== bc7Asset image) . softwareDecodedAsset) (fallbackSoftwareDecode (bc7Fallback DeviceLacksBc7 image))))"
      , "    putStrLn (\"refused = \" <> show (either (const True) (const False) (bc7Image (" <> asset <> ") Bc7Srgb 8 4 (bc7Levels image))))"
      ]
