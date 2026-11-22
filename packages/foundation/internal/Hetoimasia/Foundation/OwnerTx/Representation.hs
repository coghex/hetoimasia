-- | The representation behind "Hetoimasia.Foundation.OwnerTx": an ownership transaction is an 'STM' transaction.
--
-- This module is the one place that representation is visible. It is bridge-equivalent: importing it outside the
-- components and modules @tools/validation/owner_tx_issuers.json@ lists is refused by the repository's import guard
-- (@tools/owner-tx-guard@), exactly as importing the issuer bridge is. The cells a transaction reads and writes are
-- "Hetoimasia.Foundation.OwnerTx.Cells", which does not import this module; the STM-free operations over both are the
-- listed adapter "Hetoimasia.Foundation.OwnerTx.Operations"; the issuer bridge ("Hetoimasia.Foundation.OwnerTx.Issuer",
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
