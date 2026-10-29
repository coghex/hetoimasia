-- | Smaller profiles the request examples inject, every one built through the profile's own
-- validation: a value that is not positive, above its fixed ceiling or against a relation is
-- refused there, not here.
module Test.LuaEngine.Request.Profiles
  ( smaller
  , counts
  , bytesOf
  , smallestLegalSpec
  , smallestLegalProfile
  , copiedLeast
  ) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Time (DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Profile

-- | The fixed profile with these counts and byte limits changed, validated.
smaller ∷ [(CountLimit, Word64)] → [(ByteLimit, Word64)] → Profile
smaller countChanges byteChanges = case validateProfile spec of
  Right profile → profile
  Left refused → error ("the injected profile is refused: " <> show refused)
  where
    base = profileSpec fixedM1Profile
    spec =
      base
        { specCounts = \limit → maybe (specCounts base limit) Count (lookup limit countChanges)
        , specBytes = \limit → maybe (specBytes base limit) Bytes (lookup limit byteChanges)
        }

-- | Only counts changed.
counts ∷ [(CountLimit, Word64)] → Profile
counts changes = smaller changes []

-- | Only byte limits changed.
bytesOf ∷ [(ByteLimit, Word64)] → Profile
bytesOf = smaller []

-- | Every limit at the least validation allows it ('minimumBytes', 'minimumCount', 'minimumDuration'): the smallest legal
-- profile. The minimum of a limit that depends on others (the print bound on the identity bound, the copied value's on
-- both) is read from this specification itself.
smallestLegalSpec ∷ ProfileSpec
smallestLegalSpec =
  ProfileSpec
    { specBytes = \limit → Bytes (minimumBytes smallestLegalSpec limit)
    , specCounts = \limit → Count (minimumCount smallestLegalSpec limit)
    , specDurations = \limit → case durationFromNanoseconds RequirePositive (toInteger (minimumDuration smallestLegalSpec limit)) of
        Right duration → duration
        Left refused → error ("the least duration is not a duration: " <> show refused)
    }

-- | The least the copied-value bound may be for a profile that keeps the fixed profile's failure bounds, given its
-- bounds on an identity and on one @print@ or @warn@: the status record the failure bounds admit is what dominates.
copiedLeast ∷ Int → Int → Word64
copiedLeast idBytes printBytes =
  fromIntegral (minimumCopiedValueBytes idBytes printBytes (failureTextBytes (bound MessageBytes) (bound TracebackBytes) idBytes (bound PathBytes) (bound RoleFailureRecordBytes)))
  where
    bound limit = let Bytes n = bytesLimit fixedM1Profile limit in fromIntegral n

-- | The smallest legal profile, validated.
smallestLegalProfile ∷ Profile
smallestLegalProfile = case validateProfile smallestLegalSpec of
  Right profile → profile
  Left refused → error ("the smallest legal profile is refused: " <> show refused)
