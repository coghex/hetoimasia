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

import Data.Char (isDigit, isHexDigit, isSpace)
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
