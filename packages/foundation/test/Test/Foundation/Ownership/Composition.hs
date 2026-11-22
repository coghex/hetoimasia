{-# LANGUAGE MultiWayIf #-}

-- | A positive issuer composition through the bridge ("Hetoimasia.Foundation.OwnerTx.Issuer").
--
-- Two issuers keep their own 'STM' state, as an existing subsystem does: a ledger of reserved slots in a 'TVar', and a
-- register of named holders in a 'TVar' of its own. Each exports one concrete operation, embedded with 'fromIssuerSTM':
-- it reads only its own state and the values it is handed, validates before it writes, answers a refusal as data and
-- never waits or raises. A caller composes the two with an owner cell in one commit: the coupled writes land together,
-- and a refusal of either leaves all three as they were.
--
-- This module imports the bridge, so its component, @hetoimasia-foundation:test:foundation-tests@, depends on the
-- @owner-tx-issuer@ sublibrary, and @tools/validation/owner-tx-issuers.fields@ lists that component.
module Test.Foundation.Ownership.Composition (spec) where

import Control.Concurrent.STM (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.OwnerTx
import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM, modifyCell, stateCell)
import Test.Hspec

-- An issuer over existing STM: a ledger of free slots.
newtype Ledger = Ledger (TVar Int)

-- Reserve one slot: refused, writing nothing, when none is free.
reserveSlot ∷ Ledger → OwnerTx (Either String ())
reserveSlot (Ledger free) =
  fromIssuerSTM $ do
    available ← readTVar free
    if available <= 0 then pure (Left "no slot is free") else Right () <$ writeTVar free (available - 1)

-- A second issuer over existing STM: holders by name.
newtype Register = Register (TVar (Map String Int))

-- Record a holder: refused, writing nothing, when the name is taken.
recordHolder ∷ Register → String → Int → OwnerTx (Either String ())
recordHolder (Register holders) name value =
  fromIssuerSTM $ do
    held ← readTVar holders
    if Map.member name held then pure (Left (name <> " is already held")) else Right () <$ writeTVar holders (Map.insert name value held)

-- The coupled transition: every guard before any write, then the two issuers' operations and the owner's count.
holdOne ∷ Ledger → Register → OwnerCell Int → String → OwnerTx (Either String ())
holdOne ledger@(Ledger free) register@(Register holders) count name = do
  available ← fromIssuerSTM (readTVar free)
  taken ← fromIssuerSTM (Map.member name <$> readTVar holders)
  if
    | available <= 0 → pure (Left "no slot is free")
    | taken → pure (Left (name <> " is already held"))
    | otherwise → do
        reserved ← reserveSlot ledger
        recorded ← recordHolder register name available
        modifyCell count (+ 1)
        pure (reserved >> recorded)

spec ∷ Spec
spec = describe "the issuer bridge" $ do
  it "commits an issuer composition over existing STM in one commit: the coupled writes land together, and a refusal leaves every one as it was" $ do
    ledger@(Ledger free) ← Ledger <$> newTVarIO 1
    register@(Register holders) ← Register <$> newTVarIO Map.empty
    count ← newCellIO (0 ∷ Int)
    commit (holdOne ledger register count "first") `shouldReturn` Right ()
    (,,) <$> readTVarIO free <*> readTVarIO holders <*> commit (readCell count) `shouldReturn` (0, Map.singleton "first" 1, 1)
    -- no slot is free: refused as data, and nothing of the three moved
    commit (holdOne ledger register count "second") `shouldReturn` Left "no slot is free"
    (,,) <$> readTVarIO free <*> readTVarIO holders <*> commit (readCell count) `shouldReturn` (0, Map.singleton "first" 1, 1)

  it "updates a cell by an issuer's own function, answering what the function decided" $ do
    cell ← newCellIO (5 ∷ Int)
    commit (stateCell cell (\n → (n * 10, n + 1))) `shouldReturn` 50
    commit (readCell cell) `shouldReturn` 6
