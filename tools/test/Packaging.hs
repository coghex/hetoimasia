-- | Hspec coverage for what the root package's source distribution carries.
--
-- This suite drives the repository's own validation tools and reads its own
-- workflow files out of the checkout it is running in, so a release that does
-- not carry one of them declares a suite it cannot run. A Git checkout hides
-- that: it holds every tracked file whether or not packaging names it, and the
-- omission surfaces only once a distribution is unpacked somewhere else.
--
-- So these examples ask Cabal for the inventory it would actually ship and
-- check the consumed files against it directly. Reading `extra-source-files`
-- instead would compare that declaration with the inventory derived from it,
-- which agrees with itself however much is missing.
module Packaging (spec) where

import Control.Exception (evaluate)
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf, nub, sort, stripPrefix)
import Sandbox (run, sanitizedEnvironment)
import System.Directory (copyFile, createDirectoryIfMissing, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (normalise, pathSeparator, takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import VulkanProof (readByTheseExamples)

-- | Every package-relative path this suite executes or reads out of the
-- checkout, together with the helpers those files load for themselves. An
-- indirect helper is as mandatory as the file naming it — @reuse.py@ imports
-- @receipts.py@, @docs_land.sh@ runs @docs_land_paths.py@ — and is just as
-- invisible to a reader auditing the test modules alone.
consumed ∷ [(FilePath, String)]
consumed =
  [ ("tools/docs_land.sh", "Main.hs lands documentation through it")
  , ("tools/docs_land_paths.py", "docs_land.sh runs it as its selection gate")
  , ("tools/flake/catalog.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/checks.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/common.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/install_skills.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/lab.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/probe.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/process.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/state.py", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/flake/probes.json", "FlakeLab.hs exercises the local lab and its helpers")
  , ("tools/display/x11.sh", "the separate x11-helper-tests suite runs it")
  , ("tools/display/wayland.sh", "the separate wayland-helper-tests suite runs it")
  , ("tools/ci-image/provision.sh", "Packaging.hs reads the pins it sources")
  , ("tools/ci-image/compositor.pin", "provision.sh sources it")
  , ("tools/ci-image/toolchain.pin", "provision.sh sources it")
  , ("tools/validation/plan.py", "Validation.hs, Execution.hs, Reuse.hs, TimingStep.hs, and CiImage.hs run it")
  , ("tools/validation/ci_image.py", "CiImage.hs runs it, and plan.py and run.py load it")
  , ("tools/ci-image/builder.py", "CiImage.hs runs it")
  , ("tools/native/native.py", "CiImage.hs runs it, and ci_image.py runs it to verify a worker")
  , ("tools/native/glfw.pin", "native.py reads it")
  , ("tools/native/vulkan.pin", "vulkan.py reads it, and provision.sh sources it")
  , ("tools/native/vulkan.py", "native.py imports it, and ci_image.py imports it to declare a worker's map")
  , ("tools/validation/range.py", "Execution.hs runs it")
  , ("tools/validation/run.py", "Execution.hs, Reuse.hs, and TimingStep.hs run it")
  , ("tools/validation/receipts.py", "run.py, aggregate.py, and reuse.py load it")
  , ("tools/validation/aggregate.py", "Execution.hs, Reuse.hs, and TimingStep.hs run it")
  , ("tools/validation/reuse.py", "Reuse.hs runs it")
  , ("tools/validation/review_gate.py", "ReviewGate.hs runs it")
  , ("tools/validation/review_provenance.py", "ApprovalProvenance.hs runs it")
  , ("tools/validation/review_replay.py", "ReviewReplay.hs and ApprovalProvenance.hs run it")
  , ("tools/validation/timings.py", "Timings.hs and TimingStep.hs run it")
  , (".github/workflows/review-gate.yml", "DismissalStep.hs extracts its dismissal step")
  , ("tools/validation/catalog.json", "Reuse.hs routes its groups through the workflow's worker declarations")
  , (".github/workflows/validation.yml", "TimingStep.hs and CiImage.hs extract its steps, and Reuse.hs reads its worker declarations")
  , ("cabal.project.vulkan", "VulkanProof.hs reads the packages and constraints it declares")
  , ("tools/toolchain/binding.pin", "VulkanProof.hs reads the binding flags it pins")
  , ("tools/vulkan-proof/run-proof.sh", "VulkanProof.hs reads it to check it supplies no native-session consent")
  , ("tools/vulkan-proof/run-shaders.sh", "VulkanProof.hs reads it to check the proof route runs the shader suite")
  , ("docs/vulkan/macos.md", "VulkanProof.hs reads the retained record it must agree with")
  , ("docs/vulkan/linux.md", "VulkanProof.hs reads the retained record it must agree with")
  , ("docs/vulkan_compatibility_record.md", "VulkanProof.hs checks it still quotes the records' own totals")
  , ("docs/vulkan/macos-provisioned.md", "VulkanProof.hs reads the provisioned record it must agree with")
  , ("docs/vulkan/linux-provisioned.md", "VulkanProof.hs reads the provisioned record it must agree with")
  , ("docs/vulkan/macos-vk6.md", "VulkanProof.hs reads the VK-6 record it must agree with")
  , ("docs/vulkan/linux-vk6.md", "VulkanProof.hs reads the VK-6 record it must agree with")
  , ("docs/vulkan/macos-vk5.md", "VulkanProof.hs reads the VK-5 record it must agree with")
  , ("docs/vulkan/linux-vk5.md", "VulkanProof.hs reads the VK-5 record it must agree with")
  ]

-- | Files an example reads out of a checkout that the distribution must never
-- carry, because a project file inside an unpacked distribution breaks
-- resolution wherever it lands. The example reading them reports itself
-- pending where they are absent rather than failing, so the suite still runs
-- from a distribution; where it can see them it holds them as usual.
checkoutOnly ∷ [(FilePath, String)]
checkoutOnly =
  [ ("cabal.project", "VulkanProof.hs resolves the packages it names to keep the binding off the floor")
  , ("cabal.project.cpu", "VulkanProof.hs resolves the packages it names to keep the binding off the floor")
  , ( "packages/gpu-vulkan/native/hetoimasia-gpu-vulkan-native.cabal"
    , "VulkanProof.hs reads the native package's dependencies beside the ordinary projects, as a sibling package"
    )
  , ( "packages/glfw/hetoimasia-glfw.cabal"
    , "VulkanProof.hs reads the GLFW package's interop flag and dependencies beside the ordinary projects, as a sibling package"
    )
  ]

-- | The packaging declaration the inventory is derived from.
manifest ∷ FilePath
manifest = "hetoimasia.cabal"

-- | The image recipe's own provisioning script, which sources pin files the
-- distribution must therefore carry too.
provisioning ∷ FilePath
provisioning = "tools/ci-image/provision.sh"

-- | The entry withdrawn from a throwaway copy to prove the check reacts. Any
-- consumed path would do; this one is the script Main.hs's own examples run.
withdrawn ∷ FilePath
withdrawn = "tools/docs_land.sh"

spec ∷ Spec
spec = describe "Source distribution" $ do
  it "carries every file this suite runs out of the checkout" $ do
    checkout ← getCurrentDirectory
    inventory ← packagedFiles checkout
    case unpackaged inventory of
      [] → pure ()
      absent → expectationFailure (report absent)

  it "never carries a checkout-only file" $ do
    checkout ← getCurrentDirectory
    inventory ← packagedFiles checkout
    [path | (path, _) ← checkoutOnly, path `elem` inventory] `shouldBe` []

  it "accounts for every file the Vulkan proof boundary reads" $ do
    -- That module states what it reads once, for the planner's sake; this holds
    -- the same list to the packaging inventory's two halves, so a file it
    -- starts reading is either carried or declared checkout-only.
    let accounted = map fst consumed ++ map fst checkoutOnly
    filter (`notElem` accounted) readByTheseExamples `shouldBe` []

  it "carries every pin the provisioning script sources, whatever those come to be" $ do
    -- Naming the pins in `consumed` would only hold for the pins someone
    -- remembered to name. This reads the shipped script instead, so a pin
    -- added to it later is carried or this fails.
    checkout ← getCurrentDirectory
    sourced ← sourcedPins checkout
    sourced `shouldBe` ["tools/ci-image/compositor.pin", "tools/ci-image/toolchain.pin", "tools/native/vulkan.pin"]
    inventory ← packagedFiles checkout
    filter (`notElem` inventory) sourced `shouldBe` []

  it "names a consumed file the packaging declaration has stopped carrying" $ do
    checkout ← getCurrentDirectory
    inventory ← packagedFiles checkout
    -- The mutation happens in a copy assembled from that inventory, never in
    -- the checkout: the examples must not edit the tree they are describing,
    -- and the copy is also what keeps this independent of where the package
    -- sits inside a project.
    withSystemTempDirectory "hetoimasia-packaging" $ \directory → do
      mapM_ (transplant checkout directory) inventory
      undeclare (directory </> manifest) withdrawn
      reduced ← packagedFiles directory
      unpackaged reduced `shouldBe` [withdrawn]

-- | The consumed paths the given inventory does not carry, in declaration
-- order. Additional packaged files are none of this check's business; only an
-- absence is.
unpackaged ∷ [FilePath] → [FilePath]
unpackaged inventory = [path | (path, _) ← consumed, path `notElem` inventory]

report ∷ [FilePath] → String
report absent =
  "the source distribution omits files this suite consumes:\n"
    ++ concat ["  " ++ path ++ " — " ++ reason ++ "\n" | (path, reason) ← consumed, path `elem` absent]
    ++ "declare each one in extra-source-files in "
    ++ manifest

-- | The package-relative inventory Cabal would ship from the given directory.
--
-- @--list-only@ reads the packaging declaration and the package's own sources,
-- so it answers in an unpacked distribution with no Git metadata exactly as it
-- does in a checkout, which is the situation this whole check exists for.
--
-- Only the exit status is held to: Cabal writes the inventory to its standard
-- output and keeps its notices separate, and one of those notices is that a
-- surrounding @cabal.project@ applies — which it does in an unpacked
-- distribution and does not in the package's own checkout. Reading that
-- difference as a failure would tie this to one layout.
packagedFiles ∷ FilePath → IO [FilePath]
packagedFiles directory = do
  settings ← sanitizedEnvironment
  (status, listing, errors) ← run settings directory "cabal" ["sdist", "--list-only"]
  case status of
    ExitFailure code → do
      expectationFailure
        ("cabal sdist --list-only exited " ++ show code ++ " in " ++ directory ++ "\n" ++ errors)
      pure []
    ExitSuccess → do
      let entries = map normalise (filter (not . null) (map trim (lines listing)))
      case [takeDirectory entry | entry ← entries, takeFileName entry == manifest] of
        root : _ → pure (map (beneath root) entries)
        [] → do
          expectationFailure
            ("cabal sdist --list-only in " ++ directory ++ " listed no " ++ manifest ++ ":\n" ++ listing)
          pure []

-- | One listing entry as a package-relative path.
--
-- Cabal answers relative to the project root, which is the package's own
-- directory in this checkout and its parent in a distribution unpacked beside
-- its siblings under one @cabal.project@. The package's @.cabal@ file sits at
-- the package root and is always listed, so it names the prefix to remove and
-- this reads the same in either layout.
beneath ∷ FilePath → FilePath → FilePath
beneath root entry
  | root == "." = entry
  | prefix `isPrefixOf` entry = drop (length prefix) entry
  | otherwise = entry
  where
    prefix = root ++ [pathSeparator]

-- | Copy one packaged file into the throwaway copy, creating its directories.
transplant ∷ FilePath → FilePath → FilePath → IO ()
transplant source destination path = do
  let target = destination </> path
  createDirectoryIfMissing True (takeDirectory target)
  copyFile (source </> path) target

-- | Remove one @extra-source-files@ entry, leaving the file itself in place, so
-- the copy differs from the original in its declaration alone.
undeclare ∷ FilePath → FilePath → IO ()
undeclare document path = do
  text ← readFile document
  _ ← evaluate (length text)
  let remaining = filter ((/= path) . trim) (lines text)
  length remaining `shouldBe` length (lines text) - 1
  writeFile document (unlines remaining)

-- | The recipe-relative files the provisioning script sources, in path order.
--
-- The script reaches them through its own `$recipe` root, which is what a
-- `.` line names; anything else it sources is not a packaged recipe input and
-- is not this check's business.
sourcedPins ∷ FilePath → IO [FilePath]
sourcedPins checkout = do
  text ← readFile (checkout </> provisioning)
  _ ← evaluate (length text)
  pure (sort (nub [path | line ← lines text, Just path ← [sourcedPath line]]))

sourcedPath ∷ String → Maybe FilePath
sourcedPath line = case words (trim line) of
  [".", argument] → stripPrefix "$recipe/" (filter (/= '"') argument)
  _ → Nothing

trim ∷ String → String
trim = dropWhileEnd isSpace . dropWhile isSpace
