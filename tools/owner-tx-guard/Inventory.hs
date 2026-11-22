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
import Distribution.Compiler (PerCompilerFlavor (..))
import Distribution.Fields (Field (..), FieldLine (..), Name (..), readFields)
import Distribution.Fields.ConfVar (parseConditionConfVar)
import Distribution.ModuleName (ModuleName)
import Distribution.PackageDescription
import Distribution.Compat.Newtype (unpack)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Parsec (eitherParsec)
import Distribution.FieldGrammar.Newtypes (List, NoCommaFSep, Token')
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
  , packageSelectors ∷ [(String, String, String, String)]
    -- ^ Every library selector in any branch of any component, of a dependency or a mixin: the component, the selected
    -- package, its library label, and the configurations it appears in.
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
  , configOptions ∷ [String]
    -- ^ Its compiler options, as Cabal tokenized them.
  , configSignatures ∷ [String]
  , configSelectors ∷ [(String, String)]
    -- ^ Every package and library label its dependencies and mixins select.
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

-- A project file's files read, package directories and unsupported forms, following literal local imports depth first.
-- A file already on the active import chain is a cycle, an error; one already read through another chain (two projects
-- sharing an import) is read once.
projectPackages ∷ FilePath → FilePath → IO (Either String ([FilePath], [FilePath], [String]))
projectPackages root project = fmap (\(files, directories, problems) → (reverse files, reverse directories, problems)) <$> visit [] ([], [], []) project
  where
    visit chain state@(seen, directories, problems) file
      | file `elem` chain = pure (Left ("a cyclic project import: " <> intercalate " → " (reverse (file : chain))))
      | file `elem` seen = pure (Right state)
      | otherwise = do
          present ← doesFileExist (root </> file)
          if not present
            then pure (Left (file <> " does not exist"))
            else do
              bytes ← ByteString.readFile (root </> file)
              case projectFields file bytes of
                Left why → pure (Left why)
                Right (entries, imports, found) → do
                  let start = (file : seen, reverse (map normalise entries) <> directories, problems <> found)
                  foldImports (file : chain) start [normalise (takeDirectory file </> imported) | imported ← imports]
    foldImports _ state [] = pure (Right state)
    foldImports chain state (next : rest) =
      visit chain state next >>= \case
        Left why → pure (Left why)
        Right state' → foldImports chain state' rest

-- The @packages:@ entries, @import:@ targets and unsupported forms of a project file, read by Cabal's own field parser
-- (which lowercases field and section names). The guard supports exactly the project syntax this repository uses:
-- unquoted literal @import:@s of one relative local file and @packages:@ of literal local directories at the top level;
-- the allow-listed top-level fields; @package@ sections of allow-listed fields; and @if@/@elif@/@else@ over the supported
-- targets whose bodies hold only @package@ sections (or further conditionals). Anything else is unsupported: package
-- selection or an import inside a conditional, a quoted or URI path, another field, section, option or condition.
projectFields ∷ FilePath → ByteString.ByteString → Either String ([String], [String], [String])
projectFields file bytes = case readFields bytes of
  Left failure → Left (file <> ": Cabal refused it: " <> show failure)
  Right fields → Right (walk Top fields)
  where
    walk place fields =
      let results = map (one place) fields
       in (concatMap (\(e, _, _) → e) results, concatMap (\(_, i, _) → i) results, concatMap (\(_, _, p) → p) results)
    one place = \case
      Field (Name _ name) contents →
        let key = fromUTF8BS name
            text = unwords [fromUTF8BS line | FieldLine _ line ← contents]
            values = words (map (\c → if c == ',' then ' ' else c) text)
         in case (place, key) of
              -- an unsupported entry is reported, not followed
              (Top, "packages") → ([value | value ← values, not (nonLiteral value)], [], entryProblems values)
              (Top, "import") → ([], [trim text | null (importProblems (trim text))], importProblems (trim text))
              (Conditional, _) → ([], [], ["unsupported: the project field " <> key <> " inside a conditional in " <> file <> " (only package sections)"])
              (InPackage, _) | key `elem` projectPackageFields → ([], [], if key `elem` optionFields then optionProblems (file <> " (" <> key <> ")") text else [])
              (Top, _) | key `elem` projectFieldsAllowed → ([], [], [])
              _ → ([], [], ["unsupported: the project field " <> key <> " in " <> file])
      Section (Name _ name) arguments inner →
        let key = fromUTF8BS name
         in case key of
              "package" | place /= InPackage → walk InPackage inner
              _
                | key `elem` ["if", "elif"], place /= InPackage → let (e, i, p) = walk Conditional inner in (e, i, conditionProblems arguments <> p)
                | key == "else", place /= InPackage → walk Conditional inner
                | otherwise → ([], [], ["unsupported: the project section " <> key <> " in " <> file])
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
    trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')
    nonLiteral entry = any (`isInfixOf` entry) ["://", "*", "?", "[", "{", "\"", "'"] || any (`isSuffixOf` entry) [".tar.gz", ".cabal"]
    entryProblems entries = ["unsupported: the package entry " <> entry <> " in " <> file <> " (only unquoted literal local directories)" | entry ← entries, nonLiteral entry]
    importProblems entry =
      [ "unsupported: the project import " <> entry <> " in " <> file <> " (only one unquoted literal relative local file)"
      | null entry || nonLiteral entry || any (`elem` " \t") entry || take 1 entry == "/"
      ]

-- Where a project field or section sits.
data ProjectPlace = Top | InPackage | Conditional
  deriving (Eq)

-- The project fields the guard supports: package selection and imports, and settings that change no package's
-- visibility. Inside a @package@ stanza, its flags, tests, optimisation, native search paths and allow-listed options.
projectFieldsAllowed, projectPackageFields, optionFields ∷ [String]
projectFieldsAllowed = ["constraints", "index-state", "jobs", "optimization", "semaphore", "active-repositories", "tests", "benchmarks"]
projectPackageFields = ["flags", "tests", "benchmarks", "optimization", "extra-include-dirs", "extra-lib-dirs"] <> optionFields
optionFields = ["ghc-options", "ghc-prof-options", "ghc-shared-options"]

-- | Every compiler option outside the allow-list, tokenized as Cabal tokenizes @ghc-options@ (quoted tokens included).
optionProblems ∷ String → String → [String]
optionProblems place text = case eitherParsec text ∷ Either String (List NoCommaFSep Token' String) of
  Left _ → ["unsupported: compiler options Cabal cannot read in " <> place]
  Right tokens → ["unsupported: the GHC option " <> option <> " in " <> place <> ", outside the guard's supported options" | option ← unpack tokens, not (supportedOption option)]

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
configurations directory cabal warnings description = pure (Package name directory cabal libraries exposed selectors configs (problems <> treeProblems))
  where
    configs =
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
            , configOptions = optionsOf info
            , configSignatures = map prettyShow (builtSignatures built)
            , configSelectors = selectorsOf info
            , configBuildable = buildable info
            }
        | (target, flagSets, built) ← groups entries
        , let flagsLabel = intercalate " | " (nub [unwords [(if on then "+" else "-") <> unFlagName flag | (flag, on) ← flags] | flags ← flagSets])
              info = builtInfo built
              place = name <> ":" <> builtKind built <> ":" <> builtName built <> " (" <> targetLabel target <> (if null flagsLabel then "" else " " <> flagsLabel) <> ")"
        ]
    -- the configurations of a component in which a fact holds, or the branch no supported configuration selects
    whereIn owner holds = case [configurationId configuration | configuration ← configs, componentId configuration == owner, holds configuration] of
      [] → "in a branch no supported configuration selects"
      found → "in " <> intercalate ", " found
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
          [ [ cabal <> ": unsupported: signatures " <> unwords (map prettyShow sigs) <> " in " <> place <> " (" <> whereIn place (\c → any ((`elem` configSignatures c) . prettyShow) sigs) <> ")"
            | not (null sigs)
            ]
              <> [ cabal <> ": unsupported: the GHC option " <> option <> ", outside the guard's supported options in " <> place <> " (" <> whereIn place ((option `elem`) . configOptions) <> ")"
                 | option ← optionsOf info
                 , not (supportedOption option)
                 ]
          | (place, info, sigs) ← everyNode
          ]
    selectors =
      nub
        [ (place, package', library', whereIn place (((package', library') `elem`) . configSelectors))
        | (place, info, _) ← everyNode
        , (package', library') ← selectorsOf info
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
          (signatures lib)
          [(prettyShow (moduleReexportOriginalName reexport), prettyShow (moduleReexportName reexport)) | reexport ← reexportedModules lib]
          []
    entries =
      concat
        [ maybe [] (library name) (condLibrary description)
        , concat [library (unUnqualComponentName sub) tree | (sub, tree) ← condSubLibraries description]
        , concat [component tree (\flib → Built "flib" (unUnqualComponentName sub) (foreignLibBuildInfo flib) (otherModules (foreignLibBuildInfo flib)) False [] [] []) | (sub, tree) ← condForeignLibs description]
        , concat [component tree (\exe → Built "exe" (unUnqualComponentName sub) (buildInfo exe) (otherModules (buildInfo exe)) False [] [] []) | (sub, tree) ← condExecutables description]
        , concat [component tree (testBuilt (unUnqualComponentName sub)) | (sub, tree) ← condTestSuites description]
        , concat [component tree (benchBuilt (unUnqualComponentName sub)) | (sub, tree) ← condBenchmarks description]
        ]
    testBuilt sub suite = case testInterface suite of
      TestSuiteExeV10 _ _ → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) False [] [] []
      other → Built "test" sub (testBuildInfo suite) (otherModules (testBuildInfo suite)) False [] [] ["unsupported: the test interface " <> show other]
    benchBuilt sub bench = case benchmarkInterface bench of
      BenchmarkExeV10 _ _ → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) False [] [] []
      other → Built "bench" sub (benchmarkBuildInfo bench) (otherModules (benchmarkBuildInfo bench)) False [] [] ["unsupported: the benchmark interface " <> show other]
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
  , builtSignatures ∷ [ModuleName]
  , builtReexports ∷ [(String, String)]
  , builtProblems ∷ [String]
  }

