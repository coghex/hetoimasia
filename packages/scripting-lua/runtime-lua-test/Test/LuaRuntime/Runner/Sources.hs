-- | Reading the scripts' files, loading them as modules and what a source that does not load does.
module Test.LuaRuntime.Runner.Sources (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (ModuleRef), maxIdentityLength, maxSourceBytes)
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runner.Internal (moduleRefFor)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (bounded, withBoundary)

-- | A module whose every hook records, so a hook that ran is seen.
hooked ∷ Char8.ByteString
hooked =
  lua
    [ "fx.record('loaded')"
    , "function init(self) fx.record('init') end"
    , "function run(self) fx.record('run') end"
    , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
    ]

-- | What a source that did not load leaves, whatever the cause: a failed start with a report
-- that names the file, the VM and the error, no instance, no table and the failure status, the
-- report written to the error sink and nothing to the output sink.
expectNotLoaded ∷ RFixture → RuntimeControl → FilePath → LoadProblem → RunReport → IO ()
expectNotLoaded fixture control path problem report = do
  reportEnding report `shouldBe` EndedStartupFailure
  statusOf report `shouldBe` StatusFailure
  instancesOf report `shouldBe` []
  case loadFailureOf report of
    Nothing → fail "the report of a run that did not start carries no load failure"
    Just failure → do
      loadFile failure `shouldBe` Text.pack path
      loadVm failure `shouldBe` "vm"
      loadProblem failure `shouldBe` problem
      Text.length (loadError failure) `shouldSatisfy` (<= errorLimit)
      Text.length (loadError failure) `shouldSatisfy` (> 0)
  errors ← errLines fixture
  take 1 errors `shouldSatisfy` (\found → all (Text.isPrefixOf "failure: source did not load script=") found && length found == 1)
  outLines fixture `shouldReturn` []
  -- The VM is retired, or was never started.
  outstanding control `shouldReturn` 0

