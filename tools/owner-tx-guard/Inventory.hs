{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's inventory, taken from Cabal, over the supported subset (the design's "Guard mechanism").
--
-- Projects: @cabal.project@ and @cabal.project.vulkan@, their literal local imports and their literal local package
-- directories. Optional, extra, remote and globbed package selection is unsupported.
--
-- Packages: Simple manifests read by Cabal's own parser, common stanzas expanded; an unknown field or section, even in
-- an inactive branch, is unsupported. Every condition atom of every branch is validated before either branch is
-- simplified: an operating system or architecture outside Linux and Darwin on x86_64 and aarch64, a compiler
-- condition, and a flag that is not a declared manual flag are unsupported. Each component (library, sublibrary,
-- foreign library, executable, exitcode test suite and benchmark) is simplified under every supported target and every
-- assignment of the package's manual flags; each distinct result on a target is one configuration, with its own source
-- search order, structured dependencies, mixins and re-exports, and the frontend flags its Haskell inputs are read
-- with. Signatures, generated modules, custom preprocessors, plugins, options that change the search path or the
-- packages in scope, sources other than @.hs@ and boot files beside them are unsupported.
module Inventory
  ( Target (..)
  , targets
  , targetLabel
  , Package (..)
  , Configuration (..)
  , Source (..)
  , Inventory (..)
  , readInventory
  , componentId
  , configurationId
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Distribution.Compiler (PerCompilerFlavor (..))
import Distribution.ModuleName (ModuleName, toFilePath)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Parsec.Warning (PWarnType (..), PWarning (..))
import Distribution.Pretty (prettyShow)
import Distribution.System (Arch (..), OS (..))
import Distribution.Utils.Path (getSymbolicPath)
import qualified Language.Haskell.Extension as Extension
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
  , configDirectory ∷ FilePath
  , configSourceDirectories ∷ [FilePath]
  , configSources ∷ [Source]
  , configProblems ∷ [String]
  , configDependencies ∷ [(String, [String])]
  , configMixins ∷ [(String, String, String)]
  , configReexports ∷ [(String, String)]
  , configFlags ∷ [String]
    -- ^ The frontend flags its Haskell inputs are read with.
  , configPragmas ∷ [String]
    -- ^ Its language and extensions, as LANGUAGE pragma names.
  }

data Source = Source
  { sourceModule ∷ String
  , sourcePath ∷ FilePath
  }
  deriving (Eq, Ord, Show)

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
      | otherwise = collect rest Nothing entries imports problems
    leading = length . takeWhile (== ' ')
    words' = words . map (\c → if c == ',' then ' ' else c)
    field name line = case break (== ':') (dropWhile (== ' ') line) of
      (key, ':' : value) | key == name → Just value
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
            (warnings, Right description) → Right <$> configurations root directory path warnings description
        _ → pure (Left (directory <> " holds " <> show (length cabals) <> " package descriptions, not one"))

