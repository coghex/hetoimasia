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
-- characters on the way in and copies what survives away from whatever it was
-- taken from. Bounding it here rather than at every call site is what keeps an
-- exit record's size a function of its task count.
--
-- Truncating alone would not do that. A 'Data.Text.Text' is a slice of a
-- shared array, so a 512-character prefix of a megabyte of script output keeps
-- the megabyte alive for as long as the reason is held; the retained bytes
-- would be a function of what a script happened to say rather than of the
-- bound. The copy is what makes the bound a bound on memory, and it is made
-- for every detail, not only an oversized one: a detail already within the
-- bound is just as likely to be a small slice of a large allocation.
--
-- The other half is that 'failureReason' is the only way to build one.
-- 'reasonCode' and 'reasonDetail' read a 'FailureReason' but are not its
-- record fields, so there is no field name for record-update syntax to write
-- through, and the constructor is not exported either.
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
-- Neither the constructor nor a record field is exported, so 'failureReason'
-- is the only way to obtain one and the bound on 'reasonDetail' cannot be
-- bypassed — not by building a reason directly, and not by updating one
-- through a field the type does not have.
data FailureReason = FailureReason !ReasonCode !Text
  deriving (Eq, Ord)

-- | Rendered as the two accessors that read it.
--
-- Written out rather than derived because the representation above is
-- positional and a derived instance would render it that way. What a reason
-- shows is part of what this module promised before the bound was repaired,
-- and it names the accessors a reader has, which the constructor's arguments
-- do not.
instance Show FailureReason where
  showsPrec precedence (FailureReason code detail) =
    showParen (precedence >= 11) $
      showString "FailureReason {reasonCode = "
        . shows code
        . showString ", reasonDetail = "
        . shows detail
        . showString "}"

-- | What kind of fault the reason is about.
reasonCode ∷ FailureReason → ReasonCode
reasonCode (FailureReason code _) = code

-- | The fault's evidence: at most 'reasonDetailBound' characters, stored in
-- an array of its own.
reasonDetail ∷ FailureReason → Text
reasonDetail (FailureReason _ detail) = detail

-- | The longest detail a reason retains.
reasonDetailBound ∷ Int
reasonDetailBound = 512

-- | Build a reason, truncating its detail to 'reasonDetailBound' characters
-- and copying it out of the array it came from.
--
-- 'Text.take' counts characters, so a multibyte detail is cut between code
-- points rather than inside one. 'Text.copy' is what bounds the storage: the
-- result of 'Text.take' still points into its source's array, and for a detail
-- within the bound 'Text.take' returns that source unchanged.
failureReason ∷ ReasonCode → Text → FailureReason
failureReason code detail =
  FailureReason code (Text.copy (Text.take reasonDetailBound detail))
