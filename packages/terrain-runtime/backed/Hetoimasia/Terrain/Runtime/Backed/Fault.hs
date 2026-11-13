-- | The expected storage outcomes of the backed terrain service, as values.
--
-- Requirement 8 of #665 names seven typed Haskell outcomes (@source_complexity@,
-- @storage_unsupported@, @reservation_failed@, @storage_full@, @storage_io@,
-- @storage_integrity@, @storage_size_not_increased@). Each carries the bounded
-- attribution a diagnosis needs, never a path, a descriptor or a page. Their Lua
-- spelling is TRA-23's: 'faultCode' only names the stable code design P-15 gives.
--
-- They are /domain/ outcomes. An invariant, accounting, worker, provider or cleanup
-- defect is none of them: it is a supervised host failure
-- ('Hetoimasia.Terrain.Runtime.Backed.Backend.HandleDefect') and never
-- becomes a request's result.
module Hetoimasia.Terrain.Runtime.Backed.Fault
  ( StorageFault (..)
  , FullWhy (..)
  , IntegritySource (..)
  , faultCode
  , faultCondition
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
  ( IntegrityFailure
  , IoFailure
  , ReservationFailure
  , UnsupportedWhy
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageError, PageNo, TreeId)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (IntegrityWhy)

-- | An expected storage outcome.
data StorageFault
  = -- | A valid source whose compiled connectivity needs more than a bound: the
    -- resource's name and the figure needed and the limit. Never a partial arena
    -- and never a dense fallback.
    FaultComplexity !Text !Word64 !Word64
  | -- | The filesystem or the native allocation is outside the contract.
    FaultUnsupported !UnsupportedWhy
  | -- | A supported reservation could not be obtained.
    FaultReservation !ReservationFailure
  | -- | The allowance cannot take another transaction. This is the pause, not a
    -- permanent busy and not a loss of old changes.
    FaultFull !FullWhy
  | -- | A transfer or setup error, with its operation, page, offset and bytes.
    FaultIo !IoFailure
  | -- | A page that is not the authoritative page it should be: never absent
    -- history, air or the regenerated source.
    FaultIntegrity !IntegritySource
  | -- | A growth to a size that is not larger: the committed allowance and the one
    -- asked for.
    FaultSizeNotIncreased !Word64 !Word64
  deriving stock (Eq, Show)

-- | Why a transaction could not be given the room it needs.
data FullWhy
  = -- | Free allowance short of the transaction beside the protected reclamation
    -- reserve: pages needed, pages available, pages protected.
    AllowanceExhausted !Word64 !Word64 !Word64
  | -- | A tree would pass the format's last level.
    TreeBeyondFormat !TreeId
  deriving stock (Eq, Show)

-- | Where an integrity failure was found.
data IntegritySource
  = -- | A page the backend read back and refused.
    FromBackend !IntegrityFailure
  | -- | The store's own planner found its records contradict each other.
    FromStore !IntegrityWhy
  | -- | A page the backend returned and the window refused.
    FromWindow !PageNo !PageError
  deriving stock (Eq, Show)

-- | The stable code of a fault (design P-15's names).
faultCode ∷ StorageFault → Text
faultCode = \case
  FaultComplexity {} → "source_complexity"
  FaultUnsupported _ → "storage_unsupported"
  FaultReservation _ → "reservation_failed"
  FaultFull _ → "storage_full"
  FaultIo _ → "storage_io"
  FaultIntegrity _ → "storage_integrity"
  FaultSizeNotIncreased _ _ → "storage_size_not_increased"

-- | The pause a fault puts an arena in, when it is one. A complexity refusal, an
-- unsupported or failed reservation and a growth that is not larger refuse a
-- request or an open and pause nothing.
faultCondition ∷ StorageFault → Maybe Condition
faultCondition = \case
  FaultComplexity {} → Nothing
  FaultUnsupported _ → Nothing
  FaultReservation _ → Nothing
  FaultFull _ → Just CondCapacity
  FaultIo _ → Just CondIo
  FaultIntegrity _ → Just CondIntegrity
  FaultSizeNotIncreased _ _ → Nothing
