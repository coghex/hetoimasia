-- | Hspec coverage for the boundary around the VK-2 Vulkan proof harness.
--
-- Issue #158's first requirement is that the harness exists and that the
-- mandatory validation floor never builds it, on a CI image that has no Vulkan
-- loader.
--
-- That the two ordinary project files do not name the package is not checked
-- here, and deliberately: `build.all` and every `test.*` group already run
-- through them on an image with no loader, so a package added to either fails
-- the floor outright. A text check would be a weaker restatement of a stronger
-- one, and it would mean shipping `cabal.project` inside this package's own
-- source distribution, which breaks resolution wherever that distribution is
-- unpacked.
--
-- What these examples do check is everything the floor cannot see: that the one
-- project file which does select the proof agrees with the toolchain record's
-- binding flags, that the validation catalog declares no group reaching it,
-- that each platform's driver is pinned by absolute path, and that the runner
-- never supplies the native-session consent AGENTS.md reserves for a human.
--
-- They read the repository's own project file, pins, and catalog out of the
-- checkout they run in. They start no session and build nothing.
module VulkanProof (spec) where

import Data.Char (isSpace)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, isSuffixOf, nub, stripPrefix)
import Json (asArray, asString, field, parseJson)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldSatisfy)

-- | The retained per-platform records, and the summary that quotes them.
retainedRecords ∷ [(String, FilePath)]
retainedRecords = [("macOS", "docs/vulkan/macos.md"), ("Linux", "docs/vulkan/linux.md")]

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
  [ "cabal.project.vulkan"
  , "tools/toolchain/binding.pin"
  , "tools/validation/catalog.json"
  , "tools/vulkan-proof/environment.pin"
  , "tools/vulkan-proof/run-proof.sh"
  , compatibilityRecord
  ]
    <> map snd retainedRecords

-- | The package directory the proof lives in, as a project file would name it.
proofPackage ∷ String
proofPackage = "tools/vulkan-proof"

spec ∷ Spec
spec = describe "The Vulkan proof boundary" $ do
  it "names the proof in the one project file that selects it" $ do
    declared ← projectPackages "cabal.project.vulkan"
    declared `shouldBe` [proofPackage]

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

  it "pins each platform's driver manifest by absolute path" $ do
    pin ← readFile "tools/vulkan-proof/environment.pin"
    let manifests =
          [ value
          | name ← ["MACOS_VULKAN_DRIVER_MANIFEST=", "LINUX_VULKAN_DRIVER_MANIFEST="]
          , Just value ← [settingOf pin name]
          ]
    length manifests `shouldBe` 2
    manifests `shouldSatisfy` all ("/" `isPrefixOf`)

  it "keeps the summary's callback totals equal to the records they came from" $ do
    -- The summary is declared authoritative for later Vulkan slices, and it
    -- restates figures the raw records own. Regenerating a record and not the
    -- summary is the drift this catches; it already happened once.
    summary ← readFile compatibilityRecord
    totals ← mapM (\(platform, path) → (,) platform . recordTotal <$> readFile path) retainedRecords
    missing ←
      pure
        [ platform <> " reports " <> show total <> " callbacks, which the summary does not quote"
        | (platform, Just total) ← totals
        , not ((show total <> " deliveries") `isInfixOf` summary)
        ]
    missing `shouldBe` []
    map snd totals `shouldSatisfy` all (/= Nothing)

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

  it "proved both platforms from one tree, by the digest each computed" $ do
    digests ← mapM (\(_, path) → (settingOf <$> readFile path) <*> pure "- source digest:") retainedRecords
    -- Computed independently: from a Git checkout on one, from the files the
    -- container recipe copied on the other, with no checkout to consult.
    length (nub (map (fmap trim) digests)) `shouldBe` 1

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

-- | The first line beginning with a prefix, with that prefix removed. Serves
-- both a shell-style @NAME=@ pin and a record's @- label:@ bullet, so the two
-- readers here are one.
settingOf ∷ String → String → Maybe String
settingOf text prefix =
  case [rest | line ← map trim (lines text), Just rest ← [stripPrefix prefix line]] of
    (value : _) → Just value
    [] → Nothing

-- | The total a record reports, read from its own summary line.
recordTotal ∷ String → Maybe Int
recordTotal record = do
  value ← settingOf record "- callbacks in total:"
  case reads (trim value) of
    [(total, "")] → Just total
    _ → Nothing

trim ∷ String → String
trim = dropWhileEnd isSpace . dropWhile isSpace
