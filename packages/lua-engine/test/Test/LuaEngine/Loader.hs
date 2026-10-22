{-# LANGUAGE OverloadedStrings #-}

-- | The Lua host's module loader under the fixed M1 profile: the profile is the one
-- source of the loader's limits, so a VM configured from it holds a chain of exactly 32
-- modules (the root counted) and 256 identities, and one more of either is refused. The
-- host's loader knows no role and no manifest; this is the engine's policy over it, and
-- the only wiring this slice adds.
module Test.LuaEngine.Loader (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Hetoimasia.LuaEngine.Behavior (exportLimits)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec

-- | The identity of a module by its number.
module' ∷ Int → ExportIdentity
module' n = ExportIdentity (Char8.pack ("m" <> show n))

-- | A loader whose sources are always there: each module imports the next up to the last.
chainOf ∷ Int → LoaderConfig
chainOf lastModule = loaderConfig supplier resolver
  where
    supplier =
      SourceSupplier
        { supplierAcquire = \(ExportIdentity raw) →
            pure (SourceVerified (source (read (drop 1 (Char8.unpack raw)))))
        , supplierRelease = \_ → pure ()
        }
    source ∷ Int → ByteString
    source n
      | n >= lastModule = "return {}"
      | otherwise = encodeUtf8 ("return { next = import('m" <> Text.pack (show (n + 1)) <> "') }")
    resolver _ path _ = pure (Right (ResolvedAddress (ExportIdentity (encodeUtf8 path)) path))

-- | An owner configured from the fixed profile with this loader.
underProfile ∷ LoaderConfig → (OwnedVm → IO a) → IO a
underProfile loader =
  withVmOwner ((vmConfig [LibraryBase]) {vmExportLimits = exportLimits fixedM1Profile, vmLoader = Just loader})

spec ∷ Spec
spec = describe "the Lua host's module loader under the fixed M1 profile" $ do
  it "runs a chain of 32 modules, the root counted" $
    underProfile (chainOf 32) $ \owned → do
      _ ← admitRoot owned (RootRequest (module' 1) "m1")
      report ← advanceLoader owned
      advanceBlocked report `shouldBe` BlockedIdle
      forM_ [1 .. 32] $ \n → lookupModule owned (module' n) >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)

  it "fails the importer whose dependency would make the chain 33, and admits nothing for it" $
    underProfile (chainOf 33) $ \owned → do
      _ ← admitRoot owned (RootRequest (module' 1) "m1")
      _ ← advanceLoader owned
      lookupModule owned (module' 32) >>= \case
        ModuleFailed fault → boundaryReason fault `shouldBe` ModuleRefused (ImportChainTooDeep 32 "m33")
        other → expectationFailure ("m32 is " <> show other)
      lookupModule owned (module' 33) >>= (`shouldBe` ModuleUnknown)
      lookupModule owned (module' 1) >>= (`shouldSatisfy` \case ModuleFailed _ → True; _ → False)

  it "holds 256 identities, pending ones included, and refuses the 257th with nothing recorded" $
    underProfile (chainOf 1000) $ \owned → do
      forM_ [1 .. 256] $ \n → admitRoot owned (RootRequest (module' n) (label n)) >>= (`shouldBe` RootQueued)
      admitRoot owned (RootRequest (module' 257) "m257") >>= (`shouldBe` RootRefused (RootCacheFull 256))
      lookupModule owned (module' 257) >>= (`shouldBe` ModuleUnknown)
      counts ← moduleLoaderCounts owned
      countPending counts `shouldBe` 256
  where
    label ∷ Int → Text
    label n = decodeUtf8Lenient (Char8.pack ("m" <> show n))
