-- | Hspec coverage for the boundary around the Vulkan proof harness.
--
-- Issue #158's first requirement is that the harness exists and that the
-- mandatory validation floor never builds it. That used to be established for
-- free: the floor ran on a CI image with no Vulkan loader at all, so a package
-- added to either ordinary project file failed outright. VK-4 provisioned a
-- loader, a driver, the validation layers, and a compiler into that image, and
-- a successful build there now proves nothing about independence. So the claim
-- is checked here directly instead, by reading the two ordinary project files
-- and requiring that neither names the proof package or resolves the binding.
--
-- Those two files, and the sibling packages they name, are read out of the
-- checkout and are deliberately not in the root package's source distribution:
-- a `cabal.project` inside an unpacked distribution breaks resolution wherever
-- it lands. `Packaging` records them as checkout-only and holds that they are
-- never shipped. From an unpacked distribution, where neither is present, the
-- independence example reports itself pending and says why; wherever either
-- is present it runs, and a checkout holding only one of them fails.
--
-- What the rest of these examples check is everything the floor cannot see:
-- that the one project file which does select the proof agrees with the
-- toolchain record's binding flags, that the validation catalog declares no
-- group reaching it, that every Vulkan input is pinned by absolute path, that
-- the runner takes its discovery from the provisioned prefix rather than from
-- a retired environment pin or a generated project file, and that it never
-- supplies the native-session consent AGENTS.md reserves for a human.
--
-- They read the repository's own project files, pins, and catalog out of the
-- checkout they run in. They start no session and build nothing; the one that
-- runs the runner does so only as far as a refusal made before its first check.
module VulkanProof (spec, readByTheseExamples) where

