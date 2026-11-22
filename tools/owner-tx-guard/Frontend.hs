{-# LANGUAGE LambdaCase, NoOverloadedStrings #-}

-- | What GHC's own frontend says, for one target at a time.
--
-- Headers: a source preprocessed with its configuration's flags and the target's operating-system and architecture
-- macros (a forced-include header replaces the host's), then read by GHC's header parser: its ordinary and @SOURCE@
-- imports. A source that uses CPP is held to the subset: literal object-like definitions, pinned package-version
-- macros, and conditionals over target, version and local literal macros; any other directive is unsupported.
--
-- Interfaces: a module typechecked from its resolved source path in a scratch tree, its module and path checked, then
-- its exports and its own instances. Every exported value, constructor, field, class method and synonym is walked for
-- an occurrence of 'STM' by GHC identity: under constraints, arrows and type arguments, synonyms expanded, through the
-- instantiated fields of the scratch tree's own data types and newtypes, memoized per instantiation; the five
-- Foundation boundary types are opaque, though their type arguments are walked; an unresolved type family fails closed.
module Frontend
  ( HeaderFacts (..)
  , readHeaders
  , preprocessInto
  , Interface (..)
  , Export (..)
  , Instance (..)
  , readInterface
  , withScratch
  ) where

import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isAlphaNum, isSpace)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Distribution.System (Arch (..), OS (..))
import GHC
  ( Ghc
  , LoadHowMuch (LoadAllTargets)
  , SuccessFlag (..)
  , TyThing (..)
  , getLogger
  , getModuleGraph
  , getModuleInfo
  , getSession
  , getSessionDynFlags
  , guessTarget
  , load
  , lookupName
  , mgModSummaries
  , ml_hs_file
  , modInfoExports
  , modInfoInstances
  , moduleNameString
  , ms_location
  , ms_mod
  , noLoc
  , parseDynamicFlags
  , runGhc
  , setSessionDynFlags
  , setTargets
  , unLoc
  )
import GHC.Core.Class (classMethods, classTyCon)
import GHC.Core.ConLike (ConLike (..))
import GHC.Core.DataCon (dataConInstOrigArgTys, dataConName, dataConTyCon, dataConWrapperType)
import GHC.Core.InstEnv (is_cls, is_dfun, is_tys)
import GHC.Core.Multiplicity (scaledThing)
import GHC.Core.TyCo.Rep (Type (..))
import GHC.Core.TyCon (isAlgTyCon, isClassTyCon, isTypeFamilyTyCon, synTyConRhs_maybe, tyConClass_maybe, tyConDataCons, tyConName)
import GHC.Core.Type (expandTypeSynonyms, mkTyConApp, piResultTys, splitFunTy_maybe)
import GHC.Data.StringBuffer (hGetStringBuffer)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Driver.Env (HscEnv, hscActiveUnitId, hscSetFlags, hsc_dflags, hsc_logger)
import GHC.Driver.Pipeline (preprocess)
import GHC.Parser.Header (getImports)
import GHC.Types.Id (idType)
import GHC.Types.Name (Name, getName, getOccString, nameModule_maybe)
import GHC.Unit.Module (moduleName, moduleUnit)
import GHC.Unit.Types (UnitId, toUnitId, unitIdString)
import GHC.Utils.Outputable (showPprUnsafe)
import Inventory (Target (..), targets)
import System.CPUTime (getCPUTime)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Process (getProcessID)

-- ---------------------------------------------------------------------------
-- Scratch

-- | A scratch directory outside the checkout, with the targets' forced-include headers, removed afterwards.
withScratch ∷ (FilePath → IO a) → IO a
withScratch body = do
  base ← getTemporaryDirectory
  process ← getProcessID
  stamp ← getCPUTime
  let directory = base </> ("owner-tx-guard-" <> show process <> "-" <> show stamp)
  bracket (createDirectoryIfMissing True directory >> pure directory) removeDirectoryRecursive $ \scratch → do
    forM_ targets $ \target → writeFile (headerPath scratch target) (targetHeader target)
    body scratch

headerPath ∷ FilePath → Target → FilePath
headerPath scratch (Target os arch) = scratch </> ("target-" <> osMacro os <> "-" <> archMacro arch <> ".h")

osMacro ∷ OS → String
osMacro = \case
  OSX → "darwin"
  Linux → "linux"
  other → show other

archMacro ∷ Arch → String
archMacro = \case
  AArch64 → "aarch64"
  X86_64 → "x86_64"
  other → show other

-- The forced-include header that makes CPP see the target, whatever the host: the host's macros are undefined and the
-- target's defined, after every command-line definition.
targetHeader ∷ Target → String
targetHeader (Target os arch) =
  unlines $
    ["#undef " <> macro | macro ← ["linux_HOST_OS", "darwin_HOST_OS", "linux_BUILD_OS", "darwin_BUILD_OS", "x86_64_HOST_ARCH", "aarch64_HOST_ARCH", "x86_64_BUILD_ARCH", "aarch64_BUILD_ARCH"]]
      <> ["#define " <> osMacro os <> "_HOST_OS 1", "#define " <> archMacro arch <> "_HOST_ARCH 1"]

targetFlags ∷ FilePath → Target → [String]
targetFlags scratch target = ["-optP-include", "-optP" <> headerPath scratch target]

-- A session over these package databases, and a way to configure it with a source's flags.
withSession ∷ FilePath → [FilePath] → (HscEnv → IO a) → IO a
withSession libdir databases body =
  runGhc (Just libdir) $ do
    dynamic ← getSessionDynFlags
    logger ← getLogger
    (configured, _, _) ← parseDynamicFlags logger dynamic (map noLoc (concatMap (\database → ["-package-db", database]) databases))
    _ ← setSessionDynFlags configured
    getSession >>= liftIO . body

configure ∷ HscEnv → [String] → IO (Either String HscEnv)
configure base flags = do
  (configured, leftover, _) ← parseDynamicFlags (hsc_logger base) (hsc_dflags base) (map noLoc flags)
  pure $
    if null leftover
      then Right (hscSetFlags configured base)
      else Left ("flags GHC does not read: " <> unwords (map unLoc leftover))

-- ---------------------------------------------------------------------------
-- Headers

-- | A source's header, as GHC read it for one target: its ordinary and @SOURCE@ imports, whether it used CPP, and its
-- directives outside the subset.
data HeaderFacts = HeaderFacts
  { headerImports ∷ [String]
  , headerSourceImports ∷ [String]
  , headerUsedCpp ∷ Bool
  , headerUnsupported ∷ [String]
  }

-- | Read every source's header once per target it is compiled for; a source that does not use CPP is read once and
-- shared by every target, its header being the same for each.
readHeaders ∷ FilePath → FilePath → [FilePath] → [(([String], FilePath), [Target])] → IO (Either String (Map.Map (([String], FilePath), Target) (Either String HeaderFacts)))
readHeaders libdir scratch databases items =
  guarded . withSession libdir databases $ \base → do
    results ← forM items $ \((flags, path), wanted) → case wanted of
      [] → pure []
      first : rest → do
        firstFacts ← readOne base flags first path
        case firstFacts of
          Right facts | not (headerUsedCpp facts) → pure [(((flags, path), target), Right facts) | target ← wanted]
          _ → do
            others ← forM rest $ \target → (,) ((flags, path), target) <$> readOne base flags target path
            pure ((((flags, path), first), firstFacts) : others)
    pure (Right (Map.fromList (concat results)))
  where
    readOne base flags target path =
      configure base (flags <> targetFlags scratch target) >>= \case
        Left why → pure (Left why)
        Right env →
          guarded $
            preprocess env path Nothing Nothing >>= \case
              Left _ → pure (Left (path <> ": GHC could not preprocess it for " <> show target))
              Right (preprocessed, output) → do
                let usedCpp = output /= path
                unsupported ← if usedCpp then cppSubset flags path else pure []
                buffer ← hGetStringBuffer output
                getImports (initParserOpts preprocessed) True buffer output path >>= \case
                  Left _ → pure (Left (path <> ": GHC's header parser could not read its imports"))
                  Right (sourceImports, ordinary, _) →
                    pure (Right (HeaderFacts [moduleNameString (unLoc name) | (_, _, name) ← ordinary] (map (moduleNameString . unLoc) sourceImports) usedCpp unsupported))

-- The CPP subset: definitions of object-like literals, undefinitions, and conditionals whose identifiers are target
-- macros, the compiler's and pinned packages' version macros, numbers, or literal macros defined before them (here or
-- by a configuration's -D). Anything else is unsupported.
cppSubset ∷ [String] → FilePath → IO [String]
cppSubset flags path = do
  text ← readFile path
  pure (check (lines text) (Set.fromList flagDefinitions) [])
  where
    flagDefinitions = [takeWhile (/= '=') (drop 2 option) | flag ← flags, Just option ← [definition flag], "-D" `isPrefixOf` option]
    definition flag
      | "-optP" `isPrefixOf` flag = Just (drop 5 flag)
      | "-D" `isPrefixOf` flag = Just flag
      | otherwise = Nothing
    check [] _ found = reverse found
    check (line : rest) defined found = case dropWhile isSpace line of
      '#' : directive →
        let (name, argument) = span isAlphaNum (dropWhile isSpace directive)
            names = identifiers argument
            continued = "\\" `isSuffixOf` line
         in case name of
              "define"
                | (macro, after) ← span identifierCharacter (dropWhile isSpace argument)
                , not (null macro)
                , '(' `notElem` after
                , not continued →
                    check rest (Set.insert macro defined) found
              "undef" | not continued → check rest (foldr Set.delete defined names) found
              _
                | name `elem` ["if", "elif", "ifdef", "ifndef"], not continued, all (known defined) names → check rest defined found
                | name `elem` ["else", "endif"] → check rest defined found
              _ → check rest defined (("unsupported: the CPP directive #" <> name <> " " <> trim argument <> " in " <> path) : found)
      _ → check rest defined found
    known defined word =
      word == "defined"
        || Set.member word defined
        || any (`isSuffixOf` word) ["_HOST_OS", "_HOST_ARCH", "_BUILD_OS", "_BUILD_ARCH"]
        || word `elem` ["__GLASGOW_HASKELL__", "__GLASGOW_HASKELL_FULL_VERSION__"]
        || any (`isPrefixOf` word) ["MIN_VERSION_", "VERSION_"]
        || all (`elem` "0123456789xXabcdefABCDEFuUlL") word
    identifiers text = case dropWhile (not . identifierCharacter) text of
      [] → []
      rest → let (word, after) = span identifierCharacter rest in word : identifiers after
    identifierCharacter c = c == '_' || isAlphaNum c
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | Preprocess sources for their targets into scratch files, each prefixed with its configuration's LANGUAGE pragmas
-- (its own CPP pragma turned off: the copy is preprocessed already).
preprocessInto ∷ FilePath → FilePath → [FilePath] → [(([String], [String], Target, FilePath), FilePath)] → IO (Either String ())
preprocessInto libdir scratch databases jobs =
  guarded . withSession libdir databases $ \base → do
    outcomes ← forM jobs $ \((flags, pragmas', target, path), destination) →
      configure base (flags <> targetFlags scratch target) >>= \case
        Left why → pure (Left why)
        Right env →
          guarded $
            preprocess env path Nothing Nothing >>= \case
              Left _ → pure (Left (path <> ": GHC could not preprocess it for " <> show target))
              Right (_, output) → do
                text ← readFile output
                createDirectoryIfMissing True (takeDirectory destination)
                let header = if null pragmas' then "" else "{-# LANGUAGE " <> intercalate ", " pragmas' <> " #-}\n"
                writeFile destination (header <> unlines (map noCpp (lines text)))
                pure (Right ())
    pure (sequence_ outcomes)
  where
    noCpp line
      | "{-# LANGUAGE" `isPrefixOf` dropWhile isSpace line = unwords [cppOff word | word ← words line]
      | otherwise = line
    cppOff word
      | word == "CPP" = "NoCPP"
      | word == "CPP," = "NoCPP,"
      | otherwise = word

-- ---------------------------------------------------------------------------
-- Interfaces

data Export = Export
  { exportSymbol ∷ String
  , exportDefinedIn ∷ String
  , exportKind ∷ String
    -- ^ value, constructor, type, class or synonym
  , exportType ∷ String
  , exportFindings ∷ [String]
    -- ^ What the walk found: STM, a boundary constructor, an unresolved type.
  }
  deriving (Eq, Ord, Show)

data Instance = Instance
  { instanceClass ∷ String
  , instanceHead ∷ String
  , instanceProtected ∷ Bool
    -- ^ Its head mentions STM or a boundary type.
  , instanceLifts ∷ [String]
    -- ^ The methods whose instantiated type mentions STM.
  }
  deriving (Eq, Ord, Show)

data Interface = Interface
  { interfaceModule ∷ String
  , interfaceFile ∷ FilePath
  , interfaceExports ∷ [Export]
  , interfaceInstances ∷ [Instance]
  }

-- The five boundary types, by defining module and name.
boundary ∷ [(String, String)]
boundary =
  [ ("Hetoimasia.Foundation.OwnerTx.Representation", "OwnerTx")
  , ("Hetoimasia.Foundation.OwnerTx.Cells", "OwnerCell")
  , ("Hetoimasia.Foundation.OwnerTx.Cells", "ReadOnly")
  , ("Hetoimasia.Foundation.OwnerTx.Cells", "Publisher")
  , ("Hetoimasia.Foundation.OwnerTx.Cells", "Publication")
  ]

-- | Typecheck the module at this path, its sources in these import paths with these packages exposed, and read its
-- interface. The module GHC loaded from that path must be the one the interface describes.
readInterface ∷ FilePath → [FilePath] → [FilePath] → [String] → FilePath → IO (Either String Interface)
readInterface libdir databases importPaths packages path =
  guarded . runGhc (Just libdir) $ do
    dynamic ← getSessionDynFlags
    logger ← getLogger
    let commandLine =
          ["-fno-code", "-no-link", "-w", "-hide-all-packages"]
            <> concatMap (\database → ["-package-db", database]) databases
            <> concatMap (\name → ["-package", name]) packages
            <> ["-i" <> intercalate ":" importPaths]
    (configured, leftover, _) ← parseDynamicFlags logger dynamic (map noLoc commandLine)
    if not (null leftover)
      then pure (Left ("flags GHC does not read: " <> unwords (map unLoc leftover)))
      else do
        _ ← setSessionDynFlags configured
        target ← guessTarget path Nothing Nothing
        setTargets [target]
        load LoadAllTargets >>= \case
          Failed → pure (Left ("GHC could not typecheck " <> path))
          Succeeded → do
            graph ← getModuleGraph
            case [summary | summary ← mgModSummaries graph, ml_hs_file (ms_location summary) == Just path] of
              [summary] → do
                home ← hscActiveUnitId <$> getSession
                getModuleInfo (ms_mod summary) >>= \case
                  Nothing → pure (Left ("GHC has no interface for " <> path))
                  Just info → do
                    exports ← mapM (describe home) (modInfoExports info)
                    let own = [instance' | instance' ← modInfoInstances info, nameModule_maybe (getName (is_dfun instance')) == Just (ms_mod summary)]
                    pure (Right (Interface (moduleNameString (moduleName (ms_mod summary))) path exports (map (describeInstance home) own)))
              found → pure (Left ("GHC loaded " <> show (length found) <> " modules from " <> path))
  where
    describe ∷ UnitId → Name → Ghc Export
    describe home name = do
      thing ← lookupName name
      let defined = maybe "" (moduleNameString . moduleName) (nameModule_maybe name)
          symbol = getOccString name
      pure $ case thing of
        Just (AnId identifier) →
          let ty = expandTypeSynonyms (idType identifier) in Export symbol defined "value" (showPprUnsafe ty) (walk home ty)
        Just (AConLike (RealDataCon constructor)) →
          let ty = expandTypeSynonyms (dataConWrapperType constructor)
           in Export (getOccString (dataConName constructor)) defined "constructor" (showPprUnsafe ty) (walk home ty <> ["a boundary constructor" | isBoundary (tyConName (dataConTyCon constructor))])
        Just (ATyCon tycon)
          | Just klass ← tyConClass_maybe tycon →
              Export symbol defined "class" "" (nub (concat [walk home (expandTypeSynonyms (idType method)) | method ← classMethods klass]))
          | Just rhs ← synTyConRhs_maybe tycon → Export symbol defined "synonym" (showPprUnsafe rhs) (walk home (expandTypeSynonyms rhs))
          | otherwise → Export symbol defined "type" "" []
        _ → Export symbol defined "other" "" ["unresolved: " <> symbol]
    describeInstance home instance' =
      let klass = is_cls instance'
          tys = is_tys instance'
          protected = any (\ty → any (`elem` ["STM", "boundary"]) (walkMentions home ty)) tys
          lifts =
            [ getOccString method
            | method ← classMethods klass
            , let instantiated = dropDictionary (piResultTys (idType method) tys)
            , "STM" `elem` walk home (expandTypeSynonyms instantiated)
            ]
       in Instance (getOccString (tyConName (classTyCon klass))) (showPprUnsafe (mkTyConApp (classTyCon klass) tys)) protected lifts
    dropDictionary ty = maybe ty (\(_, _, _, result) → result) (splitFunTy_maybe ty)

isBoundary ∷ Name → Bool
isBoundary name = maybe False (\m → (moduleNameString (moduleName m), getOccString name) `elem` boundary) (nameModule_maybe name)

-- STM by identity: the type constructor of GHC's own library, whatever a local type is called.
isSTM ∷ Name → Bool
isSTM name =
  getOccString name == "STM"
    && maybe False (\m → moduleNameString (moduleName m) == "GHC.Internal.Conc.Sync" && "ghc-internal" `isPrefixOf` unitIdString (toUnitId (moduleUnit m))) (nameModule_maybe name)

-- What a type's walk finds, boundary types left out: "STM", and "unresolved: ..." for a type it cannot resolve.
walk ∷ UnitId → Type → [String]
walk home ty = [finding | finding ← walkMentions home ty, finding /= "boundary"]

-- Every finding, boundary types included.
walkMentions ∷ UnitId → Type → [String]
walkMentions home = nub . snd . go Set.empty
  where
    go seen t = case expandTypeSynonyms t of
      TyVarTy _ → (seen, [])
      AppTy a b → many seen [a, b]
      TyConApp tycon arguments →
        let (seen', own) = visit seen tycon arguments
            (seen'', inner) = many seen' arguments
         in (seen'', own <> inner <> ["boundary" | isBoundary (tyConName tycon)])
      ForAllTy _ body → go seen body
      FunTy _ multiplicity argument result → many seen [multiplicity, argument, result]
      LitTy _ → (seen, [])
      CastTy inner _ → go seen inner
      CoercionTy _ → (seen, [])
    many seen = foldl (\(s, found) t → let (s', more) = go s t in (s', found <> more)) (seen, [])
    visit seen tycon arguments
      | isSTM name = (seen, ["STM"])
      | isBoundary name = (seen, [])
      | isTypeFamilyTyCon tycon = (seen, ["unresolved: the type family " <> getOccString name])
      | local && isAlgTyCon tycon =
          let key = (showPprUnsafe name, map showPprUnsafe arguments)
           in if Set.member key seen
                then (seen, [])
                else
                  let fields = [scaledThing field | constructor ← tyConDataCons tycon, field ← dataConInstOrigArgTys constructor arguments]
                      methods = [piResultTys (idType method) arguments | isClassTyCon tycon, Just klass ← [tyConClass_maybe tycon], method ← classMethods klass]
                   in many (Set.insert key seen) (fields <> methods)
      | otherwise = (seen, [])
      where
        name = tyConName tycon
        local = maybe False ((== home) . toUnitId . moduleUnit) (nameModule_maybe name)

guarded ∷ IO (Either String a) → IO (Either String a)
guarded action =
  try action >>= \case
    Left (failure ∷ SomeException) → pure (Left ("GHC's frontend failed: " <> displayException failure))
    Right result → pure result
