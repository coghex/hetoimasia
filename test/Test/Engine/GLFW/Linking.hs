-- | The GLFW package's link declarations agree with the native manifest.
--
-- An ordinary executable link receives @pkg-config --libs glfw3@ from Cabal,
-- which names the archive but not the platform libraries and frameworks GLFW
-- itself needs; those are in @Libs.private@. The package therefore declares
-- them in its @native@ library, per operating system, and this example compares
-- that declaration with what the native manifest recorded from the generated
-- @glfw3.pc@ (@pkg-config --libs --static glfw3@), for the platform the suite
-- runs on. A regenerated manifest that needs another library, or a declaration
-- that drifted, fails here rather than at some later link.
--
-- The manifest is found the way Cabal found the library: through @pkg-config@,
-- whose @glfw3@ prefix holds @hetoimasia-native-manifest.json@. The package
-- description is read out of the checkout this suite runs in.
module Test.Engine.GLFW.Linking (spec) where

import Data.Char (isSpace)
import Data.List (isPrefixOf, stripPrefix)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)

spec ∷ Spec
spec = describe "GLFW link declarations" $ do
  it "declare exactly the platform link requirements the native manifest records" $ do
    (status, out, err) ← readProcessWithExitCode "pkg-config" ["--variable=prefix", "glfw3"] ""
    case status of
      ExitSuccess → do
        let prefix = trim out
        manifest ← readFile (prefix </> "hetoimasia-native-manifest.json")
        description ← readFile packageDescription
        case libsStatic manifest >>= requirements prefix of
          Left problem → expectationFailure ("the native manifest could not be read: " <> problem)
          Right required → declaredRequirements os description `shouldBe` required
      _ →
        expectationFailure
          ("pkg-config cannot resolve glfw3; prepare the native prefix first (" <> trim err <> ")")

  it "declares the pinned GLFW series as a pkg-config dependency" $ do
    description ← readFile packageDescription
    description `shouldContain` "pkgconfig-depends: glfw3 >=3.4 && <3.5"

packageDescription ∷ FilePath
packageDescription = "packages/glfw/hetoimasia-glfw.cabal"

data Requirement = Framework String | Library String
  deriving (Eq, Show)

-- | The requirements a manifest's static link flags add beyond the private
-- archive itself.
requirements ∷ FilePath → [String] → Either String [Requirement]
requirements prefix = go
  where
    go [] = Right []
    go ("-framework" : name : rest) = (Framework name :) <$> go rest
    go (flag : rest)
      | flag == "-L" <> (prefix </> "lib") = go rest
      | flag == "-lglfw3" = go rest
      | Just name ← stripPrefix "-l" flag = (Library name :) <$> go rest
      | otherwise = Left ("a static link flag with no declaration form: " <> flag)

-- | The frameworks and extra libraries the @native@ library declares for one
-- operating system, in declaration order: unconditional ones, and those inside
-- an @if os(...)@ block naming that system.
declaredRequirements ∷ String → String → [Requirement]
declaredRequirements platform = collect False Nothing . lines
  where
    collect ∷ Bool → Maybe (Int, String) → [String] → [Requirement]
    collect _ _ [] = []
    collect inNative condition (line : rest)
      | null content || "--" `isPrefixOf` content = collect inNative condition rest
      | indent == 0 = collect (content == "library native") Nothing rest
      | not inNative = collect inNative condition rest
      | Just (conditionIndent, _) ← condition, indent <= conditionIndent = collect inNative Nothing (line : rest)
      | Just named ← stripPrefix "if os(" content = collect inNative (Just (indent, takeWhile (/= ')') named)) rest
      | applies, Just values ← stripPrefix "frameworks:" content = map Framework (words values) <> collect inNative condition rest
      | applies, Just values ← stripPrefix "extra-libraries:" content = map Library (words values) <> collect inNative condition rest
      | otherwise = collect inNative condition rest
      where
        content = trim line
        indent = length (takeWhile (== ' ') line)
        applies = maybe True ((== platform) . snd) condition

-- | The @pkg_config.libs_static@ array of a native manifest.
libsStatic ∷ String → Either String [String]
libsStatic document = case breakAfter "\"libs_static\"" document of
  Nothing → Left "it records no libs_static"
  Just after → case dropWhile isSpace (dropWhile (/= '[') after) of
    '[' : body → strings body
    _ → Left "libs_static is not an array"
  where
    strings text = case dropWhile (\c → isSpace c || c == ',') text of
      ']' : _ → Right []
      '"' : quoted → do
        (value, rest) ← string quoted
        (value :) <$> strings rest
      _ → Left "libs_static holds something other than strings"
    string ('"' : rest) = Right ("", rest)
    string ('\\' : escaped : rest) = do
      (value, after) ← string rest
      pure (unescape escaped : value, after)
    string (character : rest) = do
      (value, after) ← string rest
      pure (character : value, after)
    string [] = Left "an unterminated string"
    unescape 'n' = '\n'
    unescape 't' = '\t'
    unescape other = other

breakAfter ∷ String → String → Maybe String
breakAfter needle haystack
  | Just rest ← stripPrefix needle haystack = Just rest
  | otherwise = case haystack of
      [] → Nothing
      _ : rest → breakAfter needle rest

trim ∷ String → String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
