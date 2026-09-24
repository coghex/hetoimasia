module Main (main) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Test.Hspec (hspec)

import Test.Shader.Fragment (verificationFragment)
import Test.Shader.Spec qualified as Shader
import Test.Shader.Vertex (verificationVertex)

-- | The suite first says exactly what it embedded, so two builds — from two
-- extractions of the package, or on two machines with one compiler — can be
-- compared byte for byte from their logs alone.
main ∷ IO ()
main = do
  mapM_ identify [("vertex", verificationVertex), ("fragment", verificationFragment)]
  hspec Shader.spec
  where
    identify ∷ (String, ByteString) → IO ()
    identify (stage, spirv) =
      putStrLn
        ( "embedded "
            <> stage
            <> " SPIR-V: "
            <> show (ByteString.length spirv)
            <> " bytes, sha256 "
            <> LazyChar8.unpack (toLazyByteString (byteStringHex (SHA256.hash spirv)))
        )
