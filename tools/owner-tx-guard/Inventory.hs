{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's inventory, taken from Cabal alone (the design's "Cabal issuer dependency guard").
--
-- Projects: @cabal.project@ and @cabal.project.vulkan@, their literal local imports and their literal local package
-- directories. Optional, extra, remote and globbed package selection, and a project option that changes which packages
-- are visible, are unsupported.
--
-- Packages: Simple manifests read by Cabal's own parser, common stanzas expanded; an unknown field or section, even in
-- an inactive branch, is unsupported. Every condition atom of every branch is validated before either branch is
-- simplified: an operating system or architecture outside Linux and Darwin on x86_64 and aarch64, a compiler
-- condition, and a flag that is not a declared manual flag are unsupported. Each component (library, sublibrary,
-- foreign library, executable, exitcode test suite and benchmark) is simplified under every supported target and every
-- assignment of the package's manual flags; each distinct result on a target is one configuration, with its structured
-- dependencies, mixins, re-exports, declared modules and visibility. Backpack signatures and compiler options that
-- change which packages are visible are unsupported. Sources, compiler options and package macros are the ordinary
-- Cabal build's.
module Inventory
  ( Target (..)
  , targets
  , targetLabel
  , Package (..)
  , Configuration (..)
  , Inventory (..)
  , readInventory
  , componentId
  , configurationId
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub)
import qualified Data.Map.Strict as Map
import Distribution.Compiler (PerCompilerFlavor (..))
import Distribution.ModuleName (ModuleName)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Parsec.Warning (PWarnType (..), PWarning (..))
import Distribution.Pretty (prettyShow)
import Distribution.System (Arch (..), OS (..))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (normalise, takeDirectory, takeExtension, (</>))

-- | One supported target.
data Target = Target
  { targetOS ∷ OS
  , targetArch ∷ Arch
  }
  deriving (Eq, Ord, Show)

-- | Linux and Darwin, each on x86_64 and aarch64.
targets ∷ [Target]
targets = [Target os arch | os ← [Linux, OSX], arch ← [X86_64, AArch64]]

targetLabel ∷ Target → String
targetLabel (Target os arch) = (if os == OSX then "darwin" else prettyShow os) <> "/" <> prettyShow arch

-- | One local package: its distinct configurations, and the unsupported forms of its manifest as a whole.
data Package = Package
  { packageName ∷ String
  , packageDirectory ∷ FilePath
  , packageCabal ∷ FilePath
  , packageLibraries ∷ [String]
    -- ^ Its libraries' labels: the empty string for the main library, otherwise the sublibrary's name.
  , packageConfigurations ∷ [Configuration]
  , packageProblems ∷ [String]
  }

-- | One distinct configuration of one component on one target.
data Configuration = Configuration
  { configPackage ∷ String
  , configKind ∷ String
    -- ^ lib, flib, exe, test or bench
  , configName ∷ String
  , configTarget ∷ Target
  , configFlagsLabel ∷ String
    -- ^ The manual flag assignments that select it on its target.
  , configProblems ∷ [String]
  , configDependencies ∷ [(String, [String])]
    -- ^ Each dependency's package and the libraries it selects (the empty string for the main library).
  , configMixins ∷ [(String, String, String)]
  , configReexports ∷ [(String, String)]
  , configModules ∷ [String]
    -- ^ The modules it declares (exposed and other).
  , configPublic ∷ Bool
    -- ^ A library with @visibility: public@ (always true of a main library).
  }

-- | What the inventory found: the files it read, the packages, and every unsupported form of the projects.
data Inventory = Inventory
  { inventoryFiles ∷ [FilePath]
  , inventoryPackages ∷ [Package]
  , inventoryProblems ∷ [String]
  }

componentId ∷ Configuration → String
componentId configuration = configPackage configuration <> ":" <> configKind configuration <> ":" <> configName configuration

-- | A configuration's place, for diagnostics.
configurationId ∷ Configuration → String
configurationId configuration =
  componentId configuration <> " (" <> targetLabel (configTarget configuration) <> (if null (configFlagsLabel configuration) then "" else " " <> configFlagsLabel configuration) <> ")"