-- Every distinct configuration of every component, and the package's unsupported forms.
configurations ∷ FilePath → FilePath → FilePath → [PWarning] → GenericPackageDescription → IO Package
configurations root directory cabal warnings description = do
  configs ← forM (groups entries) $ \(target, flagSets, built) → do
    let flagsLabel = intercalate " | " (nub [unwords [(if on then "+" else "-") <> unFlagName flag | (flag, on) ← flags] | flags ← flagSets])
        info = builtInfo built
        sourceDirectories = case [normalise (directory </> getSymbolicPath d) | d ← hsSourceDirs info] of
          [] → [normalise directory]
          declared' → declared'
        place = name <> ":" <> builtKind built <> ":" <> builtName built <> " (" <> targetLabel target <> (if null flagsLabel then "" else " " <> flagsLabel) <> ")"
    resolved ← forM (builtModules built) (resolveModule root sourceDirectories)
    resolvedMains ← forM (builtMains built) (resolveMain root directory sourceDirectories)
    let (flags, flagProblems) = frontendFlags directory info
    pure
      Configuration
        { configPackage = name
        , configKind = builtKind built
        , configName = builtName built
        , configTarget = target
        , configFlagsLabel = flagsLabel
        , configDirectory = directory
        , configSourceDirectories = sourceDirectories
        , configSources = [source | Right source ← resolved <> resolvedMains]
        , configProblems = [why <> " in " <> place | why ← [w | Left w ← resolved <> resolvedMains] <> builtProblems built <> flagProblems <> unsupportedInfo info]
        , configDependencies = [(unPackageName (depPkgName dependency), map libraryLabel (toList (depLibraries dependency))) | dependency ← targetBuildDepends info]
        , configMixins = [(unPackageName (mixinPackageName mixin), libraryLabel (mixinLibraryName mixin), prettyShow (mixinIncludeRenaming mixin)) | mixin ← mixins info]
        , configReexports = builtReexports built
        , configFlags = flags
        , configPragmas = pragmas info
        }
  pure (Package name directory cabal configs problems)
  where
    name = unPackageName (pkgName (package (packageDescription description)))
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
          []
          [(prettyShow (moduleReexportOriginalName reexport), prettyShow (moduleReexportName reexport)) | reexport ← reexportedModules lib]
          ["unsupported: signatures " <> unwords (map prettyShow (signatures lib)) | not (null (signatures lib))]
    entries =
      concat
        [ maybe [] (library name) (condLibrary description)
        , concat [library (unUnqualComponentName sub) tree | (sub, tree) ← condSubLibraries description]
        , concat [component tree (\flib → Built "flib" (unUnqualComponentName sub) (foreignLibBuildInfo flib) (otherModules (foreignLibBuildInfo flib)) [] [] []) | (sub, tree) ← condForeignLibs description]
        , concat [component tree (\exe → Built "exe" (unUnqualComponentName sub) (buildInfo exe) (otherModules (buildInfo exe)) [getSymbolicPath (modulePath exe)] [] []) | (sub, tree) ← condExecutables description]
        , concat [component tree (testBuilt (unUnqualComponentName sub)) | (sub, tree) ← condTestSuites description]
        , concat [component tree (benchBuilt (unUnqualComponentName sub)) | (sub, tree) ← condBenchmarks description]
        ]
    testBuilt sub suite = case testInterface suite of
      TestSuiteExeV10 _ path → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) [getSymbolicPath path] [] []
      other → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) [] [] ["unsupported: the test interface " <> show other]
    benchBuilt sub bench = case benchmarkInterface bench of
      BenchmarkExeV10 _ path → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) [getSymbolicPath path] [] []
      other → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) [] [] ["unsupported: the benchmark interface " <> show other]
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
  , builtMains ∷ [FilePath]
  , builtReexports ∷ [(String, String)]
  , builtProblems ∷ [String]
  }

builtKey ∷ Built → (String, String, String, [String], [FilePath], [(String, String)], [String])
builtKey (Built kind name info modules mains reexports problems) = (kind, name, show info, map prettyShow modules, mains, reexports, problems)

libraryLabel ∷ LibraryName → String
libraryLabel = \case
  LMainLibName → ""
  LSubLibName sub → unUnqualComponentName sub

-- The Haskell-input options outside the subset: generated modules and custom preprocessors.
unsupportedInfo ∷ BuildInfo → [String]
unsupportedInfo info =
  ["unsupported: generated modules " <> unwords (map prettyShow (autogenModules info)) | not (null (autogenModules info))]
    <> ["unsupported: the custom preprocessor " <> prettyShow tool | ExeDependency _ tool _ ← buildToolDepends info, prettyShow tool `elem` preprocessors]
    <> ["unsupported: the custom preprocessor " <> tool | LegacyExeDependency tool _ ← buildTools info, tool `elem` preprocessors]
  where
    preprocessors = ["alex", "happy", "hsc2hs", "c2hs", "cpphs", "greencard", "markdown-unlit"]

