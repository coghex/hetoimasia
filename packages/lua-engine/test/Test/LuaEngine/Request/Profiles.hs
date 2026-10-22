-- | Smaller profiles the request examples inject, every one built through the profile's own
-- validation: a value that is not positive, above its fixed ceiling or against a relation is
-- refused there, not here.
module Test.LuaEngine.Request.Profiles
  ( smaller
  , counts
  , bytesOf
  ) where

import Data.Word (Word64)
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
