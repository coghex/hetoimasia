-- | The oracle of the printed lines ("Test.TerrainRuntime.Output"): a small parallel spec is run through the configuration the
-- suite itself runs with ("Test.TerrainRuntime.Runner.suiteConfig": the same job default, the same guarded formatters), once
-- per formatter the runner can select, with the process's standard output captured to a file; then every printed record must
-- be a whole line starting at a line start, every record must appear exactly once, and every line the formatter wrote must be
-- one it would have written whole.
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
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.Char (isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, nub, sort, stripPrefix, (\\))
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (withArgs)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (ReadMode), hClose, hFlush, hGetContents', hSetEncoding, openTempFile, stdout, utf8, withFile)
import Test.Hspec
import Test.Hspec.Runner (Summary (..), runSpec)
import Test.TerrainRuntime.Output (Output, globalOutput, newOutput, printLineOn, withOutputLocked)
import Test.TerrainRuntime.Runner (suiteConfig)

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
stress ∷ Output → Spec
stress out = parallel $ describe "stress" $ forM_ [1 .. examples] $ \i →
  it ("example " <> show i) $ forM_ [1 .. rowsPerExample] $ \j → printLineOn out (record i j)

-- | Sequential examples that follow the group, in nested describes, each writing directly to standard output.
sequentialGroups, sequentialPerGroup, directRows ∷ Int
sequentialGroups = 25
sequentialPerGroup = 4
directRows = 3

sequentialExamples ∷ Int
sequentialExamples = sequentialGroups * sequentialPerGroup

mixed ∷ Output → Spec
mixed out = do
  stress out
  forM_ [1 .. sequentialGroups] $ \g → describe ("group " <> show g) $ describe ("inner " <> show g) $
    forM_ [1 .. sequentialPerGroup] $ \k → do
      let i = (g - 1) * sequentialPerGroup + k
      it ("sequential " <> show i) $ forM_ [1 .. directRows] $ \j → putStrLn (direct i j)

-- | What a formatter writes besides the records: item lines, or dots, and the footer.
data Shape = Shape
  { shapeName ∷ String
  , shapeArgs ∷ [String]
  , shapeItems ∷ Bool
  , shapeDots ∷ Bool
  , shapeFooter ∷ Bool
  , shapeBoundary ∷ Bool
  }

shapes ∷ [Shape]
shapes =
  [ Shape "the default formatter (checks)" [] True False True True
  , Shape "specdoc" ["--format=specdoc"] True False True True
  , Shape "progress" ["--format=progress"] False True True False
  , Shape "failed-examples" ["--format=failed-examples"] False False True True
  , Shape "silent" ["--format=silent"] False False False True
  ]

-- | Everything the output got wrong, empty when every record is whole at a line start and exactly once and every other line is
-- one the formatter writes whole. The expected records are @examples@ x @rows@; @items@ and @dots@ say what the formatter
-- writes for each example.
problems ∷ Shape → Int → Int → Int → String → [String]
problems shape n rows seqN out =
  [ "the output does not end at a line end" | not (null out), last out /= '\n' ]
    <> [ "a record is not whole at a line start: " <> show (take 70 l) | l ← ls, isRecordLine l, l `notElem` expected ]
    <> [ "a record is missing: " <> r | r ← expected \\ records ]
    <> [ "a record is repeated: " <> r | r ← nub records, length (filter (== r) records) > 1 ]
    <> [ "a formatter line is not whole: " <> show (take 70 l) | l ← others, not (wholeFormatterLine l) ]
    <> [ "parallel item lines " <> show (sort parallelItems) <> " are not exactly 1.." <> show n | shapeItems shape, sort parallelItems /= [1 .. n] ]
    <> [ "sequential item lines " <> show (sort sequentialItems) <> " are not exactly 1.." <> show seqN | shapeItems shape, sort sequentialItems /= [1 .. seqN] ]
    <> [ show dots <> " progress dots, not " <> show (n + seqN) | shapeDots shape, dots /= n + seqN ]
    <> [ "the footer does not report " <> show total <> " examples, 0 failures" | shapeFooter shape, (show total <> " examples, 0 failures") `notElem` others ]
  where
    ls = lines out
    total = n + seqN
    expected = [record i j | i ← [1 .. n], j ← [1 .. rows]] <> [direct i j | i ← [1 .. seqN], j ← [1 .. directRows]]
    records = [l | l ← ls, l `elem` expected]
    others = [l | l ← ls, not (isRecordLine l)]
    items = [it' | l ← others, Just it' ← [itemNumber l]]
    parallelItems = [k | ("example", k) ← items]
    sequentialItems = [k | ("sequential", k) ← items]
    isRecordLine l = "EVIDENCE" `isInfixOf` l || "DIRECT" `isInfixOf` l
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

