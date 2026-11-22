-- | The issuer bridge: how an issuer embeds a concrete operation over its own 'STM' and its existing state into an
-- ownership transaction ("Hetoimasia.Foundation.OwnerTx").
--
-- __Who may import it.__ Only the components and modules @tools/validation/owner_tx_issuers.json@ lists. The
-- repository's import guard (@tools/owner-tx-guard@) refuses any other importer, any unlisted component
-- that depends on this sublibrary (@hetoimasia-foundation:owner-tx-issuer@), and any re-export of this module, of
-- 'fromIssuerSTM' or of the representation, in a listed module too. An issuer exports concrete operations on opaque
-- handles built here, never the bridge itself.
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
