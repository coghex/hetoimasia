-- | The oracle of the printed lines ("Test.TerrainRuntime.Output"): a small parallel spec is run through the configuration the
-- suite itself runs with ("Test.TerrainRuntime.Runner.suiteConfig": the same job default, the same guarded formatters), once
-- per formatter the runner can select, with the process's standard output captured to a file; then every printed record must
-- be a whole line starting at a line start, every record must appear exactly once, and every line the formatter wrote must be
-- one it would have written whole.
--
-- The text a formatter writes depends on its environment (colour, unicode, the formatter itself, the @.hspec@ files and the
-- @HSPEC_*@ variables, GitHub Actions), so the nested run takes none of it: its configuration is
-- "Test.TerrainRuntime.Runner.pinnedConfig" (the suite's defaults, no file, no variable, no command line; formatter, colour,
-- unicode and jobs given), and the two variables the runner itself reads, @GITHUB_ACTIONS@ and @BUILDKITE@, are set for the
-- run and restored. Every formatter is run with colour off and with colour on (what GitHub Actions does), and the checker
-- recognizes a colour sequence by rule (an escape, @[@, parameters, a final byte) and checks that a colour is reset before
-- the newline: the line start 'printLine' relies on is the end of the event's last line, which a reset after the newline would
-- spoil.
--
-- The run is made at eight jobs on eight capabilities, so the examples really write while the formatter does: 120 examples
-- print 20 records each (2,400 records against 120 item lines). A second case follows a parallel group with sequential
-- examples nested in describes that write DIRECTLY (@putStrLn@, as the storage examples do, not through the output): the
-- framework's order, not a lock, keeps those whole (a sequential item starts only after the reporting thread has written
-- every earlier event and its own start, and the formatter is then idle until the item ends), and the case shows it for each
-- formatter that ends its events at a line boundary. A check that only looks at a clean run proves nothing, so the checker is
-- itself tested on outputs with a record joined to a partial formatter line, a record cut short, a missing record, a repeated
-- record and a stray fragment. The example is sequential and holds the process's output lock for the whole capture, so
-- nothing else writes to the handle while it is redirected.
--
-- State: the redirection of standard output lasts one example and is undone on every exit; the capture file is removed.
module Test.TerrainRuntime.OutputSpec (spec) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.Char (isDigit)
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort, stripPrefix)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv, setEnv, unsetEnv, withArgs)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (ReadMode), hClose, hFileSize, hFlush, hPutStr, hGetContents', hSetEncoding, openTempFile, stdout, utf8, withFile)
import Test.Hspec
import Test.Hspec.Core.Format (Event (..), FailureReason (..), FormatConfig (..), Item (..), Result (..), Seconds (..), defaultFormatConfig)
import Test.Hspec.Runner (Config (..), Summary (..), defaultConfig, runSpec)
import Test.TerrainRuntime.Output (Effect (..), Output, eventEffect, globalOutput, guardFormatters, newOutput, printLineOn, withOutputLocked)
import Test.TerrainRuntime.Runner (pinnedConfig)

examples ∷ Int
examples = 120

rowsPerExample ∷ Int
rowsPerExample = 20

-- | A record as an example prints it.
record ∷ Int → Int → String
record i j = "EVIDENCE row=" <> show i <> "." <> show j <> " " <> replicate 40 'x'

-- | A record a sequential example writes directly.
direct ∷ Int → Int → String
direct i j = "DIRECT row=" <> show i <> "." <> show j <> " " <> replicate 40 'x'

-- | The nested spec: every example prints its rows while the other seven do.
stress ∷ Int → Output → Spec
stress count out = parallel $ describe "stress" $ forM_ [1 .. count] $ \i →
  it ("example " <> show i) $ forM_ [1 .. rowsPerExample] $ \j → printLineOn out (record i j)

-- | Sequential examples that follow the group, in nested describes, each writing directly to standard output.
sequentialGroups, sequentialPerGroup, directRows, mixedParallel ∷ Int
mixedParallel = 40
sequentialGroups = 25
sequentialPerGroup = 4
directRows = 3

sequentialExamples ∷ Int
sequentialExamples = sequentialGroups * sequentialPerGroup

