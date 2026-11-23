-- | The ownership transaction's STM-free operations over its cells: committing a transaction, and allocating, reading and
-- replacing cells and reading capabilities and publications inside one.
--
-- This is Foundation's own adapter over the transaction's representation, reviewed as the issuer bridge's consumers
-- are: no type it exports mentions 'Control.Concurrent.STM.STM'. The public module ("Hetoimasia.Foundation.OwnerTx")
-- re-exports these operations with the cells' types abstractly and their safe observation and publication operations
-- from "Hetoimasia.Foundation.OwnerTx.Cells", and imports no protected module itself.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.OwnerTx.Operations
  ( OwnerTx
  , commit
  , newCell
  , readCell
  , writeCell
  , readTx
  , readPublication
  ) where

import Control.Concurrent.STM (atomically, newTVar, readTVar, writeTVar)
import Data.Word (Word64)
import Hetoimasia.Foundation.OwnerTx.Cells (OwnerCell (..), Publication (..), ReadOnly (..))
import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))

-- | Run one ownership transaction atomically. It never waits.
commit ∷ OwnerTx a → IO a
commit (OwnerTx transaction) = atomically transaction

-- | A fresh cell holding this value, forced to weak head normal form.
newCell ∷ a → OwnerTx (OwnerCell a)
newCell value = value `seq` OwnerTx (OwnerCell <$> newTVar value)

-- | The cell's value.
readCell ∷ OwnerCell a → OwnerTx a
readCell (OwnerCell cell) = OwnerTx (readTVar cell)

-- | Replace the cell's value by this one, forced to weak head normal form.
writeCell ∷ OwnerCell a → a → OwnerTx ()
writeCell (OwnerCell cell) value = value `seq` OwnerTx (writeTVar cell value)

-- | Read through the capability inside a commit.
readTx ∷ ReadOnly a → OwnerTx a
readTx (ReadOnly cell) = OwnerTx (readTVar cell)

-- | The published revision and value, read together inside a commit. It never waits.
readPublication ∷ Publication a → OwnerTx (Word64, a)
readPublication (Publication revision cell) = OwnerTx ((,) <$> readTVar revision <*> readTVar cell)
