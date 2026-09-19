-- | Failure vocabulary: what failed, and whether anything can safely continue.
--
-- P-8 separates two questions this module keeps separate. A 'ReasonCode' says
-- what kind of thing went wrong, and 'RecoverySafety' says whether the
-- authoritative state it touched can still be relied on. Every failure record
-- in this model answers both, because D-7's policy turns on the second one
-- alone: a handled script fault whose effects were staged stays inside the
-- session as data, and an unsafe authoritative fault ends the session whatever
-- raised it.
--
-- What this module deliberately cannot express is a broken host or worker. An
-- exception escaping a VM worker is supervision's, not this model's, and a
-- model that could record one would invite a caller to handle it here instead.
-- The codes below name faults a session can observe and report about itself.
--
-- 'reasonDetail' is bounded evidence. It may quote a script's own error text,
-- which is untrusted, so 'failureReason' truncates it to 'reasonDetailBound'
-- characters on the way in. Bounding it here rather than at every call site is
-- what keeps an exit record's size a function of its task count.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( -- * Recovery
    RecoverySafety (..)

    -- * Reasons
  , ReasonCode (..)
  , FailureReason
  , reasonCode
  , reasonDetail
  , reasonDetailBound
  , failureReason
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | Whether the authoritative state a failure touched can still be relied on.
--
-- This is the whole of D-7's decision. 'RecoveryUnsafe' ends the session; there
-- is no third answer, and no operation in this model turns one into the other.
data RecoverySafety
  = -- | Nothing authoritative was left in an unknown state. The failure is
    -- data the session keeps reporting about.
    RecoverySafe
  | -- | Authoritative state may have been partially mutated. The session ends.
    RecoveryUnsafe
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What kind of fault a record is about.
data ReasonCode
  = -- | A script raised, or a behaviour reported its own failure.
    ScriptFault
  | -- | Authoritative state was mutated and its consistency is unknown.
    AuthoritativeFault
  | -- | A provider answered a request with a failure.
    ProviderFault
  | -- | The model refused something: a cap, a stale identity, a bad
    -- transition. Recoverable, returned to scripts as data.
    ValidationFault
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A bounded, copied description of one fault.
--
-- The constructor is not exported so the bound on 'reasonDetail' cannot be
-- bypassed by building one directly.
data FailureReason = FailureReason
  { reasonCode ∷ !ReasonCode
  , reasonDetail ∷ !Text
  }
  deriving (Eq, Ord, Show)

-- | The longest detail a reason retains.
reasonDetailBound ∷ Int
reasonDetailBound = 512

-- | Build a reason, truncating its detail to 'reasonDetailBound'.
failureReason ∷ ReasonCode → Text → FailureReason
failureReason code detail =
  FailureReason
    { reasonCode = code
    , reasonDetail = Text.take reasonDetailBound detail
    }
