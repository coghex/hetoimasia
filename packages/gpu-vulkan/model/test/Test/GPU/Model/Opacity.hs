-- | Examples proving that a validated 'Hetoimasia.GPU.Model.Budget.Budgets' is
-- read-only to a client outside the package.
--
-- The other budget examples import the model package directly, so they share
-- this suite's own module environment and cannot observe what the package
-- boundary exposes. These examples therefore compile separate single-module
-- clients with the same compiler against the package database this build
-- already produced, exposing @base@, @hetoimasia-foundation@, and
-- @hetoimasia-gpu-vulkan-model@ and hiding everything else. What such a client
-- can say is exactly what the library's @exposed-modules@ and each module's
-- export list allow, which is the boundary the opacity claim is about.
--
-- Thirteen clients are compiled. Twelve must be rejected: one for each of the
-- eleven validated fields, reached for through record-update syntax, and one
-- that names the constructor. Each is checked against the specific diagnostic
-- that names the rejection's cause, so a missing package, an absent compiler,
-- or an unrelated error can never be mistaken for the guarantee holding. One
-- must be accepted, linked, and run, which is both the control proving the
-- environment is sound and the evidence that closing the representation left
-- 'Hetoimasia.GPU.Model.Budget.BudgetRequest' editable and every public reader
-- usable.
--
-- The boundary protects the validator's whole promise. 'validateBudgets' is the
-- only way to obtain a 'Budgets', so every field of one is positive,
-- representable, and consistent with the sums derived from it; and
-- 'Hetoimasia.GPU.Model.newGpuModel' stores what it is handed rather than
-- re-checking it. A client that could replace a field could therefore put a
-- zero, or a presentation pool that is not the checked sum of the image and
-- frame-slot limits, into a running model: a zero pool answers
-- @Backpressure PresentationPoolBudget@ to the first reservation, and a zero
-- action limit makes every owner turn do no work.
--
-- Nothing here re-checks a budget at run time. The guarantee is the absence of
-- a way to express the rewrite, checked when the client is compiled.
--
-- The compilation harness lives in "Test.Support.ExternalClient", shared with
-- the foundation, runtime, messaging, Lua, and GLFW opacity examples.
module Test.GPU.Model.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "budget opacity across the package boundary" $ do
  mapM_ rejectsFieldUpdate protectedFields

  it "rejects a client that names the constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Budgets"

  it "accepts and runs a client that edits a request, validates it, and reads every limit" $
    withClient "Main.hs" supportedClient $ \compile → do
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
        `shouldBe` [ "limits = [3,2,32,2,5,7,268435456,4096,64,7]"
                   , "cap = Duration 25000000ns"
                   , "pool is the checked sum = True"
                   , "schedule = [Duration 5000000ns,Duration 10000000ns,Duration 20000000ns,Duration 25000000ns]"
                   , "model limits = [3,2,32,2,5,7,268435456,4096,64,7]"
                   , "model cap = Duration 25000000ns"
                   ]

-- | Every field of a validated configuration, with the type its replacement
-- would have and the import that type needs.
--
-- The whole record is listed rather than the derived pool alone: a client that
-- could rewrite any of them could put a value the validator rejects into a
-- model, and the example that names one field must not pass for another's
-- reason.
protectedFields ∷ [(String, String, [String])]
protectedFields =
  [ (reader, "Natural", ["import Numeric.Natural (Natural)"])
  | reader ←
      [ "targetRecordLimit"
      , "frameSlotLimit"
      , "aggregateFrameSlotLimit"
      , "generationLimit"
      , "imageTrackingLimit"
      , "presentationPoolCapacity"
      , "byteLimit"
      , "objectLimit"
      , "reclaimExaminationLimit"
      , "progressActionLimit"
      ]
  ]
    <> [("idleBackoffCap", "Duration", ["import Hetoimasia.Foundation.Time (Duration)"])]

