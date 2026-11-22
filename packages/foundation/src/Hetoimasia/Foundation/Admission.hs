-- | An admission its owner opens once and closes once, and the read-only token
-- others hold for it.
--
-- __Ownership.__ The owner holds the 'Admission', the only capability that
-- closes it; a closed admission never reopens, so a reopened service is a new
-- admission. Others hold an 'AdmissionToken': they can read whether it is open
-- and compare it with another by identity, inside their own transactions, and
-- nothing more. A token read is a read of the owner's cell, never code the
-- owner or a holder supplies, so a commit may verify one.
module Hetoimasia.Foundation.Admission
  ( Admission
  , newAdmission
  , newAdmissionIO
  , closeAdmission
  , admissionToken
  , AdmissionToken
  , tokenOpen
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, newTVarIO, readTVar, writeTVar)

-- | The owner's capability over one admission.
newtype Admission = Admission (TVar Bool)

-- | A read-only view of one admission, equal only to a token of the same one.
newtype AdmissionToken = AdmissionToken (TVar Bool)
  deriving (Eq)

-- | An open admission.
newAdmission ∷ STM Admission
newAdmission = Admission <$> newTVar True

-- | An open admission.
newAdmissionIO ∷ IO Admission
newAdmissionIO = Admission <$> newTVarIO True

-- | Close the admission, for good.
closeAdmission ∷ Admission → STM ()
closeAdmission (Admission cell) = writeTVar cell False

-- | The read-only token of an admission.
admissionToken ∷ Admission → AdmissionToken
admissionToken (Admission cell) = AdmissionToken cell

-- | Whether the admission is still open.
tokenOpen ∷ AdmissionToken → STM Bool
tokenOpen (AdmissionToken cell) = readTVar cell
