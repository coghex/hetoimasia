-- | The representation behind "Hetoimasia.Foundation.OwnerTx": an ownership transaction is an 'STM' transaction, and an
-- owner cell, a read-only capability and a publication are its variables.
--
-- This module is the one place the representation is visible. It is bridge-equivalent: importing it outside the
-- components and modules @tools/validation/owner_tx_issuers.json@ lists is refused by the repository's import guard
-- (@tools/validation/owner_tx_guard.py@), exactly as importing the issuer bridge is. The public module re-exports the
-- types abstractly; the issuer bridge ("Hetoimasia.Foundation.OwnerTx.Issuer", in the @owner-tx-issuer@ sublibrary)
-- exports the one embedding of an issuer's own 'STM'.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.OwnerTx.Representation
  ( OwnerTx (..)
  , OwnerCell (..)
  , ReadOnly (..)
  , Publisher (..)
  , Publication (..)
  ) where

import Control.Concurrent.STM (STM, TVar)
import Data.Word (Word64)

-- | One ownership transaction.
newtype OwnerTx a = OwnerTx (STM a)
  deriving newtype (Functor, Applicative, Monad)

-- | A cell its issuer owns.
newtype OwnerCell a = OwnerCell (TVar a)
  deriving newtype (Eq)

-- | A capability to read one owner's cell.
newtype ReadOnly a = ReadOnly (TVar a)
  deriving newtype (Eq)

-- | The source's capability over a published fact: its revision and its value, written together.
data Publisher a = Publisher !(TVar Word64) !(TVar a)

-- | What readers of a published fact hold.
data Publication a = Publication !(TVar Word64) !(TVar a)

instance Eq (Publication a) where
  Publication left _ == Publication right _ = left == right