builtKey ∷ Built → (String, String, String, [String], Bool, [String], [(String, String)], [String])
builtKey (Built kind name info modules public sigs reexports problems) = (kind, name, show info, map prettyShow modules, public, map prettyShow sigs, reexports, problems)

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

-- | The compiler options the guard supports: warnings, optimisation, the threaded runtime and its options, parallel
-- compilation, linker options and turning off full laziness. Every other option, the ones that change which packages are
-- visible among them, is unsupported.
supportedOption ∷ String → Bool
supportedOption option =
  option `elem` ["-w", "-O", "-O0", "-O1", "-O2", "-threaded", "-rtsopts", "-fno-full-laziness"]
    || any (`isPrefixOf` option) ["-W", "-with-rtsopts=", "-rtsopts=", "-optl"]
    || (take 2 option == "-j" && all (`elem` "0123456789") (drop 2 option))

-- | A build's compiler options, as Cabal tokenized them.
optionsOf ∷ BuildInfo → [String]
optionsOf info = concatMap ghcOf [options info, profOptions info, sharedOptions info, staticOptions info]
  where
    ghcOf (PerCompilerFlavor ghc _) = ghc

-- | Every package and library label a build's dependencies and mixins select.
selectorsOf ∷ BuildInfo → [(String, String)]
selectorsOf info =
  nub $
    [(unPackageName (depPkgName dependency), libraryLabel selected) | dependency ← targetBuildDepends info, selected ← toList (depLibraries dependency)]
      <> [(unPackageName (mixinPackageName mixin), libraryLabel (mixinLibraryName mixin)) | mixin ← mixins info]
