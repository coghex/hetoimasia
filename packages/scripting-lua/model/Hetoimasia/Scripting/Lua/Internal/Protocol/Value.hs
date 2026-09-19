-- | The application values this model carries without inspecting.
--
-- Every record here is parameterised by one value type @v@. A task's
-- application state or cursor /is/ a @v@, a request settles with one, and an
-- event delivers one. The model never constrains @v@ and never pattern matches
-- on it: that is how \"opaque value the model never inspects\" is stated in a
-- way the compiler checks, rather than promised in a comment.
--
-- A 'Payload' is the one place a size appears, because P-5 bounds payload size
-- and a bound needs a number. The number is the caller's declaration, recorded
-- beside the value; the model compares it against the cap and still never looks
-- at the value. A caller that declares a size its value does not have has
-- misreported its own data, which no bound can detect and none of this model's
-- invariants depend on.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Value
  ( Payload (..)
  , payloadWithin
  ) where

-- | An application value with the size its producer declared.
data Payload v = Payload
  { payloadBytes ∷ !Int
  , payloadValue ∷ v
  }
  deriving (Eq, Show)

-- | Whether a payload's declared size is within a cap.
--
-- A negative declared size is outside every cap: it is not a small payload.
payloadWithin ∷ Int → Payload v → Bool
payloadWithin cap message = payloadBytes message >= 0 && payloadBytes message <= cap
