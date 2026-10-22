-- | The fixed M1 profile of limits, and the validated smaller profiles tests
-- inject.
--
-- __Contract.__ 'fixedM1Profile' holds the production values, defined once and
-- selected by the assembly; nothing reads them from Lua, a manifest, the
-- environment or the command line, and there is no tuning API. A test builds a
-- smaller profile by changing a copy of the fixed specification
-- ('profileSpec' of 'fixedM1Profile') and passing it to 'validateProfile',
-- which refuses a value that is not positive, a value above the fixed ceiling
-- (so a profile can only shrink), a derived product that does not fit 64 bits,
-- and a relation that does not hold. Nothing is clamped.
--
-- Every limit is one constructor of 'ByteLimit', 'CountLimit' or
-- 'DurationLimit'; read it with 'bytesLimit', 'countLimit' or 'durationLimit'.
-- The unit is the type. KiB, MiB and GiB are powers of 1024 ('kibibytes',
-- 'mebibytes', 'gibibytes' construct them with a checked product).
--
-- __Derived, not stored.__ 'pngOutputBytes' is four bytes of RGBA8 for each
-- pixel of the limit, and 'sceneElementBound' follows from the sprite limit.
-- The six adopted scene revisions per target are not a limit here: the
-- profile records the two frame slots per window, and the graphics composition
-- derives six from them (@2 * (slots + 1)@ in the GPU package, which this
-- package never imports).
--
-- __Not enforced here.__ These are configuration values. Live admission and
-- retirement accounting, codec allocation safety, GPU availability, Float32
-- geometry, elapsed conversion and scheduling belong to the slices that own
-- them, and the limits bound engine service payloads, not Lua or process
-- memory. The native budget values stay CPU data until the graphics
-- composition maps them into the backend's validated model.
module Hetoimasia.LuaEngine.Profile
  ( -- * The profile
    Profile
  , fixedM1Profile
  , validateProfile
  , ProfileError (..)
  , Relation (..)
  , DerivedValue (..)

    -- * Specifications
  , ProfileSpec (..)
  , profileSpec

    -- * Limits
  , ByteLimit (..)
  , CountLimit (..)
  , DurationLimit (..)
  , AnyLimit (..)
  , bytesLimit
  , countLimit
  , durationLimit

    -- * Units
  , Bytes (..)
  , Count (..)
  , kibibytes
  , mebibytes
  , gibibytes

    -- * Derived values
  , pngOutputBytes
  , rgba8BytesPerPixel
  , sceneElementBound
  , sceneFixedElements
  , sceneElementsPerSprite
  ) where

import Hetoimasia.LuaEngine.Profile.Limits
import Hetoimasia.LuaEngine.Profile.Validate
