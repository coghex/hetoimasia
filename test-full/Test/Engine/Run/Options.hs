-- | The grammar of @hetoimasia run@, as direct examples of a pure function: every accepted form, the literal
-- separator, and each usage error with its reason. No example opens a folder.
module Test.Engine.Run.Options (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Run.Options (RunParse (..), RunProblem (..), parseRun, problemReason, runHelp, runUsage)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldSatisfy)

spec ∷ Spec
spec = describe "Options" $ do
  it "accepts exactly one folder, relative or absolute, as typed" $
    forM_ ["game", "./game", "../up/game", "/abs/game", "a b", "-", "é"] $ \root →
      if root == "-" then parseRun [root] `shouldBe` Left (UnknownOption "-") else parseRun [root] `shouldBe` Right (RunRoot root)

  it "takes the argument after the separator literally, a leading hyphen and --help included" $
    forM_ ["-game", "--help", "--", "-", "--x"] $ \root →
      parseRun ["--", root] `shouldBe` Right (RunRoot root)

  it "answers help for --help alone" $
    parseRun ["--help"] `shouldBe` Right RunHelp

  it "refuses --help beside anything else, before or after it" $ do
    parseRun ["--help", "game"] `shouldBe` Left HelpNotAlone
    parseRun ["--help", "--"] `shouldBe` Left HelpNotAlone
    parseRun ["game", "--help"] `shouldBe` Left ExtraArguments
    parseRun ["--", "--help", "x"] `shouldBe` Left ExtraArguments

  it "refuses a missing folder, with or without the separator" $ do
    parseRun [] `shouldBe` Left MissingRoot
    parseRun ["--"] `shouldBe` Left MissingRoot

  it "refuses extra arguments, with or without the separator" $ do
    parseRun ["a", "b"] `shouldBe` Left ExtraArguments
    parseRun ["--", "a", "b"] `shouldBe` Left ExtraArguments
    parseRun ["a", "--"] `shouldBe` Left ExtraArguments

  it "refuses every other option as unknown, wherever the folder is" $
    forM_ ["-x", "--mod", "--seed", "--entry", "--tick", "--window", "-h", "--script", "--help=1", "-help"] $ \option → do
      parseRun [option] `shouldBe` Left (UnknownOption option)
      parseRun [option, "game"] `shouldBe` Left (UnknownOption option)

  it "has an escaped, bounded, one-line reason for what the user typed" $ do
    let reason = problemReason (UnknownOption ("--bad\nline\ESC[0m\1234" <> replicate 500 'x'))
    Text.unpack reason `shouldNotContainAny` ["\n", "\ESC", "\1234"]
    Text.length reason `shouldSatisfy` (< 300)
    Text.unpack reason `shouldContain` "\\x0a"
    Text.unpack (problemReason MissingRoot) `shouldBe` "missing GAME_ROOT"

  it "has a help that names the usage line, the separator, the exit statuses and no fallback option" $ do
    let help = Text.unpack runHelp
    help `shouldContain` Text.unpack runUsage
    help `shouldContain` "--           Everything after it"
    help `shouldContain` "130"
    help `shouldContain` "There is no option to select a provider"
  where
    shouldNotContainAny text needles = forM_ needles $ \needle → (text `shouldNotContainText` needle)
    shouldNotContainText text needle = (needle `isIn` text) `shouldBe` False
    isIn needle text = any (\i → take (length needle) (drop i text) == needle) [0 .. length text - length needle]
