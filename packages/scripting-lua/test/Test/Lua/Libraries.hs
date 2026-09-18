-- | Which standard libraries a VM has.
--
-- The bridge opens libraries one at a time or not at all. There is no call it
-- offers whose only outcome is the whole standard library, which matters
-- because the whole standard library is @io@, @os@, @debug@, and a native
-- module loader -- the four things untrusted execution cannot be given.
--
-- The policy that decides which domain gets which library is not here; it is
-- LUA-3's. What is here is that each one is separately refusable, and that
-- refusing them all leaves a working VM.
module Test.Lua.Libraries (spec) where

import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Bridge
  ( Library
      ( LibraryBase
      , LibraryDebug
      , LibraryMath
      , LibraryPackage
      , LibraryString
      )
  , chunkName
  , evalChunk
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Support (newRecorder, recorded, recordingCallback, withVm)

-- | Each library, and a global that exists only once it is open.
--
-- @package@ is probed through @require@ rather than the @package@ table: the
-- module loader is the part of it that matters here.
probes ∷ [(Text, Text)]
probes =
  [ ("base", "print")
  , ("string", "string")
  , ("math", "math")
  , ("io", "io")
  , ("os", "os")
  , ("debug", "debug")
  , ("package", "require")
  ]

-- | A chunk that calls @found_<name>@ for each library this VM turns out to
-- have. It uses only language syntax and the globals the example installed, so
-- it runs in a VM with nothing open.
probeChunk ∷ ByteString
probeChunk =
  Text.encodeUtf8 . Text.concat $
    [ "if " <> global <> " ~= nil then " <> reporter name <> "() end\n"
    | (name, global) ← probes
    ]

reporter ∷ Text → Text
reporter name = "found_" <> name

-- | Run the probe in a VM with the named libraries open, and answer which
-- libraries it found.
present ∷ [Library] → IO [Text]
present libraries =
  withVm libraries $ \vm → do
    trace ← newRecorder
    mapM_ (\(name, _) → recordingCallback vm trace (reporter name)) probes
    evalChunk vm (chunkName "libraries") probeChunk
    sort . map (Text.drop (Text.length "found_")) <$> recorded trace

spec ∷ Spec
spec = describe "libraries" $ do
  it "opens none when none are named, and still runs a chunk" $
    present [] >>= (`shouldBe` [])

  it "opens exactly the libraries named" $
    present [LibraryBase, LibraryString] >>= (`shouldBe` sort ["base", "string"])

  it "can open one that is not the base library" $
    present [LibraryDebug] >>= (`shouldBe` ["debug"])

  it "leaves the native module loader out unless package is named" $ do
    present [LibraryBase, LibraryMath] >>= (`shouldBe` sort ["base", "math"])
    present [LibraryBase, LibraryPackage] >>= (`shouldBe` sort ["base", "package"])
