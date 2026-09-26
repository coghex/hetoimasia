-- | The failure evidence records, and the private annotation that carries them
-- on an exception's context.
--
-- 'FailureSite', 'FailureOrigin', 'OperationContext', 'FailureCause', and
-- 'FailureEvidence' are the public records "Hetoimasia.Foundation.Failure"
-- re-exports. 'Evidence' is the annotation that module attaches and reads back;
-- its 'ExceptionAnnotation' instance and the rendering that instance needs live
-- here with it. The facade does not export 'Evidence', so evidence can only be
-- attached by its raising and boundary operations. This module is private to
-- the foundation package.
--
-- The component and source-location types come from
-- "Hetoimasia.Foundation.Log.Component" and "Hetoimasia.Foundation.Log.Base"
-- directly, so failure attribution depends on no logger, filter, format, or
-- sink.
module Hetoimasia.Foundation.Failure.Types
  ( -- * Evidence
    FailureSite (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , FailureCause (..)
  , FailureEvidence (..)

    -- * The annotation
  , Evidence (..)
  , entryPosition
  ) where

import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Data.Char (isControl, ord)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure.Base (Operation, operationText)
import Hetoimasia.Foundation.Log.Base (SourceLocation (..))
import Hetoimasia.Foundation.Log.Component (Component, componentText)

-- | The source information available for one site.
data FailureSite = FailureSite
  { siteLocation ∷ !SourceLocation
    -- ^ The outermost frame: the call site outside every function that
    -- declared 'GHC.Stack.HasCallStack'.
  , siteCallStack ∷ ![SourceLocation]
    -- ^ Every frame, innermost first, as 'GHC.Stack.getCallStack' orders them.
  }
  deriving (Eq, Show)

-- | Where an engine failure was raised, and by what.
data FailureOrigin = FailureOrigin
  { originComponent ∷ !Component
  , originOperation ∷ !Operation
  , originIdentifiers ∷ ![(Text, Text)]
    -- ^ Caller-supplied identifiers, such as a resource or request name.
  , originSite ∷ !(Maybe FailureSite)
    -- ^ The caller's site; 'Nothing' only when the caller's call stack was
    -- empty.
  }
  deriving (Eq, Show)

-- | An operation an outer boundary was performing when a failure passed
-- through it.
data OperationContext = OperationContext
  { contextComponent ∷ !Component
  , contextOperation ∷ !Operation
  , contextIdentifiers ∷ ![(Text, Text)]
  , contextBoundary ∷ !(Maybe FailureSite)
    -- ^ Where the boundary observing the failure was entered. This is the
    -- observation boundary, never the failure's throw site.
  }
  deriving (Eq, Show)

-- | What is known about where a failure came from.
data FailureCause
  = EngineOrigin !FailureOrigin
    -- ^ Raised by 'Hetoimasia.Foundation.Failure.throwFailure' or
    -- 'Hetoimasia.Foundation.Failure.throwFailureSTM', whose throw site is
    -- known.
  | NativeCause
    -- ^ No engine origin was recorded: a native or library exception, or one
    -- thrown without either. Its throw site is unknown, and no site is
    -- invented for it.
  deriving (Eq, Show)

-- | The origin evidence an exception carries, and every operation context
-- added to it, in the order they were attached.
data FailureEvidence = FailureEvidence
  { failureCause ∷ !FailureCause
  , failureContexts ∷ ![OperationContext]
    -- ^ Innermost boundary first.
  }
  deriving (Eq, Show)

-- | The annotation "Hetoimasia.Foundation.Failure" attaches. The facade does
-- not export it, so evidence can only be attached by
-- 'Hetoimasia.Foundation.Failure.throwFailure',
-- 'Hetoimasia.Foundation.Failure.throwFailureSTM', and
-- 'Hetoimasia.Foundation.Failure.withOperationContext'.
--
-- Each entry records how many entries its context already held when it was
-- attached. Inspection orders by that position, so attachment order is a
-- property the failure modules define rather than a consequence of how @base@
-- stores annotations.
data Evidence
  = OriginEntry !Int !FailureOrigin
  | ContextEntry !Int !OperationContext

instance ExceptionAnnotation Evidence where
  displayExceptionAnnotation (OriginEntry _ origin) =
    "failure origin: "
      <> describe (originComponent origin) (originOperation origin) (originIdentifiers origin)
      <> " raised at "
      <> describeSite (originSite origin)
  displayExceptionAnnotation (ContextEntry _ context) =
    "during operation: "
      <> describe (contextComponent context) (contextOperation context) (contextIdentifiers context)
      <> " observed at "
      <> describeSite (contextBoundary context)

-- | How many entries the context held when this one was attached.
entryPosition ∷ Evidence → Int
entryPosition (OriginEntry position _) = position
entryPosition (ContextEntry position _) = position

-- | One entry renders as one line. Every caller-supplied text is double-quoted
-- and escaped with the rules the logger applies to the values it quotes, so an
-- operation or identifier carrying a newline or a quote cannot split the line or
-- forge another entry. A 'Component' is validated and needs no quoting.
describe ∷ Component → Operation → [(Text, Text)] → String
describe component operationName identifiers =
  Text.unpack (componentText component)
    <> " "
    <> quoted (operationText operationName)
    <> case identifiers of
      [] → ""
      _ →
        " ("
          <> intercalate ", " [quoted key <> "=" <> quoted value | (key, value) ← identifiers]
          <> ")"

describeSite ∷ Maybe FailureSite → String
describeSite Nothing = "an unknown site"
describeSite (Just site) =
  quoted (sourceFile location)
    <> ":"
    <> show (sourceLine location)
    <> " in "
    <> quoted (sourceFunction location)
  where
    location = siteLocation site

quoted ∷ Text → String
quoted value = "\"" <> concatMap escaped (Text.unpack value) <> "\""

escaped ∷ Char → String
escaped '"' = "\\\""
escaped '\\' = "\\\\"
escaped '\n' = "\\n"
escaped '\r' = "\\r"
escaped '\t' = "\\t"
escaped character
  | isControl character = "\\u" <> hex4 (ord character)
  | otherwise = [character]

hex4 ∷ Int → String
hex4 value = map nibble [4096, 256, 16, 1]
  where
    nibble place = "0123456789ABCDEF" !! ((value `div` place) `mod` 16)
