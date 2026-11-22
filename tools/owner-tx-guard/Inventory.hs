{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's inventory, taken from Cabal: the local packages both project files list (following their project
-- imports), each package description read by Cabal's own parser with its common stanzas expanded, and every distinct
-- effective configuration of every component (libraries, sublibraries, foreign libraries, executables, test suites,
-- benchmarks) across the manual and automatic flags it declares, the operating systems and architectures its
-- conditions name, and the pinned compiler. A configuration keeps its own source search order, so a module two branches
-- provide in different directories is resolved, and read, once per branch.
module Inventory
  ( Package (..)
  , Configuration (..)
  , Source (..)
  , readInventory
  , componentId
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import Data.List (intercalate, isPrefixOf, nub)
import qualified Data.Map.Strict as Map
import Distribution.Compiler (CompilerFlavor (GHC), PerCompilerFlavor (..))
import Distribution.ModuleName (ModuleName, toFilePath)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Pretty (prettyShow)
import Distribution.System (Arch (..), OS (..))
import Distribution.Utils.Path (getSymbolicPath)
import Distribution.Version (mkVersion, withinRange)
import qualified Language.Haskell.Extension as Extension
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (normalise, takeDirectory, takeExtension, (</>))

-- | One local package.
data Package = Package
  { packageName ∷ String
  , packageDirectory ∷ FilePath
    -- ^ Relative to the repository root.
  , packageCabal ∷ FilePath
  , packageConfigurations ∷ [Configuration]
  }

-- | One distinct effective configuration of one component.
data Configuration = Configuration
  { configPackage ∷ String
  , configKind ∷ String
    -- ^ lib, flib, exe, test or bench
  , configName ∷ String
  , configLabel ∷ String
    -- ^ The flag, operating-system and architecture assignments that select it.
  , configDirectory ∷ FilePath
  , configSourceDirectories ∷ [FilePath]
    -- ^ In search order, relative to the repository root.
  , configSources ∷ [Source]
  , configProblems ∷ [String]
  , configDependencies ∷ [(String, [String])]
    -- ^ Each dependency's package and the libraries it selects (@""@ the main library), whatever its version range.
  , configMixins ∷ [(String, String, String)]
    -- ^ A mixin's package, library and rendered renaming.
  , configReexports ∷ [(String, String)]
    -- ^ A re-exported module's original name and its new name.
  , configFlags ∷ [String]
    -- ^ What the frontend reads the sources with: the language, extensions, CPP options and include directories.
  }

-- | One source a configuration compiles: its module (@Main@ for an entry point) and its path from the root.
data Source = Source
  { sourceModule ∷ String
  , sourcePath ∷ FilePath
  }
  deriving (Eq, Ord, Show)

componentId ∷ Configuration → String
componentId configuration = configPackage configuration <> ":" <> configKind configuration <> ":" <> configName configuration

-- | The project files read, in order, and every local package they list.
readInventory ∷ FilePath → [FilePath] → IO (Either String ([FilePath], [Package]))
readInventory root projects = do
  listed ← mapM (projectPackages root) projects
  case sequence listed of
    Left why → pure (Left why)
    Right results → do
      let files = nub (concatMap fst results)
          directories = nub (concatMap snd results)
      packages ← forM directories $ \directory → readPackage root directory
      pure ((,) files <$> sequence packages)

-- | A project file's package directories and the files read for it (itself and its imports), following @import:@.
projectPackages ∷ FilePath → FilePath → IO (Either String ([FilePath], [FilePath]))
projectPackages root project = go [project] [] []
  where
    go [] seen directories = pure (Right (reverse seen, reverse directories))
    go (file : rest) seen directories
      | file `elem` seen = go rest seen directories
      | otherwise = do
          present ← doesFileExist (root </> file)
          if not present
            then pure (Left (file <> " does not exist"))
            else do
              text ← readFile (root </> file)
              case projectFields text of
                Left why → pure (Left (file <> ": " <> why))
                Right (entries, imports) → do
                  let relativeImports = [normalise (takeDirectory file </> imported) | imported ← imports]
                  go (rest <> relativeImports) (file : seen) (reverse (map normalise entries) <> directories)

-- The @packages:@ entries and @import:@ targets of a project file. A glob or a remote package is refused.
projectFields ∷ String → Either String ([String], [String])
projectFields text = collect (lines text) Nothing [] []
  where
    collect [] _ entries imports = check (reverse entries, reverse imports)
    collect (line : rest) collecting entries imports
      | all (`elem` " \t") line || "--" `isPrefixOf` dropWhile (== ' ') line = collect rest collecting entries imports
      | Just indent ← collecting, leading line > indent = collect rest collecting (reverse (words' line) <> entries) imports
      | Just value ← field "packages" line = collect rest (Just (leading line)) (reverse (words' value) <> entries) imports
      | Just value ← field "import" line = collect rest Nothing entries (reverse (words' value) <> imports)
      | otherwise = collect rest Nothing entries imports
    leading = length . takeWhile (== ' ')
    words' = words . map (\c → if c == ',' then ' ' else c)
    field name line = case break (== ':') (dropWhile (== ' ') line) of
      (key, ':' : value) | key == name → Just value
      _ → Nothing
    check (entries, imports)
      | any (any (`elem` "*?[{")) entries = Left "a glob or braced package entry is not read by the guard"
      | otherwise = Right (entries, imports)

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
          case snd (runParseResult (parseGenericPackageDescription bytes)) of
            Left (_, errors) → pure (Left (path <> ": Cabal refused it: " <> show (toList errors)))
            Right description → Right <$> configurations root directory path description
        _ → pure (Left (directory <> " holds " <> show (length cabals) <> " package descriptions, not one"))

-- Every distinct configuration of every component.
configurations ∷ FilePath → FilePath → FilePath → GenericPackageDescription → IO Package
configurations root directory cabal description = do
  configs ← forM (groups entries) $ \(selecting, built) → do
    let Built kind componentName info modules mains reexports = built
        labels = intercalate "; " (map label selecting)
        sourceDirectories = case [normalise (directory </> getSymbolicPath d) | d ← hsSourceDirs info] of
          [] → [normalise directory]
          declared → declared
        autogen = map prettyShow (autogenModules info)
        where' why = cabal <> " (" <> name <> ":" <> kind <> ":" <> componentName <> ", " <> labels <> "): " <> why
    resolved ← forM modules $ \moduleName → resolveModule root sourceDirectories autogen moduleName
    resolvedMains ← forM mains $ \mainIs → resolveMain root directory sourceDirectories mainIs
    pure
      Configuration
        { configPackage = name
        , configKind = kind
        , configName = componentName
        , configLabel = labels
        , configDirectory = directory
        , configSourceDirectories = sourceDirectories
        , configSources = [source | Right source ← resolved <> resolvedMains]
        , configProblems = [where' why | Left why ← resolved <> resolvedMains]
        , configDependencies = [(unPackageName (depPkgName dependency), map libraryLabel (toList (depLibraries dependency))) | dependency ← targetBuildDepends info]
        , configMixins = [(unPackageName (mixinPackageName mixin), libraryLabel (mixinLibraryName mixin), prettyShow (mixinIncludeRenaming mixin)) | mixin ← mixins info]
        , configReexports = reexports
        , configFlags = frontendFlags directory info
        }
  pure (Package name directory cabal configs)
  where
    name = unPackageName (pkgName (package (packageDescription description)))
    flagNames = map flagName (genPackageFlags description)
    assignments = mapM (\flag → [(flag, True), (flag, False)]) flagNames
    environments = [(os, arch, flags) | os ← [Linux, OSX, Windows], arch ← [X86_64, AArch64], flags ← assignments]
    evaluate (os, arch, flags) = \case
      OS target → Right (target == os)
      Arch target → Right (target == arch)
      PackageFlag flag → maybe (Left (PackageFlag flag)) Right (lookup flag flags)
      Impl GHC range → Right (mkVersion [9, 14, 1] `withinRange` range)
      Impl _ _ → Right False
    label (os, arch, flags) =
      unwords (["os=" <> prettyShow os, "arch=" <> prettyShow arch] <> [(if on then "+" else "-") <> unFlagName flag | (flag, on) ← flags])
    -- one component under every environment: what it builds there, when it is buildable there
    component ∷ Semigroup c ⇒ String → String → CondTree ConfVar [Dependency] c → (c → BuildInfo) → (c → [ModuleName]) → (c → [FilePath]) → (c → [(String, String)]) → [((OS, Arch, [(FlagName, Bool)]), Built)]
    component kind componentName tree info modules mains reexports =
      [ (environment, Built kind componentName (info built) (modules built) (mains built) (reexports built))
      | environment ← environments
      , let (_, built) = simplifyCondTree (evaluate environment) tree
      , buildable (info built)
      ]
    library componentName tree =
      component "lib" componentName tree libBuildInfo (\lib → exposedModules lib <> otherModules (libBuildInfo lib)) (const []) $ \lib →
        [(prettyShow (moduleReexportOriginalName reexport), prettyShow (moduleReexportName reexport)) | reexport ← reexportedModules lib]
    entries =
      concat
        [ maybe [] (library name) (condLibrary description)
        , concat [library (unUnqualComponentName sub) tree | (sub, tree) ← condSubLibraries description]
        , concat [component "flib" (unUnqualComponentName sub) tree foreignLibBuildInfo (otherModules . foreignLibBuildInfo) (const []) (const []) | (sub, tree) ← condForeignLibs description]
        , concat [component "exe" (unUnqualComponentName sub) tree buildInfo (otherModules . buildInfo) (\exe → [getSymbolicPath (modulePath exe)]) (const []) | (sub, tree) ← condExecutables description]
        , concat [component "test" (unUnqualComponentName sub) tree testBuildInfo suiteModules testMains (const []) | (sub, tree) ← condTestSuites description]
        , concat [component "bench" (unUnqualComponentName sub) tree benchmarkBuildInfo (otherModules . benchmarkBuildInfo) benchMains (const []) | (sub, tree) ← condBenchmarks description]
        ]
    -- distinct effective configurations, in the order first met, each with every environment that selects it
    groups found = [(map fst members, built) | members@((_, built) : _) ← Map.elems (Map.fromListWith (flip (<>)) [(builtKey built, [(environment, built)]) | (environment, built) ← found])]
    suiteModules suite = otherModules (testBuildInfo suite) <> case testInterface suite of
      TestSuiteLibV09 _ moduleName → [moduleName]
      _ → []
    testMains suite = case testInterface suite of
      TestSuiteExeV10 _ path → [getSymbolicPath path]
      _ → []
    benchMains bench = case benchmarkInterface bench of
      BenchmarkExeV10 _ path → [getSymbolicPath path]
      _ → []

-- What one component builds under one environment.
data Built = Built String String BuildInfo [ModuleName] [FilePath] [(String, String)]

builtKey ∷ Built → (String, String, String, [String], [FilePath], [(String, String)])
builtKey (Built kind componentName info modules mains reexports) = (kind, componentName, show info, map prettyShow modules, mains, reexports)

libraryLabel ∷ LibraryName → String
libraryLabel = \case
  LMainLibName → ""
  LSubLibName sub → unUnqualComponentName sub

-- What GHC's frontend reads a configuration's sources with.
frontendFlags ∷ FilePath → BuildInfo → [String]
frontendFlags directory info =
  maybe [] (\language → ["-X" <> prettyShow language]) (defaultLanguage info)
    <> ["-X" <> extensionFlag extension | extension ← defaultExtensions info <> otherExtensions info]
    <> ["-optP" <> option | option ← cppOptions info]
    <> ["-I" <> normalise (directory </> getSymbolicPath include) | include ← includeDirs info]
    <> [option | option ← ghcOptions, any (`isPrefixOf` option) ["-X", "-D", "-U", "-I", "-optP", "-cpp"]]
  where
    PerCompilerFlavor ghcOptions _ = options info
    extensionFlag = \case
      Extension.EnableExtension known → show known
      Extension.DisableExtension known → "No" <> show known
      Extension.UnknownExtension unknown → unknown

-- Resolve a module in a configuration's search order, as Cabal does: the first directory that holds a source of any
-- kind for it. Only a Haskell source is read; anything else, and a generated module, fails closed.
resolveModule ∷ FilePath → [FilePath] → [String] → ModuleName → IO (Either String Source)
resolveModule root directories autogen moduleName = go directories
  where
    stem = toFilePath moduleName
    name = prettyShow moduleName
    kinds = [".hs", ".lhs", ".hsig", ".lhsig", ".hsc", ".x", ".y", ".ly", ".chs", ".gc"]
    go [] =
      pure . Left $
        if name `elem` autogen
          then "the generated module " <> name <> " has no source the guard can read"
          else "the module " <> name <> " has no source in its source directories " <> show directories
    go (directory : rest) = do
      found ← filterM' (\kind → doesFileExist (root </> directory </> stem <> kind)) kinds
      case found of
        [] → go rest
        ".hs" : _ → pure (Right (Source name (normalise (directory </> stem <> ".hs"))))
        kind : _ → pure (Left ("the module " <> name <> " is a " <> kind <> " source, a kind the guard does not read"))

resolveMain ∷ FilePath → FilePath → [FilePath] → FilePath → IO (Either String Source)
resolveMain root directory directories mainIs
  | takeExtension mainIs /= ".hs" = pure (Left ("main-is " <> mainIs <> " is of a kind the guard does not read"))
  | otherwise = go (directories <> [directory])
  where
    go [] = pure (Left ("main-is " <> mainIs <> " has no source in its source directories"))
    go (candidate : rest) = do
      present ← doesFileExist (root </> candidate </> mainIs)
      if present then pure (Right (Source "Main" (normalise (candidate </> mainIs)))) else go rest

filterM' ∷ (a → IO Bool) → [a] → IO [a]
filterM' predicate = fmap (map fst . filter snd) . mapM (\item → (,) item <$> predicate item)