mixed ∷ Output → Spec
mixed out = do
  stress mixedParallel out
  forM_ [1 .. sequentialGroups] $ \g → describe ("group " <> show g) $ describe ("inner " <> show g) $
    forM_ [1 .. sequentialPerGroup] $ \k → do
      let i = (g - 1) * sequentialPerGroup + k
      it ("sequential " <> show i) $ forM_ [1 .. directRows] $ \j → putStrLn (direct i j)

-- | What a formatter writes besides the records: item lines, or dots, and the footer.
data Shape = Shape
  { shapeName ∷ String
  , shapeFormat ∷ String
  , shapeItems ∷ Bool
  , shapeDots ∷ Bool
  , shapeFooter ∷ Bool
  , shapeBoundary ∷ Bool
  }

shapes ∷ [Shape]
shapes =
  [ Shape "checks, the default formatter" "checks" True False True True
  , Shape "specdoc" "specdoc" True False True True
  , Shape "progress" "progress" False True True False
  , Shape "failed-examples" "failed-examples" False False True True
  , Shape "silent" "silent" False False False True
  ]

-- | Everything the output got wrong, empty when every record is whole at a line start and exactly once and every other line is
-- one the formatter writes whole. The expected records are @examples@ x @rows@; @items@ and @dots@ say what the formatter
-- writes for each example.
problems ∷ Shape → Int → Int → Int → String → [String]
problems shape n rows seqN raw =
  [ "the output does not end at a line end" | not (null raw), last raw /= '\n' ]
    <> [ "a colour sequence after the newline: " <> show (take 40 l) | l ← rawLines, not (null (sgrParams l)), null (stripSgr l) ]
    <> [ "a colour is left on at the end of a line: " <> show (take 60 l) | l ← rawLines, p : _ ← [reverse (sgrParams l)], p `notElem` ["", "0"] ]
    <> [ "a record is not whole at a line start: " <> show (take 70 l) | l ← ls, isRecordLine l, l `Set.notMember` expectedSet ]
    <> [ "a record is missing: " <> r | r ← expected, r `Map.notMember` recordCounts ]
    <> [ "a record is repeated: " <> r | (r, k) ← Map.toList recordCounts, k > 1 ]
    <> [ "a formatter line is not whole: " <> show (take 70 l) | l ← others, not (wholeFormatterLine l) ]
    <> [ "parallel item lines " <> show (sort parallelItems) <> " are not exactly 1.." <> show n | shapeItems shape, sort parallelItems /= [1 .. n] ]
    <> [ "sequential item lines " <> show (sort sequentialItems) <> " are not exactly 1.." <> show seqN | shapeItems shape, sort sequentialItems /= [1 .. seqN] ]
    <> [ show dots <> " progress dots, not " <> show (n + seqN) | shapeDots shape, dots /= n + seqN ]
    <> [ "the footer does not report " <> show total <> " examples, 0 failures" | shapeFooter shape, (show total <> " examples, 0 failures") `notElem` others ]
  where
    out = stripSgr raw
    rawLines = lines raw
    ls = lines out
    total = n + seqN
    expected = [record i j | i ← [1 .. n], j ← [1 .. rows]] <> [direct i j | i ← [1 .. seqN], j ← [1 .. directRows]]
    expectedSet = Set.fromList expected
    recordCounts = Map.fromListWith (+) [(l, 1 ∷ Int) | l ← ls, l `Set.member` expectedSet]
    others = [l | l ← ls, not (isRecordLine l)]
    items = [it' | l ← others, Just it' ← [itemNumber l]]
    parallelItems = [k | ("example", k) ← items]
    sequentialItems = [k | ("sequential", k) ← items]
    dots = sum [length l | l ← others, not (null l), all (== '.') l]
    wholeFormatterLine l =
      null l || l == "stress" || isGroupTitle l || "Finished in " `isPrefixOf` l || l == show total <> " examples, 0 failures"
        || (shapeItems shape && itemNumber l /= Nothing)
        || (shapeDots shape && all (== '.') l)
    isGroupTitle l = case words l of
      [w, ds] → w `elem` ["group", "inner"] && not (null ds) && all isDigit ds
      _ → False
    itemNumber l = do
      let body = dropWhile (== ' ') l
      (kind, rest) ← firstJust [(,) k <$> stripPrefix (k <> " ") body | k ← ["example", "sequential"]]
      let (ds, tail') = span isDigit rest
      if not (null ds) && tail' `elem` ["", " [✔]", " [v]"] then Just (kind, read ds ∷ Int) else Nothing
    firstJust xs = case [x | Just x ← xs] of
      x : _ → Just x
      [] → Nothing

-- | The records among the bytes as written, whatever else is on the line: every line that holds a record must be that record and
-- nothing else, so a record starts a line of the file even when the formatter wrote transient text and an erase before it.
-- Direct writes of sequential examples are not asked for here: in a file they follow the transient text of their item.
recordLineProblems ∷ Int → Int → Int → String → [String]
recordLineProblems n rows seqN raw =
  [ "a record does not start a line of the bytes: " <> show (take 70 l) | l ← lines raw, isRecordLine l, l `Set.notMember` expectedSet ]
  where
    expectedSet = Set.fromList ([record i j | i ← [1 .. n], j ← [1 .. rows]] <> [direct i j | i ← [1 .. seqN], j ← [1 .. directRows]])

isRecordLine ∷ String → Bool
isRecordLine l = "EVIDENCE" `isInfixOf` l || "DIRECT" `isInfixOf` l

-- | The text without its colour sequences. A sequence is recognized by its form, not by a list of the ones seen: an escape, a
-- bracket, parameter and intermediate bytes, one final byte from @ to ~.
stripSgr ∷ String → String
stripSgr ('\ESC' : '[' : rest) = stripSgr (drop 1 (dropWhile (not . isFinal) rest))
stripSgr (c : rest) = c : stripSgr rest
stripSgr [] = []

-- | What a terminal would show: a carriage return moves to the line start, an erase-to-end-of-line (@ESC [ K@) cuts the line at the
-- cursor, every other control sequence is dropped, a newline ends the line. A formatter that shows progress writes a transient
-- text and a buffered erase before the next write, which a file keeps as bytes and a terminal never shows.
render ∷ String → String
render = go "" 0
  where
    go cur _ [] = cur
    go cur _ ('\n' : rest) = cur <> "\n" <> go "" 0 rest
    go cur _ ('\r' : rest) = go cur 0 rest
    go cur pos ('\ESC' : '[' : rest) =
      let (params, remainder) = break isFinal rest
          cut = if take 1 remainder == "K" && params `elem` ["", "0"] then take pos cur else cur
       in go cut pos (drop 1 remainder)
    go cur pos (c : rest) = go (take pos cur <> [c] <> drop (pos + 1) cur) (pos + 1) rest

isFinal ∷ Char → Bool
isFinal c = c >= '@' && c <= '~'

-- | The parameters of every colour (SGR) sequence of a line, in order (@""@ and @"0"@ reset); other sequences (the cursor
-- and erase controls) are not colours.
sgrParams ∷ String → [String]
sgrParams ('\ESC' : '[' : rest) = let (params, remainder) = break isFinal rest in [params | take 1 remainder == "m"] <> sgrParams (drop 1 remainder)
sgrParams (_ : rest) = sgrParams rest
sgrParams [] = []

-- | An action with the two variables the runner reads itself pinned: @GITHUB_ACTIONS@ set as GitHub Actions sets it (colour forced
-- on does not report progress then) or unset (it does), and @BUILDKITE@ unset; both restored.
withPinnedEnvironment ∷ Bool → IO a → IO a
withPinnedEnvironment githubActions action = bracket save restore $ \_ → do
  if githubActions then setEnv "GITHUB_ACTIONS" "true" else unsetEnv "GITHUB_ACTIONS"
  unsetEnv "BUILDKITE"
  action
  where
    save = (,) <$> lookupEnv "GITHUB_ACTIONS" <*> lookupEnv "BUILDKITE"
    restore (gh, bk) = maybe (unsetEnv "GITHUB_ACTIONS") (setEnv "GITHUB_ACTIONS") gh >> maybe (unsetEnv "BUILDKITE") (setEnv "BUILDKITE") bk

-- | How the nested run is made: its colour setting, whether it runs as GitHub Actions does, and whether the capture is what a terminal
-- would show (the run reports progress, so the bytes carry the transient text and its erase).
data Mode = Mode
  { modeName ∷ String
  , modeColour ∷ Bool
  , modeGithub ∷ Bool
  , modeRendered ∷ Bool
  }

modes ∷ [Mode]
modes =
  [ Mode "colour off" False True False
  , Mode "colour on, as GitHub Actions" True True False
  , Mode "colour on with progress, as a terminal shows it" True False True
  ]

-- | Run a nested spec through the pinned configuration with the process's output captured: its text (rendered as a terminal shows
-- it in the mode that says so), the bytes as written, and its failure count.
runNested ∷ Shape → Mode → (Output → Spec) → IO (String, String, Int)
runNested shape mode nested = do
  out ← newOutput
  failures ← newIORef (-1 ∷ Int)
  raw ← withOutputLocked globalOutput $ withPinnedEnvironment (modeGithub mode) $ captured $ do
    config ← pinnedConfig out (shapeFormat shape) (modeColour mode) 8
    summary ← withArgs [] (runSpec (nested out) config)
    writeIORef failures (summaryFailures summary)
  (\f → (if modeRendered mode then render raw else raw, raw, f)) <$> readIORef failures

-- | The process's standard output while an action runs, as text. The caller holds the process's output lock.
captured ∷ IO () → IO String
captured action = capturedWith (const action)

-- | The same, handing the action a way to read how many bytes the capture holds so far (after flushing the handle).
capturedWith ∷ (IO Int → IO ()) → IO String
capturedWith action = do
  hFlush stdout
  tmp ← getTemporaryDirectory
  (path, h) ← openTempFile tmp "terrain-runtime-output-oracle.txt"
  saved ← hDuplicate stdout
  hDuplicateTo h stdout
  caps ← getNumCapabilities
  setNumCapabilities 8
  action (hFlush stdout >> fromIntegral <$> hFileSize h) `finally` (setNumCapabilities caps >> hFlush stdout >> hDuplicateTo saved stdout >> hClose saved >> hClose h)
  text ← withFile path ReadMode $ \r → hSetEncoding r utf8 >> hGetContents' r
  removeFile path
  pure text

-- | The complete event sequence of a small run, as the runner emits it: a start, a group, three items (one succeeding, one pending,
-- one failing, each with info lines), progress, the end of the group and the end of the run.
eventSequence ∷ [(String, Event)]
eventSequence =
  [ ("started", Started)
  , ("group started", GroupStarted group)
  , ("item 1 started", ItemStarted item1)
  , ("item 1 progress", Progress item1 (1, 2))
  , ("item 1 done (success)", ItemDone item1 (finished Success))
  , ("item 2 started", ItemStarted item2)
  , ("item 2 done (pending)", ItemDone item2 (finished (Pending Nothing (Just "not yet"))))
  , ("item 3 started", ItemStarted item3)
  , ("item 3 done (failure)", ItemDone item3 (finished (Failure Nothing (Reason "it failed"))))
  , ("group done", GroupDone group)
  , ("done", Done [(item1, finished Success), (item2, finished (Pending Nothing (Just "not yet"))), (item3, finished (Failure Nothing (Reason "it failed")))])
  ]
  where
    group = ([], "group")
    item1 = (["group"], "item 1")
    item2 = (["group"], "item 2")
    item3 = (["group"], "item 3")
    finished result = Item Nothing (Seconds 0) "an info line\nand a second one" result

-- | Where a record is printed in the sequence: before the first event, after each event.
positionLabels ∷ [String]
positionLabels = "before the first event" : ["after " <> label | (label, _) ← eventSequence]

-- | What an event wrote, by its bytes: nothing; a newline last; an erase last (transient text); content with no newline.
observedEffect ∷ String → Effect
observedEffect written
  | null written = Silent
  | last written == '\n' = EndsLine
  | "\ESC[K" `isSuffixOf` written = LeavesTransient
  | otherwise = LeavesOpen

-- | Drive one formatter, guarded the way the runner guards it and built the way the runner builds it (a real format configuration,
-- the cursor hidden first when progress is reported), through 'eventSequence' directly, with no scheduling in it: with a record
-- printed through the same output at the given positions (1 is before the first event, k + 1 after the k-th event). The bytes
-- written, and what each event wrote by itself.
driveSequence ∷ String → Bool → Bool → [Int] → IO (String, [(String, Effect)])
driveSequence name colour progress recordAt = do
  out ← newOutput
  observed ← newIORef []
  raw ← withOutputLocked globalOutput $ capturedWith $ \position → do
    if progress then hPutStr stdout "\ESC[?25l" else pure ()
    make ← maybe (fail ("no formatter " <> name)) pure (lookup name (configAvailableFormatters (guardFormatters out defaultConfig)))
    format ← make defaultFormatConfig {formatConfigUseColor = colour, formatConfigReportProgress = progress, formatConfigExpectedTotalCount = 3}
    let record' k = if k `elem` recordAt then printLineOn out (record k 1) else pure ()
    record' 1
    forM_ (zip [2 ..] eventSequence) $ \(k, (label, event)) → do
      from ← position
      format event
      to ← position
      modifyIORef observed ((label, (from, to)) :)
      record' k
    if progress then hPutStr stdout "\ESC[?25h" else pure ()
  spans ← reverse <$> readIORef observed
  pure (raw, [(label, observedEffect (take (to - from) (drop from raw))) | (label, (from, to)) ← spans])

-- | The modes of the direct drive: colour, and whether the runner reports progress (it does only with colour).
driveModes ∷ [(String, Bool, Bool)]
driveModes = [("colour off", False, False), ("colour on as GitHub Actions", True, False), ("colour on with progress", True, True)]

-- | The run did what its mode says: no escape at all with colour off (and none in a rendered capture), and with colour on one
-- wherever the formatter writes anything but records (the silent formatter writes none).
colourPresent ∷ Shape → Mode → String → Bool
colourPresent shape mode text
  | not (modeColour mode) = '\ESC' `notElem` text
  | modeRendered mode = '\ESC' `notElem` text
  | shapeName shape == "silent" = '\ESC' `notElem` text
  | otherwise = "\ESC[" `isInfixOf` text

spec ∷ Spec
spec = describe "the lines the suite prints and the runner's formatter's report" $ do
  forM_ modes $ \mode → do
    let colourName = modeName mode
    forM_ shapes $ \shape →
      it ("prints every record whole at a line start, and the formatter's lines whole, beside eight examples (" <> shapeName shape <> ", " <> colourName <> ")") $ do
        (text, raw, failures) ← runNested shape mode (stress examples)
        problems shape examples rowsPerExample 0 text `shouldBe` []
        recordLineProblems examples rowsPerExample 0 raw `shouldBe` []
        failures `shouldBe` 0
        colourPresent shape mode text `shouldBe` True
    forM_ (filter shapeBoundary shapes) $ \shape →
      it ("writes whole, beside the formatter, the records that sequential examples write directly after the group (" <> shapeName shape <> ", " <> colourName <> ")") $ do
        (text, _, failures) ← runNested shape mode mixed
        problems shape mixedParallel rowsPerExample sequentialExamples text `shouldBe` []
        failures `shouldBe` 0
        colourPresent shape mode text `shouldBe` True
  forM_ shapes $ \shape →
    forM_ driveModes $ \(modeLabel, colour, progress) →
      it ("keeps a record whole at a line start at every position of a complete event sequence, alone and with the others, driven directly, and its model of what each event writes is what it writes (" <> shapeName shape <> ", " <> modeLabel <> ")") $ do
        let positions = length positionLabels
            visible t = concat [l | l ← lines (render t), not (isRecordLine l), not ("Finished in " `isPrefixOf` l)]
        (raw, effects) ← driveSequence (shapeFormat shape) colour progress [1 .. positions]
        (plain, _) ← driveSequence (shapeFormat shape) colour progress []
        singles ← mapM (\k → (,) k . fst <$> driveSequence (shapeFormat shape) colour progress [k]) [1 .. positions]
        let badPositions = [label | (k, label) ← zip [1 ..] positionLabels, record k 1 `notElem` lines raw]
            -- a record printed alone, at one position: the first record the line state is asked about after the events before it
            badAlone = [label | ((k, text), label) ← zip singles positionLabels, record k 1 `notElem` lines text || length [l | l ← lines text, isRecordLine l] /= 1 || visible text /= visible plain]
            modelMisses = [label <> ": wrote " <> show seen <> ", the model says " <> show (eventEffect (shapeFormat shape) progress event) | ((label, seen), (_, event)) ← zip effects eventSequence, seen /= eventEffect (shapeFormat shape) progress event]
        badAlone `shouldBe` []
        badPositions `shouldBe` []
        recordLineProblems positions 1 0 raw `shouldBe` []
        length [l | l ← lines raw, isRecordLine l] `shouldBe` positions
        modelMisses `shouldBe` []
        visible raw `shouldBe` visible plain
  forM_ shapes $ \shape →
    it ("keeps the record printed between the start of the run and the first item's start whole, through the runner with the two events held in that order (" <> shapeName shape <> ", progress reported)") $ do
      out ← newOutput
      started ← newEmptyMVar
      printed ← newEmptyMVar
      let nested = parallel $ describe "barrier" $ it "prints between the start of the run and the first item's start" $ do
            readMVar started
            printLineOn out (record 1 1)
            putMVar printed ()
          observe make config' = do
            format ← make config'
            pure $ \event → case event of
              Started → format event >> putMVar started ()
              ItemStarted {} → readMVar printed >> format event
              _ → format event
      raw ← withOutputLocked globalOutput $ withPinnedEnvironment False $ captured $ do
        config ← pinnedConfig out (shapeFormat shape) True 8
        summary ← withArgs [] (runSpec nested config {configFormat = observe <$> configFormat config})
        summaryFailures summary `shouldBe` 0
      recordLineProblems 1 1 0 raw `shouldBe` []
      length [l | l ← lines raw, isRecordLine l] `shouldBe` 1
  it "the check refuses a record joined to a partial formatter line, a cut record, a missing, a repeated record and a stray fragment" $ do
    let shape = Shape "specdoc" "specdoc" True False True True
        good = "\nstress\n" <> record 1 1 <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n"
        check = problems shape 2 1 0
    check good `shouldBe` []
    check ("\nstress\n" <> record 1 1 <> "\n  example 1" <> record 2 1 <> "\n\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> take 30 (record 1 1) <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n" <> record 1 1 <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n  exam\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check (init good) `shouldNotBe` []
    recordLineProblems 2 1 0 ("\n" <> record 1 1 <> "\n  example 1 [ ]\r\ESC[K\n" <> record 2 1 <> "\n") `shouldBe` []
    recordLineProblems 2 1 0 ("\ESC[?25l" <> record 1 1 <> "\n") `shouldNotBe` []
    recordLineProblems 2 1 0 ("\n  example 1 [ ]\r\ESC[K" <> record 2 1 <> "\n") `shouldNotBe` []
    let col t = "\ESC[32m" <> t <> "\ESC[0m"
        goodColour = "\n" <> col "stress" <> "\n" <> record 1 1 <> "\n" <> col "  example 1" <> "\n" <> record 2 1 <> "\n" <> col "  example 2" <> "\n\n" <> "Finished in 0.0100 seconds\n" <> col "2 examples, 0 failures" <> "\n"
        itemColour = "\nstress\n" <> record 1 1 <> "\n  example 1 [\ESC[32mv\ESC[0m]\n" <> record 2 1 <> "\n  example 2 [\ESC[32mv\ESC[0m]\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n"
    check goodColour `shouldBe` []
    check itemColour `shouldBe` []
    check ("\nstress\n" <> record 1 1 <> "\n" <> col "  example 1" <> record 2 1 <> "\n" <> col "  example 2" <> "\n\nFinished in 0.0100 seconds\n" <> col "2 examples, 0 failures" <> "\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n\ESC[32m  example 1\n\ESC[0m" <> record 2 1 <> "\n" <> col "  example 2" <> "\n\nFinished in 0.0100 seconds\n" <> col "2 examples, 0 failures" <> "\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n\ESC[32m  example 1\n" <> record 2 1 <> "\n" <> col "  example 2" <> "\n\nFinished in 0.0100 seconds\n" <> col "2 examples, 0 failures" <> "\n") `shouldNotBe` []
    let directs i = concatMap (\j → direct i j <> "\n") [1 .. directRows]
        tailOf = "\nFinished in 0.0100 seconds\n2 examples, 0 failures\n"
        groups = "\ngroup 1\n  inner 1\n" <> directs 1 <> "    sequential 1\n" <> "group 2\n  inner 2\n" <> directs 2 <> "    sequential 2\n" <> tailOf
        joined = "\ngroup 1\n  inner 1\n" <> directs 1 <> "    sequential 1" <> direct 2 1 <> "\n" <> direct 2 2 <> "\n" <> direct 2 3 <> "\n    sequential 2\n" <> tailOf
    problems shape 0 1 2 groups `shouldBe` []
    problems shape 0 1 2 joined `shouldNotBe` []
