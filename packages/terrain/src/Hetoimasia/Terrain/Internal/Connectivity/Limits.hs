-- | Validated limits for compiling source connectivity.
--
-- The constructor of 'ConnectivityLimits' and its fields are private: the only
-- ways to a value are 'mkConnectivityLimits' and 'defaultConnectivityLimits', so
-- a figure the compiler's arithmetic cannot represent never reaches it and a
-- client cannot rewrite a validated figure with record-update syntax. This is
-- the convention of "Hetoimasia.Terrain.Residency": a plain specification goes
-- through one checked constructor, a figure outside its documented range is
-- refused by field, and nothing is clamped.
--
-- State, ownership and lifetime: none. Limits are immutable values.
module Hetoimasia.Terrain.Internal.Connectivity.Limits
  ( LimitsSpec (..)
  , LimitField (..)
  , LimitError (..)
  , ConnectivityLimits
  , mkConnectivityLimits
  , defaultConnectivityLimits
  , limitResultBytes
  , limitPeakBytes
  , limitNodes
  , limitRelations
  , limitWorkSteps
  , limitQuantumSteps
  , byteCeiling
  , countCeiling
  , workCeiling
  , quantumCeiling
  ) where

-- | Unvalidated limits, as a caller states them. Every field is an 'Integer' so
-- that an unrepresentable figure is refused by name instead of wrapping.
data LimitsSpec = LimitsSpec
  { specResultBytes ∷ !Integer
  -- ^ Accounted bytes of the complete compiled result.
  , specPeakBytes ∷ !Integer
  -- ^ Accounted bytes of the result plus every temporary, at any moment.
  , specNodes ∷ !Integer
  -- ^ Structural nodes: the uniform boxes that hold empty space.
  , specRelations ∷ !Integer
  -- ^ Portal relations between neighbouring nodes.
  , specWorkSteps ∷ !Integer
  -- ^ Counted primitive steps over the whole compilation.
  , specQuantumSteps ∷ !Integer
  -- ^ The most steps one resume may take.
  }
  deriving stock (Eq, Show)

-- | The field a refusal names.
data LimitField
  = FieldResultBytes
  | FieldPeakBytes
  | FieldNodes
  | FieldRelations
  | FieldWorkSteps
  | FieldQuantumSteps
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a limit configuration was refused. A refusal here is a configuration
-- error, never a @source_complexity@ outcome of a compilation.
data LimitError
  = -- | The figure is zero or negative: nothing could fit it.
    LimitNotPositive !LimitField !Integer
  | -- | The figure is above the field's ceiling, so checked arithmetic could not
    -- stay exact: the field, the figure and the ceiling.
    LimitUnrepresentable !LimitField !Integer !Integer
  | -- | The peak is below the result: the peak includes the result, so the
    -- configuration could never be satisfied. The peak and the result figures.
    PeakBelowResult !Integer !Integer
  deriving stock (Eq, Show)

-- | A validated set of limits.
data ConnectivityLimits = ConnectivityLimits
  { lResult ∷ !Int
  , lPeak ∷ !Int
  , lNodes ∷ !Int
  , lRelations ∷ !Int
  , lWork ∷ !Int
  , lQuantum ∷ !Int
  }
  deriving stock (Eq, Show)

-- | The largest byte limit, @2^40@.
byteCeiling ∷ Integer
byteCeiling = 2 ^ (40 ∷ Int)

-- | The largest node or relation limit, @2^32@.
countCeiling ∷ Integer
countCeiling = 2 ^ (32 ∷ Int)

-- | The largest total-work limit, @2^48@.
workCeiling ∷ Integer
workCeiling = 2 ^ (48 ∷ Int)

-- | The most steps one resume may be configured to take, 1,024: the approved
-- service quantum. A configuration may set it lower for a test but never above.
quantumCeiling ∷ Integer
quantumCeiling = 1024

-- | The initial approved bounds: 16 MiB of result, 48 MiB of peak, 65,536
-- nodes, 262,144 relations, 8,388,608 steps and 1,024 steps per quantum. A MiB
-- is @2^20@ bytes.
defaultConnectivityLimits ∷ ConnectivityLimits
defaultConnectivityLimits =
  ConnectivityLimits
    { lResult = 16 * 1024 * 1024
    , lPeak = 48 * 1024 * 1024
    , lNodes = 65536
    , lRelations = 262144
    , lWork = 8388608
    , lQuantum = 1024
    }

-- | Validate a specification. The first refused field, in declaration order, is
-- reported, then an inconsistent peak. The admissible ranges are: each byte
-- figure in @[1, 2^40]@, nodes and relations in @[1, 2^32]@, work in
-- @[1, 2^48]@ and the quantum in @[1, 1024]@; the peak must be at least the
-- result.
mkConnectivityLimits ∷ LimitsSpec → Either LimitError ConnectivityLimits
mkConnectivityLimits spec = do
  result ← check FieldResultBytes byteCeiling (specResultBytes spec)
  peak ← check FieldPeakBytes byteCeiling (specPeakBytes spec)
  nodes ← check FieldNodes countCeiling (specNodes spec)
  relations ← check FieldRelations countCeiling (specRelations spec)
  work ← check FieldWorkSteps workCeiling (specWorkSteps spec)
  quantum ← check FieldQuantumSteps quantumCeiling (specQuantumSteps spec)
  if peak < result then Left (PeakBelowResult (specPeakBytes spec) (specResultBytes spec)) else pure ()
  pure (ConnectivityLimits result peak nodes relations work quantum)
  where
    check field top n
      | n <= 0 = Left (LimitNotPositive field n)
      | n > top = Left (LimitUnrepresentable field n top)
      | otherwise = Right (fromInteger n)

-- | The result-byte limit.
limitResultBytes ∷ ConnectivityLimits → Int
limitResultBytes = lResult

-- | The peak-byte limit.
limitPeakBytes ∷ ConnectivityLimits → Int
limitPeakBytes = lPeak

-- | The structural-node limit.
limitNodes ∷ ConnectivityLimits → Int
limitNodes = lNodes

-- | The portal-relation limit.
limitRelations ∷ ConnectivityLimits → Int
limitRelations = lRelations

-- | The total-work limit.
limitWorkSteps ∷ ConnectivityLimits → Int
limitWorkSteps = lWork

-- | The per-resume step limit.
limitQuantumSteps ∷ ConnectivityLimits → Int
limitQuantumSteps = lQuantum