import Control.Monad (forM_)
import Data.Char (isDigit, isHexDigit, isSpace)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, isSuffixOf, nub, stripPrefix)
import Json (asArray, asString, field, parseJson)
import Sandbox (run)
import System.Directory (doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

-- | The retained per-platform records, and the summary that quotes them.
retainedRecords ∷ [(String, FilePath)]
retainedRecords = [("macOS", "docs/vulkan/macos.md"), ("Linux", "docs/vulkan/linux.md")]

-- | The records VK-4 produced from the environment this recipe provisions.
--
-- A second pair rather than a revision of the first: they consumed different
-- files by a different discovery route, so the VK-2 pair stays exactly as it
-- was and these are retained beside it.
-- | Where a retained record stops being this repository's prose and starts
-- being what the harness printed.
capturedMarker ∷ String
capturedMarker = "## Captured record"

provisionedRecords ∷ [(String, FilePath)]
provisionedRecords =
  [("macOS", "docs/vulkan/macos-provisioned.md"), ("Linux", "docs/vulkan/linux-provisioned.md")]

-- | The records VK-6's native cases produced: the same proof run, retained for
-- its C-only capture section.
captureRecords ∷ [(String, FilePath)]
captureRecords = [("macOS", "docs/vulkan/macos-vk6.md"), ("Linux", "docs/vulkan/linux-vk6.md")]

-- | The records VK-5's native cases produced: the same proof run, retained for
-- its production surface bridge section.
bridgeRecords ∷ [(String, FilePath)]
bridgeRecords = [("macOS", "docs/vulkan/macos-vk5.md"), ("Linux", "docs/vulkan/linux-vk5.md")]

compatibilityRecord ∷ FilePath
compatibilityRecord = "docs/vulkan_compatibility_record.md"

-- | Every path these examples read out of the checkout.
--
-- A test is only a guard if the planner selects it when what it guards moves,
-- and `*.md` is classified non-affecting, so the evidence documents reach this
-- suite only because `test.workflow` declares them as inputs. That is easy to
-- forget when a new file is read, and forgetting it is silent: the suite keeps
-- passing and simply stops running. So the list is stated once here and checked
-- against the catalog below.
readByTheseExamples ∷ [FilePath]
readByTheseExamples =
  [ "cabal.project"
  , "cabal.project.cpu"
  , "cabal.project.vulkan"
  , "tools/native/vulkan.pin"
  , "tools/toolchain/binding.pin"
  , "tools/validation/catalog.json"
  , "tools/vulkan-proof/run-proof.sh"
  , nativePackage </> "hetoimasia-gpu-vulkan-native.cabal"
  , glfwPackage </> "hetoimasia-glfw.cabal"
  , compatibilityRecord
  ]
    <> map snd retainedRecords
    <> map snd provisionedRecords
    <> map snd captureRecords
    <> map snd bridgeRecords

-- | The two project files every mandatory validation group runs through.
ordinaryProjects ∷ [FilePath]
ordinaryProjects = ["cabal.project", "cabal.project.cpu"]

-- | The package directory the proof lives in, as a project file would name it.
proofPackage ∷ String
proofPackage = "tools/vulkan-proof"

-- | The native backend package. Like the proof it resolves the binding and the
-- Vulkan headers, so the Vulkan project is the only one that may name it.
nativePackage ∷ String
nativePackage = "packages/gpu-vulkan/native"

-- | The GLFW package. The ordinary projects list it with its Vulkan interop
-- component switched off; the Vulkan project lists it with that component on.
glfwPackage ∷ String
glfwPackage = "packages/glfw"

-- | The manual flag that switches the GLFW package's Vulkan interop component
-- on. Off by default, and set by the Vulkan project alone.
interopFlag ∷ String
interopFlag = "vulkan-interop"

-- | Everything the Vulkan project names: the proof, the native package, the
-- GLFW package whose interop component it enables, and the local dependency
-- closure of the native package and that component. All but the first two are
-- ordinary packages the other projects list too, and with the interop flag
-- off none of them depends on the binding.
vulkanProject ∷ [String]
vulkanProject =
  [ proofPackage
  , nativePackage
  , glfwPackage
  , "packages/gpu-vulkan/diagnostics"
  , "packages/gpu-vulkan/model"
  , "packages/runtime"
  , "packages/foundation"
  ]

-- | The Hackage package that is the Vulkan binding. Nothing the mandatory floor
-- builds may depend on it, whatever the image happens to carry.
bindingPackage ∷ String
bindingPackage = "vulkan"

spec ∷ Spec
spec = describe "The Vulkan proof boundary" $ do
  it "names the proof and the native package, with its local closure, in the one project file that selects them" $ do
    declared ← projectPackages "cabal.project.vulkan"
    declared `shouldBe` vulkanProject

  it "turns the GLFW interop component on in the Vulkan project, and nowhere else" $ do
    project ← map trim . lines <$> readFile "cabal.project.vulkan"
    -- The flag is set on the GLFW package's own stanza, where Cabal applies it.
    dropWhile (/= "package hetoimasia-glfw") project `shouldSatisfy` \case
      (_ : setting : _) → setting == "flags: +" <> interopFlag
      _ → False
    present ← mapM doesFileExist ordinaryProjects
    if not (or present)
      then
        pendingWith
          "cabal.project and cabal.project.cpu are checkout-only and absent here, as in an unpacked source \
          \distribution; this check runs from a checkout, which is where the mandatory floor runs it"
      else do
        forM_ ordinaryProjects $ \path → do
          text ← readFile path
          (path, interopFlag `isInfixOf` text) `shouldBe` (path, False)
        -- And off by default, so a project that says nothing leaves it off.
        cabal ← readFile (glfwPackage </> "hetoimasia-glfw.cabal")
        flagDefaults cabal `shouldBe` [(interopFlag, (False, True))]

  it "hashes every package the Vulkan project builds into the proof's source digest" $ do
    -- A record's digest has to move when production capture code moves, not
    -- only when the harness does, or two different builds could be recorded
    -- as one. The runner names its roots by directory, so each is looked for
    -- as a quoted root.
    runner ← readFile "tools/vulkan-proof/run-proof.sh"
    [package | package ← vulkanProject, not (("\"" <> package <> "\"") `isInfixOf` runner)] `shouldBe` []

  it "shares the qualified index with every other project" $ do
    text ← readFile "cabal.project.vulkan"
    lines text `shouldContain` ["import: cabal.project.common"]

  it "constrains the binding to the flags the toolchain record qualified" $ do
    project ← readFile "cabal.project.vulkan"
    pin ← readFile "tools/toolchain/binding.pin"
    -- The pin is the record; the constraint is what actually reaches the
    -- dependency. A flag flipped in one and not the other is the drift this
    -- example exists to catch.
    settingOf pin "VULKAN_FLAG_SAFE_FOREIGN_CALLS=" `shouldBe` Just "on"
    settingOf pin "VULKAN_FLAG_DARWIN_LIB_DIRS=" `shouldBe` Just "off"
    map trim (lines project) `shouldContain` ["vulkan +safe-foreign-calls,"]
    map trim (lines project) `shouldContain` ["vulkan -darwin-lib-dirs"]

  it "declares no validation group whose command would build the proof" $ do
    catalog ← readFile "tools/validation/catalog.json"
    -- A group may declare the proof's files as *inputs* — `test.workflow` does,
    -- because this module reads them — but no group's command may select the
    -- project file or the package. One that did would put a Vulkan loader on
    -- the mandatory floor of an image that has none.
    case parseJson catalog >>= field "groups" >>= asArray of
      Nothing → expectationFailure "tools/validation/catalog.json is not a JSON object with a groups array"
      Just groups → do
        let commands =
              [ (identifier, word)
              | group ← groups
              , Just identifier ← [field "id" group >>= asString]
              , Just arguments ← [field "command" group >>= asArray]
              , Just word ← map asString arguments
              ]
            offending =
              [ identifier <> " runs " <> word
              | (identifier, word) ← commands
              , any (`isInfixOf` word) ["vulkan-proof", "cabal.project.vulkan"]
              ]
        offending `shouldBe` []

  it "pins every Vulkan input on both platforms, each by absolute path" $ do
    -- One pin now names the loader, the driver manifest, the layer manifest and
    -- the compiler for each platform, and a relative path among them would mean
    -- the recipe resolved an input against whatever directory it happened to
    -- run in. The count is checked too: an input silently dropped from the pin
    -- would otherwise leave this passing over the ones that remain.
    pin ← readFile "tools/native/vulkan.pin"
    let names =
          [ platform <> input
          | platform ← ["MACOS_", "LINUX_"]
          , input ← ["LOADER=", "LOADER_PC=", "INCLUDE=", "DRIVER_MANIFEST=", "LAYER_MANIFEST=", "GLSLANG="]
          ]
        values = [(name, value) | name ← names, Just value ← [settingOf pin name]]
    map fst values `shouldBe` names
    [name | (name, value) ← values, not ("/" `isPrefixOf` value)] `shouldBe` []

  it "keeps the binding out of every package the mandatory floor builds" $ do
    -- The image carries a loader now, so a build that resolved the binding
    -- would succeed rather than fail, and the floor would stop being the proof
    -- of independence it used to be. This is that proof instead, and it reads
    -- the dependencies rather than the project text: `packages/gpu-vulkan/model`
    -- is named by both files and is exactly the package whose independence
    -- matters, so a check that merely looked for the word would have to be
    -- taught to ignore the one entry worth reading.
    present ← mapM doesFileExist ordinaryProjects
    if not (or present)
      then
        pendingWith
          "cabal.project and cabal.project.cpu are checkout-only and absent here, as in an unpacked source \
          \distribution; this independence check runs from a checkout, which is where the mandatory floor runs it"
      else forM_ ordinaryProjects $ \path → do
        declared ← projectPackages path
        (path, filter (\entry → proofPackage `isPrefixOf` entry || nativePackage `isPrefixOf` entry) declared)
          `shouldBe` (path, [])
        -- The diagnostics package is the header-free half: it is in both, and
        -- the dependency check below is what holds it free of the binding.
        (path, filter (== "packages/gpu-vulkan/diagnostics") declared)
          `shouldBe` (path, ["packages/gpu-vulkan/diagnostics"])
        -- The GLFW package is in it too, with its interop component off; only
        -- that component's own flag-guarded block is set aside, as Cabal sets
        -- it aside, and every other component is read in full.
        (path, filter (== glfwPackage) declared) `shouldBe` (path, [glfwPackage | path == "cabal.project"])
        resolved ← mapM (packageDependenciesWith []) declared
        (path, [name | name ← concat resolved, name == bindingPackage]) `shouldBe` (path, [])
        -- And the packages that do resolve it, to show the check would notice.
        proofDependencies ← packageDependencies proofPackage
        proofDependencies `shouldContain` [bindingPackage]
        nativeDependencies ← packageDependencies nativePackage
        nativeDependencies `shouldContain` [bindingPackage]
        interopDependencies ← packageDependenciesWith [interopFlag] glfwPackage
        interopDependencies `shouldContain` [bindingPackage]

  it "sets aside only a disabled flag's own block when it reads a package's dependencies" $ do
    -- The rule above must not become an exemption: a dependency outside the
    -- guarded block, in the same component or another, is still read, and the
    -- flag's else-branch is read too.
    let cabal =
          unlines
            [ "flag vulkan-interop"
            , "    default: False"
            , "    manual: True"
            , ""
            , "library"
            , "    build-depends:"
            , "        base,"
            , "        vulkan"
            , ""
            , "library vulkan-interop"
            , "    build-depends: text"
            , "    if flag(vulkan-interop)"
            , "        build-depends:"
            , "            bytestring,"
            , "            vulkan"
            , "    else"
            , "        buildable: False"
            , "        build-depends: containers"
            ]
    dependencyNamesWith [] cabal `shouldBe` ["base", "vulkan", "text", "containers"]
    dependencyNamesWith [interopFlag] cabal `shouldBe` ["base", "vulkan", "text", "bytestring", "vulkan"]

  it "takes the runner's discovery from the provisioned prefix, not a pinned environment" $ do
    -- VK-4 retired `tools/vulkan-proof/environment.pin`; the prefix's own
    -- manifest is the single place a driver manifest, a layer directory, and
    -- the loader's directories are named. A runner that read a pin again, or
    -- named a machine path itself, would be selecting inputs nothing qualified.
    runner ← readFile "tools/vulkan-proof/run-proof.sh"
    let active = [line | line ← map trim (lines runner), not ("#" `isPrefixOf` line)]
    filter ("environment.pin" `isInfixOf`) active `shouldBe` []
    active `shouldSatisfy` any ("native.py\" prepare --prefix" `isInfixOf`)
    active `shouldSatisfy` any ("--extra-lib-dirs=\"$HETOIMASIA_VULKAN_LIBDIR\"" `isInfixOf`)

  it "diagnoses an obsolete generated project file rather than building under it" $ do
    -- Cabal reads `<project-file>.local` silently, so one left over from before
    -- VK-4 would put the former SDK paths back into every build here without
    -- saying so. The runner must refuse and name it, and must not write one.
    runner ← readFile "tools/vulkan-proof/run-proof.sh"
    let active = [line | line ← map trim (lines runner), not ("#" `isPrefixOf` line)]
    active `shouldSatisfy` any (\line → "refuse " `isPrefixOf` line && "$local_project exists" `isInfixOf` line)
    filter (\line → "cat > \"$local_project\"" `isInfixOf` line) active `shouldBe` []

  it "attributes each record's callback total to that record's own platform" $ do
    -- The summary is declared authoritative for later Vulkan slices, and it
    -- restates figures the raw records own. Regenerating a record and not the
    -- summary is the drift this catches; it already happened once. Checking
    -- only that a number appears somewhere would let the two platforms' totals
    -- be swapped, which is a subtler version of the same lie, so the column
    -- each one sits in is checked against the header.
    summary ← readFile compatibilityRecord
    totals ← mapM (\(platform, path) → (,) platform . recordTotal <$> readFile path) retainedRecords
    map snd totals `shouldSatisfy` all (/= Nothing)
    case (tableRow "| What |" summary, tableRow "| Callbacks |" summary) of
      (Nothing, _) → expectationFailure "the summary has no profile table header naming the platforms"
      (_, Nothing) → expectationFailure "the summary has no Callbacks row"
      (Just header, Just callbacks) → do
        let misplaced =
              [ platform <> " reports " <> show total <> " callbacks, which is not what the summary's " <> platform <> " column says"
              | (platform, Just total) ← totals
              , Just column ← [lookup platform (zip header [0 ..])]
              , not (maybe False ((show total <> " deliveries") `isInfixOf`) (cellAt column callbacks))
              ]
        misplaced `shouldBe` []

  it "retains a record for each platform, each naming the sources it proved" $
    mapM_
      ( \(platform, path) → do
          record ← readFile path
          let digest = settingOf record "- source digest:"
          case digest of
            Nothing → expectationFailure (platform <> "'s record names no source digest")
            Just value → do
              let hex = trim value
              length hex `shouldBe` 64
              hex `shouldSatisfy` all (`elem` ("0123456789abcdef" ∷ String))
      )
      retainedRecords

  it "retains a provisioned record for each platform, each a pass on the provisioned inputs" $
    mapM_
      ( \(platform, path) → do
          record ← readFile path
          -- The harness writes its own verdict; a record retained for a run
          -- that did not pass would be evidence of the opposite of what the
          -- requirement asks for.
          lines record `shouldContain` ["Verdict: **pass**."]
          -- And it says it is the provisioned pair rather than the VK-2 one,
          -- so neither can be mistaken for the other by its heading alone.
          take 1 (lines record)
            `shouldBe` ["# The VK-4 provisioned native Vulkan compatibility record, " <> platform]
          -- The retained file is a captured record with context written above
          -- it, and a reader has to be able to tell which is which. The harness
          -- prints its verdict directly under the heading it generates, so the
          -- marker must sit immediately before that verdict and nowhere else:
          -- anything above is this repository's narration, everything below is
          -- what the run actually said.
          let marked = [number | (number, line) ← zip [0 ∷ Int ..] (lines record), line == capturedMarker]
          case marked of
            [only] →
              take 1 (dropWhile null (drop (only + 1) (lines record)))
                `shouldBe` ["Verdict: **pass**."]
            _ →
              expectationFailure
                ( platform
                    <> "'s provisioned record marks its captured output "
                    <> show (length marked)
                    <> " times, not once"
                )
          -- Every Vulkan path it consumed came from the provisioned prefix.
          case settingOf record "- VK_DRIVER_FILES:" of
            Nothing → expectationFailure (platform <> "'s provisioned record names no driver manifest")
            Just manifest → trim manifest `shouldSatisfy` ("/vulkan/share/vulkan/icd.d/" `isInfixOf`)
          case settingOf record "- VK_LAYER_PATH:" of
            Nothing → expectationFailure (platform <> "'s provisioned record names no layer path")
            Just path' → trim path' `shouldSatisfy` ("/vulkan/share/vulkan/explicit_layer.d" `isSuffixOf`)
          -- One layer, because the prefix holds a selection rather than a
          -- directory to search. This is the difference from the VK-2 records,
          -- which offered whatever their platform's directory happened to hold.
          case settingOf record "- layers the pinned path offers:" of
            Nothing → expectationFailure (platform <> "'s provisioned record lists no layers")
            Just offered → length (splitOn ',' offered) `shouldBe` 1
      )
      provisionedRecords

  it "proved both platforms from one tree in the provisioned pair too" $ do
    -- The same property the VK-2 pair has, and for the same reason: one digest
    -- computed independently on each platform, from a checkout on macOS and
    -- from the candidate mounted into the image on Linux.
    digests ← mapM (\(_, path) → (settingOf <$> readFile path) <*> pure "- source digest:") provisionedRecords
    map (fmap trim) digests `shouldSatisfy` all (/= Nothing)
    length (nub (map (fmap trim) digests)) `shouldBe` 1

  it "retains a VK-6 record for each platform, each a pass whose capture reported only the error it provoked" $
    mapM_
      ( \(platform, path) → do
          record ← readFile path
          take 1 (lines record) `shouldBe` ["# The VK-6 validation capture record, " <> platform]
          let marked = [number | (number, line) ← zip [0 ∷ Int ..] (lines record), line == capturedMarker]
          case marked of
            [only] →
              take 1 (dropWhile null (drop (only + 1) (lines record)))
                `shouldBe` ["Verdict: **pass**."]
            _ → expectationFailure (platform <> "'s VK-6 record marks its captured output " <> show (length marked) <> " times, not once")
          -- The capture section's own verdict, as the lifetime reached it: the
          -- provoked validation error and nothing else, with every report
          -- delivered.
          fmap trim (settingOf record "- verdict issues:") `shouldBe` Just "ErrorLatched"
          fmap trim (settingOf record "- undelivered:") `shouldBe` Just "0"
          fmap trim (settingOf record "- drain worker:") `shouldBe` Just "completed"
      )
      captureRecords

  it "proved the VK-6 capture on both platforms from one tree" $ do
    digests ← mapM (\(_, path) → (settingOf <$> readFile path) <*> pure "- source digest:") captureRecords
    map (fmap trim) digests `shouldSatisfy` all (/= Nothing)
    length (nub (map (fmap trim) digests)) `shouldBe` 1

  it "retains a VK-5 record for each platform, each a pass that restored GLFW's default after the bridge's session" $
    mapM_
      ( \(platform, path) → do
          record ← readFile path
          take 1 (lines record) `shouldBe` ["# The VK-5 surface bridge record, " <> platform]
          let marked = [number | (number, line) ← zip [0 ∷ Int ..] (lines record), line == capturedMarker]
          case marked of
            [only] →
              take 1 (dropWhile null (drop (only + 1) (lines record)))
                `shouldBe` ["Verdict: **pass**."]
            _ → expectationFailure (platform <> "'s VK-5 record marks its captured output " <> show (length marked) <> " times, not once")
          -- The bridge section's own readings: the surface was refused its
          -- retirement while owed and destroyed off the owner, and the loader
          -- setting was restored once the session ended.
          fmap trim (settingOf record "- disposal fact while owed:") `shouldBe` Just "Nothing"
          fmap trim (settingOf record "- discharge:") `shouldBe` Just "SurfaceDestroyed"
          fmap trim (settingOf record "- discharged off the owner thread:") `shouldBe` Just "yes"
          fmap trim (settingOf record "- shim setting after termination:") `shouldBe` Just "0x0000000000000000"
          fmap trim (settingOf record "- capability after termination:") `shouldBe` Just "IntegrationRestored"
      )
      bridgeRecords

  it "observed the reset after a failed initialization in the Linux VK-5 record" $ do
    -- Cocoa offers no initialization failure an application can provoke, so
    -- the native observation of this path is Linux's alone.
    record ← readFile "docs/vulkan/linux-vk5.md"
    fmap trim (settingOf record "- shim setting after the failed initialization:") `shouldBe` Just "0x0000000000000000"
    fmap trim (settingOf record "- capability after the failed initialization:") `shouldBe` Just "IntegrationRestored"

  it "proved the VK-5 bridge on both platforms from one tree" $ do
    digests ← mapM (\(_, path) → (settingOf <$> readFile path) <*> pure "- source digest:") bridgeRecords
    map (fmap trim) digests `shouldSatisfy` all (/= Nothing)
    length (nub (map (fmap trim) digests)) `shouldBe` 1

  it "proved both platforms from one tree, by the digest each computed" $ do
    digests ← mapM (\(_, path) → (settingOf <$> readFile path) <*> pure "- source digest:") retainedRecords
    -- Computed independently: from a Git checkout on one, from the files the
    -- container recipe copied on the other, with no checkout to consult.
    length (nub (map (fmap trim) digests)) `shouldBe` 1

  it "describes each platform's pre-wait fence status as that platform's own record has it" $ do
    -- The summary carries this as one word per platform, and the word is read
    -- back out of that platform's own frame table. Checking the two records
    -- only against each other was not enough: macOS is separately required to
    -- be uniform, so a Linux record that was uniformly `signalled` would still
    -- make the pair disagree and pass, while the summary said Linux disagrees
    -- with itself.
    summary ← readFile compatibilityRecord
    statuses ← mapM (\(platform, path) → (,) platform . preWaitStatuses <$> readFile path) retainedRecords
    let described platform = tableRow ("| " <> platform <> " |") summary >>= cellAt 1
        mismatches =
          [ platform
              <> " is "
              <> shape observed
              <> " in its record, and the summary calls it "
              <> maybe "nothing" (takeWhile (/= ' ')) (described platform)
          | (platform, observed) ← statuses
          , Just cell ← [described platform]
          , not (shape observed `isPrefixOf` cell)
          ]
    map snd statuses `shouldSatisfy` all (not . null)
    mismatches `shouldBe` []
    -- And the words are the ones the summary actually uses today, so a record
    -- that changed shape cannot be papered over by rewording the cell.
    map (shape . snd) statuses `shouldBe` ["uniform", "mixed"]

  it "quotes no digest the records disagree with" $ do
    -- The summary names the digest for a reader's benefit, which means it can
    -- go stale every time the harness changes — and did. Any digest-shaped
    -- token it quotes, in full or abbreviated, must be the one the records
    -- carry; removing the quotation is allowed, contradicting it is not.
    summary ← readFile compatibilityRecord
    recorded ← case retainedRecords of
      ((_, path) : _) → (settingOf <$> readFile path) <*> pure "- source digest:"
      [] → pure Nothing
    case fmap trim recorded of
      Nothing → expectationFailure "the retained record names no source digest"
      Just digest → do
        let quoted = filter looksLikeDigest (map (takeWhile isHexDigit) (backticked summary))
        quoted `shouldSatisfy` all (`isPrefixOf` digest)

  it "is selected by the planner whenever anything it reads changes" $ do
    catalog ← readFile "tools/validation/catalog.json"
    case parseJson catalog >>= field "groups" >>= asArray of
      Nothing → expectationFailure "tools/validation/catalog.json is not a JSON object with a groups array"
      Just groups → do
        let declared =
              [ value
              | group ← groups
              , (field "id" group >>= asString) == Just "test.workflow"
              , Just entries ← [field "inputs" group >>= asArray]
              , Just value ← map asString entries
              ]
            covered path =
              any (\entry → entry == path || ("/" `isSuffixOf` entry && entry `isPrefixOf` path)) declared
        declared `shouldSatisfy` (not . null)
        filter (not . covered) readByTheseExamples `shouldBe` []

  it "forwards its own arguments to the harness rather than dropping them" $ do
    -- `--headless` selects the release decision's pure examples, and the
    -- harness is what owns that flag. A runner that forwarded nothing would
    -- read consent and start the native proof instead — the opposite of what
    -- the caller asked for, and a session this mode has no approval for.
    runner ← lines <$> readFile "tools/vulkan-proof/run-proof.sh"
    runner `shouldSatisfy` any ("--test-option=$argument" `isInfixOf`)
    runner `shouldSatisfy` any ("${options[@]+\"${options[@]}\"}" `isInfixOf`)

  forM_ [("LD_LIBRARY_PATH", False), ("LD_PRELOAD", True)] $ \(variable, namesFile) →
    it ("refuses " ++ variable ++ " naming an alternate loader before it checks or builds anything") $
      withSystemTempDirectory "hetoimasia-alternate-loader" $ \directory → do
        -- An ABI-compatible loader ahead of the pinned one on a runtime search
        -- path would be loaded after `prepare` verified the pinned file, and
        -- GLFW and the binding would then share it faithfully. The runner
        -- refuses the override outright; this refusal comes before the
        -- toolchain check, so it needs no compiler and starts no session.
        let alternate = directory </> "libvulkan.so.1"
        writeFile alternate "an ABI-compatible substitute loader\n"
        inherited ← filter ((`notElem` searchOverrides) . fst) <$> getEnvironment
        checkout ← getCurrentDirectory
        (status, output, errors) ←
          run
            ((variable, if namesFile then alternate else directory) : inherited)
            checkout
            "bash"
            ["tools/vulkan-proof/run-proof.sh"]
        status `shouldBe` ExitFailure 2
        errors `shouldContain` ("run-proof: " ++ variable ++ " is set")
        output `shouldNotContain` "run-proof: ghc"

  it "never supplies the native-session consent itself" $ do
    -- AGENTS.md: the human's approval is given on one approved command, never
    -- by a script an agent runs on its own, and `tools/display/x11.sh` is the
    -- only thing that may supply the isolated-display value.
    runner ← readFile "tools/vulkan-proof/run-proof.sh"
    let assignments =
          [ line
          | line ← lines runner
          , "HETOIMASIA_NATIVE_SESSION=" `isInfixOf` line
          , not ("#" `isPrefixOf` trim line)
          ]
    assignments `shouldBe` []

-- | The runtime library search overrides the runner refuses, stripped from an
-- example's inherited environment so only the one under test is present.
searchOverrides ∷ [String]
searchOverrides =
  [ "LD_LIBRARY_PATH"
  , "LD_PRELOAD"
  , "LD_AUDIT"
  , "DYLD_LIBRARY_PATH"
  , "DYLD_FALLBACK_LIBRARY_PATH"
  , "DYLD_INSERT_LIBRARIES"
  , "DYLD_FRAMEWORK_PATH"
  , "DYLD_FALLBACK_FRAMEWORK_PATH"
  , "DYLD_IMAGE_SUFFIX"
  ]

-- | The package locations a project file declares, in order. Cabal's
-- `packages:` stanza is either inline or a block of indented continuations, and
-- both spellings are used in this repository.
projectPackages ∷ FilePath → IO [String]
projectPackages path = collect . lines <$> readFile path
  where
    collect [] = []
    collect (line : rest)
      | Just remainder ← afterField "packages:" line =
          let inline = words remainder
              (continued, following) = span continuation rest
           in inline <> concatMap words continued <> collect following
      | otherwise = collect rest
    continuation line = case line of
      (c : _) → isSpace c && not (null (trim line))
      [] → False
    afterField name line =
      if name `isPrefixOf` trim line && not ("--" `isPrefixOf` trim line)
        then Just (drop (length name) (trim line))
        else Nothing

-- | Every package one project entry declares a dependency on, across all of its
-- components.
--
-- Cabal writes @build-depends@ and @pkgconfig-depends@ as a comma-separated
-- list that may run over indented continuation lines, and each entry is a name
-- followed by an optional version range or sublibrary. Only the name is taken,
-- so a version range mentioning nothing and a comment mentioning everything
-- both contribute nothing.
packageDependencies ∷ FilePath → IO [String]
packageDependencies directory = do
  files ← filter (".cabal" `isSuffixOf`) <$> listDirectory (normalisedPackage directory)
  concat <$> mapM (\file → dependencyNames <$> readFile (normalisedPackage directory </> file)) files
  where
    normalisedPackage entry = if entry == "." then "." else entry

-- | 'packageDependencies' as a project would configure the package: a block
-- guarded by @if flag(name)@ is read only when that flag would be on — named
-- here, or on by default — and its @else@ block only when it would be off.
-- Every other line of every component is read exactly as before.
packageDependenciesWith ∷ [String] → FilePath → IO [String]
packageDependenciesWith enabled directory = do
  files ← filter (".cabal" `isSuffixOf`) <$> listDirectory directory
  concat <$> mapM (\file → dependencyNamesWith enabled <$> readFile (directory </> file)) files

-- | Each flag a package declares, with its default and whether it is manual.
flagDefaults ∷ String → [(String, (Bool, Bool))]
flagDefaults text = go (map (dropWhileEnd isSpace) (lines text))
  where
    go [] = []
    go (line : rest)
      | Just name ← stripPrefix "flag " line =
          let (body, following) = span (all isSpace . take 1) rest
              setting key = [trim value | entry ← body, Just value ← [stripPrefix key (trim entry)]]
              isTrue values = map (map toLower') values == ["true"]
           in (trim name, (isTrue (setting "default:"), isTrue (setting "manual:"))) : go following
      | otherwise = go rest
    toLower' c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | 'dependencyNames' over only the lines a configuration with these flags on
-- would keep.
dependencyNamesWith ∷ [String] → String → [String]
dependencyNamesWith enabled text = dependencyNames (unlines (configured (lines text)))
  where
    defaults = flagDefaults text
    on name = name `elem` enabled || maybe False fst (lookup name defaults)
    indentOf = length . takeWhile isSpace
    configured [] = []
    configured (line : rest)
      | Just name ← guardedFlag line =
          let depth = indentOf line
              (guarded, afterGuard) = span (\entry → null (trim entry) || indentOf entry > depth) rest
              (elseBranch, following) = case afterGuard of
                (entry : more)
                  | indentOf entry == depth && trim entry == "else" →
                      span (\next → null (trim next) || indentOf next > depth) more
                _ → ([], afterGuard)
           in (if on name then configured guarded else configured elseBranch) <> configured following
      | otherwise = line : configured rest
    guardedFlag line = do
      remainder ← stripPrefix "if flag(" (trim line)
      let (name, closing) = break (== ')') remainder
      if closing == ")" then Just name else Nothing

dependencyNames ∷ String → [String]
dependencyNames text = concatMap entries (stanzas (map (dropWhileEnd isSpace) (lines text)))
  where
    fields = ["build-depends:", "pkgconfig-depends:"]
    stanzas [] = []
    stanzas (line : rest)
      | Just remainder ← firstJust [stripPrefix name (trim line) | name ← fields] =
          let (continued, following) = span continuation rest
           in (remainder : continued) : stanzas following
      | otherwise = stanzas rest
    continuation line = case line of
      (c : _) → isSpace c && not (null (trim line)) && not (any (`isPrefixOf` trim line) sectionStarts)
      [] → False
    -- A continuation is indented, and so is every field inside a component, so
    -- the run has to end at the next field rather than at the next blank line.
    sectionStarts = ["build-depends:", "pkgconfig-depends:", "if ", "else", "ghc-options:", "hs-source-dirs:", "other-modules:", "default-language:", "exposed-modules:", "type:", "main-is:", "import:", "c-sources:", "include-dirs:", "frameworks:", "extra-libraries:", "default-extensions:", "build-tool-depends:"]
    entries block = [name | piece ← splitOn ',' (unwords (map trim block)), Just name ← [firstWord piece]]
    firstWord piece = case words (trim piece) of
      (name : _) → Just name
      [] → Nothing

firstJust ∷ [Maybe a] → Maybe a
firstJust values = case [value | Just value ← values] of
  (value : _) → Just value
  [] → Nothing

-- | The first line beginning with a prefix, with that prefix removed. Serves
-- both a shell-style @NAME=@ pin and a record's @- label:@ bullet, so the two
-- readers here are one.
settingOf ∷ String → String → Maybe String
settingOf text prefix =
  case [rest | line ← map trim (lines text), Just rest ← [stripPrefix prefix line]] of
    (value : _) → Just value
    [] → Nothing

-- | How one platform's pre-wait statuses look as a whole: all the same answer,
-- or more than one. These are the two words the summary is allowed to use.
shape ∷ [String] → String
shape observed = if length (nub observed) > 1 then "mixed" else "uniform"

-- | The "present fence before wait" cell of every frame row in a record's
-- completion table, found through the table's own header so a reordered column
-- cannot silently change what is read.
preWaitStatuses ∷ String → [String]
preWaitStatuses record = case tableRow "| frame |" record of
  Nothing → []
  Just header → case lookup "present fence before wait" (zip header [0 ..]) of
    Nothing → []
    Just column ->
      [ cell
      | line ← map trim (lines record)
      , "| " `isPrefixOf` line
      , (digit : _) ← [drop 2 line]
      , isDigit digit
      , Just cell ← [cellAt column (map trim (dropEdgeCells (splitOn '|' line)))]
      ]

-- | Every backticked span in a document, which is where this summary puts a
-- digest when it quotes one.
backticked ∷ String → [String]
backticked text = case break (== '`') text of
  (_, []) → []
  (_, _ : rest) → case break (== '`') rest of
    (_, []) → []
    (span', _ : more) → span' : backticked more

-- | Long enough to be a digest rather than a word that happens to be hex.
looksLikeDigest ∷ String → Bool
looksLikeDigest token = length token >= 8

-- | A Markdown table row, as its trimmed cells. The leading and trailing pipes
-- produce empty edges, which are dropped so a cell index matches the column a
-- reader counts.
tableRow ∷ String → String → Maybe [String]
tableRow prefix text =
  case [line | line ← map trim (lines text), prefix `isPrefixOf` line] of
    (row : _) → Just (map trim (dropEdges (splitOn '|' row)))
    [] → Nothing
  where
    dropEdges = dropEdgeCells

-- | A Markdown row's cells without the empty spans its outer pipes create.
dropEdgeCells ∷ [String] → [String]
dropEdgeCells cells = case cells of
  (_ : rest) → if null rest then [] else init rest
  [] → []

cellAt ∷ Int → [String] → Maybe String
cellAt index cells = if index < length cells then Just (cells !! index) else Nothing

splitOn ∷ Char → String → [String]
splitOn separator text = case break (== separator) text of
  (chunk, []) → [chunk]
  (chunk, _ : rest) → chunk : splitOn separator rest

-- | The total a record reports, read from its own summary line.
recordTotal ∷ String → Maybe Int
recordTotal record = do
  value ← settingOf record "- callbacks in total:"
  case reads (trim value) of
    [(total, "")] → Just total
    _ → Nothing

trim ∷ String → String
trim = dropWhileEnd isSpace . dropWhile isSpace
