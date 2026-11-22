-- | The representation behind "Hetoimasia.Foundation.OwnerTx": an ownership transaction is an 'STM' transaction.
--
-- This module is the one place that representation is visible. It is bridge-equivalent: it stays in this package's
-- private library, the repository's dependency guard (@tools/owner-tx-guard@) refuses a Cabal re-export or mixin of it
-- and a declaration of it anywhere else, and review checks its consumers as it does the issuer bridge's. The cells a transaction reads and writes are
-- "Hetoimasia.Foundation.OwnerTx.Cells", which does not import this module; the STM-free operations over both are the
-- private adapter "Hetoimasia.Foundation.OwnerTx.Operations"; the issuer bridge ("Hetoimasia.Foundation.OwnerTx.Issuer",
-- in the @owner-tx-issuer@ sublibrary) exports the one embedding of an issuer's own 'STM'.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.OwnerTx.Representation
  ( OwnerTx (..)
  ) where

import Control.Concurrent.STM (STM)

-- | One ownership transaction.
newtype OwnerTx a = OwnerTx (STM a)
  deriving newtype (Functor, Applicative, Monad)
