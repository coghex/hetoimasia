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
  , MixinFacts (..)
  , Provides (..)
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
import Data.Char (toLower)
import Distribution.Compiler (PerCompilerFlavor (..))
import Distribution.Fields (Field (..), FieldLine (..), Name (..), readFields)
import Distribution.Fields.ConfVar (parseConditionConfVar)
import Distribution.ModuleName (ModuleName)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Utils.Generic (fromUTF8BS)
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
  , packageExposed ∷ [(String, [String])]
    -- ^ Each library's exposed modules, in any branch.
  , packageSelectors ∷ [(String, String, String)]
    -- ^ Every library selector in any branch of any component, of a dependency or a mixin: the component, the selected
    -- package and its library label.
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
  , configMixins ∷ [MixinFacts]
  , configReexports ∷ [(String, String)]
  , configModules ∷ [String]
    -- ^ The modules it declares (exposed and other).
  , configPublic ∷ Bool
    -- ^ A library with @visibility: public@ (always true of a main library).
  , configBuildable ∷ Bool
    -- ^ Whether Cabal builds it: an unbuildable configuration is diagnosed for unsupported forms but selects nothing.
  }

-- | A mixin: the package and library it includes, its renaming as written, what it provides and the module names its
-- requirement renaming mentions.
data MixinFacts = MixinFacts
  { mixinPackage ∷ String
  , mixinLibrary ∷ String
  , mixinText ∷ String
  , mixinProvides ∷ Provides
  , mixinRequires ∷ [String]
  }

-- | Which of the included library's modules a mixin brings into scope.
data Provides
  = ProvidesAll
  | ProvidesRenamed [(String, String)]
  | ProvidesHiding [String]

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
              bytes ← ByteString.readFile (root </> file)
              case projectFields file bytes of
                Left why → pure (Left why)
                Right (entries, imports, found) → do
                  let relativeImports = [normalise (takeDirectory file </> imported) | imported ← imports]
                  go (rest <> relativeImports) (file : seen) (reverse (map normalise entries) <> directories) (problems <> found)

-- The @packages:@ entries, @import:@ targets and unsupported forms of a project file, read by Cabal's own field parser:
-- field names in any case, continuation lines, and every section (a @package@ stanza, a conditional and its @else@)
-- walked. A condition on anything but a supported operating system or architecture is unsupported.
projectFields ∷ FilePath → ByteString.ByteString → Either String ([String], [String], [String])
projectFields file bytes = case readFields bytes of
  Left failure → Left (file <> ": Cabal refused it: " <> show failure)
  Right fields → Right (walk fields)
  where
    walk fields =
      let results = map one fields
       in (concatMap (\(e, _, _) → e) results, concatMap (\(_, i, _) → i) results, concatMap (\(_, _, p) → p) results)
    one = \case
      Field (Name _ name) contents →
        let key = map toLower (fromUTF8BS name)
            values = words (map (\c → if c == ',' then ' ' else c) (unwords [fromUTF8BS line | FieldLine _ line ← contents]))
         in case key of
              "packages" → (values, [], entryProblems values)
              "import" → ([], values, importProblems values)
              _
                | key `elem` ["optional-packages", "extra-packages"] → ([], [], ["unsupported: " <> key <> " in " <> file])
                | key `elem` ["ghc-options", "ghc-prof-options", "ghc-shared-options"], refused@(_ : _) ← filter visibilityOption values →
                    ([], [], ["unsupported: the option " <> unwords refused <> " in " <> file <> ", which changes which packages are visible"])
                | otherwise → ([], [], [])
      Section (Name _ name) arguments inner →
        let key = map toLower (fromUTF8BS name)
            (entries, imports, problems) = walk inner
         in case key of
              "source-repository-package" → (entries, imports, ("unsupported: source-repository-package in " <> file) : problems)
              _ | key `elem` ["if", "elif"] → (entries, imports, conditionProblems arguments <> problems)
              _ → (entries, imports, problems)
    conditionProblems arguments = case runParseResult (parseConditionConfVar arguments) of
      (_, Left _) → ["unsupported: a condition Cabal cannot read in " <> file]
      (_, Right condition) →
        [ "unsupported: condition " <> atom <> " in " <> file
        | atom ← nub (concatMap projectAtom (conditionVariables condition))
        ]
    projectAtom = \case
      OS os | os `elem` [Linux, OSX] → []
      Arch arch | arch `elem` [X86_64, AArch64] → []
      OS os → ["os(" <> prettyShow os <> ")"]
      Arch arch → ["arch(" <> prettyShow arch <> ")"]
      PackageFlag flag → ["flag(" <> unFlagName flag <> ")"]
      Impl flavour range → ["impl(" <> prettyShow flavour <> " " <> prettyShow range <> ")"]
    remote entry = any (`isInfixOf` entry) ["://", "*", "?", "[", "{"] || any (`isSuffixOf` entry) [".tar.gz", ".cabal"]
    entryProblems entries = ["unsupported: the package entry " <> entry <> " in " <> file <> " (only literal local directories)" | entry ← entries, remote entry]
    importProblems imports = ["unsupported: the project import " <> entry <> " in " <> file <> " (only literal local files)" | entry ← imports, remote entry]