-- | The process's standard output while an action runs, as text. The caller holds the process's output lock.
captured ∷ IO () → IO String
captured action = do
  hFlush stdout
  tmp ← getTemporaryDirectory
  (path, h) ← openTempFile tmp "terrain-runtime-output-oracle.txt"
  saved ← hDuplicate stdout
  hDuplicateTo h stdout
  caps ← getNumCapabilities
  setNumCapabilities 8
  action `finally` (setNumCapabilities caps >> hFlush stdout >> hDuplicateTo saved stdout >> hClose saved >> hClose h)
  text ← withFile path ReadMode $ \r → hSetEncoding r utf8 >> hGetContents' r
  removeFile path
  pure text

spec ∷ Spec
spec = describe "the lines the suite prints and the runner's formatter's report" $ do
  forM_ shapes $ \shape →
    it ("prints every record whole at a line start, and the formatter's lines whole, beside eight examples (" <> shapeName shape <> ")") $ do
      out ← newOutput
      failures ← newIORef (-1 ∷ Int)
      text ← withOutputLocked globalOutput $ captured $ do
        config ← suiteConfig out (shapeArgs shape <> ["--jobs=8"])
        summary ← withArgs [] (runSpec (stress out) config)
        writeIORef failures (summaryFailures summary)
      problems shape examples rowsPerExample 0 text `shouldBe` []
      readIORef failures >>= (`shouldBe` 0)
  forM_ (filter shapeBoundary shapes) $ \shape →
    it ("writes whole, beside the formatter, the records that sequential examples write directly after the group (" <> shapeName shape <> ")") $ do
      out ← newOutput
      failures ← newIORef (-1 ∷ Int)
      text ← withOutputLocked globalOutput $ captured $ do
        config ← suiteConfig out (shapeArgs shape <> ["--jobs=8"])
        summary ← withArgs [] (runSpec (mixed out) config)
        writeIORef failures (summaryFailures summary)
      problems shape examples rowsPerExample sequentialExamples text `shouldBe` []
      readIORef failures >>= (`shouldBe` 0)
  it "the check refuses a record joined to a partial formatter line, a cut record, a missing, a repeated record and a stray fragment" $ do
    let shape = Shape "specdoc" [] True False True True
        good = "\nstress\n" <> record 1 1 <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n"
        check = problems shape 2 1 0
    check good `shouldBe` []
    check ("\nstress\n" <> record 1 1 <> "\n  example 1" <> record 2 1 <> "\n\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> take 30 (record 1 1) <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n" <> record 1 1 <> "\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check ("\nstress\n" <> record 1 1 <> "\n  exam\n  example 1\n" <> record 2 1 <> "\n  example 2\n\nFinished in 0.0100 seconds\n2 examples, 0 failures\n") `shouldNotBe` []
    check (init good) `shouldNotBe` []
    let directs i = concatMap (\j → direct i j <> "\n") [1 .. directRows]
        tailOf = "\nFinished in 0.0100 seconds\n2 examples, 0 failures\n"
        groups = "\ngroup 1\n  inner 1\n" <> directs 1 <> "    sequential 1\n" <> "group 2\n  inner 2\n" <> directs 2 <> "    sequential 2\n" <> tailOf
        joined = "\ngroup 1\n  inner 1\n" <> directs 1 <> "    sequential 1" <> direct 2 1 <> "\n" <> direct 2 2 <> "\n" <> direct 2 3 <> "\n    sequential 2\n" <> tailOf
    problems shape 0 1 2 groups `shouldBe` []
    problems shape 0 1 2 joined `shouldNotBe` []
