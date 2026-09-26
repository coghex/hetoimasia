-- | The abstract 'Operation' name and its naming operations.
--
-- This module depends on no other foundation module, so a consumer that only
-- names an operation needs neither failure annotations nor logging. The
-- constructor stays here: 'operation' is the only way to build one. The public
-- facade is "Hetoimasia.Foundation.Failure", which exports the type abstractly;
-- this module is private to the foundation package.
module Hetoimasia.Foundation.Failure.Base
  ( Operation
  , operation
  , operationText
  ) where

import Data.Text (Text)

-- | The stable name of an operation a component performs, such as
-- @load-texture@. Like a 'Hetoimasia.Foundation.Log.Component', it is a name
-- chosen in code, not a value built from a request; per-request values belong
-- in the identifiers.
newtype Operation = Operation Text
  deriving (Eq, Ord, Show)

-- | Name an operation.
operation ∷ Text → Operation
operation = Operation

-- | The operation's name.
operationText ∷ Operation → Text
operationText (Operation name) = name