-- | Compile one field-replacement client and require the compiler to reject it
-- because the replacement is inaccessible, naming the reader that was reached
-- for so the eleven cases cannot pass for each other's reasons.
rejectsFieldUpdate ∷ (String, String, [String]) → Spec
rejectsFieldUpdate (reader, replacementType, extraImports) =
  it ("rejects a client that replaces " <> reader <> " with record update") $
    withClient "Client.hs" (updateClient reader replacementType extraImports) $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` reader

-- | Write one client into a temporary directory, compile it against this
-- build's own package database, and hand the outcome to the example.
--
-- The model's clients see exactly @base@, @hetoimasia-foundation@, and
-- @hetoimasia-gpu-vulkan-model@. Every package either library depends on is a
-- boot library, so the build's own database resolves the whole unit graph and
-- no dependency store has to be exposed.
withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation", "hetoimasia-gpu-vulkan-model"]

-- | The client from the issue, one field at a time: it replaces part of a
-- validated configuration through record-update syntax, which needs only the
-- field label in scope.
--
-- The reader is imported by name in every case, which is what makes the
-- rejection mean what the example claims: an unimported label is out of scope
-- whether or not it is a field, so a client that did not import it would be
-- rejected on the unrepaired library too.
--
-- The configuration itself comes in as an argument, because a client can
-- obtain one only from 'validateBudgets'; what is under test is the rewrite,
-- not the acquisition.
updateClient ∷ String → String → [String] → String
updateClient reader replacementType extraImports =
  unlines $
    [ "module Client (rewritten) where"
    , ""
    ]
      <> extraImports
      <> [ "import Hetoimasia.GPU.Model.Budget (Budgets, " <> reader <> ")"
         , ""
         , "rewritten ∷ Budgets → " <> replacementType <> " → Budgets"
         , "rewritten budgets replacement = budgets { " <> reader <> " = replacement }"
         ]

-- | The other half of the same reach: building a configuration of the client's
-- own by naming the constructor, which would bypass validation entirely.
--
-- This one is rejected on master as well, since the type has always been
-- exported without its children. It is kept as the guard proving that the
-- field-label route the eleven cases above close was the only one open.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (named) where"
    , ""
    , "import Hetoimasia.GPU.Model.Budget (Budgets (Budgets))"
    , ""
    , "named ∷ Maybe Budgets"
    , "named = Nothing"
    ]

-- | A client using only what the boundary offers: an edited 'BudgetRequest',
-- the validator, every public reader, the backoff schedule the cap describes,
-- and a model built from the result.
--
-- It reports the limits it read, the cap, whether the derived pool is still the
-- checked sum of the image and frame-slot limits, and the same readings taken
-- back out of the model through
-- 'Hetoimasia.GPU.Model.modelBudgets', so the example checks that the
-- configuration survived construction unchanged and not merely that the client
-- built.
supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Data.Unique (newUnique)"
    , "import Hetoimasia.Foundation.Time (Duration)"
    , "import Hetoimasia.GPU.Model (modelBudgets, newGpuModel)"
    , "import Hetoimasia.GPU.Model.Budget"
    , "  ( BudgetRequest (..)"
    , "  , Budgets"
    , "  , aggregateFrameSlotLimit"
    , "  , backoffSchedule"
    , "  , byteLimit"
    , "  , defaultBudgetRequest"
    , "  , frameSlotLimit"
    , "  , generationLimit"
    , "  , idleBackoffCap"
    , "  , imageTrackingLimit"
    , "  , objectLimit"
    , "  , presentationPoolCapacity"
    , "  , progressActionLimit"
    , "  , reclaimExaminationLimit"
    , "  , targetRecordLimit"
    , "  , validateBudgets"
    , "  )"
    , "import Hetoimasia.GPU.Model.Identity (sessionIdentity)"
    , "import Numeric.Natural (Natural)"
    , "import System.Exit (exitFailure)"
    , "import System.IO (hPutStrLn, stderr)"
    , ""
    , "-- Small budgets stated the supported way: edit the request, then"
    , "-- validate it."
    , "request ∷ BudgetRequest"
    , "request ="
    , "  defaultBudgetRequest"
    , "    { requestedTargetRecords = 3"
    , "    , requestedFrameSlots = 2"
    , "    , requestedImageTracking = 5"
    , "    , requestedProgressActions = 7"
    , "    , requestedIdleBackoffMilliseconds = 25"
    , "    }"
    , ""
    , "limits ∷ Budgets → [Natural]"
    , "limits budgets ="
    , "  [ targetRecordLimit budgets"
    , "  , frameSlotLimit budgets"
    , "  , aggregateFrameSlotLimit budgets"
    , "  , generationLimit budgets"
    , "  , imageTrackingLimit budgets"
    , "  , presentationPoolCapacity budgets"
    , "  , byteLimit budgets"
    , "  , objectLimit budgets"
    , "  , reclaimExaminationLimit budgets"
    , "  , progressActionLimit budgets"
    , "  ]"
    , ""
    , "cap ∷ Budgets → Duration"
    , "cap = idleBackoffCap"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  budgets ← case validateBudgets request of"
    , "    Left reason → do"
    , "      hPutStrLn stderr (\"the edited request must validate: \" <> show reason)"
    , "      exitFailure"
    , "    Right validated → pure validated"
    , "  putStrLn (\"limits = \" <> show (limits budgets))"
    , "  putStrLn (\"cap = \" <> show (cap budgets))"
    , "  putStrLn"
    , "    ( \"pool is the checked sum = \""
    , "        <> show"
    , "          ( presentationPoolCapacity budgets"
    , "              == imageTrackingLimit budgets + frameSlotLimit budgets"
    , "          )"
    , "    )"
    , "  putStrLn (\"schedule = \" <> show (backoffSchedule budgets))"
    , "  unique ← newUnique"
    , "  let (model, _) = newGpuModel (sessionIdentity unique) budgets"
    , "  putStrLn (\"model limits = \" <> show (limits (modelBudgets model)))"
    , "  putStrLn (\"model cap = \" <> show (cap (modelBudgets model)))"
    ]