conditionVariables ∷ Condition c → [c]
conditionVariables = \case
  Var v → [v]
  Lit _ → []
  CNot c → conditionVariables c
  COr a b → conditionVariables a <> conditionVariables b
  CAnd a b → conditionVariables a <> conditionVariables b

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
            , configProblems = [why <> " in " <> place | why ← builtProblems built]
            , configDependencies = [(unPackageName (depPkgName dependency), map libraryLabel (toList (depLibraries dependency))) | dependency ← targetBuildDepends info]
            , configMixins = map mixinFacts (mixins info)
            , configReexports = builtReexports built
            , configModules = map prettyShow (builtModules built)
            , configPublic = builtPublic built
            , configBuildable = buildable info
            }
        | (target, flagSets, built) ← groups entries
        , let flagsLabel = intercalate " | " (nub [unwords [(if on then "+" else "-") <> unFlagName flag | (flag, on) ← flags] | flags ← flagSets])
              info = builtInfo built
              place = name <> ":" <> builtKind built <> ":" <> builtName built <> " (" <> targetLabel target <> (if null flagsLabel then "" else " " <> flagsLabel) <> ")"
        ]
  pure (Package name directory cabal libraries exposed selectors configs (problems <> treeProblems))
  where
    name = unPackageName (pkgName (package (packageDescription description)))
    libraries = ["" | Just _ ← [condLibrary description]] <> [unUnqualComponentName sub | (sub, _) ← condSubLibraries description]
    libraryTrees = [(name, "", tree) | Just tree ← [condLibrary description]] <> [(unUnqualComponentName sub, unUnqualComponentName sub, tree) | (sub, tree) ← condSubLibraries description]
    exposed = [(label, nub [prettyShow m | lib ← nodes tree, m ← exposedModules lib]) | (_, label, tree) ← libraryTrees]
    -- every node of every component's conditional tree, before any branch is dropped: its place, build information and
    -- the signatures it declares
    everyNode ∷ [(String, BuildInfo, [ModuleName])]
    everyNode =
      concat
        [ [(name <> ":lib:" <> componentName, libBuildInfo lib, signatures lib) | (componentName, _, tree) ← libraryTrees, lib ← nodes tree]
        , [(name <> ":flib:" <> unUnqualComponentName sub, foreignLibBuildInfo flib, []) | (sub, tree) ← condForeignLibs description, flib ← nodes tree]
        , [(name <> ":exe:" <> unUnqualComponentName sub, buildInfo exe, []) | (sub, tree) ← condExecutables description, exe ← nodes tree]
        , [(name <> ":test:" <> unUnqualComponentName sub, testBuildInfo suite, []) | (sub, tree) ← condTestSuites description, suite ← nodes tree]
        , [(name <> ":bench:" <> unUnqualComponentName sub, benchmarkBuildInfo bench, []) | (sub, tree) ← condBenchmarks description, bench ← nodes tree]
        ]
    treeProblems =
      nub $
        concat
          [ ["unsupported: signatures " <> unwords (map prettyShow sigs) <> " in " <> place | not (null sigs)]
              <> [why <> " in " <> place | why ← visibilityProblems info]
          | (place, info, sigs) ← everyNode
          ]
    selectors =
      nub $
        concat
          [ [(place, unPackageName (depPkgName dependency), libraryLabel selected) | dependency ← targetBuildDepends info, selected ← toList (depLibraries dependency)]
              <> [(place, unPackageName (mixinPackageName mixin), libraryLabel (mixinLibraryName mixin)) | mixin ← mixins info]
          | (place, info, _) ← everyNode
          ]
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
    atomsOf tree = concat [conditionVariables (condBranchCondition branch) <> atomsOf (condBranchIfTrue branch) <> maybe [] atomsOf (condBranchIfFalse branch) | branch ← condTreeComponents tree]
    -- a component whose conditions are all supported, under every environment; an unbuildable result is kept, so its
    -- unsupported forms are diagnosed, and selects nothing
    component ∷ Semigroup c ⇒ CondTree ConfVar [Dependency] c → (c → Built) → [((Target, [(FlagName, Bool)]), Built)]
    component tree build =
      [ (environment, build (snd (simplifyCondTree (evaluate environment) tree)))
      | null (concatMap conditionProblems (atomsOf tree))
      , environment ← environments
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
          []
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

-- Every node of a conditional tree, both branches of every condition.
nodes ∷ CondTree v d c → [c]
nodes tree = condTreeData tree : concat [nodes (condBranchIfTrue branch) <> maybe [] nodes (condBranchIfFalse branch) | branch ← condTreeComponents tree]

mixinFacts ∷ Mixin → MixinFacts
mixinFacts mixin =
  MixinFacts
    { mixinPackage = unPackageName (mixinPackageName mixin)
    , mixinLibrary = libraryLabel (mixinLibraryName mixin)
    , mixinText = prettyShow (mixinIncludeRenaming mixin)
    , mixinProvides = case provides of
        DefaultRenaming → ProvidesAll
        ModuleRenaming pairs → ProvidesRenamed [(prettyShow from, prettyShow to) | (from, to) ← pairs]
        HidingRenaming hidden → ProvidesHiding (map prettyShow hidden)
    , mixinRequires = case requires of
        DefaultRenaming → []
        ModuleRenaming pairs → concat [[prettyShow from, prettyShow to] | (from, to) ← pairs]
        HidingRenaming hidden → map prettyShow hidden
    }
  where
    IncludeRenaming provides requires = mixinIncludeRenaming mixin

libraryLabel ∷ LibraryName → String
libraryLabel = \case
  LMainLibName → ""
  LSubLibName sub → unUnqualComponentName sub

-- | Compiler options that change which packages are visible, which only the manifest's structured dependencies may do.
visibilityOption ∷ String → Bool
visibilityOption option =
  any
    (`isPrefixOf` option)
    [ "-package"
    , "-hide-package"
    , "-hide-all-packages"
    , "-ignore-package"
    , "-trust"
    , "-distrust"
    , "-distrust-all-packages"
    , "-fpackage-trust"
    , "-plugin-package"
    , "-hide-all-plugin-packages"
    , "-clear-package-db"
    , "-global-package-db"
    , "-no-global-package-db"
    , "-user-package-db"
    , "-no-user-package-db"
    , "-this-unit-id"
    , "-this-package-name"
    , "-working-dir"
    , "-unit"
    ]

visibilityProblems ∷ BuildInfo → [String]
visibilityProblems info =
  ["unsupported: the GHC option " <> option <> ", which changes which packages are visible" | option ← concatMap ghcOf [options info, profOptions info, sharedOptions info, staticOptions info], visibilityOption option]
  where
    ghcOf (PerCompilerFlavor ghc _) = ghc