-- | Read both projects and every package they list. A manifest Cabal refuses is an error ('Left'); every other form
-- outside the subset is a problem.
readInventory ∷ FilePath → [FilePath] → IO (Either String Inventory)
readInventory root projects = do
  listed ← mapM (projectPackages root) projects
  case sequence listed of
    Left why → pure (Left why)
    Right results → do
      let files = nub (concatMap (\(f, _, _) → f) results)
          directories = nub (concatMap (\(_, d, _) → d) results)
          problems = concatMap (\(_, _, p) → p) results
      packages ← forM directories (readPackage root)
      pure (Inventory files <$> sequence packages <*> pure problems)

-- A project file's files read, package directories and unsupported forms, following literal local imports.
projectPackages ∷ FilePath → FilePath → IO (Either String ([FilePath], [FilePath], [String]))
projectPackages root project = go [project] [] [] []
  where
    go [] seen directories problems = pure (Right (reverse seen, reverse directories, problems))
    go (file : rest) seen directories problems
      | file `elem` seen = go rest seen directories problems
      | otherwise = do
          present ← doesFileExist (root </> file)
          if not present
            then pure (Left (file <> " does not exist"))
            else do
              text ← readFile (root </> file)
              let (entries, imports, found) = projectFields file text
                  relativeImports = [normalise (takeDirectory file </> imported) | imported ← imports]
              go (rest <> relativeImports) (file : seen) (reverse (map normalise entries) <> directories) (problems <> found)

