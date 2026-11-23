-- | The issuer bridge: how an issuer embeds a concrete operation over its own 'STM' and its existing state into an
-- ownership transaction ("Hetoimasia.Foundation.OwnerTx").
--
-- __Who may depend on it.__ Only the stanzas @tools/validation/owner-tx-issuers.fields@ lists. The repository's textual
-- guard (@tools/owner-tx-guard@) refuses this sublibrary's name (@owner-tx-issuer@), this module's or the
-- representation's in any other stanza, or at the top level, of any package description or project file. Issuer
-- review checks what a listed stanza's component imports and exports: an issuer
-- exports concrete operations on opaque handles built here, never the bridge itself, no conversion between a caller's
-- 'STM' and a transaction, and no instance on 'STM' or the protected Foundation types.
--
-- __What an embedded path must do.__ Every 'STM' action an issuer embeds reads only issuer-controlled inputs (never a
-- caller's transaction, callback or reader), validates every guard before its first write, answers a refusal as data,
-- and finishes without waiting and without raising. The compiler cannot see inside an embedded action, so review and
-- the issuer's outcome tests check those properties, its callees included.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.OwnerTx.Issuer
  ( -- * The embedding
    fromIssuerSTM

    -- * Issuer-side cell updates
  , modifyCell
  , stateCell
  ) where

import Control.Concurrent.STM (STM, readTVar, writeTVar)
import Hetoimasia.Foundation.OwnerTx.Cells (OwnerCell (..))
import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))

-- | Embed one of the issuer's own concrete operations. It must read only issuer-controlled inputs, validate before
-- writing, answer refusals as data, and finish without waiting or raising.
fromIssuerSTM ∷ STM a → OwnerTx a
fromIssuerSTM = OwnerTx

-- | Replace a cell's value by a function of it, forced to weak head normal form. The function is the issuer's own.
modifyCell ∷ OwnerCell a → (a → a) → OwnerTx ()
modifyCell (OwnerCell cell) change = OwnerTx (readTVar cell >>= \value → let next = change value in next `seq` writeTVar cell next)

-- | Replace a cell's value by a function of it that also answers, the new value forced to weak head normal form. The
-- function is the issuer's own.
stateCell ∷ OwnerCell a → (a → (b, a)) → OwnerTx b
stateCell (OwnerCell cell) change =
  OwnerTx $ do
    (answer, next) ← change <$> readTVar cell
    next `seq` writeTVar cell next
    pure answer
