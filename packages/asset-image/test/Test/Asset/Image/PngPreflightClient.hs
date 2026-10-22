-- | Examples proving the bounded PNG preflight is usable from outside the
-- asset-image package through its public module alone, and that a client
-- can neither forge the checked values nor reach the internals.
--
-- Each example compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @bytestring@, @text@,
-- @hetoimasia-asset@ and @hetoimasia-asset-image@ and hiding everything else:
-- no JuicyPixels, no @zlib@, no Lua-engine, no graphics package. Each rejected
-- client is checked against the diagnostic naming its cause, so a missing
-- package or an unrelated error can never pass for the boundary holding.
--
-- One client must be accepted, linked and run: it preflights a PNG under
-- narrow limits, then one past them, and still calls the general decoder, the
-- KTX2 reader, the BC7 checks and the mip generator, showing the existing
-- entry points are compatible.
module Test.Asset.Image.PngPreflightClient (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotBe)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "PngPreflight across the package boundary" $ do
  it "rejects a client that names the limits constructor" $
    rejected limitsConstructorClient "GHC-01928" "PngLimits"

  it "rejects a client that updates a limit with record syntax" $
    rejected limitsUpdateClient "GHC-" "sourceLimit"

  it "rejects a client that names the preflight constructor" $
    rejected preflightConstructorClient "GHC-" "PngPreflight"

  forM_ ["Hetoimasia.Asset.Image.Internal.PngStructure", "Hetoimasia.Asset.Image.Internal.PngInflate", "Hetoimasia.Asset.Image.Internal.PngGeometry"] $ \internal →
    it ("rejects a client that imports " <> internal <> ": it is a hidden module") $
      hidden (internalClient internal) "hidden module in the package" internal

  it "rejects a client that needs JuicyPixels: the package is not exposed to it" $
    hidden jpClient "member of the hidden package" "Codec.Picture.Png.Internal.Type"

  it "accepts and runs a client using only the public modules" $
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
        `shouldBe` [ "limits = Right"
                   , "zero refused = Left LimitChunks"
                   , "accepted = (4,4,68,64)"
                   , "narrow width = ExceededLimit LimitWidth"
                   , "foreign = UnsupportedFormat"
                   , "damaged = MalformedPng"
                   , "same bytes = True"
                   , "general decoder refused = True"
                   ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "text", "hetoimasia-asset", "hetoimasia-asset-image"]

rejected ∷ String → String → String → IO ()
rejected source reason subject =
  withClient "Main.hs" source $ \compile → do
    outcome ← compile Typecheck
    outcome `rejectedBecause` reason
    outcome `rejectedBecause` subject

-- | The client was rejected because the module is not exposed to it. The
-- shared harness treats that message as an environment failure for the
-- boundary examples, so this checks it directly, and the hiding itself: the
-- message must say the module or package is hidden, not that it is missing.
hidden ∷ String → String → String → IO ()
hidden source why subject =
  withClient "Main.hs" source $ \compile → do
    outcome ← compile Typecheck
    clientStatus outcome `shouldNotBe` ExitSuccess
    clientOutput outcome `shouldContain` "Could not load module"
    clientOutput outcome `shouldContain` why
    clientOutput outcome `shouldContain` subject

header ∷ String
header =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    ]

limitsConstructorClient, limitsUpdateClient, preflightConstructorClient, jpClient ∷ String
limitsConstructorClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.PngPreflight"
      , ""
      , "forged ∷ PngLimits"
      , "forged = PngLimits 1 1 1 1 1 1 1"
      , ""
      , "main ∷ IO ()"
      , "main = print (pngLimitSettings forged)"
      ]
limitsUpdateClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.PngPreflight"
      , ""
      , "main ∷ IO ()"
      , "main = print (pngLimitSettings (m1PngLimits {sourceLimit = 0}))"
      ]
preflightConstructorClient =
  header
    <> unlines
      [ "import Hetoimasia.Asset.Image.PngPreflight (PngPreflight (PngPreflight))"
      , ""
      , "main ∷ IO ()"
      , "main = pure ()"
      ]
jpClient =
  header
    <> unlines
      [ "import Codec.Picture.Png.Internal.Type (pngSignature)"
      , ""
      , "main ∷ IO ()"
      , "main = print pngSignature"
      ]

internalClient ∷ String → String
internalClient internal =
  header
    <> unlines
      [ "import " <> internal
      , ""
      , "main ∷ IO ()"
      , "main = pure ()"
      ]

supportedClient ∷ String
supportedClient =
  header
    <> unlines
      [ "import qualified Data.ByteString as ByteString"
      , "import Data.Word (Word8)"
      , "import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))"
      , "import Hetoimasia.Asset.Image (ImageKind (..))"
      , "import Hetoimasia.Asset.Image.Png (decodePng)"
      , "import Hetoimasia.Asset.Image.PngPreflight"
      , ""
      , "asset ∷ Asset"
      , "asset = Asset (AssetId \"client\") (FromMemory \"client\")"
      , ""
      , "-- A 4 × 4 RGBA8 PNG: IHDR, one IDAT holding a stored zlib stream of 68"
      , "-- zero bytes, IEND. The CRCs were computed independently."
      , "png ∷ ByteString.ByteString"
      , "png = ByteString.pack pngBytes"
      , ""
      , "pngBytes ∷ [Word8]"
      , "pngBytes = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 4, 0, 0, 0, 4, 8, 6, 0, 0, 0, 169, 241, 158, 126, 0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 160, 28, 0, 0, 0, 68, 0, 1, 215, 227, 72, 253, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]"
      , ""
      , "classOf ∷ Either PngRefusal a → String"
      , "classOf = either (show . pngRefusalClass) (const \"accepted\")"
      , ""
      , "main ∷ IO ()"
      , "main = do"
      , "  let settings = PngLimitSettings 1000 8 4 4 16 64 68"
      , "  putStrLn (\"limits = \" <> either (const \"Left\") (const \"Right\") (pngLimits settings))"
      , "  putStrLn (\"zero refused = \" <> either (\\r -> \"Left \" <> show (refusedLimit r)) (const \"Right\") (pngLimits settings {settingChunks = 0}))"
      , "  case pngLimits settings of"
      , "    Left _ -> putStrLn \"unreachable\""
      , "    Right limits -> do"
      , "      case preflightPng limits asset png of"
      , "        Right p -> putStrLn (\"accepted = \" <> show (preflightWidth p, preflightHeight p, preflightScanlineBytes p, preflightRgba8Bytes p))"
      , "        Left r -> putStrLn (\"accepted = \" <> show (pngRefusalClass r))"
      , "      case pngLimits settings {settingWidth = 3} of"
      , "        Right narrow -> putStrLn (\"narrow width = \" <> classOf (preflightPng narrow asset png))"
      , "        Left _ -> putStrLn \"unreachable\""
      , "      putStrLn (\"foreign = \" <> classOf (preflightPng limits asset \"GIF89a\"))"
      , "      putStrLn (\"damaged = \" <> classOf (preflightPng limits asset (ByteString.take 30 png)))"
      , "      putStrLn (\"same bytes = \" <> show (fmap preflightSource (preflightPng limits asset png) == Right png))"
      , "  putStrLn (\"general decoder refused = \" <> show (either (const True) (const False) (decodePng DataImage asset \"GIF89a\")))"
      ]
