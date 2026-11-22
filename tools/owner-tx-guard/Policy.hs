{-# LANGUAGE NoOverloadedStrings #-}

-- | The guard's policy: Cabal's facts compared with the component allowlist (the design's "Cabal issuer dependency
-- guard").
--
-- The allowlist is exact: it equals the components whose effective @build-depends@ selects
-- @hetoimasia-foundation:owner-tx-issuer@ in at least one supported configuration. No component's Cabal
-- @reexported-modules@ or @mixins@ may expose or rename the bridge or the representation, a listed component's
-- included. The protected modules are declared only by their defining components, the representation's privately, and
-- a library selector on a local package names one of its libraries. What a listed component's modules import, export
-- and instantiate is the issuer review's, not the guard's.
module Policy
  ( Allowlist (..)
  , readAllowlist
  , check
  ) where

import Control.Monad (forM)
import Data.List (intercalate, isInfixOf, nub)
import qualified Data.Map.Strict as Map
import Inventory
import Json

-- | The exact allowlist: each listed component, by package, kind and name (@package:kind:name@).
newtype Allowlist = Allowlist
  { allowedDependents ∷ [String]
  }

bridgePackage, bridgeLibrary, bridgeModule, representationModule ∷ String
bridgePackage = "hetoimasia-foundation"
bridgeLibrary = "owner-tx-issuer"
bridgeModule = "Hetoimasia.Foundation.OwnerTx.Issuer"
representationModule = "Hetoimasia.Foundation.OwnerTx.Representation"

-- Each protected module, the component that defines it, and whether that component must be private.
protected ∷ [(String, String, Bool)]
protected =
  [ (bridgeModule, bridgePackage <> ":lib:" <> bridgeLibrary, False)
  , (representationModule, bridgePackage <> ":lib:internal", True)
  ]

protectedModules ∷ [String]
protectedModules = [moduleName | (moduleName, _, _) ← protected]

readAllowlist ∷ String → Either String Allowlist
readAllowlist text = do
  document ← parseJson text
  case member "schema_version" document >>= asInteger of
    Just 3 → pure ()
    _ → Left "the allowlist must be an object with schema_version 3"
  let known = ["schema_version", "description", "dependents"]
  case document of
    JObject fields | all ((`elem` known) . fst) fields → pure ()
    _ → Left ("the allowlist has fields other than " <> intercalate ", " known)
  listed ← maybe (Left "the allowlist has no dependents") Right (member "dependents" document)
  items ← maybe (Left "dependents is not an array") Right (asArray listed)
  dependents ← forM items $ \item → do
    let get key = maybe (Left ("dependents: an entry needs " <> key <> " as a string: " <> show item)) Right (member key item >>= asString)
    _ ← get "reason"
    get "component"
  pure (Allowlist dependents)

-- | Every problem: unsupported forms, an unlisted or stale dependent, a protected re-export or mixin, a protected module
-- declared outside its defining component, and an unresolved library selector.
check ∷ Allowlist → Inventory → [String]
check allowlist inventory =
  inventoryProblems inventory
    <> concatMap packageProblems packages
    <> nub (concatMap configProblems configurations)
    <> unlisted
    <> stale
    <> reexports
    <> mixinProblems
    <> declarations
    <> definitions
    <> selectors
  where
    packages = inventoryPackages inventory
    configurations = concatMap packageConfigurations packages
    libraries = Map.fromList [(packageName package', packageLibraries package') | package' ← packages]
    dependents =
      [ configuration
      | configuration ← configurations
      , (dependency, selected) ← configDependencies configuration
      , dependency == bridgePackage
      , bridgeLibrary `elem` selected
      ]
    unlisted =
      [ configurationId configuration <> " depends on " <> bridgePackage <> ":" <> bridgeLibrary <> " and is not a listed dependent"
      | configuration ← dependents
      , componentId configuration `notElem` allowedDependents allowlist
      ]
    stale =
      [ "the listed dependent " <> component <> " depends on no " <> bridgePackage <> ":" <> bridgeLibrary <> " in any supported configuration: a stale entry"
      | component ← nub (allowedDependents allowlist)
      , component `notElem` map componentId dependents
      ]
    reexports =
      [ configurationId configuration <> " re-exports " <> original <> " as " <> renamed <> " through reexported-modules, exposing a protected module"
      | configuration ← configurations
      , (original, renamed) ← configReexports configuration
      , any (`isInfixOf` original) protectedModules || renamed `elem` protectedModules
      ]
    mixinProblems =
      [ configurationId configuration <> " names a protected module or library in the mixin " <> package <> (if null library then "" else ":" <> library) <> " " <> renaming
      | configuration ← configurations
      , (package, library, renaming) ← configMixins configuration
      , (package == bridgePackage && library `elem` [bridgeLibrary, "internal"]) || any (`isInfixOf` renaming) protectedModules
      ]
    declarations =
      [ configurationId configuration <> " declares the protected module " <> moduleName <> ", which only " <> defining <> " may"
      | configuration ← configurations
      , (moduleName, defining, _) ← protected
      , moduleName `elem` configModules configuration
      , componentId configuration /= defining
      ]
    definitions =
      concat
        [ [ "uncovered: the protected module " <> moduleName <> " is not declared by " <> defining <> " in any supported configuration"
          | not (any (\configuration → componentId configuration == defining && moduleName `elem` configModules configuration) configurations)
          ]
            <> [ configurationId configuration <> " declares the protected module " <> moduleName <> " with visibility: public; its library must be private"
               | private
               , configuration ← configurations
               , componentId configuration == defining
               , configPublic configuration
               ]
        | (moduleName, defining, private) ← protected
        ]
    selectors =
      nub
        [ "uncovered: " <> configurationId configuration <> " selects " <> dependency <> ":" <> library <> ", which names no library of the local package " <> dependency
        | configuration ← configurations
        , (dependency, selected) ← configDependencies configuration
        , Just known ← [Map.lookup dependency libraries]
        , library ← selected
        , library `notElem` known
        ]
