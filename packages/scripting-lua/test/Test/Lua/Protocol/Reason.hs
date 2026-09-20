{-# LANGUAGE MagicHash #-}

-- | The bound on a failure reason's detail, asked of the value and of the
-- module's boundary.
--
-- Two claims are checked here, because either one alone leaves the bound
-- worthless. The first is that 'failureReason' retains no more than
-- 'reasonDetailBound' characters /and no more storage than those characters
-- need/: a 'Text' is a slice of a shared array, so a truncated detail can name
-- 512 characters while holding a megabyte alive, and a detail already within
-- the bound can be a small window onto a large allocation. The examples build
-- their details out of a million-character source and assert on the array
-- behind the result, which they read through "Data.Text.Internal" — a
-- dependency of these examples and not of the model.
--
-- Each of those examples also asserts that the /source/ slice it handed in was
-- oversized. Without that, an example would still pass if 'Text.take' had
-- quietly started copying, and would therefore stop being evidence about
-- 'failureReason' at all.
--
-- The second claim is that a client outside the module cannot write a detail
-- into a reason. An example inside this suite cannot ask that question: it
-- shares the suite's module environment, and the suite is built against the
-- model directly. The two clients below are compiled separately against this
-- build's own package database, and they differ in one expression — the
-- accepted one reads a reason's code and detail and builds one through
-- 'failureReason', the rejected one adds a record update naming
-- @reasonDetail@. Both resolve the private model sublibrary and import the
-- module, so the rejection is about the update and not about the environment.
module Test.Lua.Protocol.Reason (spec) where

import Data.Array.Byte (ByteArray (ByteArray))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Internal as Internal
import GHC.Exts (Int (I#), sizeofByteArray#)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (ScriptFault)
  , failureReason
  , reasonCode
  , reasonDetail
  , reasonDetailBound
  )
import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldSatisfy
  )
import Test.Support.ExternalClient
  ( Client (clientOutput, clientStatus)
  , Mode (Typecheck)
  , rejectedBecause
  , withStorePackageClient
  )

-- | The size of the array a text is a window onto.
--
-- This is the whole point of the storage examples: 'Text.length' answers how
-- much of the array the value names, and this answers how much of it the value
-- keeps alive.
backingBytes ∷ Text → Int
backingBytes (Internal.Text (ByteArray array) _ _) = I# (sizeofByteArray# array)

-- | The most storage a detail within the bound can need: every one of its
-- characters encoded at UTF-8's widest.
storageBound ∷ Int
storageBound = 4 * reasonDetailBound

-- | A million characters, which no bounded detail may retain.
oversized ∷ Text
oversized = Text.replicate 1000000 "x"

-- | A million characters of one, two, three, and four UTF-8 bytes each, so a
-- truncation that counted bytes would land inside a character.
oversizedMultibyte ∷ Text
oversizedMultibyte = Text.replicate 250000 "aé漢😀"

-- | The detail a reason built from this text retains.
detailOf ∷ Text → Text
detailOf = reasonDetail . failureReason ScriptFault

-- The model sublibrary is named by its local unit id, since it shares its
-- package name with the package's other libraries, and it stays private: what
-- these clients may say is what its `exposed-modules` and this module's export
-- list allow. The dependency store is exposed as well so that a unit the model
-- was resolved against is never missing, which would reject both clients for a
-- reason about the environment.
withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withStorePackageClient
    ["base", "text", "hetoimasia-scripting-lua-0.1.0.0-inplace-model"]
    "Client.hs"

spec ∷ Spec
spec = describe "failure reason detail" $ do
  it "truncates an oversized detail to the bound and retains only its storage" $ do
    backingBytes oversized `shouldSatisfy` (> storageBound)
    let detail = detailOf oversized
    Text.length detail `shouldBe` reasonDetailBound
    detail `shouldBe` Text.take reasonDetailBound oversized
    backingBytes detail `shouldSatisfy` (<= storageBound)

  it "truncates a multibyte detail by characters, never inside one" $ do
    let detail = detailOf oversizedMultibyte
    Text.length detail `shouldBe` reasonDetailBound
    detail `shouldBe` Text.take reasonDetailBound oversizedMultibyte
    backingBytes detail `shouldSatisfy` (<= storageBound)

  it "leaves a detail shorter than the bound unchanged" $ do
    let reason = failureReason ScriptFault "the behaviour raised"
    reasonCode reason `shouldBe` ScriptFault
    reasonDetail reason `shouldBe` "the behaviour raised"
    detailOf "" `shouldBe` ""

  it "copies a short detail out of the much larger source it was cut from" $ do
    let slice = Text.take 8 oversized
    backingBytes slice `shouldSatisfy` (> storageBound)
    let detail = detailOf slice
    detail `shouldBe` slice
    backingBytes detail `shouldSatisfy` (<= storageBound)

  it "copies a detail of exactly the bound out of the source it was cut from" $ do
    let slice = Text.take reasonDetailBound oversized
    Text.length slice `shouldBe` reasonDetailBound
    backingBytes slice `shouldSatisfy` (> storageBound)
    let detail = detailOf slice
    detail `shouldBe` slice
    backingBytes detail `shouldSatisfy` (<= storageBound)

  it "accepts a client that reads a reason and builds one through failureReason" $
    withClient readingClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "a client using the module's whole surface must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

  it "rejects the same client once it writes a detail through record update" $
    withClient updatingClient $ \compile → do
      outcome ← compile Typecheck
      -- The diagnostic has to name the detail the update tried to write, and
      -- not an environment failure, which `rejectedBecause` rules out. What it
      -- calls that name -- an unavailable record field, an unavailable
      -- constructor, a name that is not a record selector -- follows from the
      -- representation the module chose to enforce the bound with, so pinning
      -- one of them here would make this example a test of that choice rather
      -- than of the boundary. What is pinned instead is the expression the
      -- compiler rejected, which is the update and nothing else; the accepted
      -- client above, identical but for that expression, is what makes this a
      -- statement about the update rather than about the import.
      rejectedBecause outcome "reasonDetail"
      clientOutput outcome `shouldContain` "bounded {reasonDetail ="

-- | Everything the module offers a client: both accessors, the constructor
-- function, and the bound.
readingClient ∷ String
readingClient = unlines (clientPreamble <> ["reason = bounded"])

-- | The same client, writing a detail into the reason it just built.
updatingClient ∷ String
updatingClient =
  unlines (clientPreamble <> ["reason = bounded {reasonDetail = Text.replicate 1000000 (Text.pack \"x\")}"])

-- | What both clients share: the import list and the reason they inspect.
clientPreamble ∷ [String]
clientPreamble =
  [ "module Client (observed, reason) where"
  , ""
  , "import qualified Data.Text as Text"
  , "import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure"
  , "  ( FailureReason"
  , "  , ReasonCode (ScriptFault)"
  , "  , failureReason"
  , "  , reasonCode"
  , "  , reasonDetail"
  , "  , reasonDetailBound"
  , "  )"
  , ""
  , "bounded ∷ FailureReason"
  , "bounded = failureReason ScriptFault (Text.pack \"small\")"
  , ""
  , "observed ∷ (ReasonCode, Int, Int)"
  , "observed = (reasonCode bounded, Text.length (reasonDetail bounded), reasonDetailBound)"
  , ""
  , "reason ∷ FailureReason"
  ]
