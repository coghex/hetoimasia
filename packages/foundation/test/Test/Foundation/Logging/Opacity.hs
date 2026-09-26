-- | Examples proving that the logging and failure families are reached through
-- their public modules alone.
--
-- "Hetoimasia.Foundation.Log" and "Hetoimasia.Foundation.Failure" re-export
-- what clients may use from hidden modules of the foundation's main library.
-- An example in this suite cannot observe that boundary, so these examples
-- compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@ and @hetoimasia-foundation@
-- and hiding everything else, as the worker opacity examples do.
--
-- One client must be accepted: it imports, by name, every name the two public
-- modules export, with exactly the constructors and fields each exports. Every
-- other client must be rejected for the diagnostic naming its cause. A client
-- importing a hidden module is refused with @GHC-87110@ against the main
-- library's own unit; a client asking the public module for an abstract type's
-- constructor is refused with @GHC-10237@.
module Test.Foundation.Logging.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Logging and failure opacity across the package boundary" $ do
  it "accepts a client that imports every public logging and failure name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

  forM_ hiddenModules $ \hidden →
    it ("rejects a client that imports the hidden module " <> hidden) $
      withClient (importClient hidden) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
        -- Found in the main library and refused as hidden; naming that unit
        -- tells this apart from a missing module or an unresolvable package.
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

  forM_ abstractTypes $ \(public, abstract) →
    it ("rejects a client that asks " <> public <> " for the " <> abstract <> " constructor") $
      withClient (constructorClient public abstract) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` abstract

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation"] "Client.hs"

-- | Every module the two families keep private to the main library.
hiddenModules ∷ [String]
hiddenModules =
  [ "Hetoimasia.Foundation.Log.Base"
  , "Hetoimasia.Foundation.Log.Component"
  , "Hetoimasia.Foundation.Log.Types"
  , "Hetoimasia.Foundation.Log.Filter"
  , "Hetoimasia.Foundation.Log.Format"
  , "Hetoimasia.Foundation.Log.Sink"
  , "Hetoimasia.Foundation.Failure.Base"
  , "Hetoimasia.Foundation.Failure.Types"
  ]

-- | Each abstract type, with the public module that exports it.
abstractTypes ∷ [(String, String)]
abstractTypes =
  [ ("Hetoimasia.Foundation.Log", "Component")
  , ("Hetoimasia.Foundation.Log", "LogSink")
  , ("Hetoimasia.Foundation.Log", "Logger")
  , ("Hetoimasia.Foundation.Failure", "Operation")
  ]

importClient ∷ String → String
importClient hidden = unlines ["module Client () where", "", "import " <> hidden]

constructorClient ∷ String → String → String
constructorClient public abstract =
  unlines
    [ "module Client () where"
    , ""
    , "import " <> public <> " (" <> abstract <> " (" <> abstract <> "))"
    ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Foundation.Log"
    , "  ( LogLevel (Debug, Info, Warning, Error)"
    , "  , Component"
    , "  , mkComponent"
    , "  , unsafeComponent"
    , "  , componentText"
    , "  , LogFilter (LogFilter, filterEnabled, filterGlobalLevel, filterComponentLevels, filterDebug, filterSource)"
    , "  , DebugSelection (DebugNone, DebugAll, DebugComponents)"
    , "  , defaultLogFilter"
    , "  , parseLogLevel"
    , "  , parseComponentLevels"
    , "  , parseDebugSelection"
    , "  , LogVariables (LogVariables, variableGlobalLevel, variableComponentLevels, variableDebug)"
    , "  , resolveLogFilter"
    , "  , LogEntry (LogEntry, entryLevel, entryComponent, entryMessage, entryFields, entryBreadcrumbs, entryTime, entryThread, entrySource)"
    , "  , SourceLocation (SourceLocation, sourceFile, sourceLine, sourceFunction)"
    , "  , FormatOptions (FormatOptions, formatThread, formatFlush)"
    , "  , defaultFormatOptions"
    , "  , formatEntry"
    , "  , LogSink"
    , "  , newHandleSink"
    , "  , newHandleSinkWith"
    , "  , callbackSink"
    , "  , callbackSinkWith"
    , "  , writeEntry"
    , "  , flushSink"
    , "  , MetadataProviders (MetadataProviders, metadataClock, metadataThread)"
    , "  , systemMetadata"
    , "  , Logger"
    , "  , mkLoggerWith"
    , "  , mkLogger"
    , "  , handleLogger"
    , "  , withFields"
    , "  , withBreadcrumb"
    , "  , flushLogger"
    , "  , logEvent"
    , "  , logDebug"
    , "  , logInfo"
    , "  , logWarning"
    , "  , logError"
    , "  )"
    , "import Hetoimasia.Foundation.Failure"
    , "  ( Operation"
    , "  , operation"
    , "  , operationText"
    , "  , throwFailure"
    , "  , throwFailureSTM"
    , "  , withOperationContext"
    , "  , FailureEvidence (FailureEvidence, failureCause, failureContexts)"
    , "  , FailureCause (EngineOrigin, NativeCause)"
    , "  , FailureOrigin (FailureOrigin, originComponent, originOperation, originIdentifiers, originSite)"
    , "  , OperationContext (OperationContext, contextComponent, contextOperation, contextIdentifiers, contextBoundary)"
    , "  , FailureSite (FailureSite, siteLocation, siteCallStack)"
    , "  , failureEvidence"
    , "  , failureEvidenceInContext"
    , "  )"
    ]
