-- | The loader's permanent bounds, at the bound and one past it: the identities an
-- owner holds, the bytes of one module's source, and the length of an import chain.
--
-- The bounds are small injected ones, so each is reached with a handful of modules.
-- Pending and failed identities count as much as ready ones, a refused new identity
-- makes no record and takes no read, an identity the owner already holds is reused at
-- any fill, and a dependency that does not fit fails its importer instead of waiting
-- for room that will never come.
module Test.Lua.Boundary.Loader.Limits (spec) where

import Control.Monad (forM_)
import Data.IORef (modifyIORef')
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

-- | An owner held to these bounds.
bounded ∷ Int → Int → Int → (Rig → OwnedVm → IO a) → IO a
bounded sourceBytes identities depth =
  withRigAt (\config → config {vmExportLimits = ExportLimits {exportMaxSourceBytes = sourceBytes, exportMaxIdentities = identities, exportMaxChainDepth = depth}})

simple ∷ Text → [Text]
simple name = ["trace.mark('" <> name <> "')", "return { name = '" <> name <> "' }"]

spec ∷ Spec
spec = describe "the loader's bounds" $ do
  describe "identities" $ do
    it "admits roots up to the bound and refuses the next one with nothing recorded and no source asked for" $
      bounded 1024 3 8 $ \rig owned → do
        forM_ ["a", "b", "c"] $ \name → admit owned name >>= (`shouldBe` RootQueued)
        before ← ledger owned
        refused ← admit owned "d"
        refused `shouldBe` RootRefused (RootCacheFull 3)
        acquired rig >>= (`shouldBe` map ident ["a", "b", "c"])
        statusOfName owned "d" >>= (`shouldBe` ModuleUnknown)
        after ← ledger owned
        after `shouldBe` before

    it "counts pending and failed identities as much as ready ones" $
      bounded 1024 3 8 $ \rig owned → do
        _ ← admit owned "ok"
        _ ← admit owned "bad"
        _ ← admit owned "waiting"
        _ ← supply rig owned "ok" (simple "ok")
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← advance owned
        counts ← moduleLoaderCounts owned
        (countReady counts, countFailed counts, countPending counts) `shouldBe` (1, 1, 1)
        admit owned "more" >>= (`shouldBe` RootRefused (RootCacheFull 3))

    it "reuses an identity the owner already holds, at any fill: a ready, a failed and a pending one" $
      bounded 1024 3 8 $ \rig owned → do
        _ ← admit owned "ok"
        _ ← admit owned "bad"
        _ ← admit owned "waiting"
        _ ← supply rig owned "ok" (simple "ok")
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← advance owned
        ready ← admit owned "ok"
        ready `shouldSatisfy` \case RootSettled (ModuleReady _) → True; _ → False
        failed ← admit owned "bad"
        failed `shouldSatisfy` \case RootSettled (ModuleFailed _) → True; _ → False
        admit owned "waiting" >>= (`shouldBe` RootJoined)
        acquired rig >>= (`shouldBe` map ident ["ok", "bad", "waiting"])

    it "lets a module import what the owner already holds when the owner is full" $
      bounded 1024 3 8 $ \rig owned → do
        _ ← supply rig owned "ok" (simple "ok")
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← supply rig owned "user" ["local ok = import('ok')", "local good, why = pcall(import, 'bad')", "return { ok = ok }"]
        _ ← admit owned "ok"
        _ ← admit owned "bad"
        _ ← admit owned "user"
        _ ← advance owned
        counts ← moduleLoaderCounts owned
        -- The ready table was reused; the failed one fails the user, which the full owner
        -- allowed to ask without a new identity.
        countReady counts `shouldBe` 1
        countFailed counts `shouldBe` 2

    it "refuses a dependency the application's own bound has no room for, in the step that would take its interest, with nothing recorded" $
      bounded 1024 3 8 $ \rig owned → do
        modifyIORef' (rigAvailable rig) (Map.insert (ident "b") SourceNoRoom)
        _ ← supply rig owned "a" ["local ok = pcall(import, 'b')", "return {}"]
        _ ← admit owned "a"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedIdle
        failed ← failureOf owned "a"
        case boundaryReason failed of
          ModuleRefused (ImportCacheFull 3 "game:b") → pure ()
          other → error ("unexpected " <> show other)
        statusOfName owned "b" >>= (`shouldBe` ModuleUnknown)
        -- The supplier took no interest, so none is ended.
        released rig >>= (`shouldSatisfy` notElem (ident "b"))
        ledger owned >>= (`shouldSatisfy` balanced)

    it "fails a module whose dependency does not fit, allocates nothing for it, and does not wait for room" $
      bounded 1024 2 8 $ \rig owned → do
        _ ← supply rig owned "a" ["local ok = pcall(import, 'b')", "return {}"]
        _ ← supply rig owned "b" (simple "b")
        _ ← supply rig owned "c" ["local ok = pcall(import, 'a')", "local late = import('overflow')", "return {}"]
        _ ← admit owned "a"
        _ ← admit owned "c"
        -- 'a' imports 'b', which would be the third identity.
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedIdle
        failed ← failureOf owned "a"
        case boundaryReason failed of
          ModuleRefused (ImportCacheFull 2 "game:b") → pure ()
          other → error ("unexpected " <> show other)
        statusOfName owned "b" >>= (`shouldBe` ModuleUnknown)
        acquired rig >>= (`shouldBe` map ident ["a", "c"])
        ledger owned >>= (`shouldSatisfy` balanced)
        counts ← moduleLoaderCounts owned
        countFailed counts `shouldBe` 2

  describe "source" $ do
    let exact n = ByteString.take n (Char8.pack ("return {} --" <> replicate n 'x'))
    it "compiles a source of exactly the bound and fails one byte more without compiling it" $
      bounded 64 8 8 $ \rig owned → do
        _ ← admit owned "fits"
        _ ← admit owned "past"
        _ ← supplyBytes rig owned "fits" (exact 64)
        _ ← supplyBytes rig owned "past" (exact 65 <> "")
        counts ← moduleLoaderCounts owned
        -- The oversize bytes were not kept.
        countSourcesHeld counts `shouldBe` 1
        _ ← advance owned
        statusOfName owned "fits" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
        past ← failureOf owned "past"
        boundaryReason past `shouldBe` ModuleRefused (SourceTooLarge 64)
        boundaryEffect past `shouldBe` NoEffect
        -- It still counts, and its interest ended with it.
        after ← moduleLoaderCounts owned
        countFailed after `shouldBe` 1
        countInterestsHeld after `shouldBe` 0

    it "fails the importer of a dependency whose source is past the bound, with the dependency a charged failure" $
      bounded 64 8 8 $ \rig owned → do
        _ ← supplyBytes rig owned "big" (exact 65)
        _ ← supply rig owned "a" ["local ok = pcall(import, 'big')", "return {}"]
        _ ← admit owned "a"
        _ ← advance owned
        boundaryReason <$> failureOf owned "big" >>= (`shouldBe` ModuleRefused (SourceTooLarge 64))
        failureOf owned "a" >>= \failed → case boundaryReason failed of
          ModuleRefused (DependencyFailed "game:big" _ _) → pure ()
          other → error ("unexpected " <> show other)
        ledger owned >>= (`shouldSatisfy` balanced)

  describe "chain depth" $ do
    let chainOf ∷ Int → [(Text, [Text])]
        chainOf n = [("n" <> Text.pack (show i), if i == n then ["return {}"] else ["return { next = import('n" <> Text.pack (show (i + 1)) <> "') }"]) | i ← [1 .. n]]
    it "runs a chain of exactly the bound, the root counted" $
      bounded 1024 16 4 $ \rig owned → do
        forM_ (chainOf 4) $ \(name, body) → supply rig owned name body
        _ ← admit owned "n1"
        _ ← advance owned
        forM_ ["n1", "n2", "n3", "n4"] $ \name → statusOfName owned name >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)

    it "fails the importer whose dependency would make the chain one longer, and admits nothing for it" $
      bounded 1024 16 4 $ \rig owned → do
        forM_ (chainOf 5) $ \(name, body) → supply rig owned name body
        _ ← admit owned "n1"
        _ ← advance owned
        deepest ← failureOf owned "n4"
        boundaryReason deepest `shouldBe` ModuleRefused (ImportChainTooDeep 4 "game:n5")
        statusOfName owned "n5" >>= (`shouldBe` ModuleUnknown)
        acquired rig >>= (`shouldBe` map ident ["n1", "n2", "n3", "n4"])
        -- Each importer above fails with it.
        forM_ ["n3", "n2", "n1"] $ \name → failureOf owned name >>= \failed → case boundaryReason failed of
          ModuleRefused (DependencyFailed _ _ _) → pure ()
          other → error ("unexpected " <> show other)
        ledger owned >>= (`shouldSatisfy` balanced)

    it "reports an import of an identity on the chain as a cycle even when the chain is as long as it may be" $
      bounded 1024 16 1 $ \rig owned → do
        _ ← supply rig owned "a" ["return import('a')"]
        _ ← admit owned "a"
        _ ← advance owned
        failureOf owned "a" >>= \failed → boundaryReason failed `shouldBe` ModuleRefused (ImportCycle ["game:a", "game:a"])
