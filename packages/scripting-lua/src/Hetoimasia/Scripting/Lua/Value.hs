-- | The values that cross between an application and its Lua scripts, the
-- schemas they are checked against, and the bounds on both.
--
-- A crossing is a /bounded copy/. Nil, booleans, 64-bit integers, floats, byte
-- strings, UTF-8 text, lists, records and application capabilities cross, and
-- nothing else: a function, a coroutine, a userdata that is not a capability,
-- a table with a cycle or a metatable is refused with a typed reason, and no
-- metamethod is ever consulted. Integers keep their exact value over the whole
-- 64-bit range and floats stay floats; a byte string and a text are different
-- things, and invalid UTF-8 is refused where text is declared.
--
-- = Rules
--
-- * An integer schema ('SInteger') accepts integers and refuses every float,
--   integral ones included. A float schema ('SFloat') accepts floats and refuses
--   integers. 'SNumber' accepts either and keeps which it was.
-- * A list is a table whose keys are exactly @1..n@. A record is a table whose
--   keys are exactly its declared field names; an 'SOptional' field may be
--   absent, and a field it does not declare is refused. A table that carries a
--   metatable is refused outright.
-- * Arity is exact: a call with more or fewer values than declared is refused.
-- * The reader stops at the first limit it reaches, so the work it does is
--   bounded by the limits and not by the input.
--
-- = Limits
--
-- 'ValueLimits' bounds one crossing -- all the arguments of a call, or all its
-- results -- by bytes, depth and elements. The default is 65,536 bytes, depth 8
-- and 4,096 elements, and a configuration may raise each to at most 16 MiB,
-- depth 64 and 1,048,576 elements ('valueLimitMaxima'). Bytes are the size of
-- the copy's encoding: 1 for nil and a boolean, 9 for a number, 5 and the length
-- for a string, 21 for a capability, and for a table 5 and the size of every key
-- and value. Depth counts nested tables, a flat table being 1. Elements count
-- every value in the copy, nested ones included and table keys not.
--
-- A capability is an opaque identity the application hands its scripts: a type
-- it declared and a key within the type. See "Hetoimasia.Scripting.Lua.Registration".
module Hetoimasia.Scripting.Lua.Value
  ( -- * Values
    Value (..)
  , Capability
  , capability
  , capabilityTypeName
  , capabilityKey
  , VmIdentity

    -- * Schemas
  , Schema (..)

    -- * Limits
  , ValueLimits
  , limitBytes
  , limitDepth
  , limitElements
  , defaultValueLimits
  , valueLimitMaxima
  , valueLimits
  , LimitsRefusal (..)

    -- * Why a value is refused
  , Side (..)
  , PathStep (..)
  , ValueRule (..)
  , ValueRefusal (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Internal.Value
  ( Capability (capabilityKey, capabilityTypeName)
  , LimitsRefusal (..)
  , PathStep (..)
  , Schema (..)
  , Side (..)
  , Value (..)
  , ValueLimits
  , ValueRefusal (..)
  , ValueRule (..)
  , VmIdentity
  , defaultValueLimits
  , valueLimitMaxima
  , valueLimits
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Value as Internal
import Data.Text (Text)

-- | A capability of the application type of this name, with this key. The VM
-- that hands it to a script stamps it as its own; a script cannot make one.
capability ∷ Text → Word64 → Capability
capability name key = Internal.Capability name key Nothing

-- The limits are read with ordinary functions, and 'ValueLimits' has no
-- constructor here: a limit configuration comes from 'valueLimits', which checks
-- every bound, or from 'defaultValueLimits'. Exporting the record labels would
-- allow an update that skipped the check.

-- | The most bytes one crossing may copy.
limitBytes ∷ ValueLimits → Int
limitBytes = Internal.limitBytes

-- | The deepest nesting of tables one crossing may have.
limitDepth ∷ ValueLimits → Int
limitDepth = Internal.limitDepth

-- | The most values one crossing may copy.
limitElements ∷ ValueLimits → Int
limitElements = Internal.limitElements
