-- | Examples proving that 'Hetoimasia.Foundation.Messaging.Payload.Prepared'
-- can be obtained only through preparation, from a client outside the
-- foundation package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Engine.Resources.Opacity", exposing @base@, @deepseq@, and
-- @hetoimasia-foundation@ and hiding everything else; @deepseq@ is exposed
-- because every client that defines a payload imports "Control.DeepSeq".
--
-- Six clients must be rejected, each for the specific diagnostic naming its
-- cause, so a missing package, an absent compiler, or an unrelated error can
-- never pass for the boundary holding. Two of them reach for 'Data.Coerce':
-- one wraps an unprepared value, and one changes a handle's payload type
-- between two client newtypes over the same representation. The second is the
-- one that proves the nominal role, and it carries a control coercion between
-- the two newtypes themselves in the same module, which must not be reported.
--
-- One client must be accepted, linked, and run. It is the environment control,
-- and it shows that preparing, reading, and forwarding stay usable, with
-- unconstrained polymorphic readers and forwarders that require no 'NFData'.
module Test.Engine.Messaging.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Engine.Resources.Opacity (Client (..), Mode (..), rejectedBecause, withPackageClient)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)

spec ∷ Spec
spec = describe "Prepared payload opacity across the package boundary" $ do
  it "rejects a client that names the constructor" $
    withClient constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Prepared"

  it "rejects a client that replaces the payload with record update" $
    withClient recordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "preparedValue"

  it "rejects a client that wraps an unprepared value with coerce" $
    withClient wrapCoerceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match representation of type"
      clientOutput outcome `shouldContain` "is not in scope"

  it "rejects a client that changes the payload type with coerce between equivalent newtypes" $
    withClient retypeCoerceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match type"
      clientOutput outcome `shouldContain` "Metres"
      clientOutput outcome `shouldContain` "Feet"
      clientOutput outcome `shouldContain` ("Client.hs:" <> show retypeLine <> ":")
      -- The control coercion between the newtypes themselves is accepted, so
      -- only the role of Prepared can have caused the rejection.
      clientOutput outcome `shouldNotContain` ("Client.hs:" <> show controlLine <> ":")

  it "rejects a client that maps over a handle with fmap" $
    withClient fmapClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "No instance for"
      clientOutput outcome `shouldContain` "Functor Prepared"

  it "rejects a client that traverses a handle" $
    withClient traverseClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "No instance for"
      clientOutput outcome `shouldContain` "Traversable Prepared"

  it "accepts and runs a client that prepares, reads, and forwards without NFData" $
    withPackageClient packages "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) { cwd = Just (clientDirectory outcome) }
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "read = Reading \"thermometer\" [20,21,22]"
                   , "forwarded = Reading \"thermometer\" [20,21,22]"
                   , "kept = [20,21,22]"
                   , "rejected = sample unavailable"
                   ]

packages ∷ [String]
packages = ["base", "deepseq", "hetoimasia-foundation"]

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient packages "Client.hs"

-- | Building a handle of the client's own by naming the constructor.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared (Prepared))"
    , ""
    , "forged ∷ Int → Prepared Int"
    , "forged = Prepared"
    ]

-- | Replacing a prepared payload through record-update syntax, which needs only
-- the reader in scope. The reader is imported by name, so the rejection means
-- it is not a field rather than that it was never imported.
recordUpdateClient ∷ String
recordUpdateClient =
  unlines
    [ "module Client (replaced) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)"
    , ""
    , "replaced ∷ Prepared Int → Int → Prepared Int"
    , "replaced handle replacement = handle { preparedValue = replacement }"
    ]

-- | Wrapping a value that was never prepared with 'Data.Coerce.coerce'.
wrapCoerceClient ∷ String
wrapCoerceClient =
  unlines
    [ "module Client (wrapped) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "wrapped ∷ Int → Prepared Int"
    , "wrapped = coerce"
    ]

-- | Re-typing a handle between two client newtypes over the same
-- representation. With a representational role this would compile without the
-- constructor in scope, so it is the client that exercises the role itself.
retypeCoerceClient ∷ String
retypeCoerceClient =
  unlines
    [ "module Client (feet, relabelled) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "newtype Metres = Metres Double"
    , "newtype Feet = Feet Double"
    , ""
    , "feet ∷ Metres → Feet"
    , "feet = coerce"
    , ""
    , "relabelled ∷ Prepared Metres → Prepared Feet"
    , "relabelled = coerce"
    ]

-- | The source lines of the control and the rejected coercion in
-- 'retypeCoerceClient'.
controlLine, retypeLine ∷ Int
controlLine = 10
retypeLine = 13

-- | Transforming a prepared payload without preparing the result.
fmapClient ∷ String
fmapClient =
  unlines
    [ "module Client (incremented) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "incremented ∷ Prepared Int → Prepared Int"
    , "incremented = fmap (+ 1)"
    ]

-- | Traversing a prepared payload, which would rebuild it effectfully without
-- preparation.
traverseClient ∷ String
traverseClient =
  unlines
    [ "module Client (checked) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "checked ∷ Prepared Int → Maybe (Prepared Int)"
    , "checked = traverse Just"
    ]

-- | A client using only what the module offers. The reader and forwarder are
-- polymorphic with no 'NFData' constraint, and the failing preparation shows
-- a nested failure raised by 'prepare' with its own type.
supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.DeepSeq (NFData (rnf))"
    , "import Control.Exception (ErrorCall (ErrorCall), throw, try)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)"
    , ""
    , "data Reading = Reading !String [Int]"
    , "  deriving (Show)"
    , ""
    , "instance NFData Reading where"
    , "  rnf (Reading label samples) = rnf label `seq` rnf samples"
    , ""
    , "samplesOf ∷ Reading → [Int]"
    , "samplesOf (Reading _ samples) = samples"
    , ""
    , "describePayload ∷ Show a ⇒ Prepared a → String"
    , "describePayload = show . preparedValue"
    , ""
    , "forward ∷ Prepared a → (Prepared a, Prepared a)"
    , "forward handle = (handle, handle)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  prepared ← prepare (Reading \"thermometer\" [20, 21, 22])"
    , "  putStrLn (\"read = \" <> describePayload prepared)"
    , "  let (kept, sent) = forward prepared"
    , "  putStrLn (\"forwarded = \" <> describePayload sent)"
    , "  putStrLn (\"kept = \" <> show (samplesOf (preparedValue kept)))"
    , "  failed ← try (prepare (Reading \"broken\" [1, throw (ErrorCall \"sample unavailable\")]))"
    , "  case failed of"
    , "    Left (ErrorCall message) → putStrLn (\"rejected = \" <> message)"
    , "    Right _ → putStrLn \"rejected = nothing\""
    ]
