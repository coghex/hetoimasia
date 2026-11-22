{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's policy: the facts Cabal and GHC give, compared with the allowlist (the design's "Guard mechanism").
module Policy
  ( Allowlist (..)
  , Contract (..)
  , readAllowlist
  , check
  , checkedModules
  , typedInterfaces
  , headerFacts
  ) where

import Control.Monad (forM)
import Data.List (intercalate, isInfixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Frontend (Export (..), HeaderFacts (..), Instance (..), Interface (..), preprocessInto, readHeaders, readInterface)
import Inventory
import Json
import System.FilePath (takeFileName, (</>))

-- | The exact allowlist.
data Allowlist = Allowlist
  { allowedImporters ∷ [(String, String)]
  , allowedDependents ∷ [String]
  , allowedExports ∷ [Contract]
  }

-- | One reviewed export, or instance on a protected type, of a checked module.
data Contract = Contract
  { contractComponent ∷ String
  , contractModule ∷ String
  , contractSymbol ∷ String
  , contractKind ∷ String
  , contractType ∷ String
  }
  deriving (Eq, Ord, Show)

bridgePackage, bridgeLibrary, bridgeModule, representationModule ∷ String
bridgePackage = "hetoimasia-foundation"
bridgeLibrary = "owner-tx-issuer"
bridgeModule = "Hetoimasia.Foundation.OwnerTx.Issuer"
representationModule = "Hetoimasia.Foundation.OwnerTx.Representation"

protectedModules ∷ [String]
protectedModules = [bridgeModule, representationModule]

-- The bridge and the representation: the only modules whose own exports may mention STM.
definingModules ∷ [(String, String)]
definingModules =
  [ (bridgePackage <> ":lib:" <> bridgeLibrary, bridgeModule)
  , (bridgePackage <> ":lib:internal", representationModule)
  ]

-- | Every listed importer and both defining modules.
checkedModules ∷ Allowlist → [(String, String)]
checkedModules allowlist = nub (allowedImporters allowlist <> definingModules)

readAllowlist ∷ String → Either String Allowlist
readAllowlist text = do
  document ← parseJson text
  case member "schema_version" document >>= asInteger of
    Just 2 → pure ()
    _ → Left "the allowlist must be an object with schema_version 2"
  let known = ["schema_version", "description", "importers", "dependents", "exports"]
  case document of
    JObject fields | all ((`elem` known) . fst) fields → pure ()
    _ → Left ("the allowlist has fields other than " <> intercalate ", " known)
  importers ← entries document "importers" (\get → get "reason" *> ((,) <$> get "component" <*> get "module"))
  dependents ← entries document "dependents" (\get → get "reason" *> get "component")
  exports ← entries document "exports" (\get → Contract <$> get "component" <*> get "module" <*> get "symbol" <*> get "kind" <*> get "type")
  pure (Allowlist importers dependents exports)
  where
    entries document name build = do
      listed ← maybe (Left ("the allowlist has no " <> name)) Right (member name document)
      items ← maybe (Left (name <> " is not an array")) Right (asArray listed)
      forM items $ \item → build (\key → maybe (Left (name <> ": an entry needs " <> key <> " as a string: " <> show item)) Right (member key item >>= asString))

absoluteFlags ∷ FilePath → [String] → [String]
absoluteFlags root = map absolute
  where
    absolute flag
      | take 2 flag == "-I" && take 1 (drop 2 flag) /= "/" = "-I" <> root </> drop 2 flag
      | otherwise = flag

-- | Every source's header for every target its configuration compiles for.
headerFacts ∷ FilePath → FilePath → FilePath → [FilePath] → [Configuration] → IO (Either String (Configuration → Source → Maybe (Either String HeaderFacts)))
headerFacts root libdir scratch databases configurations = do
  let items = Map.toList (Map.fromListWith (<>) [((absoluteFlags root (configFlags configuration), root </> sourcePath source), [configTarget configuration]) | configuration ← configurations, source ← configSources configuration])
  outcome ← readHeaders libdir scratch databases [(key, nub targets') | (key, targets') ← items]
  pure $ fmap (\facts configuration source → Map.lookup ((absoluteFlags root (configFlags configuration), root </> sourcePath source), configTarget configuration) facts) outcome

-- | Every problem: unsupported forms, uncovered evidence, and every fact the allowlist does not admit.
check ∷ FilePath → FilePath → FilePath → [FilePath] → Allowlist → Inventory → IO [String]
check root libdir scratch databases allowlist inventory = do
  let packages = inventoryPackages inventory
      configurations = concatMap packageConfigurations packages
      structural = inventoryProblems inventory <> concatMap packageProblems packages <> nub (concatMap configProblems configurations)
      dependents = [(componentId configuration, configurationId configuration) | configuration ← configurations, (dependency, libraries) ← configDependencies configuration, dependency == bridgePackage, bridgeLibrary `elem` libraries]
      dependencyProblems = [place <> " depends on " <> bridgePackage <> ":" <> bridgeLibrary <> " and is not a listed dependent" | (component, place) ← dependents, component `notElem` allowedDependents allowlist]
      cabalReexports =
        [ configurationId configuration <> " re-exports " <> original <> " as " <> renamed <> " through reexported-modules"
        | configuration ← configurations
        , (original, renamed) ← configReexports configuration
        , original `elem` protectedModules
        ]
          <> [ configurationId configuration <> " names the issuer bridge in a mixin (" <> package <> ":" <> library <> " " <> renaming <> ")"
             | configuration ← configurations
             , (package, library, renaming) ← configMixins configuration
             , (package == bridgePackage && library `elem` [bridgeLibrary, "internal"]) || any (`isInfixOf` renaming) protectedModules
             ]
  headers ← headerFacts root libdir scratch databases configurations
  case headers of
    Left why → pure (structural <> dependencyProblems <> cabalReexports <> ["uncovered: " <> why])
    Right factsOf → do
      let perSource = [(configuration, source, factsOf configuration source) | configuration ← configurations, source ← configSources configuration]
          headerProblems =
            nub $
              concat
                [ case fact of
                    Nothing → ["uncovered: no header was read for " <> sourcePath source <> " in " <> configurationId configuration]
                    Just (Left why) → ["uncovered: " <> why <> " in " <> configurationId configuration]
                    Just (Right header) →
                      headerUnsupported header
                        <> ["unsupported: a {-# SOURCE #-} import of " <> imported <> " in " <> sourcePath source <> " (" <> configurationId configuration <> ")" | imported ← headerSourceImports header]
                | (configuration, source, fact) ← perSource
                ]
          importers =
            [ (componentId configuration, sourceModule source, sourcePath source, configurationId configuration, protected)
            | (configuration, source, Just (Right header)) ← perSource
            , let protected = filter (`elem` protectedModules) (headerImports header <> headerSourceImports header)
            , not (null protected)
            ]
          importProblems =
            nub
              [ path <> ": " <> moduleName <> " in " <> place <> " imports " <> intercalate ", " (nub protected) <> " and is not listed as an importer"
              | (component, moduleName, path, place, protected) ← importers
              , (component, moduleName) `notElem` allowedImporters allowlist
              ]
          seenImporters = Set.fromList [(component, moduleName) | (component, moduleName, _, _, _) ← importers]
          staleImporters =
            [ "the listed importer " <> moduleName <> " of " <> component <> " imports no protected module in any configuration: a stale entry"
            | (component, moduleName) ← allowedImporters allowlist
            , not (Set.member (component, moduleName) seenImporters)
            ]
          staleDependents =
            [ "the listed dependent " <> component <> " depends on no " <> bridgePackage <> ":" <> bridgeLibrary <> " in any configuration: a stale entry"
            | component ← allowedDependents allowlist
            , component `notElem` map fst dependents
            ]
          cppSources = Set.fromList [(configurationId configuration, sourcePath source) | (configuration, source, Just (Right header)) ← perSource, headerUsedCpp header]
      typed ← typedInterfaces root libdir scratch databases packages cppSources (checkedModules allowlist)
      pure (structural <> dependencyProblems <> cabalReexports <> headerProblems <> importProblems <> staleImporters <> staleDependents <> interfaceProblems allowlist typed)

-- | Every checked module's typed interface in every combination of its configuration and its local library
-- dependencies' variants on the same target. Each combination's sources are preprocessed with their own component's
-- flags into a scratch tree, and the module is typechecked from its resolved path there. Combinations whose sources use
-- no CPP are the same on every target and are typechecked once.
typedInterfaces ∷ FilePath → FilePath → FilePath → [FilePath] → [Package] → Set.Set (String, FilePath) → [(String, String)] → IO [((String, String), [(String, Either String Interface)])]
typedInterfaces root libdir scratch databases packages cppSources checked =
  forM (zip [0 ∷ Int ..] checked) $ \(index, key@(component, moduleName)) → do
    let compiling = [configuration | configuration ← fromMaybe [] (Map.lookup component byComponent), moduleName `elem` map sourceModule (configSources configuration)]
        distinct = Map.elems (Map.fromList [(keyOf combination, combination) | configuration ← compiling, combination ← combinations configuration])
    outcomes ← forM (zip [0 ∷ Int ..] distinct) $ \(number, combination) → case combination of
      [] → pure ("", Left "an empty combination")
      first : _ → do
        let directory = scratch </> ("check-" <> show index <> "-" <> show number)
            placed = zip [0 ∷ Int ..] combination
            destination slot source = directory </> show slot </> (if sourceModule source == "Main" then takeFileName (sourcePath source) else moduleFile (sourceModule source))
            jobs = [((absoluteFlags root (configFlags member'), configPragmas member', configTarget member', root </> sourcePath source), destination slot source) | (slot, member') ← placed, source ← configSources member']
            checkedSource = [destination (0 ∷ Int) source | source ← configSources first, sourceModule source == moduleName]
            externals = nub [package | member' ← combination, (package, _) ← configDependencies member', not (Set.member package local)]
            label = intercalate " with " (configurationId first : [configurationId member' | member' ← drop 1 combination, configFlagsLabel member' /= ""])
        prepared ← preprocessInto libdir scratch databases jobs
        case (prepared, checkedSource) of
          (Left why, _) → pure (label, Left why)
          (_, [path]) → (,) label <$> readInterface libdir databases [directory </> show slot | (slot, _) ← placed] externals path
          _ → pure (label, Left ("the source of " <> moduleName <> " is not one file"))
    pure (key, outcomes)
  where
    configurations = concatMap packageConfigurations packages
    local = Set.fromList (map packageName packages)
    byComponent = Map.fromListWith (flip (<>)) [(componentId configuration, [configuration]) | configuration ← configurations]
    -- every combination: the configuration and one variant of each local library it reaches, on its target
    combinations configuration = go [configuration] [] (Set.singleton (componentId configuration))
      where
        go [] chosen _ = [reverse chosen]
        go (next : pending) chosen seen =
          let wanted =
                nub
                  [ library
                  | (package, names) ← configDependencies next
                  , Set.member package local
                  , name ← names
                  , let library = package <> ":lib:" <> (if null name then package else name)
                  , not (Set.member library seen)
                  ]
              variants library = [variant | variant ← fromMaybe [] (Map.lookup library byComponent), configTarget variant == configTarget configuration]
              seen' = foldr Set.insert seen wanted
           in [result | picks ← mapM variants wanted, result ← go (pending <> picks) (next : chosen) seen']
    usesCpp = any (\member' → any (\source → Set.member (configurationId member', sourcePath source) cppSources) (configSources member'))
    keyOf combination =
      ( if usesCpp combination then map (show . configTarget) (take 1 combination) else []
      , [(componentId member', configFlagsLabel member', configFlags member', configPragmas member', map sourcePath (configSources member')) | member' ← combination]
      )
    moduleFile name = map (\c → if c == '.' then '/' else c) name <> ".hs"

-- The typed rules and the contracts.
interfaceProblems ∷ Allowlist → [((String, String), [(String, Either String Interface)])] → [String]
interfaceProblems allowlist typed = unknownContracts <> concatMap perModule typed
  where
    unknownContracts =
      [ "the export contract names " <> moduleName <> " of " <> component <> ", which is neither a listed importer nor a defining module: a stale entry"
      | (component, moduleName) ← nub [(contractComponent entry, contractModule entry) | entry ← allowedExports allowlist]
      , (component, moduleName) `notElem` checkedModules allowlist
      ]
    perModule (key@(component, moduleName), outcomes)
      | null outcomes = ["uncovered: the checked module " <> moduleName <> " is not a source of " <> component <> " in any configuration"]
      | otherwise =
          let contract = sort [(contractSymbol entry, contractKind entry, contractType entry) | entry ← allowedExports allowlist, (contractComponent entry, contractModule entry) == key]
              defining = key `elem` definingModules
              everActual = Set.fromList (concat [facts interface | (_, Right interface) ← outcomes])
              failures = ["uncovered: " <> moduleName <> " in " <> label <> ": no typed interface: " <> why | (label, Left why) ← outcomes]
              ruled =
                concat
                  [ concat
                      [ [place <> " exports " <> exportSymbol export <> " (" <> exportKind export <> " ∷ " <> exportType export <> "), whose type contains STM: only the bridge's and the representation's own exports may" | "STM" `elem` exportFindings export, not defining]
                          <> [place <> " exports the boundary constructor " <> exportSymbol export <> ": only its own module may" | "a boundary constructor" `elem` exportFindings export, not defining]
                          <> ["uncovered: " <> place <> " exports " <> exportSymbol export <> ": " <> finding | finding ← exportFindings export, take 11 finding == "unresolved:"]
                      | export ← interfaceExports interface
                      ]
                      <> [place <> " defines the instance " <> instanceHead instance' <> " on a protected type, which its contract does not list" | instance' ← interfaceInstances interface, instanceProtected instance', (instanceClass instance', "instance", instanceHead instance') `notElem` contract]
                      <> [place <> " defines the instance " <> instanceHead instance' <> ", whose method " <> method <> " lifts STM" | not defining, instance' ← interfaceInstances interface, method ← instanceLifts instance']
                      <> [place <> " exports " <> symbol <> " (" <> kind <> (if null ty then "" else " ∷ " <> ty) <> "), which its export contract does not list" | (symbol, kind, ty) ← exportFacts interface, (symbol, kind, ty) `notElem` contract]
                  | (label, Right interface) ← outcomes
                  , let place = moduleName <> " in " <> label
                  ]
              stale = [moduleName <> " in " <> component <> " no longer exports " <> symbol <> " (" <> kind <> (if null ty then "" else " ∷ " <> ty) <> "), which its export contract lists: a stale entry" | (symbol, kind, ty) ← contract, not (Set.member (symbol, kind, ty) everActual)]
           in failures <> nub ruled <> stale
    exportFacts interface = [(exportSymbol export, exportKind export, exportType export) | export ← interfaceExports interface]
    facts interface = exportFacts interface <> [(instanceClass instance', "instance", instanceHead instance') | instance' ← interfaceInstances interface, instanceProtected instance']
