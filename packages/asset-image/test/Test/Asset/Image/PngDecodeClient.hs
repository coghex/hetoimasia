-- | Examples proving the bounded PNG decoder is usable from outside the
-- asset-image package through its public modules alone, and that a client can
-- reach none of the decoder's internals.
--
-- Each example compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @bytestring@, @text@,
-- @hetoimasia-asset@ and @hetoimasia-asset-image@ and hiding everything else:
-- no JuicyPixels, no @zlib@, no Lua-engine, no graphics package and no console
-- module. Each rejected client is checked against the diagnostic naming its
-- cause, so a missing package or an unrelated error can never pass for the
-- boundary holding.
--
-- One client must be accepted, linked and run: it keeps its own byte account,
-- preflights a PNG, decodes it, reads the one level and the charges, hands the
-- level to a consumer that charges a staging copy beside it, and is refused
-- by an account too small for the workspace.
module Test.Asset.Image.PngDecodeClient (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotBe)
import Test.Support.ExternalClient (Client (..), Mode (..), withStorePackageClient)

spec ∷ Spec
spec = describe "PngDecode across the package boundary" $ do
  forM_
    [ "Hetoimasia.Asset.Image.Internal.PngRaster"
    , "Hetoimasia.Asset.Image.Internal.PngWorkspace"
    , "Hetoimasia.Asset.Image.Internal.PngUnfilter"
    , "Hetoimasia.Asset.Image.Internal.PngInflate"
    , "Hetoimasia.Asset.Image.Internal.Texels"
    ]
    $ \internal →
      it ("rejects a client that imports " <> internal <> ": it is a hidden module") $
        hidden (importClient internal) "hidden module in the package" internal

  it "rejects a client that needs JuicyPixels or zlib: neither package is exposed to it" $ do
    hidden (importClient "Codec.Picture.Png") "member of the hidden package" "Codec.Picture.Png"
    hidden (importClient "Codec.Compression.Zlib") "member of the hidden package" "Codec.Compression.Zlib"

  it "accepts and runs a client using only the public modules, with its own account" $
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
        `shouldBe` [ "decoded = (4,4,1,64,True)"
                   , "format = TexelRgba8Srgb"
                   , "grants = [(StageOutput,64),(StageScratch,173072),(StageWorking,68)]"
                   , "plan = [(StageOutput,64),(StageScratch,173072),(StageWorking,68)]"
                   , "live after decode = 64"
                   , "peak = 173204"
                   , "live with staging copy = 128"
                   , "live after both released = 0"
                   , "small bank = ExceededLimit LimitWorkspaceBytes"
                   , "live after refusal = 0"
                   , "general decoder untouched = True"
                   ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "text", "hetoimasia-asset", "hetoimasia-asset-image"]

-- | The client was rejected because the module is not exposed to it.
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

importClient ∷ String → String
importClient internal =
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
      [ "import Data.IORef (modifyIORef', newIORef, readIORef)"
      , "import qualified Data.ByteString as ByteString"
      , "import Data.Word (Word8)"
      , "import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))"
      , "import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..))"
      , "import Hetoimasia.Asset.Image.Png (decodePng)"
      , "import Hetoimasia.Asset.Image.PngDecode"
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
      , "-- A bank of this many bytes: its live and peak bytes, and what it granted."
      , "newBank ∷ Int → IO (PayloadAccount, IO (Int, Int, [(PayloadStage, Int)]))"
      , "newBank capacity = do"
      , "  state ← newIORef (0 ∷ Int, 0 ∷ Int, [] ∷ [(PayloadStage, Int)])"
      , "  let reserve stage bytes = do"
      , "        (live, peak, granted) ← readIORef state"
      , "        if live + bytes > capacity"
      , "          then pure False"
      , "          else modifyIORef' state (\\_ → (live + bytes, max peak (live + bytes), granted <> [(stage, bytes)])) >> pure True"
      , "      release _ bytes = modifyIORef' state (\\(live, peak, granted) → (live - bytes, peak, granted))"
      , "  pure (PayloadAccount reserve release, readIORef state)"
      , ""
      , "main ∷ IO ()"
      , "main = do"
      , "  (account, observe) ← newBank m1WorkspaceBytes"
      , "  case preflightPng m1PngLimits asset png of"
      , "    Left refusal → putStrLn (\"preflight refused \" <> show (pngRefusalClass refusal))"
      , "    Right preflighted → do"
      , "      result ← decodeBounded account preflighted"
      , "      case result of"
      , "        Left refusal → putStrLn (\"decode refused \" <> show (pngRefusalClass refusal))"
      , "        Right image → do"
      , "          putStrLn (\"decoded = \" <> show (decodedWidth image, decodedHeight image, length (decodedLevels image), sum (map ByteString.length (decodedLevels image)), decodedBinaryAlpha image))"
      , "          putStrLn (\"format = \" <> show (decodedFormat image))"
      , "          (live, peak, granted) ← observe"
      , "          putStrLn (\"grants = \" <> show granted)"
      , "          putStrLn (\"plan = \" <> show [(stage, fromInteger bytes ∷ Int) | (stage, bytes) ← decodeReservations preflighted])"
      , "          putStrLn (\"live after decode = \" <> show live)"
      , "          putStrLn (\"peak = \" <> show peak)"
      , "          -- A consumer stages a copy of the level beside the level it still holds."
      , "          staged ← reservePayload account StageOutput 64"
      , "          (liveStaged, _, _) ← observe"
      , "          putStrLn (\"live with staging copy = \" <> show (if staged then liveStaged else -1))"
      , "          releasePayload account StageOutput 64"
      , "          releasePayload account StageOutput 64"
      , "          (liveAfter, _, _) ← observe"
      , "          putStrLn (\"live after both released = \" <> show liveAfter)"
      , "  (small, observeSmall) ← newBank 1000"
      , "  case preflightPng m1PngLimits asset png of"
      , "    Left _ → putStrLn \"unreachable\""
      , "    Right preflighted → do"
      , "      refused ← decodeBounded small preflighted"
      , "      putStrLn (\"small bank = \" <> either (show . pngRefusalClass) (const \"decoded\") refused)"
      , "      (liveSmall, _, _) ← observeSmall"
      , "      putStrLn (\"live after refusal = \" <> show liveSmall)"
      , "  putStrLn (\"general decoder untouched = \" <> show (either (const False) (const True) (decodePng ColourImage asset png)))"
      ]
