-- | The arithmetic of the uncompiled-source bank (P-74 part 1): 16 MiB per VM, of which 1 MiB is
-- reserved for the active chain's next source.
--
-- Pure: the bank is two counters inside the coordinator's one state variable, so every charge and
-- every return is a step of a transaction. There are two classes of charge. An /ordinary/ charge
-- is the prefetch of a source nobody is waiting for; it may use only what is left once the reserve
-- is set aside, whatever the active class holds. An /active/ charge is the source the active
-- chain's next module needs and is the only thing that may use the reserve, so unrelated ready
-- prefetch filling the ordinary region cannot starve the chain. All arithmetic is checked: a
-- request is compared with the room left, so nothing is added that could wrap.
module Hetoimasia.LuaEngine.Modules.Bank
  ( Class (..)
  , BankLimits (..)
  , Charges (..)
  , noCharges
  , chargedTotal
  , mayCharge
  , charge
  , discharge
  , DischargeDefect (..)
  ) where

import Data.Word (Word64)

-- | Which region of the bank a charge is taken from.
data Class = Ordinary | Active
  deriving (Eq, Show)

-- | The bank's size and the part of it the active class alone may use.
data BankLimits = BankLimits
  { bankTotal ∷ !Word64
  , bankReserve ∷ !Word64
  }
  deriving (Eq, Show)

-- | What is charged in each region.
data Charges = Charges
  { chargedOrdinary ∷ !Word64
  , chargedActive ∷ !Word64
  }
  deriving (Eq, Show)

noCharges ∷ Charges
noCharges = Charges 0 0

-- | Both regions together.
chargedTotal ∷ Charges → Word64
chargedTotal (Charges ordinary active) = ordinary + active

-- | Whether this many bytes fit the class's region: the ordinary region is the bank less the
-- reserve, the active region is the reserve.
mayCharge ∷ BankLimits → Charges → Class → Word64 → Bool
mayCharge limits charges class' wanted = case class' of
  Ordinary → wanted <= region (bankTotal limits - bankReserve limits) (chargedOrdinary charges)
  Active → wanted <= region (bankReserve limits) (chargedActive charges)
  where
    region size used = if used > size then 0 else size - used

-- | Charge bytes to a class. The caller has asked 'mayCharge'.
charge ∷ Class → Word64 → Charges → Charges
charge Ordinary bytes charges = charges {chargedOrdinary = chargedOrdinary charges + bytes}
charge Active bytes charges = charges {chargedActive = chargedActive charges + bytes}

-- | Return bytes charged to a class, or say that more were returned than were charged.
discharge ∷ Class → Word64 → Charges → Either DischargeDefect Charges
discharge Ordinary bytes charges
  | bytes > chargedOrdinary charges = Left (DischargeDefect Ordinary bytes (chargedOrdinary charges))
  | otherwise = Right charges {chargedOrdinary = chargedOrdinary charges - bytes}
discharge Active bytes charges
  | bytes > chargedActive charges = Left (DischargeDefect Active bytes (chargedActive charges))
  | otherwise = Right charges {chargedActive = chargedActive charges - bytes}

-- | A return of bytes the region had not been charged: the class, what was returned and what the
-- region held. An engine defect.
data DischargeDefect = DischargeDefect !Class !Word64 !Word64
  deriving (Eq, Show)
