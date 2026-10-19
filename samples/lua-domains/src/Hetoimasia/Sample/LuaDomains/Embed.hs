{-# LANGUAGE TemplateHaskell #-}

-- | Embedding the sample's Lua sources in the library at compile time, so the executable and the
-- tests find them whatever directory they run from. Each file is registered with
-- 'addDependentFile', so changing one rebuilds the module that embeds it.
module Hetoimasia.Sample.LuaDomains.Embed
  ( embedFile
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString.Unsafe (unsafePackAddressLen)
import Language.Haskell.TH (Exp, Q, integerL, litE, runIO, stringPrimL)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.IO.Unsafe (unsafePerformIO)

-- | The bytes of the file at this path, relative to the package directory, as an expression of
-- type 'ByteString'.
embedFile ∷ FilePath → Q Exp
embedFile path = do
  addDependentFile path
  bytes ← runIO (ByteString.readFile path)
  [|unsafePerformIO (unsafePackAddressLen $(litE (integerLit (ByteString.length bytes))) $(litE (stringPrimL (ByteString.unpack bytes))))|]
  where
    integerLit = integerL . fromIntegral
