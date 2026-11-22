{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | What GHC's own frontend says about a source: its direct imports, after preprocessing with the configuration's
-- language, extensions, CPP options and include directories (GHC's header parser, so explicit braces, CPP-made names,
-- package-qualified and @SOURCE@ imports are read as GHC reads them); and a module's typechecked exports, each with the
-- module that defines it, what kind of thing it is, its type with synonyms expanded, and whether it converts between
-- 'STM' and the ownership transaction in either direction.
module Frontend
  ( Export (..)
  , readImports
  , readExports
  ) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad.IO.Class (liftIO)
import Data.List (intercalate)
import GHC
  ( Ghc
  , LoadHowMuch (LoadAllTargets)
  , SuccessFlag (..)
  , TyThing (..)
  , findModule
  , getLogger
  , getModuleInfo
  , getSession
  , getSessionDynFlags
  , guessTarget
  , load
  , lookupName
  , mkModuleName
  , modInfoExports
  , moduleNameString
  , noLoc
  , parseDynamicFlags
  , runGhc
  , setSessionDynFlags
  , setTargets
  , unLoc
  )
import GHC.Core.ConLike (ConLike (..))
import GHC.Core.DataCon (dataConName, dataConWrapperType)
import GHC.Core.TyCon (TyCon, tyConName)
import GHC.Core.Multiplicity (scaledThing)
import GHC.Core.Type (Type, expandTypeSynonyms, splitForAllTyCoVars, splitFunTys, tyConAppTyCon_maybe)
import GHC.Data.StringBuffer (hGetStringBuffer)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Driver.Env (hscSetFlags)
import GHC.Driver.Pipeline (preprocess)
import GHC.Parser.Header (getImports)
import GHC.Types.Id (idType)
import GHC.Types.Name (Name, getOccString, nameModule_maybe)
import GHC.Unit.Module (moduleName)
import GHC.Utils.Outputable (showPprUnsafe)

-- | One export of a typechecked module.
data Export = Export
  { exportSymbol ∷ String
  , exportDefinedIn ∷ String
  , exportKind ∷ String
    -- ^ value, type or constructor
  , exportType ∷ String
  , exportConverts ∷ Bool
    -- ^ A value whose type converts between 'STM' and the ownership transaction, either way.
  }
  deriving (Eq, Ord, Show)

-- | The direct imports of many sources, each read as GHC's header parser reads it after preprocessing it with its
-- configuration's flags: each imported module, ordinary and @SOURCE@ alike. One session reads them all.
readImports ∷ FilePath → [([String], [FilePath])] → IO (Either String [(([String], FilePath), Either String [String])])
readImports libdir groups =
  guarded . runGhc (Just libdir) $ do
    dynamic ← getSessionDynFlags
    logger ← getLogger
    base ← getSession
    fmap (Right . concat) . mapM (readGroup logger dynamic base) $ groups
  where
    readGroup logger dynamic base (flags, paths) = do
      (configured, leftover, _) ← parseDynamicFlags logger dynamic (map noLoc flags)
      if not (null leftover)
        then pure [((flags, path), Left ("flags GHC does not read: " <> unwords (map unLoc leftover))) | path ← paths]
        else do
          let environment = hscSetFlags configured base
          mapM (\path → (,) (flags, path) <$> liftIO (readOne environment path)) paths
    readOne environment path =
      guarded $
        preprocess environment path Nothing Nothing >>= \case
          Left _ → pure (Left (path <> ": GHC could not preprocess it with its configuration's flags"))
          Right (preprocessed, output) → do
            buffer ← hGetStringBuffer output
            getImports (initParserOpts preprocessed) True buffer output path >>= \case
              Left _ → pure (Left (path <> ": GHC's header parser could not read its imports"))
              Right (sourceImports, ordinary, _) →
                pure (Right (map (moduleNameString . unLoc) sourceImports <> [moduleNameString (unLoc name) | (_, _, name) ← ordinary]))

-- | The typechecked exports of one module, its sources found in these import paths, with these packages exposed from
-- these databases and these flags.
readExports ∷ FilePath → [String] → [FilePath] → [FilePath] → [String] → String → IO (Either String [Export])
readExports libdir flags databases importPaths packages target =
  guarded . runGhc (Just libdir) $ do
    dynamic ← getSessionDynFlags
    logger ← getLogger
    let commandLine =
          ["-fno-code", "-no-link", "-w", "-hide-all-packages"]
            <> concatMap (\database → ["-package-db", database]) databases
            <> concatMap (\name → ["-package", name]) packages
            <> ["-i" <> intercalate ":" importPaths]
            <> flags
    (configured, leftover, _) ← parseDynamicFlags logger dynamic (map noLoc commandLine)
    if not (null leftover)
      then pure (Left ("flags GHC does not read: " <> unwords (map unLoc leftover)))
      else do
        _ ← setSessionDynFlags configured
        targetted ← guessTarget target Nothing Nothing
        setTargets [targetted]
        load LoadAllTargets >>= \case
          Failed → pure (Left ("GHC could not typecheck " <> target))
          Succeeded → do
            found ← findModule (mkModuleName target) Nothing
            getModuleInfo found >>= \case
              Nothing → pure (Left ("GHC has no interface for " <> target))
              Just info → Right <$> mapM describe (modInfoExports info)
  where
    describe ∷ Name → Ghc Export
    describe name = do
      thing ← lookupName name
      let defined = maybe "" (moduleNameString . moduleName) (nameModule_maybe name)
      pure $ case thing of
        Just (AnId identifier) →
          let shown = expandTypeSynonyms (idType identifier)
           in Export (getOccString name) defined "value" (showPprUnsafe shown) (converts shown)
        Just (AConLike (RealDataCon constructor)) →
          let shown = expandTypeSynonyms (dataConWrapperType constructor)
           in Export (getOccString (dataConName constructor)) defined "constructor" (showPprUnsafe shown) (converts shown)
        Just (ATyCon tycon) → Export (getOccString (tyConName tycon)) defined "type" "" False
        _ → Export (getOccString name) defined "other" "" False

-- Whether a type converts between STM and the ownership transaction: an argument of one and a result of the other, at
-- any depth of a returned function.
converts ∷ Type → Bool
converts ty =
  let (_, body) = splitForAllTyCoVars ty
      (arguments, result) = splitFunTys body
      heads = map (headOf . scaledThing) arguments
   in (Just "STM" `elem` heads && headOf result == Just "OwnerTx")
        || (Just "OwnerTx" `elem` heads && headOf result == Just "STM")
        || (not (null arguments) && converts result)
  where
    headOf t = getOccString . tyConName <$> (tyConAppTyCon_maybe (expandTypeSynonyms t) ∷ Maybe TyCon)

guarded ∷ IO (Either String a) → IO (Either String a)
guarded action =
  try action >>= \case
    Left (failure ∷ SomeException) → pure (Left ("GHC's frontend failed: " <> displayException failure))
    Right result → pure result