spec ∷ Spec
spec = describe "sources" $ do
  forM_
    [ ("a syntax error", lua ["function run(self) fx.record('run'"], LoadRejected)
    , ("an error at the top level", lua ["fx.record('before')", "error('top level boom')"], LoadRejected)
    ]
    $ \(label, source, problem) →
      it ("reports " <> label <> " as a source that did not load, with no TID, and runs no hook") $ bounded $ do
        fixture ← newRFixture
        withScripts [("bad.lua", source)] $ \paths →
          withBoundary $ \control runtime → do
            report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
            expectNotLoaded fixture control (scriptAt paths 0) problem report
            -- Nothing of the module's hooks ran, and no instance was admitted.
            recorded fixture >>= (`shouldNotSatisfyElem` ["init", "run", "shutdown stopped"])

  it "reports a runtime error at the top level with what it said" $ bounded $ do
    fixture ← newRFixture
    withScripts [("bad.lua", lua ["error('top level boom')"])] $ \paths →
      withBoundary $ \_ runtime → do
        report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
        fmap (Text.unpack . loadError) (loadFailureOf report) `shouldSatisfy` maybe False (\message → "top level boom" `isInfix` message)

  it "reports a file that does not exist" $ bounded $ do
    fixture ← newRFixture
    withScripts [] $ \_ →
      withBoundary $ \control runtime → do
        let path = "/nonexistent-directory-for-the-runner/none.lua"
        report ← run fixture runtime (config fixture [noWait path]) >>= expectRan
        expectNotLoaded fixture control path LoadMissing report

  it "reports a file over the host's source limit, having read no more than one byte past it" $ bounded $ do
    fixture ← newRFixture
    withScripts [("big.lua", ByteString.replicate (maxSourceBytes + 1) 32)] $ \paths →
      withBoundary $ \control runtime → do
        report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
        expectNotLoaded fixture control (scriptAt paths 0) LoadTooLarge report

  it "accepts a file of exactly the host's source limit" $ bounded $ do
    fixture ← newRFixture
    -- A one-shot, and a comment that fills the file to the byte.
    let head' = "function run(self) fx.record('ran') end\n-- "
        body = head' <> ByteString.replicate (maxSourceBytes - ByteString.length head') 120
    withScripts [("exact.lua", body)] $ \paths →
      withBoundary $ \_ runtime → do
        report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
        ByteString.length body `shouldBe` maxSourceBytes
        loadFailureOf report `shouldBe` Nothing
        reportEnding report `shouldBe` EndedAllInstances
        recorded fixture `shouldReturn` ["ran"]

  it "reports a path that cannot be read as a file" $ bounded $ do
    fixture ← newRFixture
    withScripts [("a.lua", hooked)] $ \paths →
      withBoundary $ \control runtime → do
        -- A directory is a path that is there and cannot be read as a file.
        let directory = scriptAt paths 0 <> ".d"
        createDirectory directory
        report ← run fixture runtime (config fixture [noWait directory]) >>= expectRan
        expectNotLoaded fixture control directory LoadUnreadable report

  it "reports the first source that did not load in script order, with the modules before it loaded" $ bounded $ do
    fixture ← newRFixture
    withScripts [("a.lua", lua ["fx.record('a loaded')"]), ("b.lua", lua ["syntax error here"]), ("c.lua", lua ["fx.record('c loaded')"])] $ \paths →
      withBoundary $ \control runtime → do
        report ← run fixture runtime (config fixture (map noWait paths)) >>= expectRan
        expectNotLoaded fixture control (scriptAt paths 1) LoadRejected report
        recorded fixture `shouldReturn` ["a loaded"]

  it "reports a file that is missing, with the modules before it loaded and the ones after it never read" $ bounded $ do
    fixture ← newRFixture
    withScripts [("a.lua", lua ["fx.record('a loaded')"]), ("c.lua", lua ["syntax error here"])] $ \paths →
      withBoundary $ \control runtime → do
        let missing = scriptAt paths 0 <> ".missing"
        report ← run fixture runtime (config fixture [noWait (scriptAt paths 0), noWait missing, noWait (scriptAt paths 1)]) >>= expectRan
        expectNotLoaded fixture control missing LoadMissing report
        recorded fixture `shouldReturn` ["a loaded"]

  it "reports a module that does not load before a file that is missing later in the order" $ bounded $ do
    fixture ← newRFixture
    withScripts [("a.lua", lua ["syntax error here"])] $ \paths →
      withBoundary $ \control runtime → do
        let missing = scriptAt paths 0 <> ".missing"
        report ← run fixture runtime (config fixture [noWait (scriptAt paths 0), noWait missing]) >>= expectRan
        expectNotLoaded fixture control (scriptAt paths 0) LoadRejected report

  it "reads a path named twice once, loads it once and admits it twice" $ bounded $ do
    fixture ← newRFixture
    withScripts [("twice.lua", hooked)] $ \paths →
      withBoundary $ \_ runtime → do
        let path = scriptAt paths 0
        report ← run fixture runtime (config fixture [Script path (Just "first") Nothing, Script path (Just "second") Nothing]) >>= expectRan
        reportEnding report `shouldBe` EndedAllInstances
        map instanceNameText (instancesOf report) `shouldBe` ["first", "second"]
        length (tidsOf report) `shouldBe` 2
        -- The top level ran once; each instance ran its own hooks.
        loaded ← filter (== "loaded") <$> recorded fixture
        loaded `shouldBe` ["loaded"]
        ran' ← filter (== "run") <$> recorded fixture
        ran' `shouldBe` ["run", "run"]

  it "gives two paths with one file name distinct identities, so both load" $ bounded $ do
    fixture ← newRFixture
    withScripts [("x.lua", lua ["fx.record('top x')", "function run(self) fx.record('run x') end"])] $ \paths → do
      let one = scriptAt paths 0
          directory = one <> ".dir"
          two = directory </> "x.lua"
      createDirectory directory
      ByteString.writeFile two (Text.encodeUtf8 "fx.record('top y')\nfunction run(self) fx.record('run y') end\n")
      withBoundary $ \_ runtime → do
        report ← run fixture runtime (config fixture [noWait one, noWait two]) >>= expectRan
        loadFailureOf report `shouldBe` Nothing
        reportEnding report `shouldBe` EndedAllInstances
        recorded fixture >>= \found → do
          found `shouldContain` ["top x"]
          found `shouldContain` ["top y"]
          found `shouldContain` ["run x"]
          found `shouldContain` ["run y"]
    one ← pure (moduleRefFor 0 "a/x.lua")
    two ← pure (moduleRefFor 1 "b/x.lua")
    one `shouldNotBe` two

  describe "the identity of a module" $ do
    let odd' =
          [ "a.lua"
          , "dir/with space/ünïcode-ファイル.lua"
          , "tab\there/new\nline.lua"
          , "\DEL/\NUL/del.lua"
          , concat (replicate 40 "very/long/directory/name/")
          , concat (replicate 200 "é")
          , ""
          ]
    it "fits the host's rules for every path, whatever its characters or length" $
      forM_ (zip [0 ..] odd') $ \(place, path) → do
        let ModuleRef name version = moduleRefFor place path
        Text.null name `shouldBe` False
        ByteString.length (Text.encodeUtf8 name) `shouldSatisfy` (<= maxIdentityLength)
        Text.all (\character → character >= ' ' && character /= '\DEL') name `shouldBe` True
        ByteString.length (Text.encodeUtf8 version) `shouldSatisfy` (<= maxIdentityLength)
    it "is the same for the same place and path, and never shared by two places" $ do
      moduleRefFor 3 "x/y.lua" `shouldBe` moduleRefFor 3 "x/y.lua"
      forM_ [(a, b) | a ← [0 .. 6 ∷ Int], b ← [0 .. 6], a /= b] $ \(a, b) →
        moduleRefFor a (concat (replicate 40 "very/long/directory/name/")) `shouldNotBe` moduleRefFor b (concat (replicate 40 "very/long/directory/name/"))

isInfix ∷ String → String → Bool
isInfix needle haystack = any (needle `isPrefixOf'`) (suffixes haystack)
  where
    isPrefixOf' prefix text = take (length prefix) text == prefix
    suffixes [] = [[]]
    suffixes text@(_ : rest) = text : suffixes rest

shouldNotSatisfyElem ∷ [Text.Text] → [Text.Text] → IO ()
shouldNotSatisfyElem found unwanted = filter (`elem` unwanted) found `shouldBe` []
