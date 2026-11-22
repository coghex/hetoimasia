{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's policy: the facts Cabal and GHC give (the inventory, each source's imports, each protected module's
-- typed exports) compared with the allowlist.
module Policy
  ( Allowlist (..)
  , Contract (..)
  , readAllowlist
  , check
  , protectedModules
  , definingModules
  , checkedModules
  , typedExports
  ) where

import Control.Monad (forM)
import Data.List (intercalate, isPrefixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Frontend (Export (..), readExports, readImports)
import Inventory (Configuration (..), Package (..), Source (..), componentId)
import Json

-- | The exact allowlist.
data Allowlist = Allowlist
  { allowedImporters ∷ [(String, String)]
  , allowedDependents ∷ [String]
  , allowedExports ∷ [Contract]
  }

-- | One reviewed export of a checked module.
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

-- | The bridge and its bridge-equivalent representation.
protectedModules ∷ [String]
protectedModules = [bridgeModule, representationModule]

-- | Where each protected module is defined: the only place its own exports are permitted.
definingModules ∷ [(String, String)]
definingModules =
  [ (bridgePackage <> ":lib:" <> bridgeLibrary, bridgeModule)
  , (bridgePackage <> ":lib:internal", representationModule)
  ]

-- The bridge's functions: the raw embedding and the issuer-side updates that take functions.
bridgeFunctions ∷ [String]
bridgeFunctions = ["fromIssuerSTM", "modifyCell", "stateCell"]

-- | The modules whose typed exports are checked: every listed importer and both defining modules.
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

-- | Every problem, given the inventory, the libdir of the pinned GHC, and the package databases a typechecked interface
-- may read.
check ∷ FilePath → FilePath → [FilePath] → Allowlist → [Package] → IO [String]
check root libdir databases allowlist packages = do
  let configurations = concatMap packageConfigurations packages
      inventoryProblems = concatMap configProblems configurations
      -- dependencies on the issuer sublibrary
      dependents = [(componentId configuration, configLabel configuration) | configuration ← configurations, (dependency, libraries) ← configDependencies configuration, dependency == bridgePackage, bridgeLibrary `elem` libraries]
      dependencyProblems =
        [ componentIdLabel component label <> " depends on " <> bridgePackage <> ":" <> bridgeLibrary <> " and is not a listed dependent"
        | (component, label) ← dependents
        , component `notElem` allowedDependents allowlist
        ]
      cabalReexports =
        [ componentIdLabel (componentId configuration) (configLabel configuration) <> " re-exports " <> original <> " as " <> renamed <> " through reexported-modules"
        | configuration ← configurations
        , (original, renamed) ← configReexports configuration
        , original `elem` protectedModules
        ]
          <> [ componentIdLabel (componentId configuration) (configLabel configuration) <> " names the issuer bridge in a mixin (" <> package <> ":" <> library <> " " <> renaming <> ")"
             | configuration ← configurations
             , (package, library, renaming) ← configMixins configuration
             , (package == bridgePackage && library `elem` [bridgeLibrary, "internal"]) || any (`isSubstring` renaming) protectedModules
             ]
      -- one header pass per distinct source and preprocessing environment
      groups = Map.toList (Map.fromListWith (<>) [(map (absolute root) (configFlags configuration), [absolute root (sourcePath source)]) | configuration ← configurations, source ← configSources configuration])
  headerResults ← readImports libdir [(flags, nub paths) | (flags, paths) ← groups]
  case headerResults of
    Left why → pure (inventoryProblems <> dependencyProblems <> cabalReexports <> [why])
    Right results → do
      let imported = Map.fromList [((flags, path), outcome) | ((flags, path), outcome) ← results]
          sourceImports configuration source = Map.lookup (map (absolute root) (configFlags configuration), absolute root (sourcePath source)) imported
          headerProblems = [why | (_, Left why) ← results]
          importers =
            [ (componentId configuration, sourceModule source, sourcePath source, configLabel configuration, protected)
            | configuration ← configurations
            , source ← configSources configuration
            , Just (Right modules) ← [sourceImports configuration source]
            , let protected = filter (`elem` protectedModules) modules
            , not (null protected)
            ]
          importProblems =
            nub
              [ path <> ": " <> moduleName <> " in " <> component <> " (" <> label <> ") imports " <> intercalate ", " (nub protected) <> " and is not listed as an importer"
              | (component, moduleName, path, label, protected) ← importers
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
      interfaceProblems ← checkInterfaces root libdir databases allowlist packages
      pure (inventoryProblems <> dependencyProblems <> cabalReexports <> headerProblems <> importProblems <> staleImporters <> staleDependents <> interfaceProblems)
  where
    componentIdLabel component label = component <> " (" <> label <> ")"
    isSubstring needle haystack = any (needle `isPrefixOf`) (suffixes haystack)
    suffixes text = text : case text of
      [] → []
      _ : rest → suffixes rest

absolute ∷ FilePath → FilePath → FilePath
absolute root path
  | "-I" `isPrefixOf` path = "-I" <> absolute root (drop 2 path)
  | "-" `isPrefixOf` path = path
  | "/" `isPrefixOf` path = path
  | otherwise = root <> "/" <> path

-- | The environments one checked module typechecks in: for each distinct configuration that compiles it, the import
-- paths, external packages and flags of that configuration and of its local library dependencies, transitively, with
-- the configuration's label. Empty when no configuration compiles it.
environmentsFor ∷ FilePath → [Package] → (String, String) → [([FilePath], [String], [String], String)]
environmentsFor root packages (component, moduleName) =
  nub [environmentOf configuration | configuration ← configurations, componentId configuration == component, moduleName `elem` map sourceModule (configSources configuration)]
  where
    configurations = concatMap packageConfigurations packages
    local = Set.fromList (map packageName packages)
    byName = Map.fromListWith (flip (<>)) [(componentId configuration, [configuration]) | configuration ← configurations]
    environmentOf configuration =
      let closure = dependencyClosure [configuration] []
          paths = nub [absolute root directory | member' ← closure, directory ← configSourceDirectories member']
          externals = nub [package | member' ← closure, (package, _) ← configDependencies member', not (Set.member package local)]
          flags = nub (concat [map (absolute root) (configFlags member') | member' ← closure])
       in (paths, externals, flags, configLabel configuration)
    dependencyClosure [] seen = reverse seen
    dependencyClosure (next : rest) seen
      | componentId next `elem` map componentId seen = dependencyClosure rest seen
      | otherwise =
          let libraries =
                [ chosen
                | (package, names) ← configDependencies next
                , Set.member package local
                , name ← names
                , let wanted = package <> ":lib:" <> (if null name then package else name)
                , chosen : _ ← [fromMaybe [] (Map.lookup wanted byName)]
                ]
           in dependencyClosure (rest <> libraries) (next : seen)

-- | The typed exports of one checked module in each environment that compiles it.
typedExports ∷ FilePath → FilePath → [FilePath] → [Package] → (String, String) → IO [(String, Either String [Export])]
typedExports root libdir databases packages key@(_, moduleName) =
  forM (environmentsFor root packages key) $ \(importPaths, externals, flags, label) →
    (,) label <$> readExports libdir flags databases importPaths externals moduleName

-- Typecheck every checked module in each configuration that compiles it, and compare its exports with the contract and
-- the rules: the bridge's functions and any conversion between STM and the transaction only at the bridge's own
-- exports, the representation's constructors only at its own.
checkInterfaces ∷ FilePath → FilePath → [FilePath] → Allowlist → [Package] → IO [String]
checkInterfaces root libdir databases allowlist packages = do
  let contractOf key = sort [(contractSymbol entry, contractKind entry, contractType entry) | entry ← allowedExports allowlist, (contractComponent entry, contractModule entry) == key]
      unknownContracts =
        [ "the export contract names " <> moduleName <> " of " <> component <> ", which is neither a listed importer nor a defining module: a stale entry"
        | (component, moduleName) ← nub [(contractComponent entry, contractModule entry) | entry ← allowedExports allowlist]
        , (component, moduleName) `notElem` checkedModules allowlist
        ]
  results ← forM (checkedModules allowlist) $ \key@(component, moduleName) → do
    outcomes ← typedExports root libdir databases packages key
    pure $
      if null outcomes
        then ["the checked module " <> moduleName <> " is not a source of " <> component <> " in any configuration"]
        else concat
          [ case outcome of
              Left why → [moduleName <> " in " <> component <> " (" <> label <> "): no typed interface: " <> why]
              Right exports → exportProblems key label exports (contractOf key)
          | (label, outcome) ← outcomes
          ]
  pure (unknownContracts <> nub (concat results))
  where
    exportProblems (component, moduleName) label exports contract =
      let place = moduleName <> " in " <> component <> " (" <> label <> ")"
          isBridge = (component, moduleName) == (bridgePackage <> ":lib:" <> bridgeLibrary, bridgeModule)
          isRepresentation = (component, moduleName) == (bridgePackage <> ":lib:internal", representationModule)
          actual = sort [(exportSymbol export, exportKind export, exportType export) | export ← exports]
          ruled =
            [ place <> " exports " <> exportSymbol export <> ", which converts between STM and the ownership transaction (" <> exportType export <> "): only the bridge's own export may"
            | export ← exports
            , exportConverts export
            , not isBridge
            , not (isRepresentation && exportKind export == "constructor" && exportDefinedIn export == representationModule)
            ]
              <> [ place <> " re-exports the bridge's " <> exportSymbol export
                 | export ← exports
                 , exportDefinedIn export == bridgeModule
                 , exportSymbol export `elem` bridgeFunctions
                 , not isBridge
                 ]
              <> [ place <> " exports the representation's constructor " <> exportSymbol export <> ": only the representation's own export may"
                 | export ← exports
                 , exportKind export == "constructor"
                 , exportDefinedIn export == representationModule
                 , not isRepresentation
                 ]
          unreviewed = [place <> " exports " <> symbol <> " (" <> kind <> (if null ty then "" else " ∷ " <> ty) <> "), which its export contract does not list" | (symbol, kind, ty) ← actual, (symbol, kind, ty) `notElem` contract]
          missing = [place <> " no longer exports " <> symbol <> " (" <> kind <> (if null ty then "" else " ∷ " <> ty) <> "), which its export contract lists: a stale entry" | (symbol, kind, ty) ← contract, (symbol, kind, ty) `notElem` actual]
       in ruled <> unreviewed <> missing