-- The @packages:@ entries, @import:@ targets and unsupported forms of a project file.
projectFields ∷ FilePath → String → ([String], [String], [String])
projectFields file text = collect (lines text) Nothing [] [] []
  where
    collect [] _ entries imports problems = (reverse entries, reverse imports, reverse problems <> entryProblems (reverse entries) <> importProblems (reverse imports))
    collect (line : rest) collecting entries imports problems
      | all (`elem` " \t") line || "--" `isPrefixOf` dropWhile (== ' ') line = collect rest collecting entries imports problems
      | Just indent ← collecting, leading line > indent = collect rest collecting (reverse (words' line) <> entries) imports problems
      | Just value ← field "packages" line = collect rest (Just (leading line)) (reverse (words' value) <> entries) imports problems
      | Just value ← field "import" line = collect rest Nothing entries (reverse (words' value) <> imports) problems
      | Just name ← unsupportedField line = collect rest Nothing entries imports (("unsupported: " <> name <> " in " <> file) : problems)
      | leading line == 0 && "source-repository-package" `isPrefixOf` line = collect rest Nothing entries imports (("unsupported: source-repository-package in " <> file) : problems)
      | Just value ← optionField line, refused@(_ : _) ← filter visibilityOption (words value) =
          collect rest Nothing entries imports (("unsupported: the option " <> unwords refused <> " in " <> file <> ", which changes which packages are visible") : problems)
      | otherwise = collect rest Nothing entries imports problems
    leading = length . takeWhile (== ' ')
    words' = words . map (\c → if c == ',' then ' ' else c)
    field name line = case break (== ':') (dropWhile (== ' ') line) of
      (key, ':' : value) | key == name → Just value
      _ → Nothing
    optionField line = case break (== ':') (dropWhile (== ' ') line) of
      (key, ':' : value) | key `elem` ["ghc-options", "ghc-prof-options", "ghc-shared-options"] → Just value
      _ → Nothing
    unsupportedField line = case break (== ':') (dropWhile (== ' ') line) of
      (key, ':' : _) | key `elem` ["optional-packages", "extra-packages"] → Just key
      _ → Nothing
    remote entry = any (`isInfixOf` entry) ["://", "*", "?", "[", "{"] || any (`isSuffixOf` entry) [".tar.gz", ".cabal"]
    entryProblems entries = ["unsupported: the package entry " <> entry <> " in " <> file <> " (only literal local directories)" | entry ← entries, remote entry]
    importProblems imports = ["unsupported: the project import " <> entry <> " in " <> file <> " (only literal local files)" | entry ← imports, remote entry]

readPackage ∷ FilePath → FilePath → IO (Either String Package)
readPackage root directory = do
  exists ← doesDirectoryExist (root </> directory)
  if not exists
    then pure (Left ("the listed package directory " <> directory <> " does not exist"))
    else do
      cabals ← filter ((== ".cabal") . takeExtension) <$> listDirectory (root </> directory)
      case cabals of
        [cabal] → do
          let path = normalise (directory </> cabal)
          bytes ← ByteString.readFile (root </> path)
          case runParseResult (parseGenericPackageDescription bytes) of
            (_, Left (_, errors)) → pure (Left (path <> ": Cabal refused it: " <> show (toList errors)))
            (warnings, Right description) → Right <$> configurations directory path warnings description
        _ → pure (Left (directory <> " holds " <> show (length cabals) <> " package descriptions, not one"))

-- Every distinct configuration of every component, and the package's unsupported forms.
configurations ∷ FilePath → FilePath → [PWarning] → GenericPackageDescription → IO Package
configurations directory cabal warnings description = do
  let configs =
        [ Configuration
            { configPackage = name
            , configKind = builtKind built
            , configName = builtName built
            , configTarget = target
            , configFlagsLabel = flagsLabel
            , configProblems = [why <> " in " <> place | why ← builtProblems built <> visibilityProblems info]
            , configDependencies = [(unPackageName (depPkgName dependency), map libraryLabel (toList (depLibraries dependency))) | dependency ← targetBuildDepends info]
            , configMixins = [(unPackageName (mixinPackageName mixin), libraryLabel (mixinLibraryName mixin), prettyShow (mixinIncludeRenaming mixin)) | mixin ← mixins info]
            , configReexports = builtReexports built
            , configModules = map prettyShow (builtModules built)
            , configPublic = builtPublic built
            }
        | (target, flagSets, built) ← groups entries
        , let flagsLabel = intercalate " | " (nub [unwords [(if on then "+" else "-") <> unFlagName flag | (flag, on) ← flags] | flags ← flagSets])
              info = builtInfo built
              place = name <> ":" <> builtKind built <> ":" <> builtName built <> " (" <> targetLabel target <> (if null flagsLabel then "" else " " <> flagsLabel) <> ")"
        ]
  pure (Package name directory cabal libraries configs problems)
  where
    name = unPackageName (pkgName (package (packageDescription description)))
    libraries = ["" | Just _ ← [condLibrary description]] <> [unUnqualComponentName sub | (sub, _) ← condSubLibraries description]
    manual = [flagName flag | flag ← genPackageFlags description, flagManual flag]
    assignments = mapM (\flag → [(flag, True), (flag, False)]) manual
    environments = [(target, flags) | target ← targets, flags ← assignments]
    evaluate (Target os arch, flags) = \case
      OS wanted → Right (wanted == os)
      Arch wanted → Right (wanted == arch)
      PackageFlag flag → maybe (Left (PackageFlag flag)) Right (lookup flag flags)
      other → Left other
    problems =
      [cabal <> ": unsupported: build-type " <> prettyShow (buildType (packageDescription description)) | buildType (packageDescription description) /= Simple]
        <> [cabal <> ": unsupported: " <> show kind <> ": " <> text | PWarning kind _ text ← warnings, kind `elem` [PWTUnknownField, PWTUnknownSection, PWTInvalidSubsection, PWTExtraMainIs, PWTExtraTestModule, PWTExtraBenchmarkModule]]
        <> [cabal <> ": unsupported: condition " <> atom | atom ← nub (concatMap conditionProblems allAtoms)]
    conditionProblems = \case
      OS os | os `notElem` [Linux, OSX] → ["os(" <> prettyShow os <> ")"]
      Arch arch | arch `notElem` [X86_64, AArch64] → ["arch(" <> prettyShow arch <> ")"]
      PackageFlag flag | flag `notElem` manual → ["flag(" <> unFlagName flag <> "), not a declared manual flag"]
      Impl flavour range → ["impl(" <> prettyShow flavour <> " " <> prettyShow range <> ")"]
      _ → []
    allAtoms =
      concat
        [ maybe [] atomsOf (condLibrary description)
        , concatMap (atomsOf . snd) (condSubLibraries description)
        , concatMap (atomsOf . snd) (condForeignLibs description)
        , concatMap (atomsOf . snd) (condExecutables description)
        , concatMap (atomsOf . snd) (condTestSuites description)
        , concatMap (atomsOf . snd) (condBenchmarks description)
        ]
    atomsOf ∷ CondTree ConfVar [Dependency] c → [ConfVar]
    atomsOf tree = concat [variables (condBranchCondition branch) <> atomsOf (condBranchIfTrue branch) <> maybe [] atomsOf (condBranchIfFalse branch) | branch ← condTreeComponents tree]
    variables = \case
      Var v → [v]
      Lit _ → []
      CNot c → variables c
      COr a b → variables a <> variables b
      CAnd a b → variables a <> variables b
    -- a component whose conditions are all supported, under every environment it is buildable in
    component ∷ Semigroup c ⇒ CondTree ConfVar [Dependency] c → (c → Built) → [((Target, [(FlagName, Bool)]), Built)]
    component tree build =
      [ (environment, built)
      | null (concatMap conditionProblems (atomsOf tree))
      , environment ← environments
      , let built = build (snd (simplifyCondTree (evaluate environment) tree))
      , buildable (builtInfo built)
      ]
    library componentName tree =
      component tree $ \lib →
        Built
          "lib"
          componentName
          (libBuildInfo lib)
          (exposedModules lib <> otherModules (libBuildInfo lib))
          (componentName == name || libVisibility lib == LibraryVisibilityPublic)
          [(prettyShow (moduleReexportOriginalName reexport), prettyShow (moduleReexportName reexport)) | reexport ← reexportedModules lib]
          ["unsupported: signatures " <> unwords (map prettyShow (signatures lib)) | not (null (signatures lib))]
    entries =
      concat
        [ maybe [] (library name) (condLibrary description)
        , concat [library (unUnqualComponentName sub) tree | (sub, tree) ← condSubLibraries description]
        , concat [component tree (\flib → Built "flib" (unUnqualComponentName sub) (foreignLibBuildInfo flib) (otherModules (foreignLibBuildInfo flib)) False [] []) | (sub, tree) ← condForeignLibs description]
        , concat [component tree (\exe → Built "exe" (unUnqualComponentName sub) (buildInfo exe) (otherModules (buildInfo exe)) False [] []) | (sub, tree) ← condExecutables description]
        , concat [component tree (testBuilt (unUnqualComponentName sub)) | (sub, tree) ← condTestSuites description]
        , concat [component tree (benchBuilt (unUnqualComponentName sub)) | (sub, tree) ← condBenchmarks description]
        ]
    testBuilt sub suite = case testInterface suite of
      TestSuiteExeV10 _ _ → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) False [] []
      other → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) False [] ["unsupported: the test interface " <> show other]
    benchBuilt sub bench = case benchmarkInterface bench of
      BenchmarkExeV10 _ _ → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) False [] []
      other → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) False [] ["unsupported: the benchmark interface " <> show other]
    -- distinct configurations per target, each with every flag assignment that selects it there
    groups found =
      [ (target, map fst members, built)
      | ((target, _), members@((_, built) : _)) ← Map.toList (Map.fromListWith (flip (<>)) [((target, builtKey built), [(flags, built)]) | ((target, flags), built) ← found])
      ]

-- What one component builds under one environment.
data Built = Built
  { builtKind ∷ String
  , builtName ∷ String
  , builtInfo ∷ BuildInfo
  , builtModules ∷ [ModuleName]
  , builtPublic ∷ Bool
  , builtReexports ∷ [(String, String)]
  , builtProblems ∷ [String]
  }

builtKey ∷ Built → (String, String, String, [String], Bool, [(String, String)], [String])
builtKey (Built kind name info modules public reexports problems) = (kind, name, show info, map prettyShow modules, public, reexports, problems)

libraryLabel ∷ LibraryName → String
libraryLabel = \case
  LMainLibName → ""
  LSubLibName sub → unUnqualComponentName sub

-- | Compiler options that change which packages are visible, which only the manifest's structured dependencies may do.
visibilityOption ∷ String → Bool
visibilityOption option =
  any (`isPrefixOf` option) ["-package", "-hide-package", "-ignore-package", "-trust", "-distrust", "-clear-package-db", "-global-package-db", "-no-global-package-db", "-user-package-db", "-no-user-package-db"]

visibilityProblems ∷ BuildInfo → [String]
visibilityProblems info =
  ["unsupported: the GHC option " <> option <> ", which changes which packages are visible" | option ← concatMap ghcOf [options info, profOptions info, sharedOptions info, staticOptions info], visibilityOption option]
  where
    ghcOf (PerCompilerFlavor ghc _) = ghc
