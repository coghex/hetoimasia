{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | The guard's policy: Cabal's facts compared with the component allowlist (the design's "Cabal issuer dependency
-- guard").
--
-- The allowlist is exact: it equals the components whose effective @build-depends@ selects
-- @hetoimasia-foundation:owner-tx-issuer@ in at least one supported buildable configuration. No component's Cabal
-- @reexported-modules@ or @mixins@ may expose or rename the bridge or the representation, a listed component's
-- included: a mixin by the modules its renaming actually brings into scope. The protected modules are declared only by their defining components, the representation's privately, and
-- a library selector on a local package names one of its libraries. What a listed component's modules import, export
-- and instantiate is the issuer review's, not the guard's.
module Policy
  ( Allowlist (..)
  , readAllowlist
  , check
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as Map
import Distribution.Fields (Field (..), FieldLine (..), Name (..), readFields)
import Distribution.Utils.Generic (fromUTF8BS)
import Inventory

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

-- | Read the allowlist, in Cabal's field syntax, with Cabal's own field parser: only @dependent@ sections, each with
-- exactly one @component@ (@package:kind:name@) and one @reason@; any other field or section, and a component listed
-- twice, make it unreadable.
--
-- > dependent
-- >   component: hetoimasia-foundation:test:foundation-tests
-- >   reason: its composition example builds through the bridge
readAllowlist ∷ ByteString.ByteString → Either String Allowlist
readAllowlist bytes = do
  fields ← either (\failure → Left ("Cabal's field parser refused it: " <> show failure)) Right (readFields bytes)
  components ← forM fields $ \case
    Section (Name _ section) [] inner | fromUTF8BS section == "dependent" → do
      let values key = [unwords [fromUTF8BS line | FieldLine _ line ← contents] | Field (Name _ name) contents ← inner, fromUTF8BS name == key]
          others = [fromUTF8BS name | Field (Name _ name) _ ← inner, fromUTF8BS name `notElem` ["component", "reason"]] <> ["a section" | Section {} ← inner]
      case (values "component", values "reason", others) of
        ([component], [reason], [])
          | [_, kind, _] ← splitOn component
          , kind `elem` ["lib", "flib", "exe", "test", "bench"]
          , not (any (`elem` " \t") component)
          , not (null (words reason)) →
              Right component
        _ → Left ("a dependent section needs exactly one component (package:kind:name) and one reason, and nothing else: " <> show (values "component", others))
    Section (Name _ name) _ _ → Left ("the section " <> fromUTF8BS name <> " is not a dependent section with no arguments")
    Field (Name _ name) _ → Left ("the field " <> fromUTF8BS name <> " is outside a dependent section")
  case [component | (component, count) ← Map.toList (Map.fromListWith (+) [(c, 1 ∷ Int) | c ← components]), count > 1] of
    [] → Right (Allowlist components)
    repeated → Left ("a component listed more than once: " <> intercalate ", " repeated)
  where
    splitOn text = case break (== ':') text of
      (part, ':' : rest) → part : splitOn rest
      (part, _) → [part]

-- | Every problem: unsupported forms, an unlisted or stale dependent, a protected re-export or mixin, a protected module
-- declared outside its defining component, and an unresolved library selector.
check ∷ Allowlist → Inventory → [String]
check allowlist inventory =
  inventoryProblems inventory
    <> concatMap packageProblems packages
    <> nub (concatMap configProblems everyConfiguration)
    <> unlisted
    <> stale
    <> reexports
    <> mixinProblems
    <> declarations
    <> definitions
    <> selectors
    <> unresolvedMixins
  where
    packages = inventoryPackages inventory
    everyConfiguration = concatMap packageConfigurations packages
    -- what Cabal builds; an unbuildable configuration is only diagnosed
    configurations = filter configBuildable everyConfiguration
    libraries = Map.fromList [(packageName package', packageLibraries package') | package' ← packages]
    manifests = Map.fromList [(packageName package', packageCabal package') | package' ← packages]
    exposedModules = Map.fromList [((packageName package', label), modules) | package' ← packages, (label, modules) ← packageExposed package']
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
      , original `elem` protectedModules || renamed `elem` protectedModules
      ]
    -- what a mixin brings into scope: the included library's exposed modules, all of them, the renamed ones or those not
    -- hidden, and every name its renamings give
    mixinProblems =
      [ configurationId configuration <> " exposes or renames " <> intercalate ", " touched <> " through the mixin " <> mixinPackage mixin <> (if null (mixinLibrary mixin) then "" else ":" <> mixinLibrary mixin) <> (if null (mixinText mixin) then "" else " " <> mixinText mixin)
      | configuration ← configurations
      , mixin ← configMixins configuration
      , let available = Map.findWithDefault [] (mixinPackage mixin, mixinLibrary mixin) exposedModules
            provided = case mixinProvides mixin of
              ProvidesAll → available
              ProvidesRenamed pairs → concat [[from, to] | (from, to) ← pairs]
              ProvidesHiding hidden → filter (`notElem` hidden) available
            touched = nub (filter (`elem` protectedModules) (provided <> mixinRequires mixin))
      , not (null touched)
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
    -- every selector in any branch of any component, buildable or not, of a dependency or a mixin
    selectors =
      nub
        [ packageCabal package' <> ": uncovered: " <> component <> " selects " <> dependency <> ":" <> library <> ", which names no library of the local package " <> dependency <> " (" <> places <> ")"
        | package' ← packages
        , (component, dependency, library, places) ← packageSelectors package'
        , Just known ← [Map.lookup dependency libraries]
        , library `notElem` known
        ]
        <> nub
          [ packageCabal package' <> ": uncovered: " <> component <> " selects " <> dependency <> ":" <> library <> ", a library of a package outside this repository, which the guard cannot establish (" <> places <> ")"
          | package' ← packages
          , (component, dependency, library, places) ← packageSelectors package'
          , Nothing ← [Map.lookup dependency libraries]
          , not (null library)
          ]
    -- every mixin includes a library its configuration depends on
    unresolvedMixins =
      nub
        [ Map.findWithDefault "" (configPackage configuration) manifests <> ": uncovered: " <> configurationId configuration <> " has the mixin " <> mixinPackage mixin <> (if null (mixinLibrary mixin) then "" else ":" <> mixinLibrary mixin) <> ", which names no dependency of that configuration"
        | configuration ← everyConfiguration
        , mixin ← configMixins configuration
        , not (or [package' == mixinPackage mixin && mixinLibrary mixin `elem` selected | (package', selected) ← configDependencies configuration])
        ]