-- The frontend flags a configuration's Haskell inputs are read with, and the options it cannot apply. Every option
-- that affects Haskell inputs is applied (language, extensions, CPP definitions, include directories) or refused.
frontendFlags ∷ FilePath → BuildInfo → ([String], [String])
frontendFlags directory info =
  ( maybe [] (\language → ["-X" <> prettyShow language]) (defaultLanguage info)
      <> ["-X" <> extensionName extension | extension ← defaultExtensions info]
      <> ["-optP" <> option | option ← cppOptions info, cppOption option]
      <> ["-I" <> normalise (directory </> getSymbolicPath include) | include ← includeDirs info]
      <> [option | option ← ghcOptions, any (`isPrefixOf` option) ["-X", "-D", "-U", "-cpp"]]
      <> ["-optP" <> drop 5 option | option ← ghcOptions, "-optP" `isPrefixOf` option, cppOption (drop 5 option)]
  , ["unsupported: the CPP option " <> option | option ← cppOptions info, not (cppOption option)]
      <> ["unsupported: the GHC option " <> option | option ← ghcOptions, refused option]
  )
  where
    PerCompilerFlavor ghcOptions _ = options info
    -- an object-like literal definition, an undefinition or an include directory
    cppOption option = case option of
      '-' : 'D' : definition → objectLike definition
      '-' : 'U' : name' → not (null name') && all identifierCharacter name'
      '-' : 'I' : _ → True
      _ → False
    objectLike definition =
      let (name', value) = break (== '=') definition
       in not (null name') && all identifierCharacter name' && '(' `notElem` value
    identifierCharacter c = c == '_' || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9']
    refused option =
      any (`isPrefixOf` option) ["-F", "-pgmF", "-optF", "-fplugin", "-i", "-package", "-hide-package", "-trust", "-pgmP", "-pgmL", "-optL", "-x"]
        || ("-optP" `isPrefixOf` option && not (cppOption (drop 5 option)))

pragmas ∷ BuildInfo → [String]
pragmas info =
  sort . nub $
    maybe [] (\language → [prettyShow language]) (defaultLanguage info)
      <> [extensionName extension | extension ← defaultExtensions info]

extensionName ∷ Extension.Extension → String
extensionName = \case
  Extension.EnableExtension known → show known
  Extension.DisableExtension known → "No" <> show known
  Extension.UnknownExtension unknown → unknown

-- Resolve a module in a configuration's search order, as Cabal does: the first directory holding a source of any kind
-- for it. Only a Haskell source without a boot file beside it is supported.
resolveModule ∷ FilePath → [FilePath] → ModuleName → IO (Either String Source)
resolveModule root directories moduleName = go directories
  where
    stem = toFilePath moduleName
    name = prettyShow moduleName
    kinds = [".hs", ".lhs", ".hsig", ".lhsig", ".hsc", ".x", ".y", ".ly", ".chs", ".gc"]
    go [] = pure (Left ("uncovered: the module " <> name <> " has no source in its source directories " <> show directories))
    go (directory : rest) = do
      found ← fmap (map fst . filter snd) . forM kinds $ \kind → (,) kind <$> doesFileExist (root </> directory </> stem <> kind)
      boot ← (||) <$> doesFileExist (root </> directory </> stem <> ".hs-boot") <*> doesFileExist (root </> directory </> stem <> ".lhs-boot")
      case found of
        [] | boot → pure (Left ("unsupported: the boot file " <> normalise (directory </> stem <> ".hs-boot") <> " of " <> name))
        [] → go rest
        ".hs" : _
          | boot → pure (Left ("unsupported: the boot file " <> normalise (directory </> stem <> ".hs-boot") <> " beside " <> name))
          | otherwise → pure (Right (Source name (normalise (directory </> stem <> ".hs"))))
        kind : _ → pure (Left ("unsupported: the module " <> name <> " is a " <> kind <> " source"))

resolveMain ∷ FilePath → FilePath → [FilePath] → FilePath → IO (Either String Source)
resolveMain root directory directories mainIs
  | takeExtension mainIs /= ".hs" = pure (Left ("unsupported: main-is " <> mainIs <> " is not a Haskell source"))
  | otherwise = go (directories <> [directory])
  where
    go [] = pure (Left ("uncovered: main-is " <> mainIs <> " has no source in its source directories"))
    go (candidate : rest) = do
      present ← doesFileExist (root </> candidate </> mainIs)
      if present then pure (Right (Source "Main" (normalise (candidate </> mainIs)))) else go rest
